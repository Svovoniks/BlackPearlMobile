import 'dart:async';

import 'package:blackpearl_mobile/playback/mpv_reads.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a read libmpv answers gives its value', () async {
    final reads = MpvReads.withReader((player, property) async => property == 'aid' ? '2' : null);
    expect(await reads.readFrom(Object(), 'aid', within: const Duration(seconds: 1)), '2');
  });

  test('a read a busy libmpv holds up gives null in time, and the next read of it waits on the same one', () async {
    final answer = Completer<String?>();
    var started = 0;
    final reads = MpvReads.withReader((player, property) {
      started++;
      return answer.future;
    });
    final player = Object();
    final clock = Stopwatch()..start();
    expect(await reads.readFrom(player, 'time-pos', within: const Duration(milliseconds: 50)), isNull);
    expect(clock.elapsedMilliseconds, lessThan(1000));
    final later = reads.readFrom(player, 'time-pos', within: const Duration(seconds: 1));
    expect(started, 1);
    answer.complete('12.5');
    expect(await later, '12.5');
    // Once answered, a new read starts.
    unawaited(reads.readFrom(player, 'time-pos', within: const Duration(seconds: 1)));
    expect(started, 2);
  });

  test('a failed read gives null', () async {
    final reads = MpvReads.withReader((player, property) async => throw StateError('no libmpv'));
    expect(await reads.readFrom(Object(), 'sid', within: const Duration(seconds: 1)), isNull);
  });

  test('release waits for reads still running, and no read starts after it', () async {
    final answer = Completer<String?>();
    var started = 0;
    final reads = MpvReads.withReader((player, property) {
      started++;
      return answer.future;
    });
    final player = Object();
    unawaited(reads.readFrom(player, 'aid', within: const Duration(milliseconds: 10)));
    var released = false;
    final releasing = reads.releaseFrom(player).then((_) => released = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(released, isFalse);
    answer.complete('1');
    await releasing;
    expect(released, isTrue);
    expect(await reads.readFrom(player, 'aid', within: const Duration(seconds: 1)), isNull);
    expect(started, 1);
  });

  test('release gives up on a read that never finishes', () async {
    final reads = MpvReads.withReader((player, property) => Completer<String?>().future);
    final player = Object();
    unawaited(reads.readFrom(player, 'aid', within: const Duration(milliseconds: 10)));
    final clock = Stopwatch()..start();
    await reads.releaseFrom(player, within: const Duration(milliseconds: 100));
    expect(clock.elapsedMilliseconds, lessThan(2000));
  });
}
