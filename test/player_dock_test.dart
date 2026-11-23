import 'dart:io';
import 'dart:math';

import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/debug/preview.dart';
import 'package:blackpearl_mobile/playback/phone_playback.dart';
import 'package:blackpearl_mobile/playback/shuffle_order.dart';
import 'package:blackpearl_mobile/protocol/library.dart';
import 'package:blackpearl_mobile/ui/player_dock.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  // The real fonts: the test font draws every letter 1 em wide, which hides how chips of different labels share a row.
  setUpAll(() async {
    var dir = File(Platform.resolvedExecutable).parent;
    while (!Directory('${dir.path}/material_fonts').existsSync() && dir.parent.path != dir.path) {
      dir = dir.parent;
    }
    // Names differ in case between platforms' SDK downloads (Roboto-Regular.ttf, roboto-regular.ttf).
    final fonts = Directory('${dir.path}/material_fonts').listSync().whereType<File>().toList();
    Future<ByteData> font(String name) async {
      final file = fonts.firstWhere(
        (f) => f.uri.pathSegments.last.toLowerCase() == name,
        orElse: () => throw StateError('No $name among ${fonts.map((f) => f.uri.pathSegments.last).join(', ')}'),
      );
      return ByteData.sublistView(await file.readAsBytes());
    }

    await (FontLoader('Roboto')
          ..addFont(font('roboto-regular.ttf'))
          ..addFont(font('roboto-medium.ttf')))
        .load();
    await (FontLoader('MaterialIcons')..addFont(font('materialicons-regular.otf'))).load();
  });

  Widget dock({required bool portrait, required double width, required (String, String, String) labels}) => MaterialApp(
    theme: ThemeData(fontFamily: 'Roboto'),
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
            audio: DockChipValue(labels.$1),
            subtitles: DockChipValue(labels.$2, off: labels.$2 == 'Off'),
            quality: DockChipValue(labels.$3),
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

  const labelSets = [
    ('Japanese', 'English SDH', '720p'),
    ('Japanese', 'Off', 'Original'),
    ('Audio', 'Spanish (Latin America)', '1080p'),
    ('Portuguese (Brazil) commentary', 'Off', 'Original'),
    ('English', 'English Signs and songs', 'Original'),
  ];

  Future<void> expectChipsFit(WidgetTester tester, String where) async {
    expect(tester.takeException(), isNull, reason: 'no overflow $where');
    final chips = tester.widgetList<DockChip>(find.byType(DockChip)).toList();
    bool cut(DockChip chip) =>
        tester.renderObject<RenderParagraph>(find.descendant(of: find.byWidget(chip), matching: find.byType(RichText)).last).didExceedMaxLines;
    // The room left in a chip's row.
    double free(DockChip chip) {
      final row = tester.getRect(find.ancestor(of: find.byWidget(chip), matching: find.byType(Row)).first);
      final mates = chips.where((other) => (tester.getRect(find.byWidget(other)).center.dy - row.center.dy).abs() < 2);
      return row.width - mates.fold(0.0, (sum, other) => sum + tester.getSize(find.byWidget(other)).width) - 6 * (mates.length - 1);
    }

    bool hasIcon(DockChip chip) => find.descendant(of: find.byWidget(chip), matching: find.byIcon(chip.icon)).evaluate().isNotEmpty;
    for (final chip in chips) {
      expect(tester.getSize(find.byWidget(chip)).width, greaterThanOrEqualTo(64), reason: '${chip.name} "${chip.value.label}" big enough to tap $where');
      // A short label is never cut, and keeps its icon unless the row needs that room for a longer label.
      if (chip.value.label.length <= 5) {
        expect(cut(chip), isFalse, reason: '${chip.name} "${chip.value.label}" keeps its label $where');
        if (!hasIcon(chip)) expect(free(chip), lessThan(DockChip.iconWidth), reason: '${chip.name} "${chip.value.label}" lost its icon with room $where');
      }
    }
    // A label is cut only when its row is full.
    for (final chip in chips.where(cut)) {
      expect(free(chip), lessThan(2), reason: '${chip.name} "${chip.value.label}" cut with ${free(chip)} dp free $where');
    }
  }

  // Landscape docks are the screen less the camera cutout, a side navigation bar and the dock's margins: from a wide
  // tablet down to a 640 dp phone with a cutout and a navigation bar.
  for (final width in [1100.0, 900.0, 800.0, 740.0, 700.0, 640.0, 596.0, 540.0, 470.0]) {
    testWidgets('a landscape dock $width dp wide fits, and its chips keep what they need', (tester) async {
      tester.view.physicalSize = const Size(1200, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final labels in labelSets) {
        await tester.pumpWidget(dock(portrait: false, width: width, labels: labels));
        await expectChipsFit(tester, 'at $width dp with $labels');
        // Playback stays in the middle of the dock.
        expect((tester.getCenter(find.byIcon(Icons.pause_rounded)).dx - 600).abs(), lessThan(1));
      }
    });
  }

  for (final width in [411.0, 360.0, 320.0]) {
    testWidgets('a portrait dock $width dp wide fits, and its chips keep what they need', (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final labels in labelSets) {
        await tester.pumpWidget(dock(portrait: true, width: width - 28, labels: labels));
        await expectChipsFit(tester, 'at $width dp portrait with $labels');
        // The labelled buttons under the chips keep their words on common phones.
        if (width >= 360) {
          for (final word in ['Shuffle', 'Loop all', 'Up next']) {
            expect(tester.renderObject<RenderParagraph>(find.text(word)).didExceedMaxLines, isFalse, reason: '"$word" at $width dp portrait');
          }
        }
      }
    });
  }

  for (final portrait in [false, true]) {
    testWidgets('with a menu open, a tap anywhere on the ${portrait ? 'portrait' : 'landscape'} dock only closes it', (tester) async {
      tester.view.physicalSize = portrait ? const Size(420, 900) : const Size(1200, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final did = <String>[];
      DockMenu? open = DockMenu.audio;
      Widget build() => MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: portrait ? 392 : 1100,
              child: PlayerDock(
                portrait: portrait,
                timeline: GestureDetector(
                  key: const Key('timeline'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => did.add('timeline'),
                  child: const SizedBox(height: 28),
                ),
                playing: true,
                onPlayPause: () => did.add('play'),
                onBack10: () => did.add('back'),
                onForward10: () => did.add('forward'),
                onPrevious: () => did.add('previous'),
                onNext: () => did.add('next'),
                audio: const DockChipValue('English'),
                subtitles: const DockChipValue('Off', off: true),
                quality: const DockChipValue('Original'),
                openMenu: open,
                onChip: (menu) => did.add('chip ${menu.name}'),
                onCloseMenu: () => did.add('close'),
                loop: 'all',
                onLoop: () => did.add('loop'),
                shuffle: true,
                onShuffle: () => did.add('shuffle'),
                onUpNext: () => did.add('up next'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(build());
      final slab = tester.getRect(find.byType(DockSlab));
      final targets = {
        'Play': tester.getCenter(find.byIcon(Icons.pause_rounded)),
        'Back 10': tester.getCenter(find.byIcon(Icons.replay_10_rounded)),
        'Loop': tester.getCenter(find.byIcon(Icons.repeat_rounded)),
        'the open chip': tester.getCenter(find.text('English')),
        'another chip': tester.getCenter(find.text('Original')),
        'the timeline': tester.getCenter(find.byKey(const Key('timeline'))),
        "the slab's padding": slab.bottomCenter - const Offset(0, 4),
      };
      for (final MapEntry(key: what, value: at) in targets.entries) {
        did.clear();
        await tester.tapAt(at);
        await tester.pump(const Duration(milliseconds: 400));
        expect(did, ['close'], reason: 'a tap on $what with a menu open');
      }

      // Closed, the dock works again.
      open = null;
      await tester.pumpWidget(build());
      did.clear();
      await tester.tap(find.byIcon(Icons.pause_rounded));
      await tester.tap(find.text('Original'));
      expect(did, ['play', 'chip quality']);
    });
  }

  test('chips share a full row: the narrow keep their width, the widest give way equally', () {
    expect(fitChipWidths([70, 120, 80], 300), [70, 120, 80]);
    // Dropping the wide one's icon (22 dp) isn't enough, and the narrow ones' would take them under 64 dp: they keep
    // their whole width and the wide one gets the rest.
    expect(fitChipWidths([70, 200, 80], 300), [70, 150, 80]);
    // Without its icon the wide one fits whole, and the others keep theirs.
    expect(fitChipWidths([70, 160, 80], 290), [70, 138, 80]);
    expect(fitChipWidths([70, 200, 180], 300), [70, 115, 115]);
    // Without icons all three fit whole.
    expect(fitChipWidths([100, 100, 100], 240), [78, 78, 78]);
    // Too little room even then: equal shares.
    expect(fitChipWidths([100, 100, 100], 210), [70, 70, 70]);
  });

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
        // Seeded, so the 30 draws are the same every run (unseeded, all 30 missed the second page in about 1 run in 40).
        final order = PhonePlayback(link: link, createPlayer: () => throw StateError('no player'), shuffleOrder: ShuffleOrder(Random(i)))
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
