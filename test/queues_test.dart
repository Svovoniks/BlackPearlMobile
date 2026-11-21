import 'package:blackpearl_mobile/playback/phone_playback.dart';
import 'package:blackpearl_mobile/protocol/library.dart';
import 'package:blackpearl_mobile/protocol/remote_state.dart';
import 'package:blackpearl_mobile/ui/library_screen.dart';
import 'package:flutter_test/flutter_test.dart';

LibraryEntry entry(String id, int index, {bool playable = true}) => LibraryEntry(id: id, title: id, playable: playable, index: index);

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
}
