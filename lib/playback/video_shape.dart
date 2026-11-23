import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

/// The video's size as shown: as its file says, which is known as soon as it opens (turned and stretched as the file
/// says), or else as the picture came out ([pictureWidth] by [pictureHeight]). Zero while neither is known.
(double, double) shownSize(List<VideoTrack> tracks, String chosen, int? pictureWidth, int? pictureHeight) {
  final files = tracks.where((t) => (t.w ?? 0) > 0 && (t.h ?? 0) > 0 && t.albumart != true && t.image != true);
  final track = files.where((t) => t.id == chosen).firstOrNull ?? files.firstOrNull;
  if (track != null) {
    final width = track.w! * (track.par ?? 1.0);
    final height = track.h!.toDouble();
    return (track.rotate ?? 0) % 180 == 90 ? (height, width) : (width, height);
  }
  return ((pictureWidth ?? 0).toDouble(), (pictureHeight ?? 0).toDouble());
}

/// The ways up the player allows for a video of this size: landscape either way round for a wide one, portrait either
/// way up for a tall one, and none (it turns with the phone) when it [follows] the phone. Null keeps what it has: the
/// size isn't known yet, or the video is square.
List<DeviceOrientation>? playerOrientations((double, double) size, {required bool follows}) {
  if (follows) return const [];
  final (width, height) = size;
  if (width <= 0 || height <= 0 || width == height) return null;
  return width > height
      ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
      : const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown];
}
