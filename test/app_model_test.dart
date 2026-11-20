import 'dart:async';

import 'package:blackpearl_mobile/app_model.dart';
import 'package:blackpearl_mobile/connection/remote_connection.dart';
import 'package:blackpearl_mobile/connection/transport.dart';
import 'package:blackpearl_mobile/main.dart';
import 'package:blackpearl_mobile/protocol/pair_link.dart';
import 'package:blackpearl_mobile/storage/paired_pcs.dart';
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
}
