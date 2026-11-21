import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:blackpearl_mobile/connection/media_channel.dart';
import 'package:blackpearl_mobile/playback/media_proxy.dart';
import 'package:blackpearl_mobile/protocol/library.dart';
import 'package:flutter_test/flutter_test.dart';

/// A frame as PHONE-REMOTE.md lays it out: id, offset in the reply, reply length, reserved, resource length, data.
Uint8List frame(int id, int offset, int total, int resourceLength, List<int> data) {
  final bytes = Uint8List(24 + data.length);
  ByteData.sublistView(bytes)
    ..setUint32(0, id, Endian.little)
    ..setInt32(4, offset, Endian.little)
    ..setInt32(8, total, Endian.little)
    ..setInt32(12, 0, Endian.little)
    ..setInt64(16, resourceLength, Endian.little);
  bytes.setRange(24, bytes.length, data);
  return bytes;
}

/// A PC that answers reads from in-memory resources, in frames of [frameBytes], as the desktop app does.
class FakePc {
  FakePc(this.resources, {this.frameBytes = 16384, this.busyFirst = 0});
  final Map<String, Uint8List> resources;
  final int frameBytes;

  /// How many reads of a `stream/` resource are answered `busy` before the piece is ready.
  int busyFirst;
  final List<Map<String, dynamic>> sent = [];
  late final MediaReader reader = MediaReader(send: _receive, window: 4);

  void _receive(String text) {
    final message = jsonDecode(text) as Map<String, dynamic>;
    sent.add(message);
    if (message['type'] != 'read') return;
    final id = message['id'] as int, resource = message['resource'] as String;
    final offset = message['offset'] as int, count = message['count'] as int;
    // Answer on a later turn, as the channel would.
    scheduleMicrotask(() {
      final bytes = resources[resource];
      if (bytes == null) {
        reader.onText(jsonEncode({'type': 'read-error', 'id': id, 'code': 'gone', 'message': 'Not here'}));
        return;
      }
      if (resource.startsWith('stream/') && busyFirst > 0) {
        busyFirst--;
        reader.onText(jsonEncode({'type': 'read-error', 'id': id, 'code': 'busy', 'message': 'Converting'}));
        return;
      }
      final start = offset.clamp(0, bytes.length);
      final reply = bytes.sublist(start, (start + count).clamp(0, bytes.length));
      var at = 0;
      do {
        final size = (reply.length - at).clamp(0, frameBytes);
        reader.onBinary(frame(id, at, reply.length, bytes.length, reply.sublist(at, at + size)));
        at += size;
      } while (at < reply.length);
    });
  }
}

Uint8List pattern(int length) => Uint8List.fromList(List.generate(length, (i) => (i * 31) % 251));

void main() {
  group('media channel', () {
    test('a reply in several frames comes back whole, with the resource length', () async {
      final pc = FakePc({'file/a': pattern(100000)}, frameBytes: 7000);
      final reply = await pc.reader.read('file/a', 1000, 50000).future;
      expect(reply.resourceLength, 100000);
      expect(reply.bytes, pattern(100000).sublist(1000, 51000));
    });

    test('a read past the end is short, and one at the end is empty', () async {
      final pc = FakePc({'file/a': pattern(1000)});
      expect((await pc.reader.read('file/a', 900, 500).future).bytes.length, 100);
      expect((await pc.reader.read('file/a', 1000, 500).future).bytes, isEmpty);
    });

    test('refusals carry their code', () async {
      final pc = FakePc({});
      await expectLater(pc.reader.read('file/b', 0, 10).future, throwsA(isA<MediaReadException>().having((e) => e.code, 'code', 'gone')));
    });

    test('no more than the window is in flight; the rest waits its turn', () {
      final sent = <String>[];
      final reader = MediaReader(send: sent.add, window: 2);
      final reads = [for (var i = 0; i < 5; i++) reader.read('file/a', i * 10, 10)];
      expect(sent.where((s) => s.contains('"read"')), hasLength(2));
      // The first finishes: one more goes out.
      reader.onBinary(frame(reads[0].id, 0, 10, 100, List.filled(10, 1)));
      expect(sent.where((s) => s.contains('"read"')), hasLength(3));
      for (final read in reads.skip(1)) {
        read.cancel();
      }
    });

    test('a canceled read tells the PC and frees its place', () {
      final sent = <String>[];
      final reader = MediaReader(send: sent.add, window: 1);
      final first = reader.read('file/a', 0, 10);
      reader.read('file/a', 10, 10).future.ignore();
      first.cancel();
      expect(sent.map((s) => jsonDecode(s)['type']), ['read', 'cancel', 'read']);
      expect(first.future, throwsA(isA<MediaReadException>()));
    });

    test('closing fails every read, waiting or sent', () async {
      final reader = MediaReader(send: (_) {}, window: 1);
      final sent = reader.read('file/a', 0, 10), waiting = reader.read('file/a', 10, 10);
      reader.close('gone');
      await expectLater(sent.future, throwsA(isA<MediaReadException>().having((e) => e.code, 'code', 'closed')));
      await expectLater(waiting.future, throwsA(isA<MediaReadException>()));
      await expectLater(reader.read('file/a', 0, 1).future, throwsA(isA<MediaReadException>()));
    });

    test("a frame that disagrees with the first one about the reply's length fails the read at once", () async {
      final reader = MediaReader(send: (_) {});
      final read = reader.read('file/a', 0, 20);
      reader.onBinary(frame(read.id, 0, 20, 100, List.filled(5, 1)));
      reader.onBinary(frame(read.id, 5, 30, 100, List.filled(5, 1)));
      await expectLater(read.future, throwsA(isA<MediaReadException>().having((e) => e.code, 'code', 'invalid')));
    });

    test('a frame that runs past its reply is refused', () async {
      final reader = MediaReader(send: (_) {});
      final read = reader.read('file/a', 0, 10);
      reader.onBinary(frame(read.id, 8, 10, 100, List.filled(5, 1)));
      await expectLater(read.future, throwsA(isA<MediaReadException>().having((e) => e.code, 'code', 'invalid')));
    });
  });

  group('proxy', () {
    late HttpClient http;
    setUp(() => http = HttpClient());
    tearDown(() => http.close(force: true));

    Future<(int, Map<String, String>, Uint8List)> get(Uri uri, {String? range}) async {
      final request = await http.getUrl(uri);
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      final response = await request.close();
      final body = await response.fold<BytesBuilder>(BytesBuilder(), (b, chunk) => b..add(chunk));
      final headers = <String, String>{};
      response.headers.forEach((name, values) => headers[name] = values.join(','));
      return (response.statusCode, headers, body.takeBytes());
    }

    test('the player gets the ranges it asks for, read from the PC in pieces', () async {
      final video = pattern(1500000);
      final pc = FakePc({'file/v': video});
      final proxy = MediaProxy(reader: () => pc.reader, chunk: 100000, ahead: 3);
      addTearDown(proxy.dispose);
      final uri = await proxy.open(const StreamInfo(id: 'v', title: 'V', hls: false, resource: 'file/v', length: 1500000, extension: '.mkv'));
      expect(uri.path, endsWith('.mkv'));
      final (status, headers, body) = await get(uri, range: 'bytes=250000-1049999');
      expect(status, 206);
      expect(headers['content-range'], 'bytes 250000-1049999/1500000');
      expect(body, video.sublist(250000, 1050000));
      final (whole, _, all) = await get(uri);
      expect(whole, 200);
      expect(all, video);
      final (tail, _, end) = await get(uri, range: 'bytes=-1000');
      expect(tail, 206);
      expect(end, video.sublist(1499000));
      final (beyond, _, _) = await get(uri, range: 'bytes=1500000-');
      expect(beyond, 416);
      final (reversed, _, _) = await get(uri, range: 'bytes=500-100');
      expect(reversed, 416);
    });

    test('a conversion is a playlist of its pieces, and a piece still converting is waited for', () async {
      final piece = pattern(300000);
      final pc = FakePc({'stream/s1/1': piece}, busyFirst: 2);
      final proxy = MediaProxy(reader: () => pc.reader, chunk: 128000);
      addTearDown(proxy.dispose);
      final uri = await proxy.open(const StreamInfo(id: 'v', title: 'V', hls: true, streamId: 's1', segments: 3, segmentMs: 4000, durationMs: 10000));
      final (status, _, playlist) = await get(uri);
      expect(status, 200);
      final text = utf8.decode(playlist);
      expect(text, contains('#EXTINF:4.000,\np/0.ts'));
      expect(text, contains('#EXTINF:2.000,\np/2.ts'));
      expect(text.trim(), endsWith('#EXT-X-ENDLIST'));
      final (got, headers, body) = await get(uri.resolve('p/1.ts'));
      expect(got, 200);
      expect(headers['content-length'], '300000');
      expect(body, piece);
    });

    test('a stream the PC no longer has is reported, so the player can ask for it again', () async {
      final pc = FakePc({});
      final lost = <StreamInfo>[];
      final proxy = MediaProxy(reader: () => pc.reader, onLost: lost.add);
      addTearDown(proxy.dispose);
      const stream = StreamInfo(id: 'v', title: 'V', hls: false, resource: 'file/v', length: 1000);
      final uri = await proxy.open(stream);
      // The reply is cut short or refused; either way the player doesn't get the bytes.
      try {
        final (status, _, body) = await get(uri, range: 'bytes=0-99');
        expect(status == 206 && body.length == 100, isFalse);
      } on HttpException {
        // Cut off before the headers.
      }
      expect(lost, [stream]);
    });

    test('a stream the proxy no longer serves is not found', () async {
      final pc = FakePc({'file/v': pattern(10)});
      final proxy = MediaProxy(reader: () => pc.reader);
      addTearDown(proxy.dispose);
      final uri = await proxy.open(const StreamInfo(id: 'v', title: 'V', hls: false, resource: 'file/v', length: 10));
      proxy.close(uri);
      expect((await get(uri)).$1, 404);
    });
  });

  group('library messages', () {
    test('entries read the PC page, and say what they open', () {
      final page = LibraryPage.fromJson({
        'type': 'page',
        'total': 41,
        'page': 0,
        'pageSize': 40,
        'location': 'All titles',
        'entries': [
          {'id': 'S', 'title': 'Night Signal', 'level': 'series', 'kind': 'Show', 'playable': false},
          {'id': 'E', 'title': 'Low Tide', 'level': 'episode', 'positionMs': 600000, 'runtimeMinutes': 40, 'playable': true, 'artwork': 'abc'},
          {'title': 'no id'},
        ],
      });
      expect(page.entries, hasLength(2));
      expect(page.hasMore, isTrue);
      expect(page.entries[0].opensList, isTrue);
      expect(page.entries[1].opensList, isFalse);
      expect(page.entries[1].progress, closeTo(0.25, 0.001));
      expect(page.entries[1].artwork, 'abc');
    });

    test('a stream answer needs what the player opens', () {
      expect(StreamInfo.fromJson({'id': 'v', 'kind': 'file', 'resource': 'file/v', 'length': 0}), isNull);
      expect(StreamInfo.fromJson({'id': 'v', 'kind': 'hls', 'segments': 5}), isNull);
      final file = StreamInfo.fromJson({'id': 'v', 'kind': 'file', 'resource': 'file/v', 'length': 9, 'extension': '.mp4', 'positionMs': 5000, 'qualities': ['original', '720p']})!;
      expect(file.hls, isFalse);
      expect(file.positionMs, 5000);
      expect(file.qualities, ['original', '720p']);
    });
  });
}
