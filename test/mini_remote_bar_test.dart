import 'dart:async';

import 'package:blackpearl_mobile/app_model.dart';
import 'package:blackpearl_mobile/connection/remote_connection.dart';
import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/connection/transport.dart';
import 'package:blackpearl_mobile/debug/preview.dart';
import 'package:blackpearl_mobile/protocol/library.dart';
import 'package:blackpearl_mobile/protocol/remote_state.dart';
import 'package:blackpearl_mobile/storage/paired_pcs.dart';
import 'package:blackpearl_mobile/ui/library_screen.dart';
import 'package:blackpearl_mobile/ui/mini_remote_bar.dart';
import 'package:blackpearl_mobile/ui/pc_chooser.dart';
import 'package:blackpearl_mobile/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('the mini remote bar', () {
    Future<(FakeRemoteLink, List<String>)> pump(WidgetTester tester, {RemoteState? state = sampleState}) async {
      final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected, path: NetworkPath.home), state: state);
      final did = <String>[];
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: MiniRemoteBar(link: link, onOpen: () => did.add('open')),
        ),
      ));
      await tester.pump();
      return (link, did);
    }

    testWidgets("says what the PC plays, with its play buttons, and opens the Remote", (tester) async {
      final (link, did) = await pump(tester);
      expect(find.text('Night Signal'), findsOneWidget);
      expect(find.text('Playing on Study'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Pause the PC'));
      await tester.tap(find.bySemanticsLabel('Back 10 seconds on the PC'));
      await tester.tap(find.bySemanticsLabel('Forward 10 seconds on the PC'));
      await tester.pump();
      expect(link.sent, [('toggle', null), ('seek-by', -10000), ('seek-by', 10000)]);
      expect(find.text('Paused on Study'), findsOneWidget);
      for (final label in ['Play on the PC', 'Back 10 seconds on the PC', 'Forward 10 seconds on the PC']) {
        final size = tester.getSize(find.bySemanticsLabel(label));
        expect((size.width, size.height), (48, 48), reason: '$label takes a fingertip');
      }
      await tester.tap(find.text('Night Signal'));
      expect(did, ['open']);
    });

    testWidgets('takes no room while nothing plays or the PC is out of reach', (tester) async {
      final (link, _) = await pump(tester, state: RemoteState.nothing);
      expect(tester.getSize(find.byType(MiniRemoteBar)).height, 0);
      expect(MiniRemoteBar.forPage(link, () {}), isNull, reason: 'a page then keeps the bottom of the screen');
      link.setState(sampleState);
      await tester.pump();
      expect(tester.getSize(find.byType(MiniRemoteBar)).height, inInclusiveRange(56, 80));
      expect(MiniRemoteBar.forPage(link, () {}), isNotNull);
      link.status = const LinkStatus(LinkPhase.failed, message: 'Lost the connection to the PC.');
      await tester.pump();
      expect(tester.getSize(find.byType(MiniRemoteBar)).height, 0);
    });

    testWidgets("in a room where only whoever plays the video controls it, the buttons are off", (tester) async {
      final (link, _) = await pump(
        tester,
        state: const RemoteState(media: true, title: 'X', playing: true, durationMs: 1000, canControl: false, room: RemoteRoom(name: 'Movie club', people: 3)),
      );
      await tester.tap(find.bySemanticsLabel('Pause the PC'), warnIfMissed: false);
      await tester.pump();
      expect(link.sent, isEmpty);
    });

    testWidgets("a show's page, which covers the tabs, keeps the bar and its way back to the Remote", (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected), state: sampleState)..offered = const {'library', 'watch'};
      link.answer = (type, fields) async => {
        'type': 'page', 'total': 1, 'page': 0, 'pageSize': 40, 'location': 'Night Signal',
        'entries': [{'id': 'e1', 'title': 'Pilot', 'level': 'episode', 'kind': 'Show', 'playable': true}],
      };
      var opened = 0;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: ShowScreen(
          link: link,
          show: const LibraryEntry(id: 'show', title: 'Night Signal', level: 'series', kind: 'Show'),
          actions: LibraryActions(
            watchHere: (entry, {bool fromStart = false, QueueRef? queue}) async {},
            playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async => null,
            openRemote: () => opened++,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Pilot'), findsOneWidget);
      expect(tester.getSize(find.byType(MiniRemoteBar)).height, lessThan(80), reason: 'the bar leaves the page its room');
      await tester.tap(find.bySemanticsLabel('Pause the PC'));
      await tester.pump();
      expect(link.sent.single.$1, 'toggle');
      await tester.tap(find.text('Paused on Study'));
      expect(opened, 1);
    });
  });

  testWidgets('any paired PC can be forgotten from its own row, without switching to it first', (tester) async {
    final store = PairedPcStore(MemorySecretStore());
    final model = AppModel(
      store: store,
      connect: (target, {onPaired, onPcName}) => RemoteConnection(
        target: target,
        identity: const PhoneIdentity(appVersion: '0.1.2', device: 'Test'),
        connectSocket: (_) => Completer<SignalingSocket>().future,
        createPeer: (_, _) => Completer<PeerLink>().future,
      ),
    );
    addTearDown(model.dispose);
    await store.save([
      PairedPc(pcId: 'A' * 32, name: 'Living room PC', server: 'https://rooms.example.com', phoneId: 'a' * 32, secret: 'b' * 64),
      PairedPc(pcId: 'B' * 32, name: 'Study', server: 'https://rooms.example.com', phoneId: 'c' * 32, secret: 'd' * 64),
    ]);
    await model.load();
    expect(model.currentPcId, 'A' * 32);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Builder(
        builder: (context) => Scaffold(body: TextButton(onPressed: () => showPcChooser(context, model), child: const Text('open'))),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More for Study'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget Study'));
    await tester.pumpAndSettle();
    expect(find.text('Forget Study?'), findsOneWidget);
    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();
    expect(model.pcs.map((pc) => pc.name), ['Living room PC']);
    expect(model.currentPcId, 'A' * 32, reason: 'the PC in use stays connected');
    expect(find.text('Your PCs'), findsOneWidget, reason: 'the sheet stays, without the forgotten PC');
    expect(find.text('Study'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
