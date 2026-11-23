import 'package:blackpearl_mobile/playback/video_shape.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

const _landscape = [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight];
const _portrait = [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown];

VideoTrack _track(String id, int w, int h, {double? par, int? rotate, bool? albumart, bool? image}) =>
    VideoTrack(id, null, null, w: w, h: h, par: par, rotate: rotate, albumart: albumart, image: image);

void main() {
  group('the size a video shows at', () {
    test('comes from the file before the picture', () {
      expect(shownSize([VideoTrack.auto(), VideoTrack.no(), _track('1', 1920, 1080)], 'auto', null, null), (1920.0, 1080.0));
    });

    test('is turned as the file says, as a phone recording held upright', () {
      expect(shownSize([_track('1', 1920, 1080, rotate: 90)], '1', null, null), (1080.0, 1920.0));
      expect(shownSize([_track('1', 1920, 1080, rotate: 270)], '1', null, null), (1080.0, 1920.0));
      expect(shownSize([_track('1', 1920, 1080, rotate: 180)], '1', null, null), (1920.0, 1080.0));
    });

    test('is stretched as the file says, as a widescreen DVD', () {
      final (width, height) = shownSize([_track('1', 720, 480, par: 32 / 27)], '1', null, null);
      expect(width, closeTo(853.3, 0.1));
      expect(height, 480);
    });

    test('is the chosen track, not cover art', () {
      final tracks = [_track('1', 600, 600, albumart: true), _track('2', 500, 800, image: true), _track('3', 1280, 720)];
      expect(shownSize(tracks, 'auto', null, null), (1280.0, 720.0));
      expect(shownSize([_track('1', 1280, 720), _track('2', 720, 1280)], '2', null, null), (720.0, 1280.0));
    });

    test('is the picture\'s when the file gives none, and nothing before either', () {
      expect(shownSize([VideoTrack.auto(), VideoTrack.no()], 'auto', 854, 480), (854.0, 480.0));
      expect(shownSize(const [], 'auto', null, null), (0.0, 0.0));
    });
  });

  group('the ways up the player allows', () {
    test('are sideways for a wide video and upright for a tall one', () {
      expect(playerOrientations((1920, 1080), follows: false), _landscape);
      expect(playerOrientations((1080, 1920), follows: false), _portrait);
    });

    test('stay as they are for a square video or one of no known size', () {
      expect(playerOrientations((1080, 1080), follows: false), isNull);
      expect(playerOrientations((0, 0), follows: false), isNull);
      expect(playerOrientations((1920, 0), follows: false), isNull);
    });

    test('are any way when the player turns with the phone', () {
      expect(playerOrientations((1920, 1080), follows: true), isEmpty);
      expect(playerOrientations((0, 0), follows: true), isEmpty);
    });
  });
}
