import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/debug/preview.dart';
import 'package:blackpearl_mobile/playback/phone_playback.dart';
import 'package:blackpearl_mobile/protocol/library.dart';
import 'package:blackpearl_mobile/ui/player_dock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Widget dock({required bool portrait, required double width}) => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          width: width,
          child: PlayerDock(
            portrait: portrait,
            timeline: const SizedBox(height: 28),
            playing: true,
            onPlayPause: () {},
            onBack10: () {},
            onForward10: () {},
            onPrevious: () {},
            onNext: () {},
            audio: const DockChipValue('Japanese'),
            subtitles: const DockChipValue('English SDH'),
            quality: const DockChipValue('720p'),
            onChip: (_) {},
            loop: 'all',
            onLoop: () {},
            shuffle: true,
            onShuffle: () {},
            onUpNext: () {},
          ),
        ),
      ),
    ),
  );

  // Landscape docks are the screen less the camera cutout, a side navigation bar and the dock's margins: from a wide
  // tablet down to a 640 dp phone with a cutout and a navigation bar.
  for (final width in [1100.0, 900.0, 800.0, 740.0, 700.0, 640.0, 596.0, 540.0, 470.0]) {
    testWidgets('a landscape dock $width dp wide fits, and every chip stays big enough to tap', (tester) async {
      tester.view.physicalSize = const Size(1200, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(dock(portrait: false, width: width));
      expect(tester.takeException(), isNull, reason: 'no overflow');
      for (final chip in tester.widgetList<DockChip>(find.byType(DockChip))) {
        expect(tester.getSize(find.byWidget(chip)).width, greaterThanOrEqualTo(64), reason: '${chip.name} at $width dp');
      }
      // A chip shortens its label only when the row has no room left for it: no empty gap beside a cut label.
      final cut = tester
          .widgetList<DockChip>(find.byType(DockChip))
          .where(
            (chip) => tester.renderObject<RenderParagraph>(find.descendant(of: find.byWidget(chip), matching: find.byType(RichText)).last).didExceedMaxLines,
          );
      if (cut.isNotEmpty) {
        final chipsEnd = tester
            .widgetList<DockChip>(find.byType(DockChip))
            .map((chip) => tester.getRect(find.byWidget(chip)).right)
            .reduce((a, b) => a > b ? a : b);
        final modesStart = tester.getRect(find.byIcon(Icons.shuffle_rounded)).left;
        final playTop = tester.getRect(find.byIcon(Icons.pause_rounded)).top;
        // In the two-row dock the chips share a row with playback, which they can't reach into.
        if (tester.getRect(find.byWidget(cut.first)).top > playTop + 30) {
          expect(modesStart - chipsEnd, lessThan(20), reason: '${cut.map((c) => c.name)} cut at $width dp with room beside them');
        }
      }
      // Playback stays in the middle of the dock.
      final play = tester.getCenter(find.byIcon(Icons.pause_rounded));
      expect((play.dx - 600).abs(), lessThan(1));
    });
  }

  for (final width in [411.0, 360.0, 320.0]) {
    testWidgets('a portrait dock $width dp wide fits', (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(dock(portrait: true, width: width - 28));
      expect(tester.takeException(), isNull);
    });
  }

  group('the shuffle list', () {
    EpisodeStep step(String id) => EpisodeStep(id: id, title: id, detail: 'Season 1 · Episode $id');
    Map<String, dynamic> page(int number, int total) => {
      'type': 'page',
      'total': total,
      'page': number,
      'pageSize': 40,
      'location': 'Show',
      'entries': [
        for (var i = number * 40; i < total && i < (number + 1) * 40; i++)
          {'id': 'e$i', 'title': 'Episode $i', 'caption': '', 'level': 'episode', 'season': 1, 'episode': i + 1, 'playable': true, 'index': i},
      ],
    };

    PhonePlayback playing(FakeRemoteLink link) =>
        PhonePlayback(link: link, createPlayer: () => throw StateError('no player'))
          ..debugShow(null, StreamInfo(id: 'e0', title: 'Episode 0', hls: false, next: step('e1')));

    test("loads every page of the show, and Next picks from all of it", () async {
      final link = FakeRemoteLink(pcName: 'PC', status: const LinkStatus(LinkPhase.connected))..offered = const {'watch', 'queues'};
      final asked = <int>[];
      link.answer = (type, fields) async {
        asked.add(fields['page'] as int? ?? 0);
        return page(fields['page'] as int? ?? 0, 45);
      };
      final playback = playing(link)..shuffle = true;
      await pumpEventQueue();
      expect(asked, [0, 1]);
      final seen = <String>{};
      for (var i = 0; i < 30; i++) {
        final order = PhonePlayback(link: link, createPlayer: () => throw StateError('no player'))
          ..debugShow(null, StreamInfo(id: 'e0', title: 'Episode 0', hls: false, next: step('e1')))
          ..shuffle = true;
        await pumpEventQueue();
        seen.add(order.nextEpisode!.id);
        order.dispose();
      }
      expect(seen.any((id) => int.parse(id.substring(1)) >= 40), isTrue, reason: 'episodes from the second page are picked too');
      playback.dispose();
    });

    test("a PC that can't list the show leaves Next in the usual order", () async {
      final link = FakeRemoteLink(pcName: 'PC', status: const LinkStatus(LinkPhase.connected))..offered = const {'watch', 'queues'};
      link.answer = (type, fields) async => throw const RemoteRequestException('browse', 'Not here');
      final playback = playing(link)..shuffle = true;
      await pumpEventQueue();
      expect(playback.nextEpisode?.id, 'e1');
      playback.dispose();
    });

    test('a film outside any list asks for nothing', () async {
      final link = FakeRemoteLink(pcName: 'PC', status: const LinkStatus(LinkPhase.connected))..offered = const {'watch', 'queues'};
      var asked = 0;
      link.answer = (type, fields) async {
        asked++;
        return page(0, 0);
      };
      final playback = PhonePlayback(link: link, createPlayer: () => throw StateError('no player'))
        ..debugShow(null, const StreamInfo(id: 'film', title: 'Film', hls: false))
        ..shuffle = true;
      await pumpEventQueue();
      expect(asked, 0);
      expect(playback.inList, isFalse);
      playback.dispose();
    });
  });
}
