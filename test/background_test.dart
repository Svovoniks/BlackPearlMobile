import 'dart:async';

import 'package:blackpearl_mobile/app_model.dart';
import 'package:blackpearl_mobile/background/background_link.dart';
import 'package:blackpearl_mobile/connection/remote_connection.dart';
import 'package:blackpearl_mobile/connection/transport.dart';
import 'package:blackpearl_mobile/storage/app_settings.dart';
import 'package:blackpearl_mobile/storage/paired_pcs.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// The background service, as the app sees it: what it was asked to show, and the buttons on its notification.
class FakeBackground extends BackgroundLink {
  final List<BackgroundNotice> shown = [];
  int stops = 0, asked = 0;
  bool _on = false;
  void Function(String action)? press;

  @override
  bool get running => _on;
  @override
  void listen(void Function(String action) onAction) => press = onAction;
  @override
  Future<bool> show(BackgroundNotice notice) async {
    _on = true;
    shown.add(notice);
    return true;
  }

  @override
  Future<void> stop() async {
    _on = false;
    stops++;
  }

  @override
  Future<void> askForNotifications() async => asked++;
}

final pc = PairedPc(pcId: '0123456789ABCDEF0123456789ABCDEF', name: 'Study', server: 'https://rooms.example.com', phoneId: 'a' * 32, secret: 'b' * 64);

AppModel model(FakeBackground background, AppSettings settings) => AppModel(
  store: PairedPcStore(MemorySecretStore()),
  settings: settings,
  background: background,
  connect: (target, {onPaired, onPcName}) => RemoteConnection(
    target: target,
    identity: const PhoneIdentity(appVersion: '1.0.0', device: 'Test phone'),
    connectSocket: (_) => Completer<SignalingSocket>().future,
    createPeer: (_, _) => Completer<PeerLink>().future,
  ),
);

void main() {
  test('with a paired PC the service starts, names the PC, and asks once to show its notification', () async {
    final background = FakeBackground();
    final app = model(background, AppSettings(MemorySettingsStore()));
    await app.store.save([pc]);
    await app.load();
    await pumpEventQueue();
    expect(background.running, isTrue);
    expect(background.shown.last.title, 'Study');
    expect(background.shown.last.text, 'Reconnecting to the PC');
    expect(background.asked, 1);
    app.dispose();
  });

  test('closing the app keeps the link while the service runs, and lets it go once the setting is off', () {
    fakeAsync((async) {
      final background = FakeBackground();
      final settings = AppSettings(MemorySettingsStore());
      final app = model(background, settings);
      unawaited(app.store.save([pc]).then((_) => app.load()));
      async.flushMicrotasks();
      final connection = app.connection!;
      app.paused();
      async.elapse(const Duration(minutes: 5));
      expect(connection.running, isTrue);
      // Turned off from the notification while the app is closed.
      background.press!('turnOff');
      async.flushMicrotasks();
      expect(settings.backgroundLink, isFalse);
      expect(background.running, isFalse);
      async.elapse(const Duration(seconds: 31));
      expect(connection.running, isFalse);
      app.dispose();
    });
  });

  test('turning the setting off stops the service; on again starts it', () async {
    final background = FakeBackground();
    final settings = AppSettings(MemorySettingsStore());
    final app = model(background, settings);
    await app.store.save([pc]);
    await app.load();
    await pumpEventQueue();
    await settings.setBackgroundLink(false);
    expect(background.running, isFalse);
    expect(background.stops, greaterThan(0));
    await settings.setBackgroundLink(true);
    await pumpEventQueue();
    expect(background.running, isTrue);
    app.dispose();
  });

  test('a pairing link never starts the service', () async {
    final background = FakeBackground();
    final app = model(background, AppSettings(MemorySettingsStore()));
    await app.load();
    await pumpEventQueue();
    expect(background.shown, isEmpty);
    app.dispose();
  });

  test('settings remember their values', () async {
    final store = MemorySettingsStore();
    final settings = AppSettings(store);
    await settings.setBackgroundLink(false);
    await settings.setAwayQuality('480p');
    await settings.setAwayQuality('8k');
    final again = AppSettings(store);
    await again.load();
    expect(again.backgroundLink, isFalse);
    expect(again.awayQuality, '480p');
  });
}
