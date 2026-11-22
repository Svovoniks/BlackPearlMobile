import 'dart:math';

import 'package:blackpearl_mobile/playback/phone_playback.dart';
import 'package:blackpearl_mobile/playback/shuffle_order.dart';
import 'package:blackpearl_mobile/protocol/library.dart';
import 'package:blackpearl_mobile/protocol/remote_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const pool = ['e1', 'e2', 'e3', 'e4', 'e5', 'e6'];

  group('the shuffle order, as on the PC', () {
    test('without Loop all every episode plays once, then nothing', () {
      final order = ShuffleOrder(Random(7));
      final played = ['e1'];
      for (String? next; (next = order.next('show', played.last, pool, loop: false)) != null;) {
        played.add(next!);
      }
      expect(played.toSet(), pool.toSet());
      expect(played, hasLength(pool.length));
      expect(played, isNot(pool), reason: "not the show's order");
    });

    test('the pick for Next stays until it plays, and is replaced when it can no longer play', () {
      final order = ShuffleOrder(Random(3));
      final pick = order.next('show', 'e1', pool, loop: false);
      expect(pick, isNot('e1'));
      for (var i = 0; i < 5; i++) {
        expect(order.next('show', 'e1', pool, loop: false), pick);
      }
      expect(order.next('show', 'e1', pool, loop: false, canPlay: (id) => id != pick), allOf(isNotNull, isNot(pick)));
    });

    test('Previous walks back through what played, and Next retraces it', () {
      final order = ShuffleOrder(Random(11));
      final path = ['e3'];
      for (var i = 0; i < 3; i++) {
        path.add(order.next('show', path.last, pool, loop: false)!);
      }
      var back = order.previous('show', path[3], pool);
      expect(back, path[2]);
      order.goingBack(back!);
      back = order.previous('show', back, pool);
      expect(back, path[1]);
      order.goingBack(back!);
      expect(order.next('show', back, pool, loop: false), path[2]);
    });

    test('with Loop all each round plays every episode once and never repeats the one that just ended', () {
      final order = ShuffleOrder(Random(9));
      final played = ['e1'];
      while (played.length < pool.length * 3) {
        played.add(order.next('show', played.last, pool, loop: true)!);
      }
      for (var round = 0; round < 3; round++) {
        expect(played.sublist(round * pool.length, (round + 1) * pool.length).toSet(), pool.toSet());
      }
      for (var i = 1; i < played.length; i++) {
        expect(played[i], isNot(played[i - 1]));
      }
    });

    test('asking Previous before each Next, as the player does for its button, never makes Loop all repeat', () {
      for (var seed = 0; seed < 200; seed++) {
        final order = ShuffleOrder(Random(seed));
        final played = ['e1'];
        while (played.length < pool.length * 4) {
          order.previous('show', played.last, pool);
          played.add(order.next('show', played.last, pool, loop: true)!);
          order.previous('show', played.last, pool);
        }
        for (var round = 0; round < 4; round++) {
          expect(played.sublist(round * pool.length, (round + 1) * pool.length).toSet(), pool.toSet(), reason: 'seed $seed: $played');
        }
        for (var i = 1; i < played.length; i++) {
          expect(played[i], isNot(played[i - 1]), reason: 'seed $seed: $played');
        }
      }
    });

    test('a list of one has nothing else to shuffle to', () {
      expect(ShuffleOrder().next('show', 'e1', ['e1'], loop: true), isNull);
    });
  });

  group("the phone's player", () {
    LibraryEntry entry(String id, {int season = 1, bool playable = true, int? index}) =>
        LibraryEntry(id: id, title: id, level: 'episode', season: season, episode: 1, playable: playable, index: index);

    test("a show shuffles its regular episodes that can play, and skips specials", () {
      final entries = [entry('special', season: 0), entry('a', index: 0), entry('b', index: 1), entry('gone', playable: false, index: 2), entry('c', index: 3)];
      final order = ShuffleOrder(Random(1));
      final seen = <String>{};
      var current = 'a';
      for (var i = 0; i < 5; i++) {
        final step = PhonePlayback.shuffledStep(order, scope: 'show:a', entries: entries, inQueue: false, current: current, loop: false, forward: true);
        if (step == null) break;
        expect(step.queueIndex, isNull, reason: 'a show is not a queue');
        seen.add(step.id);
        current = step.id;
      }
      expect(seen, {'b', 'c'});
    });

    test('in a queue a step keeps its place, and a video queued twice plays from its other place', () {
      final entries = [entry('a', index: 0), entry('a', index: 1)];
      final step = PhonePlayback.shuffledStep(ShuffleOrder(Random(1)), scope: 'queue:q', entries: entries, inQueue: true, current: 'b', place: 5, loop: false, forward: true);
      expect(step?.queueIndex, 0);
      final order = ShuffleOrder(Random(1));
      final queue = [entry('x', index: 0), entry('y', index: 1), entry('x', index: 2)];
      final next = PhonePlayback.shuffledStep(order, scope: 'queue:q', entries: queue, inQueue: true, current: 'y', place: 1, loop: false, forward: true);
      expect(next?.id, 'x');
      expect(next?.queueIndex, isNotNull);
    });

    test('Previous with nothing played before has no step', () {
      expect(
        PhonePlayback.shuffledStep(ShuffleOrder(), scope: 'show:a', entries: [entry('a'), entry('b')], inQueue: false, current: 'a', loop: false, forward: false),
        isNull,
      );
    });
  });

  test("the PC's state carries its Shuffle, and an older PC's leaves it unknown", () {
    expect(RemoteState.fromJson({'type': 'state', 'media': true, 'shuffle': true}).shuffle, isTrue);
    expect(RemoteState.fromJson({'type': 'state', 'media': true, 'shuffle': false}).shuffle, isFalse);
    expect(RemoteState.fromJson({'type': 'state', 'media': true}).shuffle, isNull);
    expect(RemoteState.fromJson({'type': 'state', 'media': true, 'shuffle': true}).copyWith(positionMs: 5).shuffle, isTrue);
  });
}
