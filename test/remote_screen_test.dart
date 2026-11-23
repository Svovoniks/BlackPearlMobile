import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/connection/transport.dart';
import 'package:blackpearl_mobile/debug/preview.dart';
import 'package:blackpearl_mobile/protocol/remote_state.dart';
import 'package:blackpearl_mobile/ui/player_options.dart';
import 'package:blackpearl_mobile/ui/remote_screen.dart';
import 'package:blackpearl_mobile/ui/remote_tracks.dart';
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

  testWidgets('a timeline drag the link cuts short ends: the knob and clocks follow the PC again', (tester) async {
    final link = await pump(tester, state: sampleState.copyWith(playing: false));
    final box = tester.getRect(find.bySemanticsLabel('Timeline'));
    final gesture = await tester.startGesture(box.centerLeft + Offset(box.width * 0.1, 0));
    await gesture.moveBy(Offset(box.width * 0.1, 0));
    await gesture.moveBy(Offset(box.width * 0.1, 0));
    await tester.pump();
    expect(find.text(formatClock(sampleState.positionMs)), findsNothing, reason: 'the clock follows the finger');
    link.status = const LinkStatus(LinkPhase.failed, message: 'Lost the connection to the PC.');
    await tester.pump();
    await gesture.up();
    link.status = const LinkStatus(LinkPhase.connected, path: NetworkPath.home);
    await tester.pump();
    expect(find.text(formatClock(sampleState.positionMs)), findsOneWidget);
    expect(link.sent, isEmpty, reason: 'a drag cut short seeks nowhere');
    await tester.tap(find.bySemanticsLabel('Forward 10 seconds'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(formatClock(sampleState.positionMs + 10000)), findsOneWidget, reason: '+10 s starts from where the PC is');
  });

  testWidgets('a timeline drag that ends in the same frame as its last move seeks to where the finger left', (tester) async {
    final link = await pump(tester, state: sampleState.copyWith(playing: false));
    final box = tester.getRect(find.bySemanticsLabel('Timeline'));
    final gesture = await tester.startGesture(box.centerLeft + Offset(box.width * 0.2, 0));
    await gesture.moveBy(Offset(box.width * 0.1, 0));
    await tester.pump();
    // No frame between the last move and the release.
    await gesture.moveBy(Offset(box.width * 0.4, 0));
    await gesture.up();
    await tester.pump();
    final target = link.sent.single;
    expect(target.$1, 'seek-to');
    expect((target.$2 as int) / sampleState.durationMs, closeTo(0.7, 0.01));
  });

  testWidgets('a volume drag that ends in the same frame as its last move sends the final value', (tester) async {
    final link = await pump(tester, state: sampleState.copyWith(playing: false));
    final track = tester.getRect(find.bySemanticsLabel('PC volume'));
    final gesture = await tester.startGesture(track.centerLeft + Offset(track.width * 0.2, 0));
    await gesture.moveBy(Offset(track.width * 0.1, 0));
    await tester.pump();
    await gesture.moveBy(Offset(track.width * 0.6, 0));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    final volumes = link.sent.where((c) => c.$1 == 'volume').map((c) => c.$2 as int).toList();
    expect(volumes.last, closeTo(90, 1));
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

  Finder inSheet(String text) => find.descendant(of: find.byType(RemoteTracksPanel), matching: find.text(text));

  bool picked(WidgetTester tester, String name) =>
      tester.widget<OptionRow>(find.ancestor(of: inSheet(name), matching: find.byType(OptionRow)).first).selected;

  testWidgets("the PC's audio and subtitles show beside each other and open its menus", (tester) async {
    final link = await pump(tester, state: sampleState.copyWith(playing: false));
    expect(find.bySemanticsLabel(RegExp('^Audio, Japanese')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^Subtitles, English')), findsOneWidget);
    await tester.ensureVisible(find.bySemanticsLabel(RegExp('^Subtitles, English')));
    await tester.tap(find.bySemanticsLabel(RegExp('^Subtitles, English')));
    await tester.pumpAndSettle();
    // The subtitles page, with the PC's tick on its full English track; the two English tracks tell themselves apart.
    expect(inSheet('Signs & songs'), findsOneWidget);
    expect(inSheet('Portuguese (Brazil)'), findsOneWidget);
    expect(picked(tester, 'Full subtitles'), isTrue);
    expect(picked(tester, 'Signs & songs'), isFalse);
    await tester.tap(inSheet('Signs & songs'));
    await tester.pump();
    expect(link.sent.last, ('subtitle-track', 4));
    expect(picked(tester, 'Signs & songs'), isTrue);
    // The PC answered at once, so nothing is left waiting.
    expect(tester.widget<OptionRow>(find.ancestor(of: inSheet('Signs & songs'), matching: find.byType(OptionRow))).busy, isFalse);
    await tester.tap(inSheet('Off'));
    await tester.pump();
    expect(link.sent.last, ('subtitle-track', -1));
    // The audio page.
    await tester.tap(inSheet('Audio'));
    await tester.pumpAndSettle();
    await tester.tap(inSheet('English'));
    await tester.pump();
    expect(link.sent.last, ('audio-track', 2));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(RemoteTracksPanel))).pop();
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('^Audio, English')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^Subtitles, Off')), findsOneWidget);
  });

  testWidgets('a choice the PC never confirms stops showing as picked', (tester) async {
    final link = await pump(tester, state: sampleState.copyWith(playing: false));
    link.ignoreCommands = true;
    await tester.ensureVisible(find.bySemanticsLabel(RegExp('^Audio, Japanese')));
    await tester.tap(find.bySemanticsLabel(RegExp('^Audio, Japanese')));
    await tester.pumpAndSettle();
    await tester.tap(inSheet('English'));
    await tester.pump();
    expect(picked(tester, 'English'), isTrue);
    await tester.pump(const Duration(seconds: 4));
    expect(picked(tester, 'English'), isFalse);
    expect(picked(tester, 'Japanese'), isTrue);
  });

  testWidgets("in a room where only whoever plays the video picks tracks, the menus show but can't be changed", (tester) async {
    final link = await pump(
      tester,
      state: sampleState.withTracks(canChange: false, room: const RemoteRoom(name: 'Movie club', people: 3)),
    );
    await tester.ensureVisible(find.bySemanticsLabel(RegExp('^Audio, Japanese')));
    await tester.tap(find.bySemanticsLabel(RegExp('^Audio, Japanese')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Usually only whoever plays the video picks them'), findsOneWidget);
    // The rule note is about picking, which can't be done here.
    expect(find.textContaining("Subtitles you haven't picked"), findsNothing);
    await tester.tap(inSheet('English'), warnIfMissed: false);
    await tester.pump();
    expect(link.sent, isEmpty);
  });

  testWidgets('two subtitle tracks in one language are told apart on the pill', (tester) async {
    await pump(tester, state: sampleState.copyWith(playing: false, subtitleTrack: 4));
    expect(find.bySemanticsLabel(RegExp('^Subtitles, English · Signs & songs')), findsOneWidget);
    // A language only one track has stays short.
    expect(find.bySemanticsLabel(RegExp(r'^Audio, Japanese(?! ·)')), findsOneWidget);
  });

  testWidgets('a choice still waiting is dropped when the PC moves to another video', (tester) async {
    final link = await pump(tester, state: sampleState.copyWith(playing: false));
    link.ignoreCommands = true;
    await tester.ensureVisible(find.bySemanticsLabel(RegExp('^Audio, Japanese')));
    await tester.tap(find.bySemanticsLabel(RegExp('^Audio, Japanese')));
    await tester.pumpAndSettle();
    await tester.tap(inSheet('English'));
    await tester.pump();
    expect(picked(tester, 'English'), isTrue);
    // The next episode, whose tracks reuse the ids.
    link.setState(
      const RemoteState(
        media: true,
        title: 'Night Signal',
        detail: 'Season 2 · Episode 4 · High Water',
        playing: false,
        durationMs: 2700000,
        volume: 64,
        audioTracks: sampleAudioTracks,
        audioTrack: 1,
        subtitleTracks: sampleSubtitleTracks,
        subtitleTrack: 3,
      ),
    );
    await tester.pump();
    expect(picked(tester, 'English'), isFalse);
    expect(picked(tester, 'Japanese'), isTrue);
  });

  testWidgets('a sheet left open when the PC stops says nothing is playing', (tester) async {
    final link = await pump(tester, state: sampleState.copyWith(playing: false));
    await tester.ensureVisible(find.bySemanticsLabel(RegExp('^Audio, Japanese')));
    await tester.tap(find.bySemanticsLabel(RegExp('^Audio, Japanese')));
    await tester.pumpAndSettle();
    link.setState(RemoteState.nothing);
    await tester.pump();
    expect(inSheet('Nothing is playing on the PC.'), findsOneWidget);
    expect(inSheet('The audio tracks show once the video has opened on the PC.'), findsNothing);
  });

  testWidgets('a video still opening on the PC says its tracks come once it has', (tester) async {
    await pump(tester, state: sampleState.withTracks(audio: const [], subtitles: const []));
    expect(find.bySemanticsLabel(RegExp('^Audio, Not yet')), findsOneWidget);
    await tester.ensureVisible(find.bySemanticsLabel(RegExp('^Subtitles, Not yet')));
    await tester.tap(find.bySemanticsLabel(RegExp('^Subtitles, Not yet')));
    await tester.pumpAndSettle();
    expect(inSheet('The subtitles show once the video has opened on the PC.'), findsOneWidget);
  });

  testWidgets("a track change the PC refuses says why in the sheet, not behind it", (tester) async {
    final link = await pump(tester, state: sampleState.copyWith(playing: false));
    await tester.ensureVisible(find.bySemanticsLabel(RegExp('^Audio, Japanese')));
    await tester.tap(find.bySemanticsLabel(RegExp('^Audio, Japanese')));
    await tester.pumpAndSettle();
    link.showNotice("The PC couldn't change the audio track.");
    await tester.pump();
    expect(inSheet("The PC couldn't change the audio track."), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets("a state the PC sent before a seek reached it doesn't put the knob back", (tester) async {
    final link = await pump(tester, state: sampleState.copyWith(playing: false));
    link.ignoreCommands = true;
    final box = tester.getRect(find.bySemanticsLabel('Timeline'));
    await tester.tapAt(box.centerLeft + Offset(box.width * 0.8, 0));
    await tester.pump();
    final target = link.sent.single.$2 as int;
    expect(find.text(formatClock(target)), findsOneWidget);
    // Sent before the seek arrived: the old position.
    await tester.pump(const Duration(milliseconds: 500));
    link.setState(sampleState.copyWith(playing: false));
    await tester.pump();
    expect(find.text(formatClock(target)), findsOneWidget);
    // The seek done.
    link.setState(sampleState.copyWith(playing: false, positionMs: target));
    await tester.pump();
    expect(find.text(formatClock(target)), findsOneWidget);
  });

  testWidgets('while disconnected the clock stops at the last word from the PC', (tester) async {
    final link = await pump(tester);
    link.status = const LinkStatus(LinkPhase.failed, message: 'Lost the connection to the PC.');
    await tester.pump(const Duration(seconds: 5));
    expect(find.text(formatClock(sampleState.positionMs)), findsOneWidget);
  });

  testWidgets('a video without subtitles says it has none, not that they are still coming', (tester) async {
    await pump(tester, state: sampleState.withTracks(subtitles: const []));
    await tester.ensureVisible(find.bySemanticsLabel(RegExp('^Subtitles, None')));
    await tester.tap(find.bySemanticsLabel(RegExp('^Subtitles, None')));
    await tester.pumpAndSettle();
    expect(inSheet('This video has no subtitles. Subtitles from a file can be loaded on the PC.'), findsOneWidget);
  });

  testWidgets('a PC from before tracks on the remote shows no track pills', (tester) async {
    await pump(
      tester,
      state: const RemoteState(media: true, title: 'X', playing: false, positionMs: 0, durationMs: 1000, volume: 30),
    );
    expect(find.bySemanticsLabel(RegExp('^Audio, ')), findsNothing);
    expect(find.bySemanticsLabel(RegExp('^Subtitles, ')), findsNothing);
  });

  testWidgets('"Muted" stays on one line with large text', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pump(tester, state: sampleState.copyWith(playing: false, muted: true));
    final muted = find.text('Muted');
    await tester.ensureVisible(muted);
    final line = tester.getSize(muted);
    expect(line.height, lessThan(13 * 1.3 * 1.6), reason: 'one line, not "Mute" over "d"');
  });

  testWidgets('sideways, the play buttons show without scrolling', (tester) async {
    tester.view.physicalSize = const Size(2400, 1080);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final link = FakeRemoteLink(pcName: 'Living room PC', status: const LinkStatus(LinkPhase.connected, path: NetworkPath.home), state: sampleState);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        // The tab bar takes the bottom of the screen, as in the app.
        home: Scaffold(
          body: RemoteScreen(link: link, onChoosePc: () {}, onPairAgain: () {}),
          bottomNavigationBar: const SizedBox(height: 70),
        ),
      ),
    );
    await tester.pump();
    final height = 1080 / 2.625 - 70;
    for (final label in ['Previous', 'Back 10 seconds', 'Pause', 'Forward 10 seconds', 'Next']) {
      expect(tester.getRect(find.bySemanticsLabel(label)).bottom, lessThanOrEqualTo(height), reason: label);
    }
    // Every control is still there, further down.
    for (final label in [RegExp('^Stop'), RegExp('^Loop'), RegExp('^Shuffle'), RegExp('^Fullscreen'), RegExp('^Audio'), RegExp('^Subtitles'), RegExp('PC volume')]) {
      expect(find.bySemanticsLabel(label), findsWidgets, reason: '$label');
    }
  });
}
