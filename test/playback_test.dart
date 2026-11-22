import 'dart:async';

import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/debug/preview.dart';
import 'package:blackpearl_mobile/playback/phone_playback.dart';
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

  @override
  PlayerState get state => PlayerState(position: Duration(milliseconds: positionMs));

  @override
  late final PlayerStream stream = PlayerStream(
    const Stream.empty(), const Stream.empty(), const Stream.empty(), positions.stream, const Stream.empty(),
    const Stream.empty(), const Stream.empty(), const Stream.empty(), const Stream.empty(), const Stream.empty(),
    const Stream.empty(), const Stream.empty(), const Stream.empty(), const Stream.empty(), const Stream.empty(),
    const Stream.empty(), const Stream.empty(), const Stream.empty(), const Stream.empty(), const Stream.empty(),
    const Stream.empty(), const Stream.empty(), const Stream.empty(), const Stream.empty(), const Stream.empty(),
  );

  @override
  PlatformPlayer? get platform => null;

  @override
  Future<void> open(Playable playable, {bool play = true}) async => opened.add(playable as Media);

  @override
  Future<void> pause() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> setAudioTrack(AudioTrack track) async {}

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}

  @override
  Future<void> dispose() async {}
}
