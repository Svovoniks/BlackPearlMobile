import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../protocol/ice_servers.dart';
import '../protocol/pair_link.dart';
import '../protocol/remote_state.dart';
import '../protocol/signing.dart';
import '../storage/paired_pcs.dart';
import 'media_channel.dart';
import 'remote_link.dart';
import 'transport.dart';

/// Whom to connect to, and with which key.
@immutable
class LinkTarget {
  const LinkTarget({required this.pcId, required this.pcName, required this.server, required this.phone, required this.keyHex, this.lan});

  factory LinkTarget.paired(PairedPc pc) =>
      LinkTarget(pcId: pc.pcId, pcName: pc.name, server: pc.server, phone: pc.phoneId, keyHex: pc.secret, lan: pc.lan);

  factory LinkTarget.pairing(PairLink link) =>
      LinkTarget(pcId: link.pcId, pcName: link.name, server: link.server, phone: 'pair', keyHex: link.code);

  final String pcId;
  final String pcName;
  final String server;

  /// The phone id signals are sent under: `pair` while pairing with a code.
  final String phone;
  final String keyHex;

  /// Where the PC listens on its home network, for when the room server can't introduce the two. Null: unknown.
  final LanEndpoints? lan;

  bool get isPairing => phone == 'pair';

  LinkTarget withLan(LanEndpoints? lan) => LinkTarget(pcId: pcId, pcName: pcName, server: server, phone: phone, keyHex: keyHex, lan: lan);
}

/// A home-network socket that has greeted the phone as its PC's, ready to take over from the room server's.
class _LanLink {
  _LanLink(this.socket, this.subscription, this.welcome);
  final SignalingSocket socket;
  final StreamSubscription<String> subscription;

  /// The `remote-welcome`'s data.
  final String welcome;

  void discard() {
    unawaited(subscription.cancel());
    unawaited(socket.close());
  }
}

/// The device and app the phone introduces itself as.
@immutable
class PhoneIdentity {
  const PhoneIdentity({required this.appVersion, required this.device});
  final String appVersion;
  final String device;
}

/// One phone's link to one PC, following PHONE-REMOTE.md: the room server's `/remote` socket introduces the phone,
/// signed signals set up a WebRTC data channel, and commands and state travel on that channel.
///
/// It keeps trying: after a drop it reconnects with backoff, and [retryNow] (for the app returning to the foreground
/// or the network changing) starts over at once.
class RemoteConnection extends RemoteLink {
  RemoteConnection({
    required LinkTarget target,
    required this.identity,
    required this.connectSocket,
    required this.createPeer,
    this.onPaired,
    this.onPcName,
    Random? random,
    this.answerTimeout = const Duration(seconds: 20),
    this.helloTimeout = const Duration(seconds: 10),
    this.pairTimeout = const Duration(seconds: 20),
    this.pingInterval = const Duration(seconds: 25),
    this.lanTimeout = const Duration(seconds: 4),
    this.lanRetryInterval = const Duration(seconds: 20),
  }) : _target = target,
       _random = random ?? Random.secure(),
       _pcName = target.pcName;

  final PhoneIdentity identity;
  final SocketConnector connectSocket;
  final PeerFactory createPeer;

  /// Called once the PC has paired this phone; the caller stores it. Later attempts use the new credentials.
  final void Function(PairedPc pc)? onPaired;

  /// Called when the PC reports a different name than the one stored.
  final void Function(String pcId, String name)? onPcName;

  final Duration answerTimeout;
  final Duration helloTimeout;

  /// How long the PC has to answer `pair` with `paired` or an error.
  final Duration pairTimeout;
  final Duration pingInterval;

  /// How long the PC's home-network addresses have, together, to greet the phone.
  final Duration lanTimeout;

  /// How often the home network is tried again while the room server says the PC is offline.
  final Duration lanRetryInterval;
  final Random _random;

  LinkTarget _target;
  LinkTarget get target => _target;

  String _pcName;
  LinkStatus _status = const LinkStatus(LinkPhase.idle);
  RemoteState? _state;
  DateTime? _stateAt;
  final ValueNotifier<String?> _notice = ValueNotifier(null);
  final StreamController<Map<String, dynamic>> _pushes = StreamController.broadcast(sync: true);

  @override
  Stream<Map<String, dynamic>> get pushes => _pushes.stream;

  // One "generation" per attempt; callbacks from an earlier attempt are ignored.
  int _generation = 0;
  bool _running = false;
  // A failure only the user can fix (removed phone, expired code, protocol mismatch): nothing retries on its own, not
  // even a return to the app or a network change, until the user asks to try again.
  bool _halted = false;
  int _failures = 0;
  Timer? _retryTimer, _answerTimer, _helloTimer, _pairTimer, _pingTimer, _pathTimer;
  SignalingSocket? _socket;
  StreamSubscription<String>? _socketSubscription;
  PeerLink? _peer;
  String? _session;
  // Who the current session signs as. A session that began with a pairing code stays signed as "pair" with that code,
  // even after the PC pairs the phone.
  String _sessionPhone = '', _sessionKey = '';
  DateTime _lastSocketMessage = DateTime.fromMillisecondsSinceEpoch(0);
  bool _offerSent = false, _answered = false, _rejectedHandled = false, _welcomed = false;
  final List<(String, String)> _pendingLocal = [];
  final List<(String, String?)> _pendingRemote = [];
  List<Map<String, dynamic>> _iceServers = const [];
  bool _forceRelay = false;
  int _pingNumber = 0;
  Set<String> _features = const {};
  bool _canStart = true;
  MediaReader? _media;
  bool _mediaOpen = false;
  int _requestNumber = 0;
  final Map<int, Completer<Map<String, dynamic>>> _requests = {};

  // The home network (PHONE-REMOTE.md, "On the home network"): whether this attempt's signaling goes through the PC's own
  // socket rather than the room server, the try under way (one per attempt), and the next try while the PC is offline.
  bool _viaLan = false;
  (int, Future<bool>)? _lanTry;
  Timer? _lanTimer;
  LanEndpoints? _learnedLan;

  /// Where the PC said it listens on its home network, from its last `welcome` that said so; the app stores it.
  LanEndpoints? get learnedLan => _learnedLan;

  /// Whether the current attempt was introduced on the home network rather than by the room server.
  bool get viaHomeNetwork => _viaLan;

  static const List<int> _backoffSeconds = [1, 2, 4, 8, 15, 30];

  @override
  String get pcName => _pcName;
  @override
  LinkStatus get status => _status;
  @override
  RemoteState? get state => _state;
  @override
  DateTime? get stateReceivedAt => _stateAt;
  @override
  ValueListenable<String?> get notice => _notice;

  bool get running => _running;

  @override
  Set<String> get features => _features;
  @override
  bool get canStart => _canStart;
  @override
  MediaReader? get media => _status.isConnected && _mediaOpen && !(_media?.closed ?? true) ? _media : null;

  @override
  Future<Map<String, dynamic>> ask(String type, Map<String, dynamic> fields, {Duration timeout = const Duration(seconds: 20)}) {
    if (!_status.isConnected || _peer == null) return Future.error(const RemoteRequestException('offline', "The PC isn't connected."));
    final number = ++_requestNumber;
    final completer = Completer<Map<String, dynamic>>();
    _requests[number] = completer;
    _peer!.send(jsonEncode({...fields, 'type': type, 'request': number}));
    return completer.future.whenComplete(_settled).timeout(timeout, onTimeout: () {
      _requests.remove(number);
      _settled();
      throw const RemoteRequestException('timeout', "The PC didn't answer. Try again.");
    });
  }

  // Waiting for every asked request to be answered (or to fail).
  final List<Completer<void>> _quiet = [];

  @override
  Future<void> answered(Duration limit) {
    if (_requests.isEmpty) return Future.value();
    final done = Completer<void>();
    _quiet.add(done);
    return done.future.timeout(limit, onTimeout: () => _quiet.remove(done));
  }

  void _settled() {
    if (_requests.isNotEmpty || _quiet.isEmpty) return;
    final waiting = _quiet.toList();
    _quiet.clear();
    for (final done in waiting) {
      if (!done.isCompleted) done.complete();
    }
  }

  @override
  void tell(String type, Map<String, dynamic> fields) {
    if (!_status.isConnected) return;
    _peer?.send(jsonEncode({...fields, 'type': type}));
  }

  void _failRequests(String message) {
    final pending = _requests.values.toList();
    _requests.clear();
    scheduleMicrotask(_settled);
    for (final request in pending) {
      if (!request.isCompleted) request.completeError(RemoteRequestException('offline', message));
    }
  }

  /// Stopped by a failure only the user can fix; see [retryNow].
  bool get halted => _halted;

  void start() {
    if (_running) return;
    _running = true;
    _halted = false;
    _failures = 0;
    _attempt();
  }

  /// Stops trying and closes everything, keeping the last state for when it starts again. A failure that needs the
  /// user stays on screen.
  Future<void> stop() async {
    _running = false;
    final generation = ++_generation;
    _retryTimer?.cancel();
    await _teardown();
    // Started again while it closed (the app came back meanwhile): the new attempt's status stands.
    if (!_halted && !_running && generation == _generation) _setStatus(const LinkStatus(LinkPhase.idle));
  }

  /// The user asked to try again: also after a failure that stopped the automatic retries.
  @override
  void retryNow() {
    _halted = false;
    if (!_running) {
      start();
      return;
    }
    _failures = 0;
    _attempt();
  }

  /// For the app returning to the foreground: starts over unless the link is still healthy, or a failure is waiting
  /// for the user.
  void resume() {
    if (_halted) return;
    if (!_running) {
      start();
    } else if (!_status.isConnected || !(_peer?.alive ?? false)) {
      retryNow();
    } else {
      _checkPath();
    }
  }

  /// For a network change: the old path is probably gone, so set up a new link at once.
  void networkChanged() {
    if (!_running || _halted) return;
    _failures = 0;
    _attempt();
  }

  @override
  void command(String action, [Object? value]) {
    if (!_status.isConnected) return;
    final message = <String, dynamic>{'type': 'command', 'action': action};
    if (value != null) message['value'] = value;
    _peer?.send(jsonEncode(message));
  }

  @override
  void dispose() {
    _running = false;
    _generation++;
    _retryTimer?.cancel();
    unawaited(_teardown());
    _notice.dispose();
    unawaited(_pushes.close());
    super.dispose();
  }

  // ---- attempt ----

  Future<void> _attempt() async {
    final generation = ++_generation;
    _retryTimer?.cancel();
    await _teardown();
    if (generation != _generation || !_running) return;
    // Every attempt starts with the room server.
    _viaLan = false;
    _setStatus(const LinkStatus(LinkPhase.connecting));
    final Uri uri;
    try {
      uri = remoteSocketUri(_target.server);
    } on FormatException {
      _fail(generation, "The room server address for this PC isn't valid. Pair it again.", permanent: true, needsPairing: true);
      return;
    }
    final SignalingSocket socket;
    try {
      socket = await connectSocket(uri);
    } catch (e) {
      // A server that refused (an error status: one from before phones, or a proxy whose server is down) isn't the
      // phone's internet: it says so, and asks again slowly. Any other answer, such as a hotel Wi-Fi's sign-in page, is.
      final status = int.tryParse(RegExp(r'HTTP status code: (\d+)', caseSensitive: false).firstMatch('$e')?.group(1) ?? '');
      if (status != null && status >= 400) {
        unawaited(_fallBack(generation, "The room server didn't take the connection. It may be down or need an update.", slow: true));
      } else {
        unawaited(_fallBack(generation, "Can't reach the room server. Check your internet connection."));
      }
      return;
    }
    if (generation != _generation || !_running) {
      unawaited(socket.close());
      return;
    }
    _listen(generation, socket, socket.messages.listen(null, cancelOnError: true));
    _send({'type': 'remote-phone', 'target': _target.pcId, 'number': 1});
  }

  /// Makes [socket] the attempt's signaling socket: the room server's, or the PC's own on the home network.
  void _listen(int generation, SignalingSocket socket, StreamSubscription<String> subscription) {
    _socket = socket;
    _socketSubscription = subscription
      ..onData((text) => _onSocketMessage(generation, text))
      ..onError((Object _) => _onSocketClosed(generation))
      ..onDone(() => _onSocketClosed(generation));
    if (subscription.isPaused) subscription.resume();
    _lastSocketMessage = clock.now();
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(pingInterval, (_) {
      // Both answer every ping; a socket that stays silent across two of them is gone.
      if (clock.now().difference(_lastSocketMessage) > pingInterval * 2 + const Duration(seconds: 5)) {
        final socket = _socket;
        _onSocketClosed(generation);
        unawaited(socket?.close());
        return;
      }
      _send({'type': 'ping', 'number': ++_pingNumber});
    });
  }

  /// Lets go of the signaling socket, closing it when [close].
  void _dropSocket({bool close = false}) {
    _pingTimer?.cancel();
    final subscription = _socketSubscription, socket = _socket;
    _socketSubscription = null;
    _socket = null;
    unawaited(subscription?.cancel());
    if (close) unawaited(socket?.close());
  }

  // ---- the home network ----

  /// The room server couldn't introduce the phone to the PC: it can't be reached, refused, or went before the link was
  /// up. A PC whose home-network address the phone knows gets a try there; failing that, [message] stands as before.
  Future<void> _fallBack(int generation, String message, {bool slow = false}) async {
    if (generation != _generation) return;
    if (_target.lan == null || _target.isPairing || _viaLan) {
      _fail(generation, message, slow: slow);
      return;
    }
    _lanTimer?.cancel();
    // A link being set up through the room server can't finish without it.
    _dropSocket(close: true);
    await _closePeer();
    if (generation != _generation) return;
    final adopted = await _tryLan(generation);
    if (!adopted && generation == _generation && !_viaLan) _fail(generation, message, slow: slow);
  }

  /// The room server says the PC is offline, which it also says of a PC that lost its internet: the home network gets a
  /// try now and every [lanRetryInterval] while it says so.
  void _probeWhileOffline(int generation) {
    if (_viaLan || _target.lan == null || _target.isPairing) return;
    _lanTimer?.cancel();
    unawaited(
      _tryLan(generation).then((adopted) {
        if (adopted || generation != _generation || _status.phase != LinkPhase.waitingForPc) return;
        _lanTimer?.cancel();
        _lanTimer = Timer(lanRetryInterval, () {
          if (generation == _generation && _status.phase == LinkPhase.waitingForPc) _probeWhileOffline(generation);
        });
      }),
    );
  }

  /// One try at a time per attempt: a second caller waits for the one under way. Completes with whether the attempt now
  /// goes through the home network.
  Future<bool> _tryLan(int generation) {
    final running = _lanTry;
    if (running != null && running.$1 == generation) return running.$2;
    final future = _tryLanOnce(generation);
    _lanTry = (generation, future);
    unawaited(
      future.then((_) {
        if (identical(_lanTry?.$2, future)) _lanTry = null;
      }),
    );
    return future;
  }

  Future<bool> _tryLanOnce(int generation) async {
    final lan = _target.lan;
    if (lan == null || _target.isPairing) return false;
    final found = await _greetLan(lan, _target.pcId);
    if (found == null) return false;
    // Still wanted: the same attempt, and not linking through the room server meanwhile (the PC came online there).
    final wanted = generation == _generation && _running && !_viaLan && (_socket == null || _status.phase == LinkPhase.waitingForPc);
    if (!wanted) {
      found.discard();
      return false;
    }
    _lanTimer?.cancel();
    _dropSocket(close: true);
    _viaLan = true;
    _listen(generation, found.socket, found.subscription);
    _readWelcome(found.welcome);
    unawaited(_startPeer(generation));
    return true;
  }

  /// Connects to all of the PC's addresses at once and returns the first that greets the phone as that PC's within
  /// [lanTimeout], closing the others; null when none does.
  Future<_LanLink?> _greetLan(LanEndpoints lan, String pcId) {
    final result = Completer<_LanLink?>();
    var left = lan.addresses.length;
    for (final address in lan.addresses) {
      unawaited(
        _greet(remoteLanUri(address, lan.port), pcId, result.future).then((link) {
          if (link != null && !result.isCompleted) {
            result.complete(link);
          } else {
            link?.discard();
          }
          if (--left == 0 && !result.isCompleted) result.complete(null);
        }),
      );
    }
    if (left == 0) result.complete(null);
    return result.future;
  }

  /// One address: the socket opens, the phone asks for its PC, and the PC answers `remote-welcome` and `remote-online`.
  /// Anything else (another PC's `error`, a close, silence, or another address answering first) is null.
  Future<_LanLink?> _greet(Uri uri, String pcId, Future<_LanLink?> settled) {
    final done = Completer<_LanLink?>();
    SignalingSocket? socket;
    StreamSubscription<String>? subscription;
    late final Timer timer;
    void give(_LanLink? link) {
      if (done.isCompleted) return;
      timer.cancel();
      if (link == null) {
        unawaited(subscription?.cancel());
        unawaited(socket?.close());
      } else {
        // Held until the attempt takes it, so nothing that arrives meanwhile is lost.
        link.subscription.pause();
      }
      done.complete(link);
    }

    timer = Timer(lanTimeout, () => give(null));
    // Another address answered first.
    unawaited(settled.then((_) => give(null)));
    unawaited(
      Future.sync(() => connectSocket(uri)).then(
        (opened) {
          // Too late: the phone has moved on, and nothing else would close it.
          if (done.isCompleted) {
            unawaited(opened.close());
            return;
          }
          socket = opened;
          String? welcome;
          subscription = opened.messages.listen(
            (text) {
              Object? message;
              try {
                message = jsonDecode(text);
              } on FormatException {
                return;
              }
              if (message is! Map) return;
              switch (message['type']) {
                case 'remote-welcome':
                  welcome = message['data'] is String ? message['data'] as String : '{}';
                case 'remote-online' when welcome != null:
                  give(_LanLink(opened, subscription!, welcome!));
                case 'error' || 'remote-offline' || 'closed':
                  give(null);
              }
            },
            onError: (Object _) => give(null),
            onDone: () => give(null),
            cancelOnError: true,
          );
          try {
            opened.send(jsonEncode({'type': 'remote-phone', 'target': pcId, 'number': 1}));
          } catch (_) {
            give(null);
          }
        },
        onError: (Object _) => give(null),
      ),
    );
    return done.future;
  }

  void _send(Map<String, dynamic> message) {
    try {
      _socket?.send(jsonEncode(message));
    } catch (_) {}
  }

  void _onSocketClosed(int generation) {
    if (generation != _generation || _socket == null) return;
    _dropSocket();
    // The direct link doesn't need the room server (or the PC's own socket) once it's up.
    if (_status.isConnected || _status.phase == LinkPhase.pairing) return;
    if (_status.phase == LinkPhase.failed) return;
    if (_viaLan) {
      _fail(generation, 'Lost the connection to the PC.');
    } else {
      unawaited(_fallBack(generation, 'Lost the room server connection.'));
    }
  }

  void _onSocketMessage(int generation, String text) {
    if (generation != _generation) return;
    _lastSocketMessage = clock.now();
    final Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      message = decoded;
    } on FormatException {
      return;
    }
    switch (message['type']) {
      case 'remote-welcome':
        _readWelcome(message['data']);
      case 'remote-online':
        if (!_status.isConnected && _status.phase != LinkPhase.pairing) unawaited(_startPeer(generation));
      case 'remote-offline':
        if (!_status.isConnected && _status.phase != LinkPhase.pairing) {
          unawaited(_closePeer());
          _setStatus(const LinkStatus(LinkPhase.waitingForPc, message: "Your PC isn't online"));
          _probeWhileOffline(generation);
        }
      case 'signal':
        _onSignal(generation, message['data']);
      case 'error':
        final reason = message['text'];
        final text = reason is String && reason.isNotEmpty ? reason : 'The room server refused the connection.';
        if (_viaLan) {
          _fail(generation, text, slow: true);
        } else {
          unawaited(_fallBack(generation, text, slow: true));
        }
      case 'closed':
        final reason = message['text'];
        if (!_status.isConnected) {
          unawaited(_fallBack(generation, reason is String && reason.isNotEmpty ? reason : 'The room server closed the connection.'));
        }
    }
  }

  void _readWelcome(Object? data) {
    if (data is! String) return;
    try {
      final json = jsonDecode(data);
      if (json is! Map) return;
      final servers = json['iceServers'];
      _iceServers = servers is List ? toWebRtcIceServers(servers.whereType<String>()) : const [];
      _forceRelay = json['forceRelay'] == true;
    } on FormatException {
      _iceServers = const [];
    }
  }

  Future<void> _startPeer(int generation) async {
    await _closePeer();
    if (generation != _generation) return;
    _setStatus(const LinkStatus(LinkPhase.linking));
    final session = Signing.randomHex(16, _random);
    _session = session;
    _sessionPhone = _target.phone;
    _sessionKey = _target.keyHex;
    _offerSent = false;
    _answered = false;
    _rejectedHandled = false;
    _welcomed = false;
    _pendingLocal.clear();
    _pendingRemote.clear();
    final PeerLink peer;
    try {
      peer = await createPeer(_iceServers, _forceRelay);
    } catch (_) {
      _fail(generation, "Couldn't set up a connection on this phone.");
      return;
    }
    if (generation != _generation || _session != session) {
      unawaited(peer.close());
      return;
    }
    _peer = peer;
    final media = MediaReader(send: peer.sendMedia);
    _media = media;
    _mediaOpen = false;
    peer.onMediaOpen = () {
      if (generation != _generation || _session != session) return;
      _mediaOpen = true;
      notifyListeners();
    };
    peer.onMediaBinary = media.onBinary;
    peer.onMediaText = media.onText;
    peer.onMediaClosed = () {
      _mediaOpen = false;
      media.close();
      if (generation == _generation && _session == session) notifyListeners();
    };
    peer.onLocalCandidate = (candidate, mid) {
      if (generation != _generation || _session != session) return;
      if (!_offerSent) {
        _pendingLocal.add((candidate, mid));
      } else {
        _signal('ice', jsonEncode({'candidate': candidate, 'mid': mid}));
      }
    };
    peer.onOpen = () {
      if (generation != _generation || _session != session) return;
      _answerTimer?.cancel();
      peer.send(jsonEncode({'type': 'hello', 'protocol': 1, 'app': identity.appVersion, 'device': identity.device}));
      _helloTimer = Timer(helloTimeout, () {
        if (generation == _generation && !_welcomed) _fail(generation, "The PC didn't answer. Try again.");
      });
    };
    peer.onMessage = (text) {
      if (generation == _generation && _session == session) _onChannelMessage(generation, text);
    };
    peer.onClosed = (reason) {
      if (generation != _generation || _session != session) return;
      _fail(generation, _status.isConnected ? 'Lost the connection to the PC.' : reason);
    };
    try {
      final sdp = await peer.createOffer();
      if (generation != _generation || _session != session) return;
      _signal('sdp', jsonEncode({'type': 'offer', 'sdp': sdp}));
      _offerSent = true;
      for (final (candidate, mid) in _pendingLocal) {
        _signal('ice', jsonEncode({'candidate': candidate, 'mid': mid}));
      }
      _pendingLocal.clear();
    } catch (_) {
      _fail(generation, "Couldn't set up a connection on this phone.");
      return;
    }
    _answerTimer = Timer(answerTimeout, () {
      if (generation == _generation && !_welcomed) {
        if (!_answered && _target.isPairing) {
          // A PC ignores an offer signed with a code that isn't its current one (replaced by a newer code, or mistyped),
          // and trying the same code again gets the same silence.
          _fail(
            generation,
            "The PC didn't answer this code. Show the code on the PC again, or check that Phone remote is on in BlackPearl's Settings › Profile.",
            permanent: true,
            needsPairing: true,
          );
          return;
        }
        _fail(
          generation,
          _answered
              ? "Couldn't reach the PC directly or through the relay."
              : "Your PC didn't answer. Check that Phone remote is on in BlackPearl's Settings › Profile.",
        );
      }
    });
  }

  void _signal(String kind, String payload) {
    final session = _session;
    if (session == null) return;
    final signal = SignedSignal.fromPhone(keyHex: _sessionKey, phone: _sessionPhone, session: session, kind: kind, payload: payload);
    _send({'type': 'signal', 'data': signal.encode()});
  }

  void _onSignal(int generation, Object? data) {
    final signal = SignedSignal.tryParse(data is String ? data : null);
    final session = _session;
    if (signal == null || session == null || signal.session.toLowerCase() != session) return;
    if (signal.phone.toLowerCase() != _sessionPhone.toLowerCase()) return;
    if (signal.kind == 'rejected' && signal.auth.isEmpty) {
      // Unsigned, so only a hint: it can't grant anything, and it only stops automatic retries.
      if (_rejectedHandled || _answered) return;
      _rejectedHandled = true;
      if (signal.payload == 'unknown-phone') {
        _fail(generation, 'This phone was removed from the PC. Pair it again.', permanent: true, needsPairing: true);
      } else if (signal.payload == 'pairing-expired') {
        _fail(generation, 'That code has expired', permanent: true, needsPairing: true);
      }
      return;
    }
    if (!signal.verifyFromPc(_sessionKey)) return;
    final peer = _peer;
    if (peer == null) return;
    try {
      final payload = jsonDecode(signal.payload);
      if (payload is! Map) return;
      if (signal.kind == 'sdp' && payload['type'] == 'answer' && payload['sdp'] is String && !_answered) {
        _answered = true;
        unawaited(_applyAnswer(generation, session, peer, payload['sdp'] as String));
      } else if (signal.kind == 'ice' && payload['candidate'] is String) {
        final candidate = payload['candidate'] as String;
        final mid = payload['mid'] is String ? payload['mid'] as String : null;
        if (candidate.isEmpty) return;
        if (!_remoteDescriptionSet) {
          _pendingRemote.add((candidate, mid));
        } else {
          unawaited(peer.addRemoteCandidate(candidate, mid).catchError((_) {}));
        }
      }
    } on FormatException {
      return;
    }
  }

  bool _remoteDescriptionSet = false;

  Future<void> _applyAnswer(int generation, String session, PeerLink peer, String sdp) async {
    // A new session (the PC came online again) can start while the answer is applied; the old one's outcome is not
    // the new one's.
    bool current() => generation == _generation && _session == session && identical(_peer, peer);
    try {
      await peer.setAnswer(sdp);
    } catch (_) {
      if (current()) _fail(generation, "Couldn't connect to the PC.");
      return;
    }
    if (!current()) return;
    _remoteDescriptionSet = true;
    for (final (candidate, mid) in _pendingRemote) {
      unawaited(peer.addRemoteCandidate(candidate, mid).catchError((_) {}));
    }
    _pendingRemote.clear();
  }

  void _onChannelMessage(int generation, String text) {
    final Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      message = decoded;
    } on FormatException {
      return;
    }
    switch (message['type']) {
      case 'welcome':
        if (_welcomed) return;
        _welcomed = true;
        _helloTimer?.cancel();
        _answerTimer?.cancel();
        final features = message['features'];
        _features = features is List ? features.whereType<String>().toSet() : const {};
        _canStart = message['canStart'] != false;
        // Where the PC listens on its home network. Left out by older PCs, and by one not listening just now: what the
        // phone knew stays.
        if (LanEndpoints.fromJson(message['lan']) case final lan?) {
          _learnedLan = lan;
          if (!_target.isPairing) _target = _target.withLan(lan);
        }
        final name = message['pc'];
        if (name is String && name.trim().isNotEmpty && name != _pcName) {
          _pcName = name.trim();
          if (!_target.isPairing) onPcName?.call(_target.pcId, _pcName);
        }
        if (_target.isPairing) {
          _setStatus(const LinkStatus(LinkPhase.pairing));
          _peer?.send(jsonEncode({'type': 'pair', 'name': identity.device}));
          _pairTimer?.cancel();
          _pairTimer = Timer(pairTimeout, () {
            if (generation == _generation && _status.phase == LinkPhase.pairing) {
              _fail(generation, "The PC didn't finish pairing this phone", permanent: true, needsPairing: true);
            }
          });
        } else {
          _connected();
        }
      case 'paired':
        if (!_target.isPairing) return;
        final phoneId = message['phoneId'], secret = message['secret'];
        if (!Signing.isHex(phoneId is String ? phoneId : null, 32) || !Signing.isHex(secret is String ? secret : null, 64)) return;
        final pcName = message['pc'] is String && (message['pc'] as String).trim().isNotEmpty ? (message['pc'] as String).trim() : _pcName;
        final pcId = message['pcId'] is String && Signing.isHex(message['pcId'] as String, 32)
            ? (message['pcId'] as String).toUpperCase()
            : _target.pcId;
        final paired = PairedPc(
          pcId: pcId,
          name: pcName,
          server: _target.server,
          phoneId: phoneId as String,
          secret: secret as String,
          lan: _learnedLan,
        );
        _pairTimer?.cancel();
        _pcName = pcName;
        // This session stays signed as "pair"; the next one uses the phone's own id and secret.
        _target = LinkTarget.paired(paired);
        onPaired?.call(paired);
        _connected();
      case 'page' || 'stream' || 'done' || 'queues' || 'listen' || 'clock' when message['request'] is num:
        _requests.remove((message['request'] as num).toInt())?.complete(message);
      case 'error' when message['request'] is num && _requests.containsKey((message['request'] as num).toInt()):
        final code = message['code'] is String ? message['code'] as String : 'failed';
        final text = message['message'] is String && (message['message'] as String).isNotEmpty ? message['message'] as String : "The PC couldn't do that.";
        _requests.remove((message['request'] as num).toInt())?.completeError(RemoteRequestException(code, text));
      case 'sound':
        _pushes.add(message);
      case 'state':
        _state = RemoteState.fromJson(message);
        _stateAt = clock.now();
        notifyListeners();
      case 'error':
        final code = message['code'];
        final text = message['message'] is String && (message['message'] as String).isNotEmpty ? message['message'] as String : null;
        if (code == 'protocol') {
          _fail(generation, text ?? 'The PC and this phone run different versions of the remote. Update both apps.', permanent: true);
        } else if (code == 'pairing') {
          _fail(generation, text ?? 'That code has expired', permanent: true, needsPairing: true);
        } else if (text != null) {
          _notice.value = null;
          _notice.value = text;
        }
    }
  }

  void _connected() {
    _failures = 0;
    _setStatus(LinkStatus(LinkPhase.connected, path: _status.path));
    _checkPath();
    _pathTimer?.cancel();
    _pathTimer = Timer.periodic(const Duration(seconds: 10), (_) => _checkPath());
  }

  Future<void> _checkPath() async {
    final peer = _peer;
    final generation = _generation;
    if (peer == null || !_status.isConnected) return;
    final path = await peer.path();
    if (generation != _generation || !_status.isConnected || path == _status.path) return;
    _setStatus(LinkStatus(LinkPhase.connected, path: path));
  }

  void _fail(int generation, String message, {bool permanent = false, bool needsPairing = false, bool slow = false}) {
    if (generation != _generation) return;
    _generation++;
    unawaited(_teardown());
    if (permanent) _halted = true;
    if (permanent || !_running) {
      _setStatus(LinkStatus(LinkPhase.failed, message: message, needsPairing: needsPairing));
      return;
    }
    final seconds = slow
        ? max(30, _backoffSeconds[min(_failures, _backoffSeconds.length - 1)])
        : _backoffSeconds[min(_failures, _backoffSeconds.length - 1)];
    _failures++;
    final retryAt = clock.now().add(Duration(seconds: seconds));
    _setStatus(LinkStatus(LinkPhase.failed, message: message, retryAt: retryAt));
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: seconds), () {
      if (_running) _attempt();
    });
  }

  Future<void> _closePeer() async {
    _answerTimer?.cancel();
    _helloTimer?.cancel();
    _pairTimer?.cancel();
    _pathTimer?.cancel();
    _remoteDescriptionSet = false;
    _session = null;
    _mediaOpen = false;
    _media?.close();
    _media = null;
    _failRequests('Lost the connection to the PC.');
    final peer = _peer;
    _peer = null;
    if (peer != null) await peer.close();
  }

  Future<void> _teardown() async {
    _lanTimer?.cancel();
    _dropSocket(close: true);
    await _closePeer();
  }

  void _setStatus(LinkStatus status) {
    _status = status;
    notifyListeners();
  }
}
