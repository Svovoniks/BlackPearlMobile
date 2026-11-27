import 'dart:async';

import 'package:blackpearl_mobile/playback/hardware_decoding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MPEG-4 Part 2 is left to software decoding; the codecs media_kit sends to hardware otherwise stay', () {
    final codecs = hardwareCodecs.split(',');
    expect(codecs, isNot(contains('mpeg4')));
    expect(codecs, containsAll(['h264', 'hevc', 'mpeg2video', 'vp8', 'vp9', 'av1']));
  });

  test('the list is set at once and again after the video controller writes its own', () async {
    final sets = <String>[];
    final ready = Completer<void>();
    keepHardwareCodecs((property, value) async => sets.add('$property=$value'), ready.future);
    await pumpEventQueue();
    expect(sets, ['hwdec-codecs=$hardwareCodecs']);

    ready.complete();
    await pumpEventQueue();
    expect(sets, ['hwdec-codecs=$hardwareCodecs', 'hwdec-codecs=$hardwareCodecs']);
  });

  test('a player that is gone or a controller that failed does not throw', () async {
    final ready = Completer<void>();
    keepHardwareCodecs((property, value) async => throw AssertionError('[Player] has been disposed'), ready.future);
    ready.completeError(UnsupportedError('no video'));
    await pumpEventQueue();
  });
}
