import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/connection/transport.dart';
import 'package:blackpearl_mobile/debug/preview.dart';
import 'package:blackpearl_mobile/playback/phone_sound.dart';
import 'package:blackpearl_mobile/protocol/remote_state.dart';
import 'package:blackpearl_mobile/storage/app_settings.dart';
import 'package:blackpearl_mobile/ui/remote_screen.dart';
import 'package:blackpearl_mobile/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

ClockSample sample(int sent, int received, int position, {bool playing = true, String source = 'film'}) =>
    ClockSample(sentMs: sent, receivedMs: received, positionMs: position, playing: playing, source: source);

void main() {
  group('the PC clock', () {
    test('follows the answer with the shortest round trip', () {
      final clock = SoundClock();
      // The PC was at 10,000 ms halfway through each round trip.
      clock.add(sample(0, 200, 10100));
      clock.add(sample(1000, 1020, 11010));
      clock.add(sample(2000, 2300, 12150));
      expect(clock.positionAt(3000), 13000);
      expect(clock.playing, isTrue);
    });

    test('starts over when the PC seeks, pauses or plays another video', () {
      final clock = SoundClock();
      clock.add(sample(0, 20, 5010));
      clock.add(sample(1000, 1300, 60000));
      expect(clock.positionAt(2300), 61150, reason: 'a seek replaces even a better answer from before it');
      clock.add(sample(3000, 3010, 61500, playing: false));
      expect(clock.positionAt(9000), 61500, reason: 'paused, the position stays');
      clock.add(sample(10000, 10010, 0, source: 'next'));
      expect(clock.source, 'next');
      expect(clock.positionAt(10010), 5);
    });

    test('an answer slower than the best one but in line with it is kept, not taken for a seek', () {
      final clock = SoundClock();
      clock.add(sample(0, 10, 1005));
      clock.add(sample(1000, 1400, 2200));
      expect(clock.positionAt(2000), 3000);
    });
  });

  group('closing the gap', () {
    test('a large gap seeks', () {
      expect(soundCorrection(900, 1.0).seek, isTrue);
      expect(soundCorrection(-401, 1.0).seek, isTrue);
    });

    test('a small gap changes the speed a little, and in step it plays at normal speed', () {
      expect(soundCorrection(20, 1.0), (rate: 1.0, seek: false));
      final ahead = soundCorrection(120, 1.0);
      expect(ahead.rate, lessThan(1.0));
      expect(ahead.rate, greaterThanOrEqualTo(1 - PhoneSound.maxRateChange));
      expect(soundCorrection(-180, 1.0).rate, 1.045);
      expect(soundCorrection(-250, 1.0).seek, isTrue);
      // Once correcting, it carries on past the start threshold, and stops in step or past it.
      expect(soundCorrection(20, ahead.rate).rate, lessThan(1.0));
      expect(soundCorrection(5, ahead.rate).rate, 1.0);
      expect(soundCorrection(-20, ahead.rate).rate, 1.0);
    });
  });

  group('turning it on and off', () {
    FakeRemoteLink pc() => FakeRemoteLink(
      pcName: 'Den',
      status: const LinkStatus(LinkPhase.connected, path: NetworkPath.home),
      state: sampleState,
    )..offered = const {'sound'};

    test('asks the PC for its sound, waits for something to play, and gives it back', () async {
      final link = pc();
      link.answer = (type, fields) async => {
        'type': type,
        if (type == 'clock') ...{'positionMs': 0, 'playing': false},
      };
      final held = <bool>[];
      final sound = PhoneSound(link: link, settings: AppSettings(MemorySettingsStore()), keepAwake: held.add);
      await sound.turnOn();
      expect((link.asked.first.$1, link.asked.first.$2['on']), ('listen', true));
      expect(sound.phase, SoundPhase.waiting);
      expect(held, [true]);
      link.push({'type': 'sound', 'on': true, 'stream': null, 'why': "The PC's audio is turned off for this video."});
      expect(sound.statusText, "The PC's audio is turned off for this video.");
      await sound.turnOff();
      expect(sound.phase, SoundPhase.off);
      expect((link.asked.last.$1, link.asked.last.$2['on']), ('listen', false));
      expect(held, [true, false]);
      sound.dispose();
    });

    test('the PC taking the sound back turns it off here and says why', () async {
      final link = pc();
      link.answer = (type, fields) async => {'type': type};
      final sound = PhoneSound(link: link, settings: AppSettings(MemorySettingsStore()));
      await sound.turnOn();
      link.push({'type': 'sound', 'on': false, 'why': 'The sound is back on the PC.'});
      await pumpEventQueue();
      expect(sound.on, isFalse);
      expect(sound.message, 'The sound is back on the PC.');
      expect(sound.notice.value, 'The sound is back on the PC.', reason: 'the Remote tab says why');
      expect(link.asked.where((a) => a.$1 == 'listen' && a.$2['on'] == false), isEmpty, reason: 'the PC already knows');
      sound.dispose();
    });

    test("a PC that refuses says why, and nothing stays on", () async {
      final link = pc();
      link.answer = (type, fields) =>
          Future.error(const RemoteRequestException('in-room', "Sound on the phone isn't available in a room."));
      final sound = PhoneSound(link: link, settings: AppSettings(MemorySettingsStore()));
      await sound.turnOn();
      expect(sound.on, isFalse);
      expect(sound.message, "Sound on the phone isn't available in a room.");
      sound.dispose();
    });
  });

  group('on the Remote tab', () {
    Future<(FakeRemoteLink, PhoneSound)> pump(WidgetTester tester, {Set<String> offered = const {'sound'}}) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final link = FakeRemoteLink(
        pcName: 'Den',
        status: const LinkStatus(LinkPhase.connected, path: NetworkPath.home),
        state: sampleState,
      )..offered = offered;
      link.answer = (type, fields) async => {
        'type': type,
        if (type == 'clock') ...{'positionMs': 0, 'playing': false},
      };
      final sound = PhoneSound(link: link, settings: AppSettings(MemorySettingsStore()));
      addTearDown(sound.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: RemoteScreen(link: link, sound: sound, onChoosePc: () {}, onPairAgain: () {}),
        ),
      );
      await tester.pump();
      return (link, sound);
    }

    testWidgets('a PC that can send its sound gets the Sound option; others do not', (tester) async {
      await pump(tester, offered: const {});
      expect(find.bySemanticsLabel(RegExp('^Sound')), findsNothing);
      await pump(tester);
      expect(find.bySemanticsLabel(RegExp('^Sound, On the PC')), findsOneWidget);
    });

    testWidgets('turning it on moves the volume to the phone and offers the delay', (tester) async {
      final (link, sound) = await pump(tester);
      await tester.tap(find.bySemanticsLabel(RegExp('^Sound, On the PC')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect((link.asked.first.$1, link.asked.first.$2['on']), ('listen', true));
      expect(find.bySemanticsLabel(RegExp('^Sound, On this phone')), findsOneWidget);
      expect(find.text('Waiting for the PC to play something'), findsOneWidget);
      expect(find.text('Sound delay: none'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Sound later'));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Sound later'));
      await tester.pump();
      expect(sound.settings.soundDelayMs, 100);
      expect(find.text('Sound 0.10 s later'), findsOneWidget);
      // The volume row is the phone's now: nothing goes to the PC.
      await tester.tap(find.bySemanticsLabel('Mute the phone'));
      await tester.pump();
      expect(sound.muted, isTrue);
      final track = tester.getRect(find.bySemanticsLabel('Phone volume'));
      await tester.tapAt(track.centerLeft + Offset(track.width * 0.3, 0));
      await tester.pump();
      expect(sound.volume, closeTo(30, 2));
      expect(link.sent.where((c) => c.$1 == 'mute' || c.$1 == 'volume'), isEmpty);
      await tester.tap(find.bySemanticsLabel(RegExp('^Sound, On this phone')));
      await tester.pump(const Duration(milliseconds: 950));
      expect(sound.on, isFalse);
      expect(find.bySemanticsLabel('PC volume'), findsOneWidget);
    });

    testWidgets("another phone's sound shows, and this one can take it", (tester) async {
      final (link, _) = await pump(tester);
      link.setState(
        RemoteState.fromJson({
          'media': true,
          'title': 'Night Signal',
          'playing': true,
          'durationMs': 60000,
          'shuffle': false,
          'phoneSound': true,
        }),
      );
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp('^Sound, On a phone')), findsOneWidget);
    });
  });
}
