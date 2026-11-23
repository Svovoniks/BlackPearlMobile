import 'dart:async';

import 'package:blackpearl_mobile/app_model.dart';
import 'package:blackpearl_mobile/connection/remote_connection.dart';
import 'package:blackpearl_mobile/protocol/pair_link.dart';
import 'package:blackpearl_mobile/storage/app_settings.dart';
import 'package:blackpearl_mobile/storage/paired_pcs.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'background_test.dart' show FakeBackground;
import 'connection_test.dart' show FakePeer, FakeSocket;

final studyPc = PairedPc(
  pcId: '0123456789ABCDEF0123456789ABCDEF',
  name: 'Study',
  server: 'https://rooms.example.com',
  phoneId: 'a' * 32,
  secret: 'b' * 64,
);
final ghost = PairLink(pcId: 'F' * 32, code: '00112233445566778899aabbccddeeff', server: 'https://rooms.example.com', name: 'Ghost');

/// The app with a PC in use (Study) whose room server and PC the test plays, and a pairing code tried while it is kept.
class Rig {
  Rig({bool backgroundLink = true}) {
    unawaited(settings.setBackgroundLink(backgroundLink));
    app = AppModel(
      store: PairedPcStore(MemorySecretStore()),
      settings: settings,
      background: background,
      connect: (target, {onPaired, onPcName}) => RemoteConnection(
        target: target,
        identity: const PhoneIdentity(appVersion: '1.0.0', device: 'Test phone'),
        connectSocket: (_) async {
          final socket = FakeSocket();
          (target.isPairing ? attemptSockets : studySockets).add(socket);
          return socket;
        },
        createPeer: (servers, relay) async {
          final peer = FakePeer(servers, relay);
          (target.isPairing ? attemptPeers : studyPeers).add(peer);
          return peer;
        },
        onPaired: onPaired,
        onPcName: onPcName,
      ),
    );
  }

  final background = FakeBackground();
  final settings = AppSettings(MemorySettingsStore());
  late final AppModel app;
  final List<FakeSocket> studySockets = [], attemptSockets = [];
  final List<FakePeer> studyPeers = [], attemptPeers = [];
  late RemoteConnection study;

  /// Loads the app, and links it to Study.
  void start(FakeAsync async) {
    unawaited(app.store.save([studyPc]).then((_) => app.load()));
    async.flushMicrotasks();
    study = app.connection!;
    studySockets.last
      ..receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'})
      ..receive({'type': 'remote-online'});
    async.flushMicrotasks();
    studyPeers.last.open();
    studyPeers.last.receive({'type': 'welcome', 'protocol': 1, 'pc': 'Study', 'features': <String>[]});
    async.flushMicrotasks();
    expect(study.status.isConnected, isTrue);
  }

  /// Tries the Ghost code, whose server answers once the test says.
  RemoteConnection pair(FakeAsync async) {
    app.pair(ghost);
    async.flushMicrotasks();
    final attempt = app.connection!;
    expect(attempt.target.isPairing, isTrue);
    expect(study.running, isTrue, reason: 'Study is kept while the code is tried');
    return attempt;
  }
}

void main() {
  test("a code for a PC that isn't online brings the PC in use back, and says so", () {
    fakeAsync((async) {
      final rig = Rig()..start(async);
      final attempt = rig.pair(async);
      rig.attemptSockets.last
        ..receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'})
        ..receive({'type': 'remote-offline'});
      async.flushMicrotasks();
      expect(rig.app.connection, same(rig.study));
      expect(rig.study.status.isConnected, isTrue);
      expect(attempt.running, isFalse);
      expect(rig.app.showPairing, isTrue);
      expect(rig.app.pairingError, contains("Ghost isn't online"));
      rig.app.dispose();
    });
  });

  test('an attempt that neither pairs nor fails gives way to the PC in use after a while', () {
    fakeAsync((async) {
      final rig = Rig()..start(async);
      // The code's room server never answers.
      final attempt = rig.pair(async);
      async.elapse(AppModel.pairingAttemptLimit - const Duration(seconds: 1));
      expect(rig.app.connection, same(attempt));
      async.elapse(const Duration(seconds: 2));
      expect(rig.app.connection, same(rig.study));
      expect(attempt.running, isFalse);
      expect(rig.app.pairingError, contains("didn't finish pairing"));
      rig.app.dispose();
    });
  });

  test('closing the app without the service ends the attempt and lets the PC in use go too', () {
    fakeAsync((async) {
      final rig = Rig(backgroundLink: false)..start(async);
      final attempt = rig.pair(async);
      rig.app.paused();
      async.elapse(const Duration(seconds: 31));
      expect(attempt.running, isFalse);
      expect(rig.study.running, isFalse);
      expect(rig.app.connection, same(rig.study));
      async.elapse(const Duration(minutes: 10));
      expect(rig.study.running, isFalse);
      rig.app.dispose();
    });
  });

  test("the notification's Disconnect during an attempt drops the PC in use, and the service stops", () {
    fakeAsync((async) {
      final rig = Rig()..start(async);
      final attempt = rig.pair(async);
      expect(rig.background.running, isTrue);
      rig.background.press!('disconnect');
      async.flushMicrotasks();
      expect(attempt.running, isFalse);
      expect(rig.study.running, isFalse);
      expect(rig.background.running, isFalse);
      rig.app.dispose();
    });
  });

  test("the notification's Play/Pause during an attempt goes to the PC it names", () {
    fakeAsync((async) {
      final rig = Rig()..start(async);
      rig.pair(async);
      expect(rig.background.shown.last.title, 'Study');
      rig.background.press!('toggle');
      expect(rig.studyPeers.last.sent.where((m) => m['type'] == 'command').map((m) => m['action']), ['toggle']);
      rig.app.dispose();
    });
  });

  test('forgetting the PC kept for an attempt lets it go: a failing attempt then brings nothing back', () {
    fakeAsync((async) {
      final rig = Rig()..start(async);
      final attempt = rig.pair(async);
      unawaited(rig.app.forget(studyPc));
      async.flushMicrotasks();
      expect(rig.study.running, isFalse);
      rig.attemptSockets.last
        ..receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'})
        ..receive({'type': 'error', 'text': 'Invalid PC id. Pair the phone again.'});
      async.flushMicrotasks();
      expect(rig.app.connection, same(attempt));
      expect(rig.app.pcs, isEmpty);
      rig.app.dispose();
    });
  });
}
