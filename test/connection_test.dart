import 'dart:async';
import 'dart:convert';

import 'package:blackpearl_mobile/connection/remote_connection.dart';
import 'package:clock/clock.dart';
import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/connection/transport.dart';
import 'package:blackpearl_mobile/protocol/pair_link.dart';
import 'package:blackpearl_mobile/protocol/signing.dart';
import 'package:blackpearl_mobile/storage/paired_pcs.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'spec_vectors.dart';

/// An in-memory room server socket: the test plays the server and the PC.
class FakeSocket implements SignalingSocket {
  final StreamController<String> _incoming = StreamController<String>();
  final List<Map<String, dynamic>> sent = [];
  bool closed = false;
  bool answerPings = true;

  @override
  Stream<String> get messages => _incoming.stream;
  @override
  void send(String text) {
    final message = jsonDecode(text) as Map<String, dynamic>;
    sent.add(message);
    // As the room server does.
    if (answerPings && message['type'] == 'ping' && !_incoming.isClosed) {
      receive({'type': 'pong', 'number': message['number'], 'data': '0'});
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

  void receive(Map<String, dynamic> message) => _incoming.add(jsonEncode(message));
  void receiveText(String text) => _incoming.add(text);
  void drop() => _incoming.close();

  Iterable<SignedSignal> signals() => sent.where((m) => m['type'] == 'signal').map((m) => SignedSignal.tryParse(m['data'] as String)!);
}

class FakePeer extends PeerLink {
  FakePeer(this.iceServers, this.forceRelay);
  final List<Map<String, dynamic>> iceServers;
  final bool forceRelay;
  String? answer;
  final List<(String, String?)> remoteCandidates = [];
  final List<Map<String, dynamic>> sent = [];
  bool closed = false;
  NetworkPath currentPath = NetworkPath.home;

  @override
  bool get alive => !closed;
  @override
  Future<String> createOffer() async {
    // Candidates can arrive before the offer is out; they must wait for it.
    onLocalCandidate?.call('candidate:1 1 UDP 2122317823 192.168.1.30 50000 typ host', '0');
    return 'v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=mid:0\r\n';
  }

  /// Holds setAnswer until completed, to let something else happen meanwhile.
  Completer<void>? answerGate;

  @override
  Future<void> setAnswer(String sdp) async {
    final gate = answerGate;
    if (gate != null) await gate.future;
    answer = sdp;
  }

  @override
  Future<void> addRemoteCandidate(String candidate, String? mid) async => remoteCandidates.add((candidate, mid));
  @override
  void send(String text) => sent.add(jsonDecode(text) as Map<String, dynamic>);
  @override
  Future<NetworkPath> path() async => currentPath;
  @override
  Future<void> close() async {
    closed = true;
    // A real peer connection takes a while to close.
    if (closeGate case final gate?) await gate.future;
  }

  Completer<void>? closeGate;

  void open() => onOpen?.call();
  void receive(Map<String, dynamic> message) => onMessage?.call(jsonEncode(message));
  void lose() => onClosed?.call('gone');
}

const pcId = '0123456789ABCDEF0123456789ABCDEF';
const phoneId = 'a1b2c3d4e5f60718a1b2c3d4e5f60718';
// Made-up keys with a visible pattern; nothing here is a real credential.
final secret = hexOf(List.generate(32, (i) => i * 7 % 256));
final code = hexOf(List.generate(16, (i) => 200 - i));

class Harness {
  Harness(LinkTarget target) {
    connection = RemoteConnection(
      target: target,
      identity: const PhoneIdentity(appVersion: '1.2.3', device: 'Test phone'),
      connectSocket: (uri) async {
        uris.add(uri);
        final socket = FakeSocket();
        sockets.add(socket);
        return socket;
      },
      createPeer: (servers, relay) async {
        final peer = FakePeer(servers, relay);
        peers.add(peer);
        return peer;
      },
      onPaired: paired.add,
    );
  }

  late final RemoteConnection connection;
  final List<Uri> uris = [];
  final List<FakeSocket> sockets = [];
  final List<FakePeer> peers = [];
  final List<PairedPc> paired = [];

  FakeSocket get socket => sockets.last;
  FakePeer get peer => peers.last;

  /// The PC's side: sign as the PC would.
  void pcSignal(String keyHex, String phone, String session, String kind, String payload, {String? auth}) {
    final signal = SignedSignal(
      phone: phone,
      session: session,
      kind: kind,
      payload: payload,
      auth: auth ?? Signing.sign(keyHex, 'pc', phone, session, kind, payload),
    );
    socket.receive({'type': 'signal', 'sender': pcId, 'data': signal.encode()});
  }
}

LinkTarget get pairedTarget =>
    LinkTarget.paired(PairedPc(pcId: pcId, name: 'Living room', server: 'https://rooms.example.com', phoneId: phoneId, secret: secret));

void main() {
  test('connects: handshake, signed offer, answer, hello, welcome, state', () {
    fakeAsync((async) {
      final h = Harness(pairedTarget);
      final phases = <LinkPhase>[];
      h.connection.addListener(() => phases.add(h.connection.status.phase));
      h.connection.start();
      async.flushMicrotasks();

      expect(h.uris.single.toString(), 'wss://rooms.example.com/remote');
      expect(h.socket.sent.first, {'type': 'remote-phone', 'target': pcId, 'number': 1});

      h.socket.receive({
        'type': 'remote-welcome',
        'target': 'conn1',
        'data': jsonEncode({
          'iceServers': ['stun:stun.example.com:3478', 'turn://us%3Aer:p%40ss@turn.example.com:3478?transport=udp'],
          'forceRelay': false,
        }),
      });
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();

      expect(h.connection.status.phase, LinkPhase.linking);
      expect(h.peer.iceServers, [
        {'urls': 'stun:stun.example.com:3478'},
        {'urls': 'turn:turn.example.com:3478?transport=udp', 'username': 'us:er', 'credential': 'p@ss'},
      ]);
      final signals = h.socket.signals().toList();
      expect(signals.map((s) => s.kind), ['sdp', 'ice'], reason: 'the offer goes first, then the candidates found meanwhile');
      final offer = signals.first;
      expect(offer.phone, phoneId);
      expect(Signing.isHex(offer.session, 32), isTrue);
      expect(Signing.verify(secret, 'phone', phoneId, offer.session, 'sdp', offer.payload, offer.auth), isTrue);
      expect(jsonDecode(offer.payload), {'type': 'offer', 'sdp': startsWith('v=0')});
      expect(jsonDecode(signals[1].payload), {'candidate': 'candidate:1 1 UDP 2122317823 192.168.1.30 50000 typ host', 'mid': '0'});

      // A candidate that arrives before the answer waits for it.
      h.pcSignal(
        secret,
        phoneId,
        offer.session,
        'ice',
        jsonEncode({'candidate': 'candidate:2 1 UDP 1 192.168.1.5 6000 typ host', 'mid': '0'}),
      );
      async.flushMicrotasks();
      expect(h.peer.remoteCandidates, isEmpty);
      h.pcSignal(secret, phoneId, offer.session, 'sdp', jsonEncode({'type': 'answer', 'sdp': 'v=0 answer'}));
      async.flushMicrotasks();
      expect(h.peer.answer, 'v=0 answer');
      expect(h.peer.remoteCandidates, [('candidate:2 1 UDP 1 192.168.1.5 6000 typ host', '0')]);

      h.peer.open();
      expect(h.peer.sent.single, {'type': 'hello', 'protocol': 1, 'app': '1.2.3', 'device': 'Test phone'});
      h.peer.receive({'type': 'welcome', 'protocol': 1, 'app': '0.4.0', 'pc': 'Living room', 'pcId': pcId, 'canStart': true});
      async.flushMicrotasks();
      expect(h.connection.status.phase, LinkPhase.connected);
      expect(h.connection.status.path, NetworkPath.home);

      h.peer.receive({'type': 'state', 'media': true, 'title': 'Night Signal', 'playing': true, 'positionMs': 1000, 'durationMs': 60000});
      expect(h.connection.state!.title, 'Night Signal');
      async.elapse(const Duration(seconds: 2));
      expect(h.connection.currentPositionMs(), 3000);

      h.connection.command('seek-by', -10000);
      h.connection.command('toggle');
      expect(h.peer.sent.skip(1), [
        {'type': 'command', 'action': 'seek-by', 'value': -10000},
        {'type': 'command', 'action': 'toggle'},
      ]);
      expect(phases, containsAllInOrder([LinkPhase.connecting, LinkPhase.linking, LinkPhase.connected]));
      h.connection.dispose();
    });
  });

  test("a queues answer reaches its request; reads hold back until the PC has answered, or for the time given", () {
    fakeAsync((async) {
      final h = Harness(pairedTarget);
      h.connection.start();
      async.flushMicrotasks();
      h.socket.receive({'type': 'remote-welcome', 'target': 'conn1', 'data': jsonEncode({'iceServers': <String>[], 'forceRelay': false})});
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      final offer = h.socket.signals().first;
      h.pcSignal(secret, phoneId, offer.session, 'sdp', jsonEncode({'type': 'answer', 'sdp': 'v=0 answer'}));
      async.flushMicrotasks();
      h.peer.open();
      h.peer.receive({'type': 'welcome', 'protocol': 1, 'app': '0.4.0', 'pc': 'Living room', 'pcId': pcId, 'canStart': true, 'features': ['library', 'watch', 'queues']});
      async.flushMicrotasks();
      expect(h.connection.features, contains('queues'));

      var quiet = false;
      unawaited(h.connection.answered(const Duration(seconds: 4)).then((_) => quiet = true));
      async.flushMicrotasks();
      expect(quiet, isTrue, reason: 'nothing asked, nothing to wait for');

      Map<String, dynamic>? answer;
      unawaited(h.connection.ask('queues', const {}).then((a) => answer = a));
      final request = h.peer.sent.last['request'];
      quiet = false;
      unawaited(h.connection.answered(const Duration(seconds: 4)).then((_) => quiet = true));
      async.elapse(const Duration(seconds: 1));
      expect(quiet, isFalse, reason: 'reads wait while the answer is on its way');
      h.peer.receive({'type': 'queues', 'request': request, 'queues': []});
      async.flushMicrotasks();
      expect(answer?['type'], 'queues');
      expect(quiet, isTrue);

      // An answer that doesn't come holds reads back only for the time given.
      unawaited(h.connection.ask('queues', const {}).catchError((Object _) => <String, dynamic>{}));
      quiet = false;
      unawaited(h.connection.answered(const Duration(seconds: 4)).then((_) => quiet = true));
      async.elapse(const Duration(seconds: 3));
      expect(quiet, isFalse);
      async.elapse(const Duration(seconds: 2));
      expect(quiet, isTrue);
      async.elapse(const Duration(seconds: 30));
      h.connection.dispose();
    });
  });

  test('drops signals with a bad signature, another session, or signed as the phone', () {
    fakeAsync((async) {
      final h = Harness(pairedTarget);
      h.connection.start();
      async.flushMicrotasks();
      h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      final session = h.socket.signals().first.session;
      final answer = jsonEncode({'type': 'answer', 'sdp': 'forged'});

      h.pcSignal(secret, phoneId, session, 'sdp', answer, auth: Signing.sign(code, 'pc', phoneId, session, 'sdp', answer));
      h.pcSignal('11${secret.substring(2)}', phoneId, session, 'sdp', answer);
      h.pcSignal(secret, phoneId, '0' * 32, 'sdp', answer);
      // A reflected copy of the phone's own signature uses the wrong direction.
      h.socket.receive({
        'type': 'signal',
        'data': SignedSignal.fromPhone(keyHex: secret, phone: phoneId, session: session, kind: 'sdp', payload: answer).encode(),
      });
      async.flushMicrotasks();
      expect(h.peer.answer, isNull);

      h.pcSignal(secret, phoneId, session, 'sdp', jsonEncode({'type': 'answer', 'sdp': 'real'}));
      async.flushMicrotasks();
      expect(h.peer.answer, 'real');
      h.connection.dispose();
    });
  });

  test("waits while the PC is offline and links up when it comes online", () {
    fakeAsync((async) {
      final h = Harness(pairedTarget);
      h.connection.start();
      async.flushMicrotasks();
      h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      h.socket.receive({'type': 'remote-offline'});
      async.flushMicrotasks();
      expect(h.connection.status.phase, LinkPhase.waitingForPc);
      expect(h.peers, isEmpty);
      async.elapse(const Duration(minutes: 2));
      expect(h.connection.status.phase, LinkPhase.waitingForPc, reason: 'pings keep the socket; no retries while waiting');
      expect(h.socket.sent.where((m) => m['type'] == 'ping'), isNotEmpty);
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      expect(h.connection.status.phase, LinkPhase.linking);
      expect(h.peers, hasLength(1));
      h.connection.dispose();
    });
  });

  test('pairs with a code, stores the result and keeps signing the session as pair', () {
    fakeAsync((async) {
      final h = Harness(LinkTarget.pairing(PairLink(pcId: pcId, code: code, server: 'https://rooms.example.com', name: 'Study')));
      h.connection.start();
      async.flushMicrotasks();
      h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      final offer = h.socket.signals().first;
      expect(offer.phone, 'pair');
      expect(Signing.verify(code, 'phone', 'pair', offer.session, 'sdp', offer.payload, offer.auth), isTrue);

      h.pcSignal(code, 'pair', offer.session, 'sdp', jsonEncode({'type': 'answer', 'sdp': 'v=0'}));
      async.flushMicrotasks();
      h.peer.open();
      h.peer.receive({'type': 'welcome', 'protocol': 1, 'pc': 'Study PC', 'pcId': pcId});
      async.flushMicrotasks();
      expect(h.connection.status.phase, LinkPhase.pairing);
      expect(h.peer.sent.last, {'type': 'pair', 'name': 'Test phone'});

      h.peer.receive({'type': 'paired', 'phoneId': phoneId, 'secret': secret, 'pc': 'Study PC', 'pcId': pcId});
      async.flushMicrotasks();
      expect(h.connection.status.phase, LinkPhase.connected);
      expect(h.paired.single.phoneId, phoneId);
      expect(h.paired.single.secret, secret);
      expect(h.paired.single.server, 'https://rooms.example.com');
      expect(h.connection.pcName, 'Study PC');

      // The PC's late candidates for this session are still signed with the code, as "pair".
      h.pcSignal(code, 'pair', offer.session, 'ice', jsonEncode({'candidate': 'candidate:9 1 UDP 1 10.0.0.2 7000 typ host', 'mid': '0'}));
      async.flushMicrotasks();
      expect(h.peer.remoteCandidates.last.$1, contains('10.0.0.2'));

      // The next attempt uses the phone's own id and secret.
      h.peer.lose();
      async.elapse(const Duration(seconds: 2));
      h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      final next = h.socket.signals().first;
      expect(next.phone, phoneId);
      expect(Signing.verify(secret, 'phone', phoneId, next.session, 'sdp', next.payload, next.auth), isTrue);
      h.connection.dispose();
    });
  });

  test('a rejected hint stops retries and asks to pair again', () {
    fakeAsync((async) {
      final h = Harness(pairedTarget);
      h.connection.start();
      async.flushMicrotasks();
      h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      final session = h.socket.signals().first.session;
      h.pcSignal(secret, phoneId, session, 'rejected', 'unknown-phone', auth: '');
      async.flushMicrotasks();
      expect(h.connection.status.phase, LinkPhase.failed);
      expect(h.connection.status.message, 'This phone was removed from the PC. Pair it again.');
      expect(h.connection.status.needsPairing, isTrue);
      expect(h.connection.status.retryAt, isNull);
      async.elapse(const Duration(minutes: 5));
      expect(h.sockets, hasLength(1));
      h.connection.dispose();
    });
  });

  test('an expired pairing code says so', () {
    fakeAsync((async) {
      final h = Harness(LinkTarget.pairing(PairLink(pcId: pcId, code: code, server: 'https://rooms.example.com', name: 'Study')));
      h.connection.start();
      async.flushMicrotasks();
      h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      h.pcSignal(code, 'pair', h.socket.signals().first.session, 'rejected', 'pairing-expired', auth: '');
      async.flushMicrotasks();
      expect(h.connection.status.message, 'That code has expired');
      expect(h.connection.status.needsPairing, isTrue);
      h.connection.dispose();
    });
  });

  test('reconnects with backoff after the link drops, and at once on retryNow', () {
    fakeAsync((async) {
      final h = Harness(pairedTarget);
      void link() {
        h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
        h.socket.receive({'type': 'remote-online'});
        async.flushMicrotasks();
        final session = h.socket.signals().first.session;
        h.pcSignal(secret, phoneId, session, 'sdp', jsonEncode({'type': 'answer', 'sdp': 'v=0'}));
        async.flushMicrotasks();
        h.peer.open();
        h.peer.receive({'type': 'welcome', 'protocol': 1, 'pc': 'Living room'});
        async.flushMicrotasks();
      }

      h.connection.start();
      async.flushMicrotasks();
      link();
      expect(h.connection.status.isConnected, isTrue);

      h.peer.lose();
      async.flushMicrotasks();
      expect(h.connection.status.phase, LinkPhase.failed);
      expect(h.connection.status.message, 'Lost the connection to the PC.');
      expect(h.connection.status.retryAt, isNotNull);
      expect(h.peers.first.closed, isTrue);
      expect(h.sockets.first.closed, isTrue);
      async.elapse(const Duration(milliseconds: 1100));
      expect(h.sockets, hasLength(2));
      link();
      expect(h.connection.status.isConnected, isTrue);

      // The socket fails twice: the waits grow.
      h.peer.lose();
      async.elapse(const Duration(milliseconds: 1100));
      h.socket.drop();
      async.flushMicrotasks();
      expect(h.connection.status.phase, LinkPhase.failed);
      async.elapse(const Duration(milliseconds: 1500));
      expect(h.sockets, hasLength(3), reason: 'second failure waits 2 s');
      async.elapse(const Duration(milliseconds: 600));
      expect(h.sockets, hasLength(4));

      h.socket.drop();
      async.flushMicrotasks();
      h.connection.retryNow();
      async.flushMicrotasks();
      expect(h.sockets, hasLength(5));
      h.connection.dispose();
    });
  });

  test('the room server refusing ends with its reason', () {
    fakeAsync((async) {
      final h = Harness(pairedTarget);
      h.connection.start();
      async.flushMicrotasks();
      h.socket.receive({'type': 'error', 'text': 'This phone app is older than the room server. Update BlackPearl Mobile.'});
      async.flushMicrotasks();
      expect(h.connection.status.phase, LinkPhase.failed);
      expect(h.connection.status.message, 'This phone app is older than the room server. Update BlackPearl Mobile.');
      expect(h.connection.status.retryAt!.difference(clock.now()).inSeconds, greaterThanOrEqualTo(29));
      h.connection.dispose();
    });
  });

  test('a PC that never answers times out with a hint', () {
    fakeAsync((async) {
      final h = Harness(pairedTarget);
      h.connection.start();
      async.flushMicrotasks();
      h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 19));
      expect(h.connection.status.phase, LinkPhase.linking);
      async.elapse(const Duration(milliseconds: 1500));
      expect(h.connection.status.phase, LinkPhase.failed);
      expect(h.connection.status.message, contains('Phone remote is on'));
      h.connection.dispose();
    });
  });

  test("a pairing code the PC doesn't answer isn't tried again: it asks for a new code", () {
    fakeAsync((async) {
      final h = Harness(LinkTarget.pairing(PairLink(pcId: pcId, code: code, server: 'https://rooms.example.com', name: 'Study')));
      h.connection.start();
      async.flushMicrotasks();
      h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 21));
      expect(h.connection.status.phase, LinkPhase.failed);
      expect(h.connection.status.needsPairing, isTrue);
      expect(h.connection.status.retryAt, isNull);
      expect(h.connection.halted, isTrue);
      async.elapse(const Duration(minutes: 5));
      expect(h.sockets, hasLength(1), reason: 'the dead code is not sent again');
      h.connection.dispose();
    });
  });

  test("a room server that answers without taking the connection says so, and asks again slowly", () {
    fakeAsync((async) {
      final connection = RemoteConnection(
        target: pairedTarget,
        identity: const PhoneIdentity(appVersion: '1.2.3', device: 'Test phone'),
        connectSocket: (uri) async => throw Exception("WebSocketException: Connection to 'https://rooms.example.com:0/remote#' was not upgraded to websocket, HTTP status code: 404"),
        createPeer: (servers, relay) async => FakePeer(servers, relay),
      );
      connection.start();
      async.flushMicrotasks();
      expect(connection.status.phase, LinkPhase.failed);
      expect(connection.status.message, contains("didn't take the connection"));
      expect(connection.status.retryAt!.difference(clock.now()).inSeconds, greaterThanOrEqualTo(29));
      connection.dispose();
    });
  });

  test("a sign-in page answering for the room server (hotel Wi-Fi) is the phone's internet, not the server", () {
    fakeAsync((async) {
      final connection = RemoteConnection(
        target: pairedTarget,
        identity: const PhoneIdentity(appVersion: '1.2.3', device: 'Test phone'),
        connectSocket: (uri) async => throw Exception("WebSocketException: Connection to 'https://rooms.example.com:0/remote#' was not upgraded to websocket, HTTP status code: 200"),
        createPeer: (servers, relay) async => FakePeer(servers, relay),
      );
      connection.start();
      async.flushMicrotasks();
      expect(connection.status.message, contains('Check your internet connection'));
      expect(connection.status.retryAt!.difference(clock.now()).inSeconds, lessThan(5));
      connection.dispose();
    });
  });

  test('coming back to the app while the link is still closing leaves it connecting, not stopped', () {
    fakeAsync((async) {
      final h = Harness(pairedTarget);
      h.connection.start();
      async.flushMicrotasks();
      h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      final closing = h.peer.closeGate = Completer<void>();
      // Back before the stop has finished closing the peer connection.
      unawaited(h.connection.stop());
      h.connection.resume();
      async.flushMicrotasks();
      closing.complete();
      async.flushMicrotasks();
      expect(h.connection.running, isTrue);
      expect(h.connection.status.phase, isNot(LinkPhase.idle));
      h.connection.dispose();
    });
  });

  test("the PC's protocol error is shown and not retried; other errors are notices", () {
    fakeAsync((async) {
      final h = Harness(pairedTarget);
      h.connection.start();
      async.flushMicrotasks();
      h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      h.pcSignal(secret, phoneId, h.socket.signals().first.session, 'sdp', jsonEncode({'type': 'answer', 'sdp': 'v=0'}));
      async.flushMicrotasks();
      h.peer.open();
      h.peer.receive({'type': 'welcome', 'protocol': 1});
      async.flushMicrotasks();
      final notices = <String?>[];
      h.connection.notice.addListener(() => notices.add(h.connection.notice.value));
      h.peer.receive({'type': 'error', 'code': 'not-allowed', 'message': 'Only Alex can control this video.'});
      expect(notices, contains('Only Alex can control this video.'));
      expect(h.connection.status.isConnected, isTrue);
      h.peer.receive({'type': 'error', 'code': 'protocol', 'message': 'Update BlackPearl Mobile to control this PC.'});
      async.flushMicrotasks();
      expect(h.connection.status.phase, LinkPhase.failed);
      expect(h.connection.status.retryAt, isNull);
      expect(h.connection.status.message, 'Update BlackPearl Mobile to control this PC.');
      h.connection.dispose();
    });
  });

  test('a room server socket that goes silent is replaced', () {
    fakeAsync((async) {
      final h = Harness(pairedTarget);
      h.connection.start();
      async.flushMicrotasks();
      h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      h.socket.receive({'type': 'remote-offline'});
      async.flushMicrotasks();
      h.socket.answerPings = false;
      async.elapse(const Duration(seconds: 50));
      expect(h.sockets, hasLength(1));
      async.elapse(const Duration(seconds: 30));
      expect(h.sockets.first.closed, isTrue);
      expect(h.sockets.length, 2, reason: 'a new socket after the silence and a short wait');
      h.connection.dispose();
    });
  });

  test('a failure only the user can fix stays stopped through resumes, network changes and backgrounding', () {
    fakeAsync((async) {
      final h = Harness(pairedTarget);
      h.connection.start();
      async.flushMicrotasks();
      h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      h.pcSignal(secret, phoneId, h.socket.signals().first.session, 'rejected', 'unknown-phone', auth: '');
      async.flushMicrotasks();
      expect(h.connection.status.needsPairing, isTrue);

      h.connection.resume();
      h.connection.networkChanged();
      async.elapse(const Duration(minutes: 1));
      unawaited(h.connection.stop());
      async.flushMicrotasks();
      h.connection.resume();
      async.elapse(const Duration(minutes: 1));
      expect(h.sockets, hasLength(1), reason: 'nothing starts again on its own');
      expect(h.connection.status.phase, LinkPhase.failed);
      expect(h.connection.status.needsPairing, isTrue, reason: '"Scan a new code" stays on screen');
      expect(h.connection.status.message, 'This phone was removed from the PC. Pair it again.');

      // The user asking does start again.
      h.connection.retryNow();
      async.flushMicrotasks();
      expect(h.sockets, hasLength(2));
      expect(h.connection.status.phase, LinkPhase.connecting);
      h.connection.dispose();
    });
  });

  test("a PC that welcomes but never pairs times out and asks for a new code", () {
    fakeAsync((async) {
      final h = Harness(LinkTarget.pairing(PairLink(pcId: pcId, code: code, server: 'https://rooms.example.com', name: 'Study')));
      h.connection.start();
      async.flushMicrotasks();
      h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      h.pcSignal(code, 'pair', h.socket.signals().first.session, 'sdp', jsonEncode({'type': 'answer', 'sdp': 'v=0'}));
      async.flushMicrotasks();
      h.peer.open();
      h.peer.receive({'type': 'welcome', 'protocol': 1, 'pc': 'Study PC'});
      async.flushMicrotasks();
      expect(h.connection.status.phase, LinkPhase.pairing);
      async.elapse(const Duration(seconds: 19));
      expect(h.connection.status.phase, LinkPhase.pairing);
      async.elapse(const Duration(seconds: 2));
      expect(h.connection.status.phase, LinkPhase.failed);
      expect(h.connection.status.message, "The PC didn't finish pairing this phone");
      expect(h.connection.status.needsPairing, isTrue);
      expect(h.peer.closed, isTrue);
      expect(h.paired, isEmpty);
      h.connection.dispose();
    });
  });

  test("an answer applied after a new session started neither fails nor marks the new session", () {
    fakeAsync((async) {
      final h = Harness(pairedTarget);
      h.connection.start();
      async.flushMicrotasks();
      h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      final first = h.peer;
      final gate = first.answerGate = Completer<void>();
      final firstSession = h.socket.signals().first.session;
      h.pcSignal(secret, phoneId, firstSession, 'sdp', jsonEncode({'type': 'answer', 'sdp': 'old'}));
      async.flushMicrotasks();

      // The PC comes online again: a new session with a new peer, while the old answer is still being applied.
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      expect(h.peers, hasLength(2));
      final second = h.peer;
      final secondSession = h.socket.signals().where((s) => s.session != firstSession).first.session;

      gate.complete();
      async.flushMicrotasks();
      // The new session has no answer yet, so its candidates still wait.
      h.pcSignal(
        secret,
        phoneId,
        secondSession,
        'ice',
        jsonEncode({'candidate': 'candidate:3 1 UDP 1 192.168.1.6 6001 typ host', 'mid': '0'}),
      );
      async.flushMicrotasks();
      expect(second.remoteCandidates, isEmpty, reason: "the old session's answer doesn't count for the new one");
      h.pcSignal(secret, phoneId, secondSession, 'sdp', jsonEncode({'type': 'answer', 'sdp': 'new'}));
      async.flushMicrotasks();
      expect(second.answer, 'new');
      expect(second.remoteCandidates.single.$1, contains('192.168.1.6'));
      expect(h.connection.status.phase, LinkPhase.linking);
      h.connection.dispose();
    });
  });

  test("an old session's failed answer doesn't tear down the new one", () {
    fakeAsync((async) {
      final h = Harness(pairedTarget);
      h.connection.start();
      async.flushMicrotasks();
      h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      final gate = h.peer.answerGate = Completer<void>();
      h.pcSignal(secret, phoneId, h.socket.signals().first.session, 'sdp', jsonEncode({'type': 'answer', 'sdp': 'old'}));
      async.flushMicrotasks();
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      final second = h.peer;

      gate.completeError(StateError('closed'));
      async.flushMicrotasks();
      expect(h.connection.status.phase, LinkPhase.linking);
      expect(second.closed, isFalse);
      expect(h.sockets.single.closed, isFalse);
      h.connection.dispose();
    });
  });
}
