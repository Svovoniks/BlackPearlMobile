// Two peer connections in this process, linked through the real library. It needs the library built for the machine
// running the tests and on its library path, so it is skipped without one. On Windows:
//
//   cmake -S src -B <out> -G Ninja -DCMAKE_BUILD_TYPE=Release   (in a Visual Studio developer prompt)
//   cmake --build <out> --target blackpearl_datachannel
//   set PATH=<out>;%PATH% && flutter test
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:blackpearl_datachannel/blackpearl_datachannel.dart';
import 'package:flutter_test/flutter_test.dart';

bool get _libraryAvailable {
  try {
    DynamicLibrary.open(Platform.isWindows ? 'blackpearl_datachannel.dll' : 'libblackpearl_datachannel.so');
    return true;
  } catch (_) {
    return false;
  }
}

Future<T> _within<T>(Future<T> future, [Duration limit = const Duration(seconds: 15)]) => future.timeout(limit);

void main() {
  final skip = _libraryAvailable ? false : 'the library isn\'t built for this machine';

  test('an offerer and an answerer link up, and messages go both ways', () async {
    final offerer = RtcPeer.create();
    final answerer = RtcPeer.create();
    addTearDown(() async {
      await offerer.close();
      await answerer.close();
    });

    // Candidates go across as they come, after the descriptions, as the app's signaling does.
    final offererDescribed = Completer<String>(), answererDescribed = Completer<String>();
    offerer.onDescription = (sdp, type) {
      expect(type, 'offer');
      offererDescribed.complete(sdp);
    };
    answerer.onDescription = (sdp, type) {
      expect(type, 'answer');
      answererDescribed.complete(sdp);
    };
    final toAnswerer = <(String, String)>[], toOfferer = <(String, String)>[];
    var answererReady = false, offererReady = false;
    offerer.onCandidate = (candidate, mid) {
      expect(candidate, startsWith('candidate:'));
      if (answererReady) {
        unawaited(answerer.addRemoteCandidate(candidate, mid));
      } else {
        toAnswerer.add((candidate, mid));
      }
    };
    answerer.onCandidate = (candidate, mid) {
      if (offererReady) {
        unawaited(offerer.addRemoteCandidate(candidate, mid));
      } else {
        toOfferer.add((candidate, mid));
      }
    };
    final connected = Completer<void>();
    offerer.onState = (state) {
      if (state == RtcState.connected && !connected.isCompleted) connected.complete();
    };

    final remote = offerer.createChannel('remote-v1');
    final media = offerer.createChannel('media-v1');
    final answererChannels = <String, RtcChannel>{};
    final bothArrived = Completer<void>();
    final remoteText = StreamController<String>(), mediaBinary = StreamController<Uint8List>();
    answerer.onChannel = (channel) {
      answererChannels[channel.label] = channel;
      if (channel.label == 'remote-v1') channel.onText = remoteText.add;
      if (channel.label == 'media-v1') channel.onBinary = mediaBinary.add;
      if (answererChannels.length == 2) bothArrived.complete();
    };
    final opened = Completer<void>();
    remote.onOpen = opened.complete;
    final offererText = StreamController<String>();
    remote.onText = offererText.add;

    await offerer.setLocalDescription('offer');
    final offer = await _within(offererDescribed.future);
    expect(offer, contains('webrtc-datachannel'));
    await answerer.setRemoteDescription(offer, 'offer');
    await answerer.setLocalDescription('answer');
    answererReady = true;
    for (final (candidate, mid) in toAnswerer) {
      await answerer.addRemoteCandidate(candidate, mid);
    }
    await offerer.setRemoteDescription(await _within(answererDescribed.future), 'answer');
    offererReady = true;
    for (final (candidate, mid) in toOfferer) {
      await offerer.addRemoteCandidate(candidate, mid);
    }

    await _within(connected.future);
    await _within(opened.future);
    await _within(bothArrived.future);
    expect(remote.isOpen, isTrue);

    // Text one way and back, and binary on the second channel, including a 16 KiB frame like the PC's reads.
    final firstText = remoteText.stream.first;
    expect(remote.sendText('{"type":"hello","note":"ünïcode ✓"}'), isTrue);
    expect(await _within(firstText), '{"type":"hello","note":"ünïcode ✓"}');
    final reply = offererText.stream.first;
    final answererRemote = answererChannels['remote-v1']!;
    await _within(Future.doWhile(() async {
      if (answererRemote.isOpen) return false;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return true;
    }));
    expect(answererRemote.sendText('{"type":"welcome"}'), isTrue);
    expect(await _within(reply), '{"type":"welcome"}');

    final frame = Uint8List.fromList(List.generate(16 * 1024 + 24, (i) => i % 251));
    final firstFrame = mediaBinary.stream.first;
    expect(media.sendBinary(frame), isTrue);
    expect(await _within(firstFrame), frame);

    final pair = await offerer.selectedPair();
    expect(pair, isNotNull);
    expect(pair!.local, contains('typ'));
    expect(pair.remote, contains('typ'));

    // The other side closing its channel is seen as closed.
    final closed = Completer<void>();
    remote.onClosed = closed.complete;
    answererRemote.close();
    await _within(closed.future);
    expect(remote.isOpen, isFalse);
    expect(remote.sendText('late'), isFalse);
  }, skip: skip);

  test('a configuration libdatachannel refuses throws, and closing twice is fine', () async {
    expect(() => RtcPeer.create(iceServers: ['nonsense://x']), throwsA(isA<RtcException>()));
    final peer = RtcPeer.create(iceServers: ['stun:stun.example.com:3478']);
    peer.createChannel('remote-v1');
    await peer.close();
    await peer.close();
    expect(peer.closed, isTrue);
    expect(() => peer.createChannel('late'), throwsA(isA<RtcException>()));
  }, skip: skip);
}
