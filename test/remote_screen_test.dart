import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/connection/transport.dart';
import 'package:blackpearl_mobile/debug/preview.dart';
import 'package:blackpearl_mobile/protocol/remote_state.dart';
import 'package:blackpearl_mobile/ui/remote_screen.dart';
import 'package:blackpearl_mobile/ui/theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

Future<FakeRemoteLink> pump(
  WidgetTester tester, {
  LinkStatus status = const LinkStatus(LinkPhase.connected, path: NetworkPath.home),
  RemoteState? state = sampleState,
}) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  final link = FakeRemoteLink(pcName: 'Living room PC', status: status, state: state);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: RemoteScreen(link: link, onChoosePc: () {}, onPairAgain: () {}),
    ),
  );
  await tester.pump();
  return link;
}

void main() {
  testWidgets('controls send commands', (tester) async {
    final link = await pump(tester, state: sampleState.copyWith(playing: false));
    await tester.tap(find.bySemanticsLabel('Play'));
    await tester.tap(find.bySemanticsLabel('Forward 10 seconds'));
    await tester.tap(find.bySemanticsLabel('Previous'));
    await tester.tap(find.bySemanticsLabel('Next'));
    await tester.tap(find.bySemanticsLabel(RegExp('^Stop')));
    await tester.tap(find.bySemanticsLabel(RegExp('^Loop')));
    await tester.tap(find.bySemanticsLabel(RegExp('^Fullscreen')));
    await tester.tap(find.bySemanticsLabel('Mute'));
    await tester.pump(const Duration(seconds: 1));
    expect(link.sent.map((c) => c.$1), ['toggle', 'seek-by', 'previous', 'next', 'stop', 'loop', 'fullscreen', 'mute']);
    expect(link.sent[1].$2, 10000);
  });

  testWidgets('the timeline seeks on release, not while dragging', (tester) async {
    final link = await pump(tester, state: sampleState.copyWith(playing: false));
    final timeline = find.bySemanticsLabel('Timeline');
    final box = tester.getRect(timeline);
    final gesture = await tester.startGesture(box.centerLeft + const Offset(20, 0));
    await gesture.moveBy(const Offset(40, 0));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(link.sent, isEmpty);
    await gesture.up();
    await tester.pump();
    expect(link.sent.single.$1, 'seek-to');
    expect(link.sent.single.$2, isA<int>());
  });

  testWidgets('volume drags send a few debounced commands and the final value', (tester) async {
    final link = await pump(tester, state: sampleState.copyWith(playing: false));
    final track = tester.getRect(find.bySemanticsLabel('PC volume'));
    final gesture = await tester.startGesture(track.centerLeft + const Offset(4, 0));
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(Offset(track.width / 25, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    final volumes = link.sent.where((c) => c.$1 == 'volume').map((c) => c.$2 as int).toList();
    expect(volumes.length, lessThan(8), reason: 'about one every 150 ms, not one per frame');
    expect(volumes.last, greaterThan(60));
  });

  testWidgets("can't control: playback is disabled and explained, volume still works", (tester) async {
    final link = await pump(
      tester,
      state: const RemoteState(
        media: true,
        title: 'X',
        playing: true,
        positionMs: 0,
        durationMs: 1000,
        volume: 30,
        canControl: false,
        room: RemoteRoom(name: 'Movie club', people: 3),
      ),
    );
    expect(find.textContaining('only whoever plays the video can control playback'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Pause'), warnIfMissed: false);
    await tester.tap(find.bySemanticsLabel(RegExp('^Stop')), warnIfMissed: false);
    await tester.ensureVisible(find.bySemanticsLabel('Mute'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Mute'));
    await tester.pump(const Duration(seconds: 1));
    expect(link.sent.map((c) => c.$1), ['mute']);
  });

  testWidgets('nothing playing shows an empty state', (tester) async {
    await pump(tester, state: RemoteState.nothing);
    expect(find.text('Nothing is playing'), findsOneWidget);
    expect(find.bySemanticsLabel('Timeline'), findsNothing);
  });

  testWidgets("waiting for the PC says it isn't online", (tester) async {
    await pump(tester, status: const LinkStatus(LinkPhase.waitingForPc), state: null);
    expect(find.text("Your PC isn't online"), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('away is marked on the PC chip', (tester) async {
    await pump(tester, status: const LinkStatus(LinkPhase.connected, path: NetworkPath.away));
    expect(find.text('away'), findsOneWidget);
  });

  testWidgets('reconnecting keeps the last state, with a banner, and disables controls', (tester) async {
    final link = await pump(
      tester,
      status: LinkStatus(
        LinkPhase.failed,
        message: 'Lost the connection to the PC.',
        retryAt: DateTime.now().add(const Duration(seconds: 3)),
      ),
    );
    expect(find.text('Lost the connection to the PC.'), findsOneWidget);
    expect(find.text('Night Signal'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Pause'), warnIfMissed: false);
    await tester.pump(const Duration(seconds: 1));
    expect(link.sent, isEmpty);
  });

  testWidgets('a swipe on the touch pad skips exactly 10 s, even when the PC answers at once', (tester) async {
    // The fake link applies each command to its state straight away, as a fast PC would.
    final link = await pump(tester, state: sampleState.copyWith(playing: false));
    expect(find.text('18:42'), findsOneWidget);
    await tester.fling(find.bySemanticsLabel(RegExp('^Touch pad')), const Offset(-200, 0), 1000);
    await tester.pump(const Duration(seconds: 1));
    expect(link.sent, [('seek-by', -10000)]);
    expect(find.text('18:32'), findsOneWidget);
  });

  testWidgets('tap on the touch pad toggles; sliding up raises the volume', (tester) async {
    final link = await pump(tester, state: sampleState.copyWith(playing: false));
    final pad = find.bySemanticsLabel(RegExp('^Touch pad'));
    await tester.tap(pad);
    await tester.pump(const Duration(seconds: 1));
    expect(link.sent.single.$1, 'toggle');
    await tester.drag(pad, const Offset(0, -80));
    await tester.pump(const Duration(seconds: 1));
    final volumes = link.sent.where((c) => c.$1 == 'volume').map((c) => c.$2 as int).toList();
    expect(volumes, isNotEmpty);
    expect(volumes.last, greaterThan(64));
  });
}
