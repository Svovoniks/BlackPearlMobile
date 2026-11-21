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
  const LinkTarget({required this.pcId, required this.pcName, required this.server, required this.phone, required this.keyHex});

  factory LinkTarget.paired(PairedPc pc) =>
      LinkTarget(pcId: pc.pcId, pcName: pc.name, server: pc.server, phone: pc.phoneId, keyHex: pc.secret);

  factory LinkTarget.pairing(PairLink link) =>
      LinkTarget(pcId: link.pcId, pcName: link.name, server: link.server, phone: 'pair', keyHex: link.code);

  final String pcId;
  final String pcName;
  final String server;

  /// The phone id signals are sent under: `pair` while pairing with a code.
  final String phone;
  final String keyHex;

  bool get isPairing => phone == 'pair';
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
  final Random _random;

  LinkTarget _target;
  LinkTarget get target => _target;

  String _pcName;
  LinkStatus _status = const LinkStatus(LinkPhase.idle);
  RemoteState? _state;
  DateTime? _stateAt;
  final ValueNotifier<String?> _notice = ValueNotifier(null);

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
    return completer.future.timeout(timeout, onTimeout: () {
      _requests.remove(number);
      throw const RemoteRequestException('timeout', "The PC didn't answer. Try again.");
    });
  }

  @override
  void tell(String type, Map<String, dynamic> fields) {
    if (!_status.isConnected) return;
    _peer?.send(jsonEncode({...fields, 'type': type}));
  }

  void _failRequests(String message) {
    final pending = _requests.values.toList();
    _requests.clear();
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
    _generation++;
    _retryTimer?.cancel();
    await _teardown();
    if (!_halted) _setStatus(const LinkStatus(LinkPhase.idle));
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
    super.dispose();
  }

  // ---- attempt ----

  Future<void> _attempt() async {
    final generation = ++_generation;
    _retryTimer?.cancel();
    await _teardown();
    if (generation != _generation || !_running) return;
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
    } catch (_) {
      _fail(generation, "Can't reach the room server. Check your internet connection.");
      return;
    }
    if (generation != _generation || !_running) {
      unawaited(socket.close());
      return;
    }
    _socket = socket;
    _socketSubscription = socket.messages.listen(
      (text) => _onSocketMessage(generation, text),
      onError: (_) => _onSocketClosed(generation),
      onDone: () => _onSocketClosed(generation),
      cancelOnError: true,
    );
    _lastSocketMessage = clock.now();
    _send({'type': 'remote-phone', 'target': _target.pcId, 'number': 1});
    _pingTimer = Timer.periodic(pingInterval, (_) {
      // The server answers every ping; a socket that stays silent across two of them is gone.
      if (clock.now().difference(_lastSocketMessage) > pingInterval * 2 + const Duration(seconds: 5)) {
        final socket = _socket;
        _onSocketClosed(generation);
        unawaited(socket?.close());
        return;
      }
      _send({'type': 'ping', 'number': ++_pingNumber});
    });
  }

  void _send(Map<String, dynamic> message) {
    try {
      _socket?.send(jsonEncode(message));
    } catch (_) {}
  }

  void _onSocketClosed(int generation) {
    if (generation != _generation || _socket == null) return;
    _pingTimer?.cancel();
    unawaited(_socketSubscription?.cancel());
    _socketSubscription = null;
    _socket = null;
    // The direct link doesn't need the room server once it's up.
    if (_status.isConnected || _status.phase == LinkPhase.pairing) return;
    if (_status.phase == LinkPhase.failed) return;
    _fail(generation, 'Lost the room server connection.');
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
        }
      case 'signal':
        _onSignal(generation, message['data']);
      case 'error':
        final reason = message['text'];
        _fail(generation, reason is String && reason.isNotEmpty ? reason : 'The room server refused the connection.', slow: true);
      case 'closed':
        final reason = message['text'];
        if (!_status.isConnected) {
          _fail(generation, reason is String && reason.isNotEmpty ? reason : 'The room server closed the connection.');
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
        final paired = PairedPc(pcId: pcId, name: pcName, server: _target.server, phoneId: phoneId as String, secret: secret as String);
        _pairTimer?.cancel();
        _pcName = pcName;
        // This session stays signed as "pair"; the next one uses the phone's own id and secret.
        _target = LinkTarget.paired(paired);
        onPaired?.call(paired);
        _connected();
      case 'page' || 'stream' || 'done' when message['request'] is num:
        _requests.remove((message['request'] as num).toInt())?.complete(message);
      case 'error' when message['request'] is num && _requests.containsKey((message['request'] as num).toInt()):
        final code = message['code'] is String ? message['code'] as String : 'failed';
        final text = message['message'] is String && (message['message'] as String).isNotEmpty ? message['message'] as String : "The PC couldn't do that.";
        _requests.remove((message['request'] as num).toInt())?.completeError(RemoteRequestException(code, text));
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
    _pingTimer?.cancel();
    final subscription = _socketSubscription;
    final socket = _socket;
    _socketSubscription = null;
    _socket = null;
    unawaited(subscription?.cancel());
    unawaited(socket?.close());
    await _closePeer();
  }

  void _setStatus(LinkStatus status) {
    _status = status;
    notifyListeners();
  }
}
