import 'dart:async';

import 'package:blackpearl_mobile/background/background_link.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pairing_attempt_test.dart' show Rig;

/// A `state` as the PC sends it while it plays a video the phone can control.
Map<String, Object?> playing({bool canControl = true, bool media = true, bool playing = true}) => {
  'type': 'state',
  'media': media,
  'title': 'Night Signal',
  'detail': 'Season 2 · Episode 3',
  'playing': playing,
  'positionMs': 61000,
  'durationMs': 1800000,
  'volume': 64,
  'hasNext': true,
  'canControl': canControl,
};

void main() {
  /// The commands the PC got, as (action, value).
  List<(Object?, Object?)> commands(Rig rig) =>
      [for (final message in rig.studyPeers.last.sent.where((m) => m['type'] == 'command')) (message['action'], message['value'])];

  test("a video the phone can control shows as Android's media controls, with where it is and the PC's volume", () {
    fakeAsync((async) {
      final rig = Rig()..start(async);
      expect(rig.background.shown.last.media, isNull, reason: 'nothing plays yet');
      rig.studyPeers.last.receive(playing());
      async.flushMicrotasks();
      final notice = rig.background.shown.last;
      expect(notice.title, 'Study');
      expect(notice.playing, isTrue, reason: 'the plain notification keeps its Play/Pause too');
      final media = notice.media!;
      expect((media.title, media.detail, media.playing, media.durationMs, media.hasNext), ('Night Signal', 'Season 2 · Episode 3', true, 1800000, true));
      expect(media.positionMs, inInclusiveRange(61000, 62000));
      expect(media.volume, 64, reason: 'the volume buttons set the PC volume');
      // What Android is handed.
      expect(notice.toMap()['media'], containsPair('title', 'Night Signal'));
      // Paused, the buttons follow.
      rig.studyPeers.last.receive(playing(playing: false));
      async.flushMicrotasks();
      expect(rig.background.shown.last.media!.playing, isFalse);
      // The PC stops: a plain notification again.
      rig.studyPeers.last.receive(playing(media: false));
      async.flushMicrotasks();
      expect(rig.background.shown.last.media, isNull);
      rig.app.dispose();
    });
  });

  test("in a room where only whoever plays the video controls it, the notification stays plain", () {
    fakeAsync((async) {
      final rig = Rig()..start(async);
      rig.studyPeers.last.receive(playing(canControl: false));
      async.flushMicrotasks();
      expect(rig.background.shown.last.media, isNull);
      expect(rig.background.shown.last.playing, isNull);
      rig.app.dispose();
    });
  });

  test("with the volume buttons left to the phone, the media controls carry no PC volume", () {
    fakeAsync((async) {
      final rig = Rig()..start(async);
      unawaited(rig.settings.setVolumeKeys(false));
      rig.studyPeers.last.receive(playing());
      async.flushMicrotasks();
      expect(rig.background.shown.last.media!.volume, isNull);
      unawaited(rig.settings.setVolumeKeys(true));
      async.flushMicrotasks();
      expect(rig.background.shown.last.media!.volume, 64, reason: 'the switch takes effect at once');
      rig.app.dispose();
    });
  });

  test("what is pressed in the media controls goes to the PC as its commands", () {
    fakeAsync((async) {
      final rig = Rig()..start(async);
      rig.studyPeers.last.receive(playing());
      async.flushMicrotasks();
      final press = rig.background.press!;
      press('pause');
      press('play');
      press('seek-by', -10000);
      press('seek-to', 600000);
      press('next');
      press('previous');
      // Without their value, the ones that need one are nothing to send.
      press('seek-to');
      press('volume');
      expect(commands(rig), [('pause', null), ('play', null), ('seek-by', -10000), ('seek-to', 600000), ('next', null), ('previous', null)]);
      rig.app.dispose();
    });
  });

  test("a volume button held down sends the first value at once, then the latest one every 100 ms", () {
    fakeAsync((async) {
      final rig = Rig()..start(async);
      rig.studyPeers.last.receive(playing());
      async.flushMicrotasks();
      final press = rig.background.press!;
      press('volume', 68);
      press('volume', 72);
      press('volume', 76);
      expect(commands(rig), [('volume', 68)]);
      async.elapse(const Duration(milliseconds: 100));
      expect(commands(rig), [('volume', 68), ('volume', 76)]);
      async.elapse(const Duration(milliseconds: 300));
      expect(commands(rig), hasLength(2), reason: 'nothing more once the button is let go');
      // Past the ends of the PC's range it stays inside.
      press('volume', 130);
      expect(commands(rig).last, ('volume', 100));
      async.elapse(const Duration(milliseconds: 200));
      rig.app.dispose();
    });
  });

  group('the channel to the Android service', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('blackpearl/background');

    Future<void> fromAndroid(Object? arguments) => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall('action', arguments)),
      (_) {},
    );

    test('a button comes as its name, or as its name with a value', () async {
      final pressed = <(String, int?)>[];
      BackgroundLink(channel: channel).listen((action, [value]) => pressed.add((action, value)));
      await fromAndroid('toggle');
      await fromAndroid({'action': 'seek-to', 'value': 600000});
      await fromAndroid({'action': 'volume', 'value': 68});
      await fromAndroid({'value': 3});
      await fromAndroid(7);
      expect(pressed, [('toggle', null), ('seek-to', 600000), ('volume', 68)]);
    });

    test("the notice carries the PC's video for the media controls, or none", () {
      const plain = BackgroundNotice(title: 'Study', text: 'Connected. Nothing is playing on the PC.');
      expect(plain.toMap(), {'title': 'Study', 'text': 'Connected. Nothing is playing on the PC.', 'playing': null, 'media': null});
      const media = NowPlaying(title: 'Night Signal', detail: 'S2 E3', playing: true, positionMs: 61000, durationMs: 1800000, hasNext: true, volume: 64);
      expect(const BackgroundNotice(title: 'Study', text: '', playing: true, media: media).toMap()['media'], {
        'title': 'Night Signal',
        'detail': 'S2 E3',
        'playing': true,
        'positionMs': 61000,
        'durationMs': 1800000,
        'hasNext': true,
        'volume': 64,
      });
      // Only a change is sent again: the same video a moment later is another notice.
      expect(media == const NowPlaying(title: 'Night Signal', detail: 'S2 E3', playing: true, positionMs: 66000, durationMs: 1800000, hasNext: true, volume: 64), isFalse);
    });
  });
}
