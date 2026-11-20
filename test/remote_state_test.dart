import 'dart:convert';

import 'package:blackpearl_mobile/protocol/remote_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses the example state from the protocol', () {
    final state = RemoteState.fromJson(
      jsonDecode('''
      {"type":"state","media":true,"title":"Night Signal","detail":"Season 2 · Episode 3 · Low Tide","playing":true,
       "positionMs":1122000,"durationMs":2830000,"volume":64,"muted":false,"loop":"all","fullscreen":false,
       "hasPrevious":true,"hasNext":true,"canControl":true,"room":{"name":"Movie club","people":3}}''') as Map<String, dynamic>,
    );
    expect(state.media, isTrue);
    expect(state.title, 'Night Signal');
    expect(state.detail, 'Season 2 · Episode 3 · Low Tide');
    expect(state.playing, isTrue);
    expect(state.positionMs, 1122000);
    expect(state.durationMs, 2830000);
    expect(state.volume, 64);
    expect(state.loop, LoopMode.all);
    expect(state.hasPrevious, isTrue);
    expect(state.canControl, isTrue);
    expect(state.room, const RemoteRoom(name: 'Movie club', people: 3));
  });

  test('nothing loaded: playback fields absent or null', () {
    // The desktop writes null for fields that don't apply.
    final state = RemoteState.fromJson(
      jsonDecode(
        '{"type":"state","media":false,"title":null,"detail":null,"playing":null,'
        '"positionMs":null,"durationMs":null,"volume":100,"muted":false,"loop":"off","fullscreen":false,"hasPrevious":false,'
        '"hasNext":false,"canControl":true,"room":null}',
      ) as Map<String, dynamic>,
    );
    expect(state.media, isFalse);
    expect(state.title, '');
    expect(state.playing, isFalse);
    expect(state.positionMs, 0);
    expect(state.room, isNull);
    final bare = RemoteState.fromJson({'type': 'state', 'media': false});
    expect(bare.media, isFalse);
    expect(bare.volume, isNull);
    expect(bare.canControl, isTrue);
  });

  test('mistyped and out-of-range fields fall back', () {
    final state = RemoteState.fromJson({
      'media': true,
      'title': 5,
      'playing': 'yes',
      'positionMs': -40,
      'durationMs': 1000.6,
      'volume': 140,
      'loop': 'sometimes',
      'canControl': false,
      'room': {'people': 2.0},
    });
    expect(state.title, '');
    expect(state.playing, isFalse);
    expect(state.positionMs, 0);
    expect(state.durationMs, 1001);
    expect(state.volume, 100);
    expect(state.loop, LoopMode.off);
    expect(state.canControl, isFalse);
    expect(state.room, const RemoteRoom(name: 'Room', people: 2));
  });

  test('loop modes', () {
    expect(LoopMode.parse('off'), LoopMode.off);
    expect(LoopMode.parse('all'), LoopMode.all);
    expect(LoopMode.parse('one'), LoopMode.one);
  });

  test('position advances while playing, stops at the end, holds while paused', () {
    const playing = RemoteState(media: true, playing: true, positionMs: 10000, durationMs: 20000);
    expect(playing.positionAfter(2500), 12500);
    expect(playing.positionAfter(60000), 20000);
    expect(playing.positionAfter(-5), 10000);
    expect(playing.copyWith(playing: false).positionAfter(2500), 10000);
    expect(RemoteState.nothing.positionAfter(1000), 0);
  });

  test('clock format', () {
    expect(formatClock(0), '0:00');
    expect(formatClock(65000), '1:05');
    expect(formatClock(1122000), '18:42');
    expect(formatClock(3723000), '1:02:03');
    expect(formatClock(-1), '0:00');
  });
}
