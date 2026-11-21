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
