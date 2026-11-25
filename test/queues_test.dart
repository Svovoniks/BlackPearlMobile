import 'package:blackpearl_mobile/playback/phone_playback.dart';
import 'package:blackpearl_mobile/protocol/library.dart';
import 'package:blackpearl_mobile/protocol/remote_state.dart';
import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/debug/preview.dart';
import 'package:blackpearl_mobile/ui/library_screen.dart';
import 'package:blackpearl_mobile/ui/queue_widgets.dart';
import 'package:blackpearl_mobile/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

LibraryEntry entry(String id, int index, {bool playable = true, bool watched = false}) =>
    LibraryEntry(id: id, title: id, playable: playable, index: index, watched: watched);

void main() {
  group('a list the player follows, as the PC steps through a queue', () {
    // A queue that holds b twice and an unavailable c.
    final queue = [entry('a', 0), entry('b', 1), entry('c', 2, playable: false), entry('d', 3), entry('b', 4)];

    test('steps to the playable videos around the place, skipping one that can\'t play', () {
      final steps = PhonePlayback.stepsIn(queue, 'd', null, inQueue: true);
      expect(steps.previous?.id, 'b');
      expect(steps.previous?.queueIndex, 1);
      expect(steps.next?.id, 'b');
      expect(steps.next?.queueIndex, 4);
      expect(steps.first, isNull);
    });

    test('a video queued twice steps from the place it plays at', () {
      expect(PhonePlayback.stepsIn(queue, 'b', 4, inQueue: true).next, isNull);
      expect(PhonePlayback.stepsIn(queue, 'b', 4, inQueue: true).first?.queueIndex, 0, reason: 'Loop all starts the queue again');
      expect(PhonePlayback.stepsIn(queue, 'b', 1, inQueue: true).next?.id, 'd');
      expect(PhonePlayback.stepsIn(queue, 'b', null, inQueue: true).next?.id, 'd', reason: 'without a place, its first');
    });

    test('a queue without the playing video starts from its first video', () {
      final steps = PhonePlayback.stepsIn(queue, 'z', null, inQueue: true);
      expect(steps.previous, isNull);
      expect(steps.next?.id, 'a');
      expect(steps.next?.queueIndex, 0);
    });

    test("a show's episodes step without queue places", () {
      final episodes = [entry('e1', 0), entry('e2', 1), entry('e3', 2)];
      final steps = PhonePlayback.stepsIn(episodes, 'e2', null, inQueue: false);
      expect((steps.previous?.id, steps.next?.id), ('e1', 'e3'));
      expect(steps.next?.queueIndex, isNull);
    });

    test("a show's episodes without the playing video have nothing to step to, rather than its first episode", () {
      final steps = PhonePlayback.stepsIn([entry('e1', 0), entry('e2', 1)], 'e9', null, inQueue: false);
      expect((steps.previous, steps.next, steps.first), (null, null, null));
    });
  });

  group("a queue's up next, as the PC works it out", () {
    test('the first unwatched video from the place on, skipping one that cannot play', () {
      final queue = [entry('a', 0), entry('b', 1, watched: true), entry('c', 2, playable: false), entry('d', 3), entry('e', 4)];
      expect(queueUpNext(queue, 1)?.id, 'd');
      expect(queueUpNext(queue, 4)?.id, 'e');
      expect(queueUpNext(queue, null)?.id, 'a');
    });

    test('from the start when nothing after the place is unwatched, and the first video when all are watched', () {
      expect(queueUpNext([entry('a', 0), entry('b', 1, watched: true)], 1)?.id, 'a');
      expect(queueUpNext([entry('a', 0, watched: true), entry('b', 1, watched: true)], 1)?.id, 'a');
      expect(queueUpNext([entry('a', 0, playable: false)], 0), isNull);
    });
  });

  test('a list closed while a page is on its way stops loading instead of asking for it again', () async {
    final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected));
    LibraryListing? listing;
    link.answer = (type, fields) async {
      final page = fields['page'] as int;
      if (page == 1) listing!.dispose();
      return {
        'type': 'page',
        'entries': [for (var i = page * 10; i < page * 10 + 10; i++) {'id': 'v$i', 'title': 'V$i', 'index': i, 'playable': true}],
        'total': 100,
        'page': page,
        'pageSize': 10,
      };
    };
    listing = LibraryListing(link, const BrowseRequest(episodesOf: 'v57'));
    await loadWholeList(listing, mustHave: 'v57').timeout(const Duration(seconds: 2));
    expect(link.asked.length, 2);
  });

  test('a long list loads past its limit until it has the playing video', () async {
    final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected));
    link.answer = (type, fields) async {
      final page = fields['page'] as int;
      return {
        'type': 'page',
        'entries': [for (var i = page * 10; i < page * 10 + 10; i++) {'id': 'v$i', 'title': 'V$i', 'index': i, 'playable': true}],
        'total': 100,
        'page': page,
        'pageSize': 10,
      };
    };
    final listing = LibraryListing(link, const BrowseRequest(episodesOf: 'v57'));
    await loadWholeList(listing, max: 20, mustHave: 'v57');
    expect(listing.entries.length, 60);
    final short = LibraryListing(link, const BrowseRequest(episodesOf: 'v57'));
    await loadWholeList(short, max: 20);
    expect(short.entries.length, 20);
  });

  group('the queue messages', () {
    test("the PC's queues are read with their counts, places and the active one", () {
      final queues = QueueSummary.listFromJson({
        'type': 'queues',
        'queues': [
          {'id': 'evening', 'name': 'Evening', 'count': 4, 'upNext': 2, 'active': true, 'artwork': 'tok'},
          {'id': 'done', 'name': 'Done', 'count': 2, 'upNext': null, 'active': false},
          {'name': 'no id'},
        ],
      });
      expect(queues.map((q) => q.id), ['evening', 'done']);
      expect((queues[0].count, queues[0].upNext, queues[0].active, queues[0].artwork), (4, 2, true, 'tok'));
      expect(queues[1].upNext, isNull);
    });

    test('a list request names the queue or the show, and a page keeps its places', () {
      expect(const BrowseRequest(queue: 'evening').toJson()['queue'], 'evening');
      expect(const BrowseRequest(episodesOf: 'e2').toJson()['episodesOf'], 'e2');
      expect(const BrowseRequest(category: LibraryCategory.films).toJson().containsKey('queue'), isFalse);
      expect(const BrowseRequest(queue: 'evening').nextPage().queue, 'evening');
      final page = LibraryPage.fromJson({
        'entries': [
          {'id': 'b', 'title': 'B', 'index': 1, 'playable': true},
          {'id': 'b', 'title': 'B', 'index': 4, 'playable': true},
        ],
        'total': 2,
      });
      expect(page.entries.map((e) => e.index), [1, 4]);
    });

    test("the stream answer and the PC's state say which queue and place", () {
      final info = StreamInfo.fromJson({
        'id': 'd',
        'kind': 'file',
        'resource': 'file/d',
        'length': 10,
        'queue': {'id': 'evening', 'name': 'Evening', 'index': 3},
        'next': {'id': 'b', 'title': 'B', 'queueIndex': 4},
      })!;
      expect((info.queue?.id, info.queue?.index, info.next?.queueIndex), ('evening', 3, 4));
      final state = RemoteState.fromJson({
        'media': true,
        'title': 'D',
        'mediaId': 'd',
        'queue': {'id': 'evening', 'name': 'Evening', 'index': 3},
      });
      expect((state.queue?.name, state.queue?.index), ('Evening', 3));
      expect(RemoteState.fromJson({'media': false, 'queue': {'id': 'x', 'name': 'X'}}).queue, isNull);
    });
  });

  test('Library actions for a queue play each video at its place', () async {
    QueueRef? watched, played;
    final actions = LibraryActions(
      watchHere: (entry, {bool fromStart = false, QueueRef? queue}) async => watched = queue,
      playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async {
        played = queue;
        return null;
      },
    ).inQueue(const QueueRef(id: 'evening', name: 'Evening'));
    await actions.watchHere(entry('b', 4));
    await actions.playOnPc(entry('d', 3));
    expect((watched?.id, watched?.index), ('evening', 4));
    expect((played?.id, played?.index), ('evening', 3));
  });

  testWidgets("a long queue loads its next page as the list nears its end; a page that fails says why and waits for Try again", (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final link = FakeRemoteLink(pcName: 'Den', status: const LinkStatus(LinkPhase.connected))..offered = const {'library', 'watch', 'queues'};
    var fail = true;
    link.answer = (type, fields) async {
      final page = fields['page'] as int;
      if (page > 0 && fail) throw const RemoteRequestException('timeout', "The PC didn't answer. Try again.");
      return {
        'type': 'page',
        'total': 60,
        'page': page,
        'pageSize': 40,
        'location': 'Evening',
        'entries': [for (var i = page * 40; i < 60 && i < page * 40 + 40; i++) {'id': 'v$i', 'title': 'Video $i', 'level': 'movie', 'playable': true, 'index': i}],
      };
    };
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: QueueScreen(
        link: link,
        queue: const QueueSummary(id: 'evening', name: 'Evening', count: 60, upNext: 0),
        actions: LibraryActions(watchHere: (entry, {bool fromStart = false, QueueRef? queue}) async {}, playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async => null),
        changed: null,
      ),
    ));
    await tester.pumpAndSettle();
    expect(link.asked, hasLength(1), reason: 'the first page only, until the list is scrolled');
    // To the end of what has loaded, and a while there: the page that failed is asked for once, not on every frame.
    await tester.drag(find.text('Video 3'), const Offset(0, -5000));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
    expect(link.asked, hasLength(2));
    expect(find.textContaining("Couldn't load more"), findsOneWidget);
    fail = false;
    await tester.ensureVisible(find.text('Try again'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(link.asked, hasLength(3));
    await tester.drag(find.text('Video 39'), const Offset(0, -5000));
    await tester.pumpAndSettle();
    expect(find.text('Video 59'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets("the Remote's Up next follows the PC to the next episode", (tester) async {
    final link = FakeRemoteLink(
      pcName: 'Den',
      status: const LinkStatus(LinkPhase.connected),
      state: const RemoteState(media: true, title: 'e1', durationMs: 1000, mediaId: 'e1'),
    )..offered = const {'library', 'queues'};
    link.answer = (type, fields) async => type == 'queues'
        ? {'type': 'queues', 'queues': <Object>[]}
        : {
            'type': 'page', 'total': 3, 'page': 0, 'pageSize': 40, 'location': 'Show',
            'entries': [for (final (i, id) in ['e1', 'e2', 'e3'].indexed) {'id': id, 'title': id, 'level': 'episode', 'playable': true, 'index': i}],
          };
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(onPressed: () => showRemoteUpNext(context, link: link, mediaId: 'e1', queue: null), child: const Text('open')),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    bool current(String id) => tester.widget<QueueEntryRow>(find.ancestor(of: find.text(id), matching: find.byType(QueueEntryRow))).current;
    expect(current('e1'), isTrue);
    link.setState(const RemoteState(media: true, title: 'e2', durationMs: 1000, mediaId: 'e2'));
    await tester.pumpAndSettle();
    expect(current('e1'), isFalse);
    expect(current('e2'), isTrue);
  });
}
