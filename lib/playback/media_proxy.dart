import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../connection/media_channel.dart';
import '../protocol/library.dart';

/// Serves the video the phone is watching to its player on `http://127.0.0.1:<port>/`, reading the bytes from the PC
/// over the media channel. The player asks for byte ranges as it would of any web server; the proxy keeps a few reads
/// ahead in flight so the link stays busy.
///
/// A link that drops mid-video is waited for: [reader] gives the current connection's reader, and a read that fails
/// because the link closed is tried again on the next one.
class MediaProxy {
  MediaProxy({required this.reader, this.chunk = 262144, this.ahead = 6, this.reconnectWait = const Duration(seconds: 45), this.onLost, this.beforeRead});

  final MediaReader? Function() reader;

  /// The PC no longer has the stream (it was restarted, or waited for the phone longer than it keeps one), or the link
  /// stayed down past [reconnectWait]. The player itself would only wait; whoever plays asks for the stream again.
  final void Function(StreamInfo stream)? onLost;

  /// Waited for before each read is sent: while the phone waits for an answer from the PC, new reads hold back so the
  /// answer isn't queued behind more video.
  final Future<void> Function()? beforeRead;
  final int chunk;
  final int ahead;
  final Duration reconnectWait;

  HttpServer? _server;
  final Map<String, StreamInfo> _streams = {};
  final Random _random = Random.secure();

  /// Bytes the proxy has handed to the player, and when, for the link's measured speed.
  int servedBytes = 0;

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (_) {});
  }

  /// The address the player opens for [stream].
  Future<Uri> open(StreamInfo stream) async {
    await start();
    final token = List.generate(16, (_) => _random.nextInt(16).toRadixString(16)).join();
    _streams[token] = stream;
    final base = 'http://127.0.0.1:${_server!.port}/v/$token';
    return Uri.parse(stream.hls ? '$base/index.m3u8' : '$base/video${_safeExtension(stream.extension)}');
  }

  /// Forgets a stream the player no longer plays.
  void close(Uri address) {
    final parts = address.pathSegments;
    if (parts.length >= 2) _streams.remove(parts[1]);
  }

  Future<void> dispose() async {
    _streams.clear();
    await _server?.close(force: true);
    _server = null;
  }

  static String _safeExtension(String extension) => RegExp(r'^\.[A-Za-z0-9]{1,8}$').hasMatch(extension) ? extension.toLowerCase() : '';

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final parts = request.uri.pathSegments;
      final stream = parts.length >= 3 && parts[0] == 'v' ? _streams[parts[1]] : null;
      if (stream == null || (request.method != 'GET' && request.method != 'HEAD')) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      if (stream.hls && parts[2] == 'index.m3u8') {
        final body = utf8.encode(stream.playlist((index) => 'p/$index.ts'));
        response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        response.contentLength = body.length;
        if (request.method == 'GET') response.add(body);
        await response.close();
        return;
      }
      if (stream.hls && parts.length == 4 && parts[2] == 'p') {
        final index = int.tryParse(parts[3].replaceAll('.ts', ''));
        if (index == null || index < 0 || index >= stream.segments) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
          return;
        }
        await _serve(request, stream, 'stream/${stream.streamId}/$index', null, ContentType('video', 'mp2t'));
        return;
      }
      if (!stream.hls && parts[2].startsWith('video')) {
        await _serve(request, stream, stream.resource!, stream.length, ContentType('application', 'octet-stream'));
        return;
      }
      response.statusCode = HttpStatus.notFound;
      await response.close();
    } catch (_) {
      // Nothing sent yet: say it failed, so the player doesn't take an empty answer for the video.
      try {
        response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {}
    }
  }

  /// A whole small resource, such as a conversion's subtitles, read as the player's reads are: waiting out a PC still
  /// preparing it ("busy") and a link that drops for a while. At most [limit] bytes.
  Future<Uint8List> fetch(String resource, {int limit = 16 << 20}) async {
    final live = <MediaRead>{};
    final out = BytesBuilder(copy: false);
    var length = -1;
    while (length < 0 || out.length < length) {
      final reply = await _read(resource, out.length, chunk, () => true, live, () {});
      length = reply.resourceLength;
      if (length > limit) throw const MediaReadException('too-large', 'The file is too large.');
      if (reply.bytes.isEmpty) break;
      out.add(reply.bytes);
    }
    return out.takeBytes();
  }

  /// One read, waiting out a piece still converting and a link that drops.
  Future<MediaReply> _read(String resource, int offset, int count, bool Function() wanted, Set<MediaRead> live, void Function() lost) async {
    final deadline = DateTime.now().add(reconnectWait);
    var busyTries = 0;
    while (true) {
      final current = reader();
      if (current == null) {
        if (!wanted()) throw const MediaReadException('closed', 'The connection to the PC closed.');
        if (DateTime.now().isAfter(deadline)) {
          lost();
          throw const MediaReadException('closed', 'The connection to the PC closed.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
        continue;
      }
      await beforeRead?.call();
      if (!wanted()) throw const MediaReadException('closed', 'The connection to the PC closed.');
      final read = current.read(resource, offset, count);
      live.add(read);
      try {
        return await read.future;
      } on MediaReadException catch (e) {
        if (!wanted()) rethrow;
        if (e.busy && busyTries++ < 150) {
          await Future<void>.delayed(const Duration(milliseconds: 700));
          continue;
        }
        if ((e.code == 'closed' || e.code == 'timeout') && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          continue;
        }
        if (e.code == 'gone' || e.code == 'closed' || e.code == 'timeout') lost();
        rethrow;
      } finally {
        live.remove(read);
      }
    }
  }

  /// Answers a request for [resource], whose length is [knownLength] or learned from the first read.
  Future<void> _serve(HttpRequest request, StreamInfo stream, String resource, int? knownLength, ContentType type) async {
    final response = request.response;
    var open = true;
    unawaited(response.done.then((_) => open = false, onError: (_) => open = false));
    bool wanted() => open;
    final live = <MediaRead>{};
    void lost() => onLost?.call(stream);
    final range = request.headers.value(HttpHeaders.rangeHeader);
    var start = 0;
    int? end;
    final match = range == null ? null : RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
    if (match != null) {
      final first = match.group(1)!, last = match.group(2)!;
      if (first.isEmpty && last.isNotEmpty) {
        // The last N bytes.
        final length = knownLength ?? (await _read(resource, 0, 1, wanted, live, lost)).resourceLength;
        start = max(0, length - int.parse(last));
        knownLength = length;
      } else {
        start = int.tryParse(first) ?? 0;
        end = last.isEmpty ? null : int.tryParse(last);
      }
    }
    // The first chunk tells a piece's length when it isn't known.
    MediaReply? first;
    if (knownLength == null) {
      first = await _read(resource, start, chunk, wanted, live, lost);
      knownLength = first.resourceLength;
    }
    final length = knownLength;
    if (start >= length && length > 0) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
      await response.close();
      return;
    }
    final last = min(end ?? length - 1, length - 1);
    final count = last - start + 1;
    if (end != null && end < start) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
      await response.close();
      return;
    }
    response.headers.contentType = type;
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.contentLength = max(0, count);
    if (match != null) {
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$last/$length');
    }
    if (request.method == 'HEAD' || count <= 0) {
      await response.close();
      return;
    }
    // Reads in order, a few ahead; each is written once the ones before it are.
    final pending = <Future<MediaReply>>[];
    var next = start;
    if (first != null) {
      pending.add(Future.value(first));
      next = start + first.bytes.length;
    }
    void fill() {
      while (pending.length < ahead && next <= last) {
        final size = min(chunk, last - next + 1);
        final at = next;
        final read = _read(resource, at, size, wanted, live, lost);
        read.ignore();
        pending.add(read);
        next += size;
      }
    }

    var written = 0;
    try {
      fill();
      while (pending.isNotEmpty && open) {
        final reply = await pending.removeAt(0);
        var bytes = reply.bytes;
        if (bytes.isEmpty) break;
        if (written + bytes.length > count) bytes = Uint8List.sublistView(bytes, 0, count - written);
        response.add(bytes);
        written += bytes.length;
        servedBytes += bytes.length;
        fill();
        await response.flush();
      }
    } catch (_) {
      // The player went away, or the PC couldn't send: end the response; the player asks again.
    } finally {
      open = false;
      for (final read in live.toList()) {
        read.cancel();
      }
      try {
        await response.close();
      } catch (_) {}
    }
  }
}
