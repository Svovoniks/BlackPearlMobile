import 'dart:async';

import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/debug/preview.dart';
import 'package:blackpearl_mobile/protocol/library.dart';
import 'package:blackpearl_mobile/protocol/remote_state.dart';
import 'package:blackpearl_mobile/ui/library_screen.dart';
import 'package:blackpearl_mobile/ui/pebbles.dart';
import 'package:blackpearl_mobile/ui/queue_widgets.dart';
import 'package:blackpearl_mobile/ui/remote_screen.dart';
import 'package:blackpearl_mobile/ui/search_screen.dart';
import 'package:blackpearl_mobile/ui/theme.dart';
import 'package:flutter/rendering.dart' show ClipRectLayer, RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Map<String, dynamic> homePage() => {
  'type': 'page',
  'total': 3,
  'page': 0,
  'pageSize': 40,
  'location': 'Home',
  'entries': [
    {'id': 'film', 'title': 'Asteroid City', 'caption': 'Movie · 2023', 'level': 'movie', 'kind': 'Movie', 'runtimeMinutes': 105, 'homeSection': 'continue', 'positionMs': 760000, 'playable': true, 'overview': 'A desert town.'},
    {'id': 'show', 'title': 'Night Signal', 'caption': 'Show · 2021', 'level': 'series', 'kind': 'Show', 'homeSection': 'suggestions', 'playable': false},
    {'id': 'pick', 'title': 'Low Tide', 'caption': 'Movie · 2019', 'level': 'movie', 'kind': 'Movie', 'homeSection': 'mystery', 'playable': true},
  ],
};

Future<(FakeRemoteLink, List<String>)> pumpLibrary(WidgetTester tester, {Set<String> features = const {'library', 'watch'}}) async {
  final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected));
  link.offered = features;
  link.answer = (type, fields) async => type == 'browse' ? homePage() : {'type': 'done'};
  final calls = <String>[];
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(),
    home: LibraryScreen(
      link: link,
      actions: LibraryActions(
        watchHere: (entry, {bool fromStart = false, QueueRef? queue}) async => calls.add('here ${entry.id} fromStart=$fromStart'),
        playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async {
          calls.add('pc ${entry.id}');
          return null;
        },
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return (link, calls);
}

void main() {
  testWidgets("Home lists the PC's rows, and a title's sheet plays it here or on the PC", (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final (link, calls) = await pumpLibrary(tester);
    expect(link.asked.first.$1, 'browse');
    expect(link.asked.first.$2['home'], isTrue);
    expect(find.text('Continue watching'), findsOneWidget);
    expect(find.text('Shows to start'), findsOneWidget);
    expect(find.text("Can't decide?"), findsOneWidget);
    expect(find.text('12:40'), findsOneWidget);
    await tester.tap(find.text('Asteroid City'));
    await tester.pumpAndSettle();
    expect(find.text('Resume on phone · 12:40'), findsOneWidget);
    expect(find.text('Stopped at 12:40 of 1:45:00'), findsOneWidget);
    await tester.tap(find.text('Play on PC'));
    await tester.pumpAndSettle();
    expect(calls, ['pc film']);
    await tester.tap(find.text('Asteroid City'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start over'));
    await tester.pumpAndSettle();
    expect(calls.last, 'here film fromStart=true');
  });

  testWidgets('a PC from before the library says to update it', (tester) async {
    await pumpLibrary(tester, features: const {});
    expect(find.text('Update BlackPearl on the PC'), findsOneWidget);
  });

  testWidgets('categories browse their own listing, chosen with the section button', (tester) async {
    final (link, _) = await pumpLibrary(tester);
    expect(find.text('Films'), findsNothing, reason: 'no row of pills over the list');
    await tester.tap(find.byType(SectionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Films'));
    await tester.pumpAndSettle();
    expect(link.asked.last.$2['category'], LibraryCategory.films.number);
    expect(link.asked.last.$2['home'], isFalse);
    // The title and the button name the section shown.
    expect(find.text('Films'), findsNWidgets(2));
    expect(find.text('Library'), findsNothing);
  });

  testWidgets('the section button stays in reach on a narrow phone, offers Queues, and Back closes its menu', (tester) async {
    tester.view.physicalSize = const Size(720, 1560);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final (link, _) = await pumpLibrary(tester, features: const {'library', 'watch', 'queues'});
    final button = find.byType(SectionButton);
    expect(tester.getRect(button).right, lessThanOrEqualTo(360));
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    expect(find.bySemanticsLabel('Section: Home. Choose another'), findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    for (final label in ['Home', 'Films', 'Shows', 'Anime', 'Queues']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    // The system's Back closes the menu and leaves Home as it was.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Queues'), findsNothing);
    expect(find.text('Continue watching'), findsOneWidget);
    final asked = link.asked.length;
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Queues'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuesView), findsOneWidget);
    expect(link.asked.length, greaterThan(asked));
  });

  group('the open sections stand as a ladder', () {
    /// The menu's pebbles, top first, the section button last.
    List<Rect> rungs(WidgetTester tester) =>
        tester.widgetList(find.descendant(of: find.byType(SectionLadder), matching: find.byType(Pebble))).map((pebble) => tester.getRect(find.byWidget(pebble))).toList();

    Future<(List<Rect>, Rect)> open(WidgetTester tester, {required Size size, double textScale = 1}) async {
      tester.view.physicalSize = size * 2;
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpLibrary(tester, features: const {'library', 'watch', 'queues'});
      final closed = tester.getRect(find.byType(SectionButton));
      await tester.tap(find.byType(SectionButton));
      await tester.pumpAndSettle();
      return (rungs(tester), closed);
    }

    void expectLabelsWhole(WidgetTester tester) {
      for (final label in ['Home', 'Films', 'Shows', 'Anime', 'Queues']) {
        final paragraph = tester.renderObject<RenderParagraph>(find.descendant(of: find.byType(SectionLadder), matching: find.text(label)).first);
        expect(paragraph.didExceedMaxLines, isFalse, reason: '$label is cut short');
      }
    }

    testWidgets('each a step wider than the one above it, the section button widest and where it was', (tester) async {
      final (ladder, closed) = await open(tester, size: const Size(400, 860));
      expect(ladder, hasLength(6));
      for (final rung in ladder) {
        expect(rung.right, moreOrLessEquals(closed.right), reason: 'the rungs share their right edge');
      }
      for (var i = 1; i < ladder.length; i++) {
        expect(ladder[i].width - ladder[i - 1].width, moreOrLessEquals(16), reason: 'rung $i');
      }
      expect(ladder.last.bottom, moreOrLessEquals(closed.bottom));
      expect(ladder.last.height, moreOrLessEquals(closed.height));
      expect(ladder.last.width, greaterThan(closed.width), reason: 'the open button widens to its rung');
      expectLabelsWhole(tester);

      // Closing it gives the button back its own width.
      await tester.tap(find.descendant(of: find.byType(SectionLadder), matching: find.byType(SectionButton)));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(SectionButton)), closed);
    });

    testWidgets('a tap beside a narrower section, over the wider button, closes the menu', (tester) async {
      final (ladder, closed) = await open(tester, size: const Size(400, 860));
      final beside = Offset(ladder.first.left - 30, ladder.first.center.dy);
      expect(beside.dx, greaterThan(ladder.last.left), reason: 'within the widest rung');
      await tester.tapAt(beside);
      await tester.pumpAndSettle();
      expect(find.byType(SectionLadder), findsNothing);
      expect(tester.getRect(find.byType(SectionButton)), closed);
    });

    testWidgets('on a narrow phone with large text, the steps shrink to fit and the labels stay whole', (tester) async {
      final (ladder, _) = await open(tester, size: const Size(300, 640), textScale: 2.2);
      expect(ladder.first.left, greaterThanOrEqualTo(16));
      final steps = [for (var i = 1; i < ladder.length; i++) ladder[i].width - ladder[i - 1].width];
      for (final step in steps) {
        expect(step, moreOrLessEquals(steps.first), reason: 'even steps: $steps');
      }
      expect(steps.first, lessThan(16));
      expectLabelsWhole(tester);
    });

    testWidgets('on a screen too short for them, the sections scroll under the button, which stays and closes the menu', (tester) async {
      final (ladder, closed) = await open(tester, size: const Size(800, 300));
      final button = find.descendant(of: find.byType(SectionLadder), matching: find.byType(SectionButton));
      expect(ladder.first.top, lessThan(0), reason: 'the top section starts scrolled out of sight');
      await tester.drag(find.descendant(of: find.byType(SectionLadder), matching: find.text('Anime')), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.descendant(of: find.byType(SectionLadder), matching: find.text('Home')).first).top, greaterThan(0));
      expect(tester.getRect(button).bottom, moreOrLessEquals(closed.bottom));
      expect(tester.getRect(button).right, moreOrLessEquals(closed.right));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(SectionLadder), findsNothing);
    });

    testWidgets('scrolled far under the button, no section shows again below it', (tester) async {
      final (_, closed) = await open(tester, size: const Size(800, 250));
      await tester.drag(find.descendant(of: find.byType(SectionLadder), matching: find.text('Anime')), const Offset(0, 300));
      await tester.pumpAndSettle();
      final ladder = tester.renderObject<RenderBox>(find.byType(SectionLadder));
      final queues = tester.getRect(find.ancestor(of: find.descendant(of: find.byType(SectionLadder), matching: find.text('Queues')), matching: find.byType(Pebble)).first);
      expect(queues.bottom, greaterThan(closed.bottom), reason: 'laid out past the button: the case to clip');
      final clips = tester.layers.whereType<ClipRectLayer>().map((layer) => ladder.localToGlobal(Offset(0, layer.clipRect!.bottom)).dy);
      expect(clips, contains(moreOrLessEquals(closed.bottom)), reason: 'the sections end at the button\'s bottom');

      // Nor can it be tapped there: a tap just under the button closes the menu and keeps the section.
      final under = Offset(closed.center.dx, closed.bottom + 8);
      expect(queues.contains(under), isTrue, reason: 'a hidden section is laid out there');
      expect(under.dy, lessThan(250));
      await tester.tapAt(under);
      await tester.pumpAndSettle();
      expect(find.byType(SectionLadder), findsNothing);
      expect(find.bySemanticsLabel('Section: Home. Choose another'), findsOneWidget);
    });
  });

  testWidgets('the section button steps aside while the list scrolls down, and is back at the top and on a short list', (tester) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected))..offered = const {'library'};
    // A Home of many rows, taller than the screen; any category is a single title.
    link.answer = (type, fields) async => fields['home'] == true
        ? {
            'type': 'page', 'total': 8, 'page': 0, 'pageSize': 40, 'location': 'Home',
            'entries': [
              for (var i = 0; i < 8; i++) {'id': 's$i', 'title': 'Title $i', 'caption': 'Movie', 'level': 'movie', 'kind': 'Kind $i', 'homeSection': 'suggestions', 'playable': true},
            ],
          }
        : {
            'type': 'page', 'total': 1, 'page': 0, 'pageSize': 40, 'location': 'Films',
            'entries': [{'id': 'f', 'title': 'Only film', 'caption': 'Movie', 'level': 'movie', 'kind': 'Movie', 'playable': true}],
          };
    final toTop = ValueNotifier(0);
    addTearDown(toTop.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: LibraryScreen(
        link: link,
        toTop: toTop,
        actions: LibraryActions(watchHere: (entry, {bool fromStart = false, QueueRef? queue}) async {}, playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async => null),
      ),
    ));
    await tester.pumpAndSettle();
    bool shown() => tester.widget<AnimatedOpacity>(find.ancestor(of: find.byType(SectionButton), matching: find.byType(AnimatedOpacity)).first).opacity == 1;
    expect(shown(), isTrue);
    await tester.drag(find.text('Kind 1'), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(shown(), isFalse, reason: 'scrolled down, it steps aside');
    // The Library tab tapped again: Home goes to its top, and the button comes back with it.
    toTop.value++;
    await tester.pumpAndSettle();
    expect(shown(), isTrue);

    await tester.tap(find.byType(SectionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Films'));
    await tester.pumpAndSettle();
    final asked = link.asked.length;
    // A list too short to scroll: pushing it up moves nothing, and the button stays.
    await tester.drag(find.text('Only film'), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(shown(), isTrue);
    expect(link.asked.length, asked);
  });

  testWidgets('Search is a tab of its own: it searches as one types, and clears', (tester) async {
    final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected))..offered = const {'library', 'watch'};
    link.answer = (type, fields) async => type == 'browse' ? homePage() : {'type': 'done'};
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: SearchScreen(link: link, actions: LibraryActions(watchHere: (entry, {bool fromStart = false, QueueRef? queue}) async {}, playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async => null)),
    ));
    await tester.pump();
    expect(find.text('Search the library'), findsOneWidget);
    expect(link.asked, isEmpty, reason: 'nothing is asked before anything is typed');
    await tester.enterText(find.byType(TextField), 'night');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(link.asked.single.$2['query'], 'night');
    expect(find.text('Asteroid City'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Search the library'), findsOneWidget);
    expect(find.text('Asteroid City'), findsNothing);
  });

  testWidgets("without a connection the Library says how it is going and can try again", (tester) async {
    final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.waitingForPc))..offered = const {'library'};
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: LibraryScreen(link: link, actions: LibraryActions(watchHere: (entry, {bool fromStart = false, QueueRef? queue}) async {}, playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async => null)),
    ));
    await tester.pump();
    expect(find.text("Your PC isn't online"), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    // While it is trying there is nothing to press.
    link.status = const LinkStatus(LinkPhase.linking);
    await tester.pump();
    expect(find.text('Reaching Study…'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets("Watch here shows for the PC's own video when it offers watching", (tester) async {
    Future<FakeRemoteLink> pump(String? mediaId, Set<String> features) async {
      final link = FakeRemoteLink(
        pcName: 'Study',
        status: const LinkStatus(LinkPhase.connected),
        state: RemoteState(media: true, title: 'Asteroid City', durationMs: 6000000, positionMs: 1000, mediaId: mediaId),
      )..offered = features;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: RemoteScreen(link: link, onChoosePc: () {}, onPairAgain: () {}, onWatchHere: (id) => link.tell('watched', {'id': id})),
      ));
      await tester.pump();
      return link;
    }

    final link = await pump('film', const {'watch'});
    await tester.tap(find.text('Watch here'));
    expect(link.told.single.$2['id'], 'film');
    await pump(null, const {'watch'});
    expect(find.text('Watch here'), findsNothing);
    await pump('film', const {});
    expect(find.text('Watch here'), findsNothing);
  });

  Map<String, dynamic> episodes(int page, {int total = 61}) => {
    'type': 'page',
    'total': total,
    'page': page,
    'pageSize': 40,
    'location': 'Season 1',
    'entries': [
      for (var i = page * 40; i < total && i < page * 40 + 40; i++)
        {'id': 'e$i', 'title': 'Episode ${i + 1}', 'level': 'episode', 'kind': 'Anime', 'season': 1, 'episode': i + 1, 'playable': true},
    ],
  };

  test('loading again keeps every page shown, not only the first', () async {
    final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected));
    link.answer = (type, fields) async => episodes(fields['page'] as int);
    final listing = LibraryListing(link, const BrowseRequest(parentId: 'show', season: 1));
    await listing.load();
    await listing.more();
    expect(listing.entries, hasLength(61));
    await listing.reload();
    expect(listing.entries, hasLength(61));
    expect(listing.entries.last.title, 'Episode 61');
    expect(listing.hasMore, isFalse);
    expect(link.asked.map((a) => a.$2['page']), [0, 1, 0, 1]);
  });

  testWidgets("Home whose next page fails asks once, says why, and tries again on request", (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected))..offered = const {'library'};
    var fail = true;
    Completer<void>? held;
    link.answer = (type, fields) async {
      if (fields['page'] == 0) return {...homePage(), 'total': 43};
      if (fail) throw const RemoteRequestException('timeout', "The PC didn't answer. Try again.");
      await held?.future;
      return {...homePage(), 'page': 1, 'total': 43, 'entries': <Map<String, dynamic>>[]};
    };
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: LibraryScreen(link: link, actions: LibraryActions(watchHere: (entry, {bool fromStart = false, QueueRef? queue}) async {}, playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async => null)),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(link.asked, hasLength(2), reason: 'the failed page is not asked for again on every frame');
    await tester.ensureVisible(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.textContaining("Couldn't load more"), findsOneWidget);
    fail = false;
    held = Completer<void>();
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(find.textContaining("Couldn't load more"), findsNothing, reason: 'Try again shows it is trying');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    held.complete();
    await tester.pumpAndSettle();
    expect(link.asked, hasLength(3));
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('pulling to refresh keeps the list until the new one has come', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final (link, _) = await pumpLibrary(tester);
    final pending = Completer<Map<String, dynamic>>();
    link.answer = (type, fields) => pending.future;
    await tester.fling(find.text('Continue watching'), const Offset(0, 500), 1500);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(link.asked.last.$2['home'], isTrue);
    expect(find.text('Asteroid City'), findsWidgets, reason: 'the list stays meanwhile');
    expect(find.byType(RefreshProgressIndicator), findsOneWidget, reason: 'and the spinner shows until the new list comes');
    pending.complete(homePage());
    await tester.pumpAndSettle();
    expect(find.byType(RefreshProgressIndicator), findsNothing);
  });

  testWidgets('an empty Home loads again when the link comes back: the PC may have answered before reading its library', (tester) async {
    final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected))..offered = const {'library'};
    link.answer = (type, fields) async => {...homePage(), 'total': 0, 'entries': <Map<String, dynamic>>[]};
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: LibraryScreen(link: link, actions: LibraryActions(watchHere: (entry, {bool fromStart = false, QueueRef? queue}) async {}, playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async => null)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Nothing here yet'), findsOneWidget);
    link.status = const LinkStatus(LinkPhase.failed, message: 'Lost the connection to the PC.');
    await tester.pump();
    link.answer = (type, fields) async => homePage();
    link.status = const LinkStatus(LinkPhase.connected);
    await tester.pumpAndSettle();
    expect(find.text('Continue watching'), findsOneWidget);
  });

  test("a Continue watching episode names its show once, and keeps the episode's title", () {
    const episode = LibraryEntry(id: 'e', title: '3 Body Problem · Episode 1 · Countdown', caption: '3 Body Problem · S01 E01', level: 'episode');
    expect(continueLines(episode), (title: '3 Body Problem', caption: 'S01 E01 · Countdown'));
    const film = LibraryEntry(id: 'f', title: 'Asteroid City', caption: 'Movie · 2023');
    expect(continueLines(film), (title: 'Asteroid City', caption: 'Movie · 2023'));
  });

  testWidgets('Play on PC from a show page closes the pages for the Remote, and nothing more', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final navigator = GlobalKey<NavigatorState>();
    final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected))..offered = const {'library', 'watch'};
    link.answer = (type, fields) async => fields['parentId'] == 'show'
        ? {
            'type': 'page', 'total': 1, 'page': 0, 'pageSize': 40, 'location': 'Night Signal',
            'entries': [{'id': 'e1', 'title': 'Episode 1', 'level': 'episode', 'kind': 'Show', 'playable': true}],
          }
        : homePage();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      theme: buildTheme(),
      home: LibraryScreen(
        link: link,
        actions: LibraryActions(
          watchHere: (entry, {bool fromStart = false, QueueRef? queue}) async {},
          // As the app does: the Remote shows, over any page.
          playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async {
            navigator.currentState!.popUntil((route) => route.isFirst);
            return null;
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Night Signal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Episode 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play on PC'));
    await tester.pumpAndSettle();
    expect(find.text('Continue watching'), findsOneWidget, reason: 'the first page stays');
  });

  testWidgets('after watching, Continue watching shows its start, where the title just watched now is', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    Map<String, dynamic> home(List<String> order) => {
      'type': 'page',
      'total': order.length,
      'page': 0,
      'pageSize': 40,
      'location': 'Home',
      'entries': [
        for (final id in order)
          {'id': id, 'title': 'Title $id', 'caption': 'Movie', 'level': 'movie', 'kind': 'Movie', 'homeSection': 'continue', 'positionMs': 60000, 'playable': true},
      ],
    };
    final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected))..offered = const {'library', 'watch'};
    var order = ['a', 'b', 'c', 'd', 'e', 'f'];
    link.answer = (type, fields) async => home(order);
    final changed = ValueNotifier(0);
    addTearDown(changed.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: LibraryScreen(
        link: link,
        changed: changed,
        actions: LibraryActions(watchHere: (entry, {bool fromStart = false, QueueRef? queue}) async {}, playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async => null),
      ),
    ));
    await tester.pumpAndSettle();
    // The user scrolls the row to a title further along and watches it on the phone.
    await tester.drag(find.text('Title a'), const Offset(-2000, 0));
    await tester.pumpAndSettle();
    final screen = tester.getRect(find.byType(LibraryScreen));
    bool shown(String id) {
      final text = find.text('Title $id');
      return text.evaluate().isNotEmpty && screen.overlaps(tester.getRect(text));
    }
    expect(shown('a'), isFalse);
    expect(shown('f'), isTrue);
    order = ['f', 'a', 'b', 'c', 'd', 'e'];
    changed.value++;
    await tester.pumpAndSettle();
    expect(shown('f'), isTrue, reason: 'the title just watched leads the row, and the row shows it');
    expect(tester.getRect(find.text('Title f')).left, lessThan(screen.width / 2));
  });

  group('Unwatched and watched marks', () {
    Map<String, dynamic> page(String location, List<Map<String, dynamic>> entries, {int? total}) =>
        {'type': 'page', 'total': total ?? entries.length, 'page': 0, 'pageSize': 40, 'location': location, 'entries': entries};
    final fresh = {'id': 'new', 'title': 'Paper Moon', 'caption': 'Movie · 1973', 'level': 'movie', 'kind': 'Movie', 'homeSection': 'unwatched', 'playable': true};
    final show = {'id': 'ep1', 'title': 'Night Signal', 'caption': 'Show · 2021', 'level': 'series', 'kind': 'Show', 'homeSection': 'unwatched', 'playable': false};

    Future<(FakeRemoteLink, List<String>)> pump(WidgetTester tester, {Set<String> features = const {'library', 'watch', 'unwatched', 'mark-watched'}}) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected))..offered = features;
      link.answer = (type, fields) async {
        if (type != 'browse') return {'type': 'done'};
        if (fields['unwatched'] == true) return page('Unwatched', [fresh, show], total: 2);
        if (fields['parentId'] == 'ep1') {
          return page('Night Signal', [
            {'id': 'ep1', 'title': 'Episode 1', 'level': 'episode', 'kind': 'Show', 'season': 1, 'episode': 1, 'playable': true},
          ]);
        }
        return {...homePage(), 'total': 5, 'entries': [...homePage()['entries'] as List, fresh, show]};
      };
      final marks = <String>[];
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: LibraryScreen(
          link: link,
          actions: LibraryActions(
            watchHere: (entry, {bool fromStart = false, QueueRef? queue}) async {},
            playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async => null,
            markWatched: (entry, watched, {String? level, int? season}) async {
              marks.add('${entry.id} ${level ?? entry.level} $watched${season == null ? '' : ' s$season'}');
              return null;
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return (link, marks);
    }

    testWidgets("Home's Unwatched row lists what the PC sends, and See all lists every title newest first", (tester) async {
      final (link, _) = await pump(tester);
      expect(find.text('Unwatched'), findsOneWidget);
      expect(find.text('Paper Moon'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Unwatched')).dy, greaterThan(tester.getTopLeft(find.text('Continue watching')).dy));
      expect(tester.getTopLeft(find.text('Unwatched')).dy, lessThan(tester.getTopLeft(find.text('Shows to start')).dy), reason: 'it follows Continue watching');
      await tester.tap(find.text('See all'));
      await tester.pumpAndSettle();
      expect(link.asked.last.$2['unwatched'], isTrue);
      expect(find.text('2 titles not started · newest first'), findsOneWidget);
      expect(find.text('Night Signal'), findsOneWidget);
      await tester.tap(find.text('Night Signal'));
      await tester.pumpAndSettle();
      expect(link.asked.last.$2['parentId'], 'ep1', reason: 'a show opens its page from the list');
    });

    testWidgets('a PC from before the full list shows the row without See all', (tester) async {
      await pump(tester, features: const {'library', 'watch'});
      expect(find.text('Paper Moon'), findsOneWidget);
      expect(find.text('See all'), findsNothing);
    });

    testWidgets("a title's sheet marks it watched and unwatched", (tester) async {
      final (_, marks) = await pump(tester);
      await tester.tap(find.text('Paper Moon'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark as watched'));
      await tester.pumpAndSettle();
      expect(marks, ['new movie true']);
      expect(find.text('Watched'), findsOneWidget);
      await tester.tap(find.text('Mark as unwatched'));
      await tester.pumpAndSettle();
      expect(marks.last, 'new movie false');
      expect(find.text('Mark as watched'), findsOneWidget);
    });

    testWidgets("a mark the PC refuses says why, and the sheet keeps the title's mark", (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected))..offered = const {'library', 'watch', 'mark-watched'};
      link.answer = (type, fields) async => homePage();
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: LibraryScreen(
          link: link,
          actions: LibraryActions(
            watchHere: (entry, {bool fromStart = false, QueueRef? queue}) async {},
            playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async => null,
            markWatched: (entry, watched, {String? level, int? season}) async => "That title is no longer in the PC's library.",
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Asteroid City'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark as watched'));
      await tester.pumpAndSettle();
      expect(find.text("That title is no longer in the PC's library."), findsOneWidget);
      expect(find.text('Mark as watched'), findsOneWidget);
    });

    testWidgets('Play on PC after a mark sends the mark as saved, not the one the sheet opened with', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected))..offered = const {'library', 'watch', 'mark-watched'};
      link.answer = (type, fields) async => homePage();
      final played = <String>[];
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: LibraryScreen(
          link: link,
          actions: LibraryActions(
            watchHere: (entry, {bool fromStart = false, QueueRef? queue}) async {},
            playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async {
              played.add('${entry.id} watched=${entry.watched} at=${entry.positionMs}');
              return 'kept open';
            },
            markWatched: (entry, watched, {String? level, int? season}) async => null,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      // Stopped at 12:40, then marked watched: the PC hears it is watched, so it starts over rather than clearing the mark.
      await tester.tap(find.text('Asteroid City'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark as watched'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play on PC'));
      await tester.pumpAndSettle();
      expect(played.last, 'film watched=true at=760000');
      await tester.tap(find.text('Mark as unwatched'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play on PC'));
      await tester.pumpAndSettle();
      expect(played.last, 'film watched=false at=760000');
    });

    testWidgets("a PC from before watched marks doesn't offer them", (tester) async {
      await pump(tester, features: const {'library', 'watch', 'unwatched'});
      await tester.tap(find.text('Paper Moon'));
      await tester.pumpAndSettle();
      expect(find.text('Mark as watched'), findsNothing);
    });

    testWidgets('a long press on a title offers where to play it and its watched mark, without opening it', (tester) async {
      final (_, marks) = await pump(tester);
      await tester.longPress(find.text('Paper Moon'));
      await tester.pumpAndSettle();
      expect(find.text('Play on phone'), findsOneWidget);
      expect(find.text('Play on Study'), findsOneWidget);
      await tester.tap(find.text('Mark as watched'));
      await tester.pumpAndSettle();
      expect(marks, ['new movie true']);
      expect(find.text('Marked watched.'), findsOneWidget);
      // A show has no mark of its own: both ways are offered, for all its episodes.
      await tester.longPress(find.text('Night Signal').first);
      await tester.pumpAndSettle();
      expect(find.text('Play on phone'), findsNothing);
      await tester.tap(find.text('Mark every episode as unwatched'));
      await tester.pumpAndSettle();
      expect(marks.last, 'ep1 series false');
    });

    testWidgets('a long press in Continue watching removes the title from the row, and Undo puts it back', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected))..offered = const {'library', 'watch', 'mark-watched', 'hide-continue'};
      var hidden = false;
      link.answer = (type, fields) async {
        final home = homePage();
        if (!hidden) return home;
        final entries = (home['entries'] as List).where((e) => (e as Map)['id'] != 'film').toList();
        return {...home, 'total': entries.length, 'entries': entries};
      };
      final changed = ValueNotifier(0);
      addTearDown(changed.dispose);
      final asked = <String>[];
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: LibraryScreen(
          link: link,
          changed: changed,
          actions: LibraryActions(
            watchHere: (entry, {bool fromStart = false, QueueRef? queue}) async {},
            playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async => null,
            hideContinue: (entry, hide) async {
              asked.add('${entry.id} $hide');
              hidden = hide;
              changed.value++;
              return null;
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Asteroid City'), findsOneWidget);
      await tester.longPress(find.text('Asteroid City'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from Continue watching'));
      await tester.pumpAndSettle();
      expect(asked, ['film true']);
      expect(find.text('Removed from Continue watching.'), findsOneWidget);
      expect(find.text('Asteroid City'), findsNothing, reason: 'Home loads again without it');
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(asked.last, 'film false');
      expect(find.text('Asteroid City'), findsOneWidget, reason: 'Undo puts it back');
    });

    testWidgets("a PC from before removing from Continue watching doesn't offer it", (tester) async {
      await pump(tester);
      await tester.longPress(find.text('Asteroid City'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Resume on phone'), findsOneWidget, reason: 'the sheet opened');
      expect(find.text('Remove from Continue watching'), findsNothing);
    });

    testWidgets("an episode's row plays it with one tap, where a video was last started", (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected))..offered = const {'library', 'watch'};
      link.answer = (type, fields) async => fields['parentId'] == 'ep1'
          ? page('Night Signal', [
              {'id': 'e1', 'title': 'Pilot', 'level': 'episode', 'kind': 'Show', 'season': 1, 'episode': 1, 'playable': true},
              {'id': 's2', 'title': 'Season 2', 'level': 'season', 'kind': 'Show', 'season': 2, 'playable': false},
            ])
          : page('Shows', [show]);
      final played = <String>[];
      var onPc = false;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: LibraryScreen(
          link: link,
          actions: LibraryActions(
            watchHere: (entry, {bool fromStart = false, QueueRef? queue}) async => played.add('here ${entry.id}'),
            playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async {
              played.add('pc ${entry.id}');
              return null;
            },
            prefersPc: () => onPc,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Night Signal'));
      await tester.pumpAndSettle();
      // A season opens its episodes: it has no play button.
      expect(find.bySemanticsLabel(RegExp('^Play Season 2')), findsNothing);
      await tester.tap(find.bySemanticsLabel('Play Pilot on this phone'));
      await tester.pump(const Duration(seconds: 1));
      expect(played, ['here e1']);
      expect(find.text('Play on PC'), findsNothing, reason: 'no sheet opened');
      onPc = true;
      link.status = const LinkStatus(LinkPhase.connected);
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Play Pilot on Study'));
      await tester.pump(const Duration(seconds: 1));
      expect(played.last, 'pc e1');
    });

    testWidgets("a show's page marks every episode", (tester) async {
      final (_, marks) = await pump(tester);
      await tester.ensureVisible(find.text('Night Signal').first);
      await tester.tap(find.text('Night Signal').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Mark the show'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark show as watched'));
      await tester.pumpAndSettle();
      expect(marks, ['ep1 series true']);
      expect(find.text('Every episode is marked watched.'), findsOneWidget);
    });
  });
}
