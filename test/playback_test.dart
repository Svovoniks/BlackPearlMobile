import 'dart:async';

import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/debug/preview.dart';
import 'package:blackpearl_mobile/playback/phone_playback.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  FakeRemoteLink link() => FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected))..offered = const {'watch'};

  test("an answer to a watch the phone gave up on lets the PC's stream go", () async {
    final pc = link();
    final answer = Completer<Map<String, dynamic>>();
    pc.answer = (type, fields) => answer.future;
    final playback = PhonePlayback(link: pc, createPlayer: () => throw StateError('no player for an abandoned watch'));
    final viewing = playback.startViewing();
    final opening = playback.watch('film');
    // The request is out; then the phone gives up.
    await pumpEventQueue();
    expect(pc.asked.map((a) => a.$1), ['watch']);
    await playback.stop(viewing: viewing);
    answer.complete({'type': 'stream', 'id': 'film', 'kind': 'file', 'resource': 'file/film', 'length': 10});
    await opening;
    expect(pc.told.map((t) => t.$1), contains('stream-stop'));
    expect(playback.phase, PhonePlaybackPhase.idle);
    playback.dispose();
  });

  test('an earlier viewing stopping late leaves the next one alone', () async {
    final pc = link();
    final answers = <Completer<Map<String, dynamic>>>[];
    pc.answer = (type, fields) => (answers..add(Completer())).last.future;
    final playback = PhonePlayback(link: pc, createPlayer: () => Player());
    final first = playback.startViewing();
    unawaited(playback.watch('a'));
    final second = playback.startViewing();
    unawaited(playback.watch('b'));
    await playback.stop(viewing: first);
    expect(playback.phase, PhonePlaybackPhase.opening, reason: 'b is still opening');
    expect(second, isNot(first));
    await playback.stop(viewing: second);
    expect(playback.phase, PhonePlaybackPhase.idle);
    playback.dispose();
  });

  test('a viewing stopped before its request went out sends none', () async {
    final pc = link();
    pc.answer = (type, fields) => Completer<Map<String, dynamic>>().future;
    final playback = PhonePlayback(link: pc, createPlayer: () => throw StateError('no player'));
    final viewing = playback.startViewing();
    final opening = playback.watch('film');
    await playback.stop(viewing: viewing);
    expect(await opening, isFalse);
    expect(pc.asked, isEmpty);
    playback.dispose();
  });

  test('leaving while a video opens resumes it once on return; a picture-in-picture window showing again clears that', () async {
    final pc = link();
    pc.answer = (type, fields) => Completer<Map<String, dynamic>>().future;
    final playback = PhonePlayback(link: pc, createPlayer: () => throw StateError('no player'));
    unawaited(playback.watch('film'));
    await pumpEventQueue();
    await playback.background();
    expect(playback.resumesOnReturn, isTrue);
    expect(playback.inBackground, isTrue);
    playback.pictureInPictureShown();
    expect(playback.resumesOnReturn, isFalse);
    expect(playback.inBackground, isFalse);
    await playback.background();
    await playback.foreground();
    expect(playback.resumesOnReturn, isFalse, reason: 'used once');
    playback.dispose();
  });

  group("a conversion's audio", () {
    Map<String, dynamic> converted(String quality, int? audio) => {
      'type': 'stream', 'id': 'film', 'kind': 'hls', 'streamId': 'a' * 32, 'segments': 10, 'segmentMs': 4000, 'durationMs': 40000,
      'quality': quality, 'qualities': ['original', '720p', '480p'],
      'audioTracks': [
        {'index': 0, 'language': 'jpn', 'title': null, 'codec': 'eac3', 'layout': '5.1(side)'},
        {'index': 1, 'language': 'eng', 'title': 'Commentary', 'codec': 'aac', 'layout': 'stereo'},
      ],
      'audioTrack': audio,
    };

    test('lists the file\'s tracks, and another one is converted again from where the video is, at the same quality', () async {
      final pc = link();
      final player = _FakePlayer();
      final playback = PhonePlayback(link: pc, createPlayer: () => player);
      pc.answer = (type, fields) async => converted('480p', 0);
      await playback.watch('film', quality: '480p');
      expect(pc.asked.single.$2.containsKey('audio'), isFalse, reason: "the PC's preferences pick the first track");
      expect(playback.audioTracks.map((t) => (t.id, t.language, t.title)), [('1', 'jpn', null), ('2', 'eng', 'Commentary')]);
      expect((await playback.selectedTracks()).audio, '1');

      player.positionMs = 61000;
      player.positions.add(const Duration(milliseconds: 61000));
      await pumpEventQueue();
      final answer = Completer<Map<String, dynamic>>();
      pc.answer = (type, fields) => answer.future;
      final switching = playback.chooseAudio(playback.audioTracks[1]);
      await pumpEventQueue();
      expect(pc.asked.last.$2, containsPair('audio', 1));
      expect(pc.asked.last.$2, containsPair('quality', '480p'));
      expect(playback.pending.value?.audio, '2', reason: 'the menus tick the track on its way');
      expect(playback.pending.value?.label, 'Switching to English audio…');
      // Picking it again while it's on its way asks nothing more.
      await playback.chooseAudio(playback.audioTracks[1]);
      expect(pc.asked, hasLength(2));
      answer.complete(converted('480p', 1));
      await switching;
      expect(player.opened.last.start, const Duration(milliseconds: 61000));
      expect(playback.pending.value, isNull);
      expect((await playback.selectedTracks()).audio, '2');

      // Another quality, or a recovery, keeps the track picked.
      pc.answer = (type, fields) async => converted('720p', 1);
      await playback.changeQuality('720p');
      expect(pc.asked.last.$2, containsPair('audio', 1));
      // Picking the track playing asks nothing.
      await playback.chooseAudio(playback.audioTracks[1]);
      expect(pc.asked, hasLength(3));
      playback.dispose();
    });

    test('a refused switch keeps the track playing, and one switch waits for the other', () async {
      final pc = link();
      final playback = PhonePlayback(link: pc, createPlayer: () => _FakePlayer());
      pc.answer = (type, fields) async => converted('480p', 0);
      await playback.watch('film', quality: '480p');
      pc.answer = (type, fields) => Future.error(const RemoteRequestException('busy', 'The PC is busy.'));
      await playback.chooseAudio(playback.audioTracks[1]);
      expect(playback.pending.value, isNull);
      expect(playback.notice.value, 'The PC is busy.');
      expect((await playback.selectedTracks()).audio, '1', reason: 'the refused track was never played');
      pc.answer = (type, fields) async => converted('720p', 0);
      await playback.changeQuality('720p');
      expect(pc.asked.last.$2, containsPair('audio', 0));

      // While another quality is on its way, an audio pick says to wait, and the other way round.
      final quality = Completer<Map<String, dynamic>>();
      pc.answer = (type, fields) => quality.future;
      final toQuality = playback.changeQuality('480p');
      await pumpEventQueue();
      await playback.chooseAudio(playback.audioTracks[1]);
      expect(playback.notice.value, 'Wait for the switch to 480p to finish, then pick the audio.');
      quality.complete(converted('480p', 0));
      await toQuality;
      final audio = Completer<Map<String, dynamic>>();
      pc.answer = (type, fields) => audio.future;
      final toAudio = playback.chooseAudio(playback.audioTracks[1]);
      await pumpEventQueue();
      final asked = pc.asked.length;
      await playback.changeQuality('720p');
      expect(pc.asked, hasLength(asked));
      expect(playback.notice.value, 'Wait for the switch to English audio to finish, then pick the quality.');
      audio.complete(converted('480p', 1));
      await toAudio;
      expect((await playback.selectedTracks()).audio, '2');
      playback.dispose();
    });

    test('the original file opens on the track the conversion played, by its place, and not on one the PC refused', () async {
      Map<String, dynamic> file() => {'type': 'stream', 'id': 'film', 'kind': 'file', 'resource': 'file/film', 'length': 10, 'qualities': ['original', '480p']};
      // libmpv lists the file's tracks untagged where the PC identified one; the PC lists the second as Russian.
      const mpv = [AudioTrack('1', null, 'jpn'), AudioTrack('2', null, null)];
      final listing = converted('480p', 0)
        ..['audioTracks'] = [
          {'index': 0, 'language': 'jpn'},
          {'index': 1, 'language': 'ru'},
        ];
      Future<(_FakePlayer, PhonePlayback, FakeRemoteLink)> converting() async {
        final pc = link();
        final player = _FakePlayer();
        final playback = PhonePlayback(link: pc, createPlayer: () => player);
        pc.answer = (type, fields) async => listing;
        await playback.watch('film', quality: '480p');
        return (player, playback, pc);
      }

      // Refused: the file opens as libmpv would, on its first track, though it could tell the refused one by language.
      var (player, playback, pc) = await converting();
      pc.answer = (type, fields) => Future.error(const RemoteRequestException('busy', 'The PC is busy.'));
      await playback.chooseAudio(playback.audioTracks[1]);
      pc.answer = (type, fields) async => file();
      await playback.changeQuality('original');
      await player.lists(const [AudioTrack('1', null, 'jpn'), AudioTrack('2', null, 'ru')]);
      expect(player.audioSet, isNot(contains('2')));
      playback.dispose();

      // Accepted: the file opens on the second track, although libmpv gives it no language.
      (player, playback, pc) = await converting();
      pc.answer = (type, fields) async => {...listing, 'audioTrack': 1};
      await playback.chooseAudio(playback.audioTracks[1]);
      pc.answer = (type, fields) async => file();
      await playback.changeQuality('original');
      await player.lists(mpv);
      expect(player.audioSet.last, '2');
      playback.dispose();
    });

    test('a new video starts with the PC\'s preferences again', () async {
      final pc = link();
      final playback = PhonePlayback(link: pc, createPlayer: () => _FakePlayer());
      pc.answer = (type, fields) async => converted('480p', 1);
      await playback.watch('film', quality: '480p');
      pc.answer = (type, fields) async => {...converted('480p', 0), 'id': 'next'};
      await playback.watch('next', quality: '480p');
      expect(pc.asked.last.$2.containsKey('audio'), isFalse);
      playback.dispose();
    });

    test('from an older PC, the player lists what it plays', () async {
      final pc = link();
      final playback = PhonePlayback(link: pc, createPlayer: () => _FakePlayer());
      pc.answer = (type, fields) async => {...converted('480p', null)}..remove('audioTracks')..remove('audioTrack');
      await playback.watch('film', quality: '480p');
      expect(playback.stream?.sourceAudio, isNull);
      expect(playback.audioTracks, isEmpty);
      playback.dispose();
    });
  });

  test('Watch here left while it waits for the link asks nothing once the link is back: the PC plays on', () async {
    final pc = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.linking))..offered = const {'watch'};
    pc.answer = (type, fields) async => {'type': 'stream', 'id': 'film', 'kind': 'file', 'resource': 'file/film', 'length': 10};
    final playback = PhonePlayback(link: pc, createPlayer: () => _FakePlayer());
    final viewing = playback.startViewing();
    final opening = playback.watch('film', takeOver: true);
    await pumpEventQueue();
    // Back on the Opening screen.
    playback.cancelOpening(viewing);
    pc.status = const LinkStatus(LinkPhase.connected);
    expect(await opening, isFalse);
    expect(pc.asked, isEmpty);
    playback.dispose();
  });

  test('a stream lost while the app is away waits for its return rather than ending in an error', () {
    fakeAsync((async) {
      final pc = link();
      final player = _FakePlayer()..durationMs = 600000;
      final playback = PhonePlayback(link: pc, createPlayer: () => player);
      pc.answer = (type, fields) async => {'type': 'stream', 'id': 'film', 'kind': 'file', 'resource': 'file/film', 'length': 1000, 'durationMs': 600000};
      unawaited(playback.watch('film'));
      async.flushMicrotasks();
      player.positionMs = 61000;
      player.positions.add(const Duration(milliseconds: 61000));
      async.flushMicrotasks();
      unawaited(playback.background());
      async.flushMicrotasks();
      // Without the background service the link goes after 30 seconds, and the stream with it.
      pc.status = const LinkStatus(LinkPhase.idle);
      playback.proxy.onLost!(playback.stream!);
      async.elapse(const Duration(minutes: 10));
      expect(playback.phase, PhonePlaybackPhase.playing, reason: 'no error waits on return');
      unawaited(playback.foreground());
      pc.status = const LinkStatus(LinkPhase.connected);
      async.elapse(const Duration(seconds: 1));
      expect(pc.asked.where((a) => a.$1 == 'watch'), hasLength(2), reason: 'it asks again once back');
      playback.dispose();
    });
  });

  test("the place one video stalled at isn't the next video's end: running out of data there is a stall", () async {
    final pc = link();
    final player = _FakePlayer()..durationMs = 600000;
    final playback = PhonePlayback(link: pc, createPlayer: () => player);
    Map<String, dynamic> stream(String id) => {'type': 'stream', 'id': id, 'kind': 'file', 'resource': 'file/$id', 'length': 1000, 'durationMs': 600000};
    pc.answer = (type, fields) async => stream(fields['id'] as String);
    await playback.watch('e1');
    player.positionMs = 61000;
    player.positions.add(const Duration(milliseconds: 61000));
    await pumpEventQueue();
    // e1 stalls at 1:01 and is asked for again; meanwhile the user opens e2.
    pc.answer = (type, fields) => fields['id'] == 'e1' ? Completer<Map<String, dynamic>>().future : Future.value(stream('e2'));
    playback.proxy.onLost!(playback.stream!);
    await pumpEventQueue();
    await playback.watch('e2');
    player.positionMs = 61500;
    player.positions.add(const Duration(milliseconds: 61500));
    await pumpEventQueue();
    player.completes.add(true);
    await pumpEventQueue();
    expect(pc.told.where((t) => t.$1 == 'progress' && t.$2['id'] == 'e2' && t.$2['ended'] == true), isEmpty);
    expect(pc.asked.last.$2['id'], 'e2', reason: 'e2 is asked for again from where it stopped');
    playback.dispose();
  });

  test('another quality starts where the video is when it is ready, not where it was when asked for', () async {
    final pc = link();
    final player = _FakePlayer()..durationMs = 600000;
    final playback = PhonePlayback(link: pc, createPlayer: () => player);
    pc.answer = (type, fields) async => {'type': 'stream', 'id': 'film', 'kind': 'file', 'resource': 'file/film', 'length': 1000, 'durationMs': 600000, 'qualities': ['original', '720p']};
    await playback.watch('film');
    player.positionMs = 61000;
    player.positions.add(const Duration(milliseconds: 61000));
    await pumpEventQueue();
    final answer = Completer<Map<String, dynamic>>();
    pc.answer = (type, fields) => answer.future;
    final switching = playback.changeQuality('720p');
    await pumpEventQueue();
    expect(pc.asked.last.$2['quality'], '720p');
    // The PC takes 9 seconds to get it ready; the old stream plays on meanwhile.
    player.positionMs = 70000;
    player.positions.add(const Duration(milliseconds: 70000));
    await pumpEventQueue();
    answer.complete({'type': 'stream', 'id': 'film', 'kind': 'hls', 'streamId': 'a' * 32, 'segments': 150, 'segmentMs': 4000, 'durationMs': 600000, 'quality': '720p', 'qualities': ['original', '720p']});
    await switching;
    expect(player.opened.last.start, const Duration(milliseconds: 70000));
    playback.dispose();
  });

  test('Continue on PC: the stream the PC ends before it answers asks for nothing again', () async {
    final pc = link();
    final player = _FakePlayer()..durationMs = 600000;
    final playback = PhonePlayback(link: pc, createPlayer: () => player);
    pc.answer = (type, fields) async => {'type': 'stream', 'id': 'film', 'kind': 'file', 'resource': 'file/film', 'length': 1000, 'durationMs': 600000};
    await playback.watch('film');
    player.positionMs = 61000;
    player.positions.add(const Duration(milliseconds: 61000));
    await pumpEventQueue();
    final played = Completer<Map<String, dynamic>>();
    pc.answer = (type, fields) => type == 'play' ? played.future : Future.value({'type': 'stream', 'id': 'film', 'kind': 'file', 'resource': 'file/film', 'length': 1000});
    final handing = playback.continueOnPc();
    await pumpEventQueue();
    // The PC ends the phone's stream, then answers.
    playback.proxy.onLost!(playback.stream!);
    await pumpEventQueue();
    played.complete({'type': 'done'});
    expect(await handing, isNull);
    await pumpEventQueue();
    expect(pc.asked.map((a) => a.$1), ['watch', 'play']);
    playback.dispose();
  });

  group('a paused video', () {
    Map<String, dynamic> file() => {
      'type': 'stream', 'id': 'film', 'kind': 'file', 'resource': 'file/film', 'length': 1000, 'durationMs': 600000,
      'qualities': ['original', '720p'],
    };
    Map<String, dynamic> converted() => {
      'type': 'stream', 'id': 'film', 'kind': 'hls', 'streamId': 'a' * 32, 'segments': 150, 'segmentMs': 4000, 'durationMs': 600000,
      'quality': '720p', 'qualities': ['original', '720p'],
    };

    test('stays paused through another quality; a playing one plays on', () async {
      final pc = link();
      final player = _FakePlayer();
      final playback = PhonePlayback(link: pc, createPlayer: () => player);
      pc.answer = (type, fields) async => file();
      await playback.watch('film');
      expect(player.openedPlaying.single, isTrue);
      await player.pause();
      pc.answer = (type, fields) async => converted();
      await playback.changeQuality('720p');
      expect(player.openedPlaying.last, isFalse, reason: 'paused by hand, it stays paused');
      await player.play();
      pc.answer = (type, fields) async => file();
      await playback.changeQuality('original');
      expect(player.openedPlaying.last, isTrue);
      playback.dispose();
    });

    test('stays paused through a recovery of its stream', () async {
      final pc = link();
      final player = _FakePlayer()..durationMs = 600000;
      final playback = PhonePlayback(link: pc, createPlayer: () => player);
      pc.answer = (type, fields) async => file();
      await playback.watch('film');
      player.positionMs = 61000;
      player.positions.add(const Duration(milliseconds: 61000));
      await player.pause();
      await pumpEventQueue();
      // The PC let the stream go while the video waited paused; the proxy's read fails.
      playback.proxy.onLost!(playback.stream!);
      await pumpEventQueue();
      expect(pc.asked.last.$1, 'watch');
      expect(player.opened, hasLength(2));
      expect(player.openedPlaying.last, isFalse);
      playback.dispose();
    });
  });

  test("closing the picture-in-picture window stops the up-next countdown: nothing starts on the app's return", () async {
    final pc = link();
    final player = _FakePlayer()..durationMs = 600000;
    final playback = PhonePlayback(link: pc, createPlayer: () => player);
    pc.answer = (type, fields) async => {
      'type': 'stream', 'id': 'e1', 'kind': 'file', 'resource': 'file/e1', 'length': 1000, 'durationMs': 600000,
      'next': {'id': 'e2', 'title': 'Episode 2'},
    };
    await playback.watch('e1');
    player.positionMs = 599000;
    player.positions.add(const Duration(milliseconds: 599000));
    player.completes.add(true);
    await pumpEventQueue();
    expect(playback.upNext.value?.step.id, 'e2');
    await playback.pictureInPictureClosed();
    expect(playback.upNext.value, isNull);
    playback.dispose();
  });

  test("the tracks stay listed after the video's end, when libmpv plays it on without listing them again", () async {
    final pc = link();
    final player = _FakePlayer()..durationMs = 600000;
    final playback = PhonePlayback(link: pc, createPlayer: () => player);
    pc.answer = (type, fields) async => {'type': 'stream', 'id': 'film', 'kind': 'file', 'resource': 'file/film', 'length': 1000, 'durationMs': 600000};
    await playback.watch('film');
    await player.lists(const [AudioTrack('1', null, 'jpn'), AudioTrack('2', null, 'eng')]);
    expect(playback.audioTracks, hasLength(2));
    // At the end media_kit empties its lists; Loop one or Previous then plays the same file from the start.
    player.audio = const [];
    player.listed.add(const Tracks());
    await pumpEventQueue();
    expect(playback.audioTracks.map((t) => t.id), ['1', '2']);
    // Let go of, the player lists nothing.
    await playback.stop();
    expect(playback.tracks.audio, isNot(contains(predicate<AudioTrack>((t) => t.id == '1'))));
    playback.dispose();
  });

  group('a file already smaller than the quality picked', () {
    Map<String, dynamic> file({bool convertible = true}) => {
      'type': 'stream', 'id': 'film', 'kind': 'file', 'resource': 'file/film', 'length': 1000, 'extension': '.avi', 'durationMs': 40000,
      'quality': 'original', 'qualities': ['original', '480p'], 'convertible': convertible,
      'note': 'This file is already smaller than 480p would be, so the phone plays it as it is.',
    };
    Map<String, dynamic> converted() => {
      'type': 'stream', 'id': 'film', 'kind': 'hls', 'streamId': 'a' * 32, 'segments': 10, 'segmentMs': 4000, 'durationMs': 40000,
      'quality': '480p', 'qualities': ['original', '480p'], 'audioTracks': [{'index': 0, 'language': null, 'title': null, 'codec': 'mp3', 'layout': 'mono'}],
      'audioTrack': 0,
    };

    test('is offered to convert anyway, and once converted stays converted through a recovery and another track', () async {
      final pc = link();
      final player = _FakePlayer();
      final playback = PhonePlayback(link: pc, createPlayer: () => player);
      pc.answer = (type, fields) async => file(convertible: false);
      await playback.watch('film');
      expect(playback.convertOffer.value, isNull, reason: 'the file was asked for');

      pc.answer = (type, fields) async => file();
      await playback.changeQuality('480p');
      expect(pc.asked.last.$2.containsKey('convertAnyway'), isFalse);
      expect(playback.convertOffer.value?.quality, '480p');

      player.positionMs = 30000;
      player.positions.add(const Duration(milliseconds: 30000));
      await pumpEventQueue();
      pc.answer = (type, fields) async => converted();
      await playback.convertAnyway('480p');
      expect(pc.asked.last.$2, containsPair('convertAnyway', true));
      expect(pc.asked.last.$2, containsPair('quality', '480p'));
      expect(playback.stream?.hls, isTrue);
      expect(player.opened.last.start, const Duration(milliseconds: 30000));
      expect(playback.convertOffer.value, isNull);

      // Another stream of this video, such as after a stall or for another track, is converted anyway too.
      await playback.watch('film', quality: '480p', audio: 0);
      expect(pc.asked.last.$2, containsPair('convertAnyway', true));

      // Another video isn't.
      pc.answer = (type, fields) async => {...file(), 'id': 'other', 'resource': 'file/other'};
      await playback.watch('other', quality: '480p');
      expect(pc.asked.last.$2.containsKey('convertAnyway'), isFalse);
      expect(playback.convertOffer.value, isNull, reason: 'only a quality picked in the player asks');
      playback.dispose();
    });

    test('declined, the file plays on and nothing more is asked', () async {
      final pc = link();
      final playback = PhonePlayback(link: pc, createPlayer: () => _FakePlayer());
      pc.answer = (type, fields) async => file(convertible: false);
      await playback.watch('film');
      pc.answer = (type, fields) async => file();
      await playback.changeQuality('480p');
      expect(playback.convertOffer.value, isNotNull);
      playback.convertOffer.value = null;
      expect(pc.asked, hasLength(2));
      expect(playback.stream?.hls, isFalse);
      playback.dispose();
    });

    test("a PC that doesn't say the file can be converted offers nothing", () async {
      final pc = link();
      final playback = PhonePlayback(link: pc, createPlayer: () => _FakePlayer());
      pc.answer = (type, fields) async => file(convertible: false);
      await playback.watch('film');
      pc.answer = (type, fields) async => {...file()}..remove('convertible');
      await playback.changeQuality('480p');
      expect(playback.convertOffer.value, isNull);
      playback.dispose();
    });
  });

  test('a refused watch says why', () async {
    final pc = link();
    pc.answer = (type, fields) => Future.error(const RemoteRequestException('gone', 'Its drive may be disconnected.'));
    final playback = PhonePlayback(link: pc, createPlayer: () => Player());
    await playback.watch('film');
    expect(playback.phase, PhonePlaybackPhase.failed);
    expect(playback.error, 'Its drive may be disconnected.');
    playback.dispose();
  });
}

// A player that opens nothing: it remembers what it was asked to open, and says it is wherever the test puts it.
class _FakePlayer extends Fake implements Player {
  final List<Media> opened = [];
  int positionMs = 0;
  final StreamController<Duration> positions = StreamController<Duration>.broadcast();
  // The audio tracks libmpv lists for what is open, and the ones set, by id.
  List<AudioTrack> audio = const [];
  final StreamController<Tracks> listed = StreamController<Tracks>.broadcast();
  final List<String> audioSet = [];
  // Whether it plays, and what each open was asked: play at once or not.
  bool playing = false;
  final List<bool> openedPlaying = [];
  int durationMs = 0;
  final StreamController<bool> completes = StreamController<bool>.broadcast();

  @override
  PlayerState get state => PlayerState(
    position: Duration(milliseconds: positionMs),
    duration: Duration(milliseconds: durationMs),
    playing: playing,
    tracks: Tracks(audio: audio),
  );

  @override
  late final PlayerStream stream = PlayerStream(
    const Stream.empty(), const Stream.empty(), completes.stream, positions.stream, const Stream.empty(),
    const Stream.empty(), const Stream.empty(), const Stream.empty(), const Stream.empty(), const Stream.empty(),
    const Stream.empty(), const Stream.empty(), const Stream.empty(), const Stream.empty(), const Stream.empty(),
    const Stream.empty(), const Stream.empty(), const Stream.empty(), const Stream.empty(), listed.stream,
    const Stream.empty(), const Stream.empty(), const Stream.empty(), const Stream.empty(), const Stream.empty(),
  );

  /// libmpv lists [tracks] for what it opened.
  Future<void> lists(List<AudioTrack> tracks) async {
    audio = tracks;
    listed.add(Tracks(audio: tracks));
    await pumpEventQueue();
  }

  @override
  PlatformPlayer? get platform => null;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add(playable as Media);
    openedPlaying.add(play);
    playing = play;
  }

  @override
  Future<void> pause() async => playing = false;

  @override
  Future<void> play() async => playing = true;

  @override
  Future<void> seek(Duration position) async => positionMs = position.inMilliseconds;

  @override
  Future<void> setAudioTrack(AudioTrack track) async => audioSet.add(track.id);

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}

  @override
  Future<void> dispose() async {}
}
