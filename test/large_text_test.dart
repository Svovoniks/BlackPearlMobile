import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/connection/transport.dart';
import 'package:blackpearl_mobile/debug/preview.dart';
import 'package:blackpearl_mobile/protocol/library.dart';
import 'package:blackpearl_mobile/ui/library_screen.dart';
import 'package:blackpearl_mobile/ui/remote_screen.dart';
import 'package:blackpearl_mobile/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'library_screen_test.dart' show homePage;

void main() {
  for (final scale in [1.0, 1.3, 2.0]) {
    for (final width in [320.0, 360.0]) {
      testWidgets('the Remote tab fits ${width.round()} dp at ${(scale * 100).round()}% text', (tester) async {
        tester.view.physicalSize = Size(width * 2, 640 * 2);
        tester.view.devicePixelRatio = 2;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final link = FakeRemoteLink(
          pcName: 'Living room PC',
          status: const LinkStatus(LinkPhase.connected, path: NetworkPath.home),
          state: sampleState,
        )..offered = const {'watch', 'queues', 'sound'};
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: RemoteScreen(link: link, onChoosePc: () {}, onPairAgain: () {}, onWatchHere: (_) {}),
          ),
        );
        await tester.pump();
      });
      testWidgets('Library and a title sheet fit ${width.round()} dp at ${(scale * 100).round()}% text', (tester) async {
        tester.view.physicalSize = Size(width * 2, 640 * 2);
        tester.view.devicePixelRatio = 2;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected))
          ..offered = const {'library', 'watch', 'queues'};
        link.answer = (type, fields) async => homePage();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: LibraryScreen(
              link: link,
              actions: LibraryActions(
                watchHere: (e, {bool fromStart = false, QueueRef? queue}) async {},
                playOnPc: (e, {bool fromStart = false, QueueRef? queue}) async => null,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Asteroid City'));
        await tester.pumpAndSettle();
      });
    }
  }
}
