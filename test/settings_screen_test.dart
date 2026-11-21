import 'dart:async';

import 'package:blackpearl_mobile/app_model.dart';
import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/connection/transport.dart';
import 'package:blackpearl_mobile/debug/preview.dart';
import 'package:blackpearl_mobile/storage/paired_pcs.dart';
import 'package:blackpearl_mobile/ui/settings_screen.dart';
import 'package:blackpearl_mobile/ui/theme.dart';
import 'package:blackpearl_mobile/update/app_update.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// GitHub answering when [answer] completes.
class _Releases implements UpdatePlatform {
  Completer<Object?> answer = Completer();

  @override
  Future<Object?> latestRelease() => answer.future;
  @override
  Future<void> download(Uri url, String path, void Function(int received) progress) async {}
  @override
  Future<String> updateFolder() async => '';
  @override
  Future<bool> canInstall() async => true;
  @override
  Future<void> allowInstalls() async {}
  @override
  Future<void> install(String path) async {}
}

Future<void> pump(WidgetTester tester, AppUpdater? updater) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: SettingsScreen(
        model: AppModel(store: PairedPcStore(MemorySecretStore()), connect: (_, {onPaired, onPcName}) => throw UnsupportedError('test')),
        link: FakeRemoteLink(
          pcName: 'Living room PC',
          status: const LinkStatus(LinkPhase.connected, path: NetworkPath.home),
        ),
        onChoosePc: () {},
        updater: updater,
      ),
    ),
  );
}

void main() {
  testWidgets('Settings checks for updates and says what it found', (tester) async {
    final releases = _Releases();
    final updater = AppUpdater(platform: releases, currentVersion: '0.4.0');
    await pump(tester, updater);
    final button = find.text('Check for updates');
    await tester.scrollUntilVisible(button, 200);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    expect(find.text('BlackPearl Mobile 0.4.0'), findsOneWidget);

    await tester.tap(button);
    await tester.pump();
    expect(find.text('Checking…'), findsOneWidget);
    expect(updater.checking, isTrue);
    // A second tap while it checks does nothing.
    await tester.tap(button);
    releases.answer.complete({'tag_name': 'v0.4.0', 'assets': const []});
    await tester.pumpAndSettle();
    expect(find.text('BlackPearl Mobile 0.4.0 is the latest version.'), findsOneWidget);

    releases.answer = Completer();
    await tester.tap(button);
    await tester.pump();
    releases.answer.completeError(Exception('offline'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't check for updates. Check the connection and try again."), findsOneWidget);
  });

  testWidgets('Settings has no update check where the app does not update itself', (tester) async {
    await pump(tester, null);
    await tester.pumpAndSettle();
    expect(find.text('Check for updates'), findsNothing);
  });
}
