import 'dart:async';

import 'package:blackpearl_mobile/app_model.dart';
import 'package:blackpearl_mobile/connection/remote_connection.dart';
import 'package:blackpearl_mobile/connection/transport.dart';
import 'package:blackpearl_mobile/main.dart';
import 'package:blackpearl_mobile/protocol/pair_link.dart';
import 'package:blackpearl_mobile/storage/paired_pcs.dart';
import 'package:blackpearl_mobile/ui/home_shell.dart';
import 'package:blackpearl_mobile/ui/theme.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Secure storage that fails while [failing] is set, as a restored backup or a locked keystore does.
class FlakyStore extends MemorySecretStore {
  bool failReads = false;
  bool failWrites = false;

  @override
  Future<String?> read(String key) async {
    if (failReads) throw PlatformException(code: 'Exception', message: 'Failed to unwrap key');
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw PlatformException(code: 'Exception', message: 'Keystore is locked');
    return super.write(key, value);
  }
}

const pcId = '0123456789ABCDEF0123456789ABCDEF';
const code = '00112233445566778899aabbccddeeff';
final link = PairLink(pcId: pcId, code: code, server: 'https://rooms.example.com', name: 'Study');
final pc = PairedPc(pcId: pcId, name: 'Study', server: 'https://rooms.example.com', phoneId: 'a' * 32, secret: 'b' * 64);

/// An app model whose connections never reach a server; [onPaired] is what the newest connection would call.
class TestApp {
  TestApp(this.secrets) {
    model = AppModel(
      store: PairedPcStore(secrets),
      connect: (target, {onPaired, onPcName}) {
        this.onPaired = onPaired;
        targets.add(target);
        return RemoteConnection(
          target: target,
          identity: const PhoneIdentity(appVersion: '1.0.0', device: 'Test phone'),
          connectSocket: (_) => Completer<SignalingSocket>().future,
          createPeer: (_, _) => Completer<PeerLink>().future,
          onPaired: onPaired,
          onPcName: onPcName,
        );
      },
    );
  }

  final FlakyStore secrets;
  late final AppModel model;
  void Function(PairedPc pc)? onPaired;
  final List<LinkTarget> targets = [];
}

void main() {
  test("storage that can't be read is reported, and loading again works once it can", () async {
    final app = TestApp(FlakyStore()..failReads = true);
    await app.model.load();
    expect(app.model.loaded, isFalse);
    expect(app.model.loadError, contains('secure storage'));

    app.secrets.failReads = false;
    await PairedPcStore(app.secrets).save([pc]);
    await app.model.load();
    expect(app.model.loadError, isNull);
    expect(app.model.loaded, isTrue);
    expect(app.model.pcs.single.pcId, pcId);
    expect(app.model.connection?.target.pcId, pcId);
    app.model.dispose();
  });

  test('a save that fails after pairing is reported', () async {
    final app = TestApp(FlakyStore());
    await app.model.load();
    app.model.pair(link);
    final notices = <String?>[];
    app.model.notice.addListener(() => notices.add(app.model.notice.value));
    app.secrets.failWrites = true;
    app.onPaired!(pc);
    await pumpEventQueue();
    expect(notices.whereType<String>().single, contains("couldn't save it"));
    expect(app.model.pcs.single.pcId, pcId, reason: 'still usable until the app closes');
    app.model.dispose();
  });

  test("pairing while the stored PCs couldn't be read doesn't replace them", () async {
    final livingRoom = PairedPc(pcId: 'F' * 32, name: 'Living room', server: 'https://rooms.example.com', phoneId: 'c' * 32, secret: 'd' * 64);
    final secrets = FlakyStore();
    await PairedPcStore(secrets).save([livingRoom]);
    secrets.failReads = true;
    final app = TestApp(secrets);
    await app.model.load();
    expect(app.model.loadError, isNotNull);
    final notices = <String?>[];
    app.model.notice.addListener(() => notices.add(app.model.notice.value));
    // A pairing link accepted on the error screen still pairs, for this session only.
    app.model.pair(link);
    app.onPaired!(pc);
    await pumpEventQueue();
    expect(app.model.pcs.single.pcId, pcId);
    expect(notices.whereType<String>().single, contains("couldn't save it"));
    secrets.failReads = false;
    expect((await PairedPcStore(secrets).load()).map((x) => x.name), ['Living room']);
    app.model.dispose();
  });

  test("a pairing code that doesn't work keeps the PC in use connected, and says why on the pairing screen", () async {
    final living = PairedPc(pcId: 'F' * 32, name: 'Living room', server: 'https://rooms.example.com', phoneId: 'c' * 32, secret: 'd' * 64);
    final secrets = FlakyStore();
    await PairedPcStore(secrets).save([living]);
    final connections = <RemoteConnection>[];
    final model = AppModel(
      store: PairedPcStore(secrets),
      connect: (target, {onPaired, onPcName}) {
        final connection = RemoteConnection(
          target: target,
          identity: const PhoneIdentity(appVersion: '1.0.0', device: 'Test phone'),
          // The PC in use stays connecting; the code's server can't be reached.
          connectSocket: (_) => target.isPairing ? Future.error(Exception('unreachable')) : Completer<SignalingSocket>().future,
          createPeer: (_, _) => Completer<PeerLink>().future,
          onPaired: onPaired,
          onPcName: onPcName,
        );
        connections.add(connection);
        return connection;
      },
    );
    await model.load();
    final working = model.connection!;
    model.pair(link);
    expect(model.connection!.target.isPairing, isTrue);
    expect(working.running, isTrue, reason: 'kept while the code is tried');
    await pumpEventQueue();
    expect(model.connection, same(working));
    expect(working.running, isTrue);
    expect(connections[1].running, isFalse, reason: 'the attempt with the code is over');
    expect(model.showPairing, isTrue);
    expect(model.pairingError, contains("Can't reach the room server"));
    expect(model.currentPcId, 'F' * 32);
    // Back from the pairing screen: the PC in use, still connected.
    model.cancelPairing();
    expect(model.showPairing, isFalse);
    model.dispose();
  });

  test('a pairing code that works replaces the PC in use', () async {
    final app = TestApp(FlakyStore());
    await PairedPcStore(app.secrets)
        .save([PairedPc(pcId: 'F' * 32, name: 'Living room', server: 'https://rooms.example.com', phoneId: 'c' * 32, secret: 'd' * 64)]);
    await app.model.load();
    final working = app.model.connection!;
    app.model.pair(link);
    final trial = app.model.connection!;
    app.onPaired!(pc);
    await pumpEventQueue();
    expect(working.running, isFalse);
    expect(app.model.connection, same(trial));
    app.model.dispose();
  });

  testWidgets('the app shows the storage problem with a working Try again', (tester) async {
    final app = TestApp(FlakyStore()..failReads = true);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Root(model: app.model, links: const Stream.empty(), network: const Stream.empty()),
      ),
    );
    await tester.runAsync(app.model.load);
    await tester.pump();
    expect(find.text("Couldn't open your paired PCs"), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    app.secrets.failReads = false;
    await tester.tap(find.text('Try again'));
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    expect(find.text("Couldn't open your paired PCs"), findsNothing);
    expect(app.model.loaded, isTrue);
    app.model.dispose();
  });

  testWidgets('a pairing link from outside the app asks first: Cancel keeps the current PC, Pair switches', (tester) async {
    final app = TestApp(FlakyStore());
    await PairedPcStore(app.secrets)
        .save([PairedPc(pcId: 'F' * 32, name: 'Living room', server: 'https://rooms.example.com', phoneId: 'c' * 32, secret: 'd' * 64)]);
    final links = StreamController<Uri>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Root(model: app.model, links: links.stream, network: const Stream<List<ConnectivityResult>>.empty()),
      ),
    );
    await tester.runAsync(app.model.load);
    await tester.pump();
    expect(app.targets.single.pcId, 'F' * 32);

    final uri = Uri.parse('blackpearl://pair?v=1&pc=$pcId&code=$code&server=https%3A%2F%2Frooms.example.com&name=Study');
    links.add(uri);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Pair with Study?'), findsOneWidget);
    expect(find.text('Through rooms.example.com'), findsOneWidget);
    expect(app.targets, hasLength(1), reason: 'nothing changes before the answer');
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(app.targets, hasLength(1));
    expect(app.model.connection?.target.pcId, 'F' * 32);

    links.add(uri);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Pair'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(app.targets, hasLength(2));
    expect(app.model.connection?.target.isPairing, isTrue);
    expect(app.model.connection?.target.pcId, pcId);
    await links.close();
    app.model.dispose();
  });

  group('Back', () {
    Future<TestApp> openApp(WidgetTester tester) async {
      final app = TestApp(FlakyStore());
      await PairedPcStore(app.secrets).save([pc]);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Root(model: app.model, links: const Stream.empty(), network: const Stream<List<ConnectivityResult>>.empty()),
        ),
      );
      await tester.runAsync(app.model.load);
      await tester.pump();
      return app;
    }

    Finder tab(String label) => find.descendant(of: find.byType(AppTabBar), matching: find.text(label));
    int shownTab(WidgetTester tester) => tester.widget<AppTabBar>(find.byType(AppTabBar)).index;

    // What the system's Back did: true when the app took it, false when it would close the app.
    Future<bool> back(WidgetTester tester) async {
      final handled = await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 400));
      return handled;
    }

    testWidgets('from Settings and the Library goes to the Remote; only the Remote closes the app', (tester) async {
      final app = await openApp(tester);
      expect(shownTab(tester), HomeShell.remoteTab);

      await tester.tap(tab('Settings'));
      await tester.pump();
      expect(shownTab(tester), HomeShell.settingsTab);
      expect(await back(tester), isTrue, reason: 'the app stays open');
      expect(shownTab(tester), HomeShell.remoteTab);

      await tester.tap(tab('Library'));
      await tester.pump();
      expect(shownTab(tester), HomeShell.libraryTab);
      expect(await back(tester), isTrue, reason: 'the app stays open');
      expect(shownTab(tester), HomeShell.remoteTab);

      expect(await back(tester), isFalse, reason: "the Remote's Back closes the app");
      app.model.dispose();
    });

    testWidgets('goes back to the tab shown before, each tab once, and the Remote forgets them', (tester) async {
      final app = await openApp(tester);
      // Library, then Settings: Back shows the Library, then the Remote.
      await tester.tap(tab('Library'));
      await tester.pump();
      await tester.tap(tab('Settings'));
      await tester.pump();
      expect(await back(tester), isTrue);
      expect(shownTab(tester), HomeShell.libraryTab);
      expect(await back(tester), isTrue);
      expect(shownTab(tester), HomeShell.remoteTab);

      // Settings, Library, Settings again: no going round, just Library and the Remote.
      for (final label in ['Settings', 'Library', 'Settings']) {
        await tester.tap(tab(label));
        await tester.pump();
      }
      expect(await back(tester), isTrue);
      expect(shownTab(tester), HomeShell.libraryTab);
      expect(await back(tester), isTrue);
      expect(shownTab(tester), HomeShell.remoteTab);

      // The Remote, reached by its tab: the tabs before are forgotten, and Back from a tab opened then is the Remote.
      for (final label in ['Library', 'Remote', 'Settings']) {
        await tester.tap(tab(label));
        await tester.pump();
      }
      expect(await back(tester), isTrue);
      expect(shownTab(tester), HomeShell.remoteTab);
      expect(await back(tester), isFalse);
      app.model.dispose();
    });

    testWidgets('from a pairing opened in Settings comes back to Settings', (tester) async {
      final app = await openApp(tester);
      await tester.tap(tab('Settings'));
      await tester.pump();

      app.model.requestPairing();
      await tester.pump();
      expect(find.text('Connect to BlackPearl'), findsOneWidget);
      expect(await back(tester), isTrue);
      expect(find.text('Connect to BlackPearl'), findsNothing);
      expect(shownTab(tester), HomeShell.settingsTab);
      app.model.dispose();
    });
  });
}
