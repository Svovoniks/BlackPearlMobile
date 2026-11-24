import 'dart:async';
import 'dart:convert';

import 'package:blackpearl_mobile/app_model.dart';
import 'package:blackpearl_mobile/connection/remote_connection.dart';
import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/protocol/pair_link.dart';
import 'package:blackpearl_mobile/protocol/signing.dart';
import 'package:blackpearl_mobile/storage/paired_pcs.dart';
import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'connection_test.dart' show FakePeer, FakeSocket, pcId, phoneId, secret, code;

// The home-network fallback (PHONE-REMOTE.md, "On the home network"): the room server first, always; the PC's own
// socket when the server can't introduce the two; nothing new for a PC whose address the phone doesn't know.

const home = LanEndpoints(port: 47830, addresses: ['192.168.1.20', '10.0.0.5']);
const roomServer = 'rooms.example.com';

/// Plays the room server and the PC's home-network sockets. Hosts in [unreachable] fail to connect.
class LanHarness {
  LanHarness(LinkTarget target) {
    connection = RemoteConnection(
      target: target,
      identity: const PhoneIdentity(appVersion: '1.2.3', device: 'Test phone'),
      connectSocket: (uri) async {
        uris.add(uri);
        if (unreachable.contains(uri.host)) throw Exception('SocketException: Connection refused');
        final socket = FakeSocket();
        (sockets[uri.host] ??= []).add(socket);
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
  final Set<String> unreachable = {};
  final Map<String, List<FakeSocket>> sockets = {};
  final List<FakePeer> peers = [];
  final List<PairedPc> paired = [];

  FakeSocket socket(String host) => sockets[host]!.last;
  List<Uri> lanUris() => uris.where((u) => u.host != roomServer).toList();

  /// The PC's side of its home-network socket: welcomes the phone that asked for it.
  void greet(String host) {
    final s = socket(host);
    expect(s.sent.first, {'type': 'remote-phone', 'target': pcId, 'number': 1});
    s.receive({'type': 'remote-welcome', 'target': 'lan:1', 'data': jsonEncode({'iceServers': [], 'forceRelay': false})});
    s.receive({'type': 'remote-online'});
  }

  /// Answers the phone's offer on [via] and finishes the link, as the PC would.
  void link(FakeSocket via, {Map<String, dynamic>? lan}) {
    final offer = via.signals().firstWhere((s) => s.kind == 'sdp');
    final payload = jsonEncode({'type': 'answer', 'sdp': 'v=0'});
    final signal = SignedSignal(
      phone: phoneId,
      session: offer.session,
      kind: 'sdp',
      payload: payload,
      auth: Signing.sign(secret, 'pc', phoneId, offer.session, 'sdp', payload),
    );
    via.receive({'type': 'signal', 'data': signal.encode()});
    peers.last.open();
    peers.last.receive({'type': 'welcome', 'protocol': 1, 'pc': 'Living room', 'pcId': pcId, 'lan': ?lan});
  }
}

LinkTarget target({LanEndpoints? lan = home}) => LinkTarget.paired(
  PairedPc(pcId: pcId, name: 'Living room', server: 'https://$roomServer', phoneId: phoneId, secret: secret, lan: lan),
);

void main() {
  test('a PC whose home-network address the phone doesn\'t know: only the room server, as before', () {
    fakeAsync((async) {
      final h = LanHarness(target(lan: null))..unreachable.add(roomServer);
      h.connection.start();
      async.flushMicrotasks();
      expect(h.connection.status.message, "Can't reach the room server. Check your internet connection.");
      expect(h.lanUris(), isEmpty);
      h.sockets.clear();
      h.unreachable.clear();
      async.elapse(const Duration(seconds: 1));
      h.socket(roomServer).receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      h.socket(roomServer).receive({'type': 'remote-offline'});
      async.elapse(const Duration(minutes: 1));
      expect(h.connection.status.phase, LinkPhase.waitingForPc);
      expect(h.lanUris(), isEmpty, reason: 'nothing tried besides the room server');
      h.connection.dispose();
    });
  });

  test('the room server out of reach: the phone links up on the home network, with no relay servers', () {
    fakeAsync((async) {
      final h = LanHarness(target())..unreachable.add(roomServer);
      h.connection.start();
      async.flushMicrotasks();
      expect(h.lanUris().map((u) => u.toString()), ['ws://192.168.1.20:47830/remote', 'ws://10.0.0.5:47830/remote'], reason: 'every address at once');
      expect(h.connection.status.phase, LinkPhase.connecting, reason: 'not failed while the home network is tried');
      h.greet('10.0.0.5');
      async.flushMicrotasks();
      expect(h.connection.viaHomeNetwork, isTrue);
      expect(h.socket('192.168.1.20').closed, isTrue, reason: 'the address that answered later is let go');
      expect(h.connection.status.phase, LinkPhase.linking);
      expect(h.peers.single.iceServers, isEmpty);
      expect(h.peers.single.forceRelay, isFalse);
      final lanSocket = h.socket('10.0.0.5');
      expect(lanSocket.signals().map((s) => s.kind), ['sdp', 'ice'], reason: 'the signed offer goes on the PC\'s own socket');
      h.link(lanSocket);
      async.flushMicrotasks();
      expect(h.connection.status.phase, LinkPhase.connected);
      async.elapse(const Duration(seconds: 60));
      expect(lanSocket.sent.where((m) => m['type'] == 'ping'), isNotEmpty, reason: 'the PC answers pings as the room server does');
      expect(h.connection.status.phase, LinkPhase.connected);
      h.connection.dispose();
    });
  });

  test('the room server says the PC is offline: the home network is tried now and every 20 seconds while it says so', () {
    fakeAsync((async) {
      final h = LanHarness(target(lan: const LanEndpoints(port: 47831, addresses: ['192.168.1.20'])));
      h.connection.start();
      async.flushMicrotasks();
      final server = h.socket(roomServer);
      server.receive({'type': 'remote-welcome', 'data': '{"iceServers":["stun:stun.example.com:3478"]}'});
      server.receive({'type': 'remote-offline'});
      async.flushMicrotasks();
      expect(h.lanUris(), hasLength(1));
      // Another BlackPearl on the network has that address now.
      h.socket('192.168.1.20').receive({'type': 'error', 'text': 'This is another PC.'});
      async.flushMicrotasks();
      expect(h.connection.status.phase, LinkPhase.waitingForPc);
      expect(server.closed, isFalse, reason: 'the room server stays, to hear when the PC comes online');
      expect(h.socket('192.168.1.20').closed, isTrue);
      async.elapse(const Duration(seconds: 19));
      expect(h.lanUris(), hasLength(1));
      async.elapse(const Duration(seconds: 2));
      expect(h.lanUris(), hasLength(2), reason: 'tried again 20 seconds later');
      h.greet('192.168.1.20');
      async.flushMicrotasks();
      expect(server.closed, isTrue, reason: 'the home network takes over from the room server');
      expect(h.connection.viaHomeNetwork, isTrue);
      expect(h.connection.status.phase, LinkPhase.linking);
      expect(h.peers.single.iceServers, isEmpty, reason: 'the room server\'s STUN servers aren\'t used on the home network');
      h.connection.dispose();
    });
  });

  test('the PC coming online at the room server while the home network is tried keeps the room server', () {
    fakeAsync((async) {
      final h = LanHarness(target());
      h.connection.start();
      async.flushMicrotasks();
      final server = h.socket(roomServer);
      server.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      server.receive({'type': 'remote-offline'});
      server.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      expect(h.connection.status.phase, LinkPhase.linking);
      h.greet('192.168.1.20');
      async.flushMicrotasks();
      expect(h.connection.viaHomeNetwork, isFalse);
      expect(h.socket('192.168.1.20').closed, isTrue, reason: 'the late home-network socket is let go');
      expect(server.closed, isFalse);
      expect(h.peers, hasLength(1));
      expect(server.signals().where((s) => s.kind == 'sdp'), hasLength(1));
      async.elapse(const Duration(seconds: 30));
      expect(h.lanUris(), hasLength(2), reason: 'no more tries once the PC is online');
      h.connection.dispose();
    });
  });

  test("the room server refusing, with the home network out of reach too, ends with the server's reason and a slow retry", () {
    fakeAsync((async) {
      final h = LanHarness(target())..unreachable.addAll(['192.168.1.20']);
      h.connection.start();
      async.flushMicrotasks();
      h.socket(roomServer).receive({'type': 'error', 'text': 'Too many phones are connecting to this PC right now.'});
      async.flushMicrotasks();
      expect(h.connection.status.phase, LinkPhase.connecting, reason: '10.0.0.5 may still answer');
      async.elapse(const Duration(seconds: 4));
      expect(h.connection.status.phase, LinkPhase.failed);
      expect(h.connection.status.message, 'Too many phones are connecting to this PC right now.');
      expect(h.connection.status.retryAt!.difference(clock.now()).inSeconds, greaterThanOrEqualTo(29));
      expect(h.socket('10.0.0.5').closed, isTrue, reason: 'the silent address is let go');
      h.connection.dispose();
    });
  });

  test('a home-network socket lost before the link is up fails as a lost PC, and the next attempt starts at the room server', () {
    fakeAsync((async) {
      final h = LanHarness(target(lan: const LanEndpoints(port: 47830, addresses: ['192.168.1.20'])))..unreachable.add(roomServer);
      h.connection.start();
      async.flushMicrotasks();
      h.greet('192.168.1.20');
      async.flushMicrotasks();
      h.socket('192.168.1.20').drop();
      async.flushMicrotasks();
      expect(h.connection.status.phase, LinkPhase.failed);
      expect(h.connection.status.message, 'Lost the connection to the PC.');
      final tried = h.uris.length;
      h.unreachable.clear();
      async.elapse(const Duration(seconds: 3));
      expect(h.uris[tried].host, roomServer);
      expect(h.connection.viaHomeNetwork, isFalse);
      h.connection.dispose();
    });
  });

  test("the PC's welcome replaces the address the phone knew; one without an address, or a malformed one, keeps it", () {
    fakeAsync((async) {
      final h = LanHarness(target(lan: null));
      h.connection.start();
      async.flushMicrotasks();
      void viaServer({Map<String, dynamic>? lan}) {
        final server = h.socket(roomServer);
        server.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
        server.receive({'type': 'remote-online'});
        async.flushMicrotasks();
        h.link(server, lan: lan);
        async.flushMicrotasks();
      }

      viaServer(lan: {'port': 47832, 'addresses': ['192.168.1.21', 'not an address', 7]});
      expect(h.connection.learnedLan, const LanEndpoints(port: 47832, addresses: ['192.168.1.21']));
      expect(h.connection.target.lan, h.connection.learnedLan);
      h.peers.last.lose();
      async.elapse(const Duration(seconds: 2));
      viaServer();
      expect(h.connection.learnedLan?.port, 47832, reason: 'a PC not listening just now says nothing, and the phone keeps the address');
      h.peers.last.lose();
      async.elapse(const Duration(seconds: 3));
      viaServer(lan: {'port': 70000, 'addresses': ['192.168.1.22']});
      expect(h.connection.learnedLan?.port, 47832);
      h.peers.last.lose();
      async.elapse(const Duration(seconds: 5));
      // The server goes: the address learnt on this connection is the one tried.
      h.socket(roomServer).drop();
      async.flushMicrotasks();
      expect(h.lanUris().last.toString(), 'ws://192.168.1.21:47832/remote');
      h.connection.dispose();
    });
  });

  test('pairing never tries the home network, and the paired PC keeps the address its welcome gave', () {
    fakeAsync((async) {
      final h = LanHarness(LinkTarget.pairing(PairLink(pcId: pcId, code: code, server: 'https://$roomServer', name: 'Study')));
      h.connection.start();
      async.flushMicrotasks();
      final server = h.socket(roomServer);
      server.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      server.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      final offer = server.signals().first;
      final payload = jsonEncode({'type': 'answer', 'sdp': 'v=0'});
      server.receive({
        'type': 'signal',
        'data': SignedSignal(phone: 'pair', session: offer.session, kind: 'sdp', payload: payload, auth: Signing.sign(code, 'pc', 'pair', offer.session, 'sdp', payload)).encode(),
      });
      h.peers.last.open();
      h.peers.last.receive({'type': 'welcome', 'protocol': 1, 'pc': 'Study', 'lan': {'port': 47830, 'addresses': ['192.168.1.20']}});
      h.peers.last.receive({'type': 'paired', 'phoneId': phoneId, 'secret': secret, 'pc': 'Study', 'pcId': pcId});
      async.flushMicrotasks();
      expect(h.paired.single.lan, const LanEndpoints(port: 47830, addresses: ['192.168.1.20']));
      h.connection.dispose();

      final refused = LanHarness(LinkTarget.pairing(PairLink(pcId: pcId, code: code, server: 'https://$roomServer', name: 'Study')))
        ..unreachable.add(roomServer);
      refused.connection.start();
      async.flushMicrotasks();
      expect(refused.lanUris(), isEmpty);
      refused.connection.dispose();
    });
  });

  test('a paired PC stored with its address reads back with it; one stored before has none; a malformed one is dropped', () async {
    final store = PairedPcStore(MemorySecretStore());
    final withLan = PairedPc(pcId: pcId, name: 'Study', server: 'https://$roomServer', phoneId: phoneId, secret: secret, lan: home);
    await store.save([withLan, withLan.withLan(null)]);
    final read = await store.load();
    expect(read.first.lan, home);
    expect(read.last.lan, isNull);
    expect(read.first.withName('Den').lan, home, reason: 'renaming keeps it');
    final old = PairedPc.fromJson({'pcId': pcId, 'name': 'Old', 'server': 'https://$roomServer', 'phoneId': phoneId, 'secret': secret});
    expect(old?.lan, isNull);
    expect(old?.toJson().containsKey('lan'), isFalse, reason: 'stored as before');
    expect(PairedPc.fromJson({...withLan.toJson(), 'lan': {'port': '47830', 'addresses': ['192.168.1.20']}})?.lan, isNull);
    expect(LanEndpoints.fromJson({'port': 47830, 'addresses': List.generate(12, (i) => '10.0.0.$i')})?.addresses, hasLength(LanEndpoints.maxAddresses));
    expect(remoteLanUri('fe80::1', 47830).toString(), 'ws://[fe80::1]:47830/remote');
  });

  test('the app keeps the address each connection learns with its PC, and saves it only when it changed', () {
    fakeAsync((async) {
      final secrets = MemorySecretStore();
      final store = PairedPcStore(secrets);
      final sockets = <FakeSocket>[];
      final peers = <FakePeer>[];
      var writes = 0;
      unawaited(store.save([target(lan: null).asPaired()]));
      async.flushMicrotasks();
      final model = AppModel(
        store: _CountingStore(secrets, () => writes++),
        connect: (target, {onPaired, onPcName}) => RemoteConnection(
          target: target,
          identity: const PhoneIdentity(appVersion: '1.2.3', device: 'Test phone'),
          connectSocket: (uri) async => FakeSocket()..let(sockets.add),
          createPeer: (servers, relay) async => FakePeer(servers, relay)..let(peers.add),
          onPaired: onPaired,
          onPcName: onPcName,
        ),
      );
      unawaited(model.load());
      async.flushMicrotasks();
      expect(model.connection?.target.lan, isNull);

      void connect(Map<String, dynamic>? lan) {
        final server = sockets.last;
        server.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
        server.receive({'type': 'remote-online'});
        async.flushMicrotasks();
        final offer = server.signals().firstWhere((s) => s.kind == 'sdp');
        final payload = jsonEncode({'type': 'answer', 'sdp': 'v=0'});
        server.receive({
          'type': 'signal',
          'data': SignedSignal(phone: phoneId, session: offer.session, kind: 'sdp', payload: payload, auth: Signing.sign(secret, 'pc', phoneId, offer.session, 'sdp', payload)).encode(),
        });
        peers.last.open();
        peers.last.receive({'type': 'welcome', 'protocol': 1, 'pc': 'Living room', 'lan': ?lan});
        async.flushMicrotasks();
      }

      connect({'port': 47830, 'addresses': ['192.168.1.20']});
      expect(model.pcs.single.lan, const LanEndpoints(port: 47830, addresses: ['192.168.1.20']));
      final saved = writes;
      expect(saved, greaterThan(0));
      peers.last.lose();
      async.elapse(const Duration(seconds: 2));
      connect({'port': 47830, 'addresses': ['192.168.1.20']});
      expect(writes, saved, reason: 'the same address again writes nothing');
      peers.last.lose();
      async.elapse(const Duration(seconds: 2));
      connect({'port': 47831, 'addresses': ['192.168.1.33']});
      expect(model.pcs.single.lan?.addresses, ['192.168.1.33']);
      unawaited(store.load().then((pcs) => expect(pcs.single.lan?.port, 47831)));
      async.flushMicrotasks();
      model.dispose();
    });
  });
}

extension on LinkTarget {
  PairedPc asPaired() => PairedPc(pcId: pcId, name: pcName, server: server, phoneId: phone, secret: keyHex, lan: lan);
}

extension _Let<T> on T {
  T let(void Function(T) use) {
    use(this);
    return this;
  }
}

/// Paired-PC storage that counts writes of the list.
class _CountingStore extends PairedPcStore {
  _CountingStore(super.store, this.wrote);
  final void Function() wrote;
  @override
  Future<void> save(List<PairedPc> pcs) {
    wrote();
    return super.save(pcs);
  }
}
