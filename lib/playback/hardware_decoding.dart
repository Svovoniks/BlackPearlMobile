import 'dart:async';

/// The codecs libmpv may decode with the phone's video hardware: media_kit's list without `mpeg4`.
///
/// MPEG-4 Part 2 (DivX, XviD) stays in software, as desktop players decode it. Android's hardware decoders take its
/// simple profile, but an XviD AVI in the advanced profile with packed B-frames (a picture and the next one in one
/// chunk, then a near-empty one) stopped the picture a few frames in while the sound played on. The decoder had
/// started, so libmpv never fell back to software. Software decoding of these files is light: they are DVD-sized or
/// smaller.
const hardwareCodecs = 'h264,hevc,mpeg2video,vp8,vp9,av1';

/// Sets libmpv's `hwdec-codecs` with [set] now, and again once [videoControllerReady] completes: media_kit's Android
/// VideoController writes its own list, with `mpeg4`, as it attaches. The picture's decoder starts once the video
/// surface arrives after that, so it sees this list.
void keepHardwareCodecs(Future<void> Function(String property, String value) set, Future<void> videoControllerReady) {
  Future<void> apply() => set('hwdec-codecs', hardwareCodecs).catchError((Object _) {});
  unawaited(apply());
  unawaited(videoControllerReady.then((_) => apply(), onError: (Object _) {}));
}
