import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/connection/transport.dart';
import 'package:blackpearl_mobile/debug/preview.dart';
import 'package:blackpearl_mobile/playback/phone_sound.dart';
import 'package:blackpearl_mobile/protocol/library.dart';
import 'package:blackpearl_mobile/protocol/remote_state.dart';
import 'package:blackpearl_mobile/storage/app_settings.dart';
import 'package:blackpearl_mobile/ui/remote_screen.dart';
import 'package:blackpearl_mobile/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'real_fonts.dart';

void main() {
  setUpAll(loadRealFonts);

  // Everything a PC can put on the Remote at once: Shuffle, its track menus, Sound on the phone, a queue, Watch here.
  const everything = RemoteState(
    media: true,
    title: 'Night Signal',
    detail: 'Season 2 · Episode 3 · Low Tide',
    playing: false,
    positionMs: 1122000,
    durationMs: 2830000,
    volume: 64,
    hasPrevious: true,
    hasNext: true,
    shuffle: true,
    mediaId: 'e3',
    queue: QueueRef(id: 'evening', name: 'Evening', index: 2),
    phoneSound: false,
    audioTracks: sampleAudioTracks,
    audioTrack: 1,
    subtitleTracks: sampleSubtitleTracks,
    subtitleTrack: 3,
  );

  Future<void> pump(WidgetTester tester, Size phone) async {
    tester.view.physicalSize = phone * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final link = FakeRemoteLink(pcName: 'Living room PC', status: const LinkStatus(LinkPhase.connected, path: NetworkPath.home), state: everything)
      ..offered = const {'library', 'watch', 'queues', 'sound'};
    final sound = PhoneSound(link: link, settings: AppSettings(MemorySettingsStore()));
    addTearDown(sound.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme().copyWith(textTheme: buildTheme().textTheme.apply(fontFamily: 'Roboto')),
        // The status bar above and the tab bar below, as in the app.
        home: MediaQuery(
          data: MediaQueryData(size: phone, padding: const EdgeInsets.only(top: 28)),
          child: Scaffold(
            body: RemoteScreen(link: link, sound: sound, onChoosePc: () {}, onPairAgain: () {}, onWatchHere: (_) {}),
            bottomNavigationBar: const SizedBox(height: 64),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('on a 360 by 780 dp phone every control a PC can offer fits without scrolling, the volume under them', (tester) async {
    await pump(tester, const Size(360, 780));
    for (final label in [RegExp('^Shuffle'), RegExp('^Loop'), RegExp('^Up next'), RegExp('^Fullscreen'), RegExp('^Stop'), RegExp('^Audio'), RegExp('^Subtitles'), RegExp('^Sound, On the PC')]) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: '$label');
    }
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(scroll.maxScrollExtent, 0, reason: 'nothing to scroll');
    // The touch pad gets the room the rows of buttons gave up: its least is 116 dp.
    expect(tester.getSize(find.bySemanticsLabel(RegExp('^Touch pad'))).height, greaterThan(180));
    // The volume isn't part of what scrolls: it stays just above the tab bar.
    expect(find.ancestor(of: find.bySemanticsLabel('PC volume'), matching: find.byType(Scrollable)), findsNothing);
    expect(tester.getRect(find.bySemanticsLabel('PC volume')).bottom, lessThanOrEqualTo(780 - 64));
    // Every button takes a fingertip.
    for (final label in [RegExp('^Stop'), RegExp('^Loop'), RegExp('^Mute'), RegExp('^Choose PC'), RegExp('^Sound, On the PC')]) {
      final size = tester.getSize(find.bySemanticsLabel(label));
      expect(size.height, greaterThanOrEqualTo(48), reason: '$label is ${size.height} dp high');
      expect(size.width, greaterThanOrEqualTo(48), reason: '$label is ${size.width} dp wide');
    }
  });

  testWidgets('on a short 360 by 640 dp phone the controls scroll and the volume still shows', (tester) async {
    await pump(tester, const Size(360, 640));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.bySemanticsLabel(RegExp('^Touch pad'))).height, 116, reason: 'the touch pad keeps its least height');
    expect(tester.getRect(find.bySemanticsLabel('PC volume')).bottom, lessThanOrEqualTo(640 - 64));
  });
}
