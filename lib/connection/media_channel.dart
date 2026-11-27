import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';

import '../diagnostics/link_reports.dart';

/// What a read returned: its bytes (shorter than asked at the end of the resource) and the whole resource's length.
class MediaReply {
  const MediaReply(this.bytes, this.resourceLength);
  final Uint8List bytes;
  final int resourceLength;
}

/// A read the PC refused (`read-error`), or one that couldn't finish.
class MediaReadException implements Exception {
  const MediaReadException(this.code, this.message);
  final String code;
  final String message;

  /// Not ready yet, as a piece still converting: ask again shortly.
  bool get busy => code == 'busy';
  @override
  String toString() => 'MediaReadException($code): $message';
}

/// One read in progress; [cancel] tells the PC to stop sending it.
class MediaRead {
  MediaRead._(this._reader, this.id);
  final MediaReader _reader;
  final int id;
  final Completer<MediaReply> _done = Completer();
  Uint8List? _bytes;
  int _received = 0;
  bool _sent = false;
  DateTime? _sentAt;

  Future<MediaReply> get future => _done.future;
  void cancel() => _reader._cancel(this);
}

/// The phone's side of the `media-v1` channel (PHONE-REMOTE.md): reads go out as text, replies come back as binary
/// frames with a 24-byte header. At most [window] reads are in flight; others wait their turn, so the PC never queues
/// more than it would answer.
class MediaReader {
  MediaReader({required this.send, this.window = 8, this.timeout = const Duration(seconds: 30)});

  /// Sends a text message on the media channel.
  final void Function(String text) send;
  final int window;
  final Duration timeout;

  static const int maxRead = 262144;
  static const int headerBytes = 24;

  final Map<int, MediaRead> _active = {};
  final Queue<(MediaRead, String, int, int)> _waiting = Queue();
  int _next = 0;
  bool _closed = false;
  String _closedReason = 'The connection to the PC closed.';

  bool get closed => _closed;

  // What the channel did since [takeUse] last asked (PHONE-REMOTE.md, "Measuring the link"): bytes that arrived, reads
  // finished, how long any read was in flight, and how long a read with none ahead of it waited for its first frame.
  DateTime? _busySince;
  Duration _busy = Duration.zero;
  int _usedBytes = 0, _usedReads = 0;
  final List<double> _firstBytes = [];

  /// What the channel did since the last call, for the link's report.
  MediaUse takeUse() {
    final now = clock.now();
    final since = _busySince;
    final use = MediaUse(
      bytes: _usedBytes,
      reads: _usedReads,
      busy: _busy + (since == null ? Duration.zero : now.difference(since)),
      firstBytes: List.of(_firstBytes),
    );
    if (since != null) _busySince = now;
    _busy = Duration.zero;
    _usedBytes = _usedReads = 0;
    _firstBytes.clear();
    return use;
  }

  void _idleIfDone() {
    final since = _busySince;
    if (_active.isNotEmpty || since == null) return;
    _busy += clock.now().difference(since);
    _busySince = null;
  }

  /// Reads [count] bytes of [resource] from [offset].
  MediaRead read(String resource, int offset, int count) {
    if (count < 1 || count > maxRead || offset < 0) throw ArgumentError('Invalid read');
    _next = (_next + 1) & 0x7fffffff;
    final read = MediaRead._(this, _next);
    if (_closed) {
      read._done.completeError(MediaReadException('closed', _closedReason));
      return read;
    }
    _waiting.add((read, resource, offset, count));
    _pump();
    return read;
  }

  void _pump() {
    while (!_closed && _active.length < window && _waiting.isNotEmpty) {
      final (read, resource, offset, count) = _waiting.removeFirst();
      if (read._done.isCompleted) continue;
      if (_active.isEmpty) _busySince ??= clock.now();
      // Only a read with none ahead of it is timed to its first frame: the PC answers in order, so a later one also waits
      // for the replies before it.
      read._sentAt = _active.isEmpty ? clock.now() : null;
      _active[read.id] = read;
      read._sent = true;
      try {
        send(jsonEncode({'type': 'read', 'id': read.id, 'resource': resource, 'offset': offset, 'count': count}));
      } catch (_) {
        _finish(read, error: const MediaReadException('closed', 'The connection to the PC closed.'));
        continue;
      }
      _arm(read);
    }
  }

  // The PC answers in order, so on a slow link a read waits behind the ones before it. It times out only when no
  // frame at all has arrived for [timeout].
  DateTime _lastFrame = DateTime.now();
  void _arm(MediaRead read) {
    Timer(timeout, () {
      if (!identical(_active[read.id], read)) return;
      if (DateTime.now().difference(_lastFrame) < timeout) {
        _arm(read);
        return;
      }
      _abort(read, const MediaReadException('timeout', "The PC didn't send the video in time."));
    });
  }

  void _cancel(MediaRead read) {
    // Nobody waits for a canceled read; keep its error from reaching the zone.
    read._done.future.ignore();
    _abort(read, const MediaReadException('canceled', 'Canceled'));
  }

  void _abort(MediaRead read, MediaReadException error) {
    if (read._done.isCompleted) return;
    _waiting.removeWhere((waiting) => identical(waiting.$1, read));
    if (identical(_active[read.id], read)) {
      _active.remove(read.id);
      _idleIfDone();
      if (read._sent && !_closed) {
        try {
          send(jsonEncode({'type': 'cancel', 'id': read.id}));
        } catch (_) {}
      }
    }
    read._done.completeError(error);
    _pump();
  }

  void _finish(MediaRead read, {MediaReply? reply, MediaReadException? error}) {
    _active.remove(read.id);
    if (reply != null) _usedReads++;
    _idleIfDone();
    if (!read._done.isCompleted) {
      if (reply != null) {
        read._done.complete(reply);
      } else {
        read._done.completeError(error ?? const MediaReadException('failed', 'The read failed.'));
      }
    }
    _pump();
  }

  /// A binary frame from the PC.
  void onBinary(Uint8List frame) {
    if (frame.length < headerBytes) return;
    _lastFrame = DateTime.now();
    final header = ByteData.sublistView(frame, 0, headerBytes);
    final id = header.getUint32(0, Endian.little);
    final read = _active[id];
    if (read == null) return;
    final offset = header.getInt32(4, Endian.little);
    final total = header.getInt32(8, Endian.little);
    final resourceLength = header.getInt64(16, Endian.little);
    final data = frame.length - headerBytes;
    if (total < 0 || offset < 0 || offset + data > total) {
      _finish(read, error: const MediaReadException('invalid', 'The PC sent a broken frame.'));
      return;
    }
    final bytes = read._bytes ??= Uint8List(total);
    if (bytes.length != total) {
      _finish(read, error: const MediaReadException('invalid', 'The PC sent a broken frame.'));
      return;
    }
    bytes.setRange(offset, offset + data, frame, headerBytes);
    final sentAt = read._sentAt;
    if (read._received == 0 && sentAt != null && _firstBytes.length < 4096) {
      _firstBytes.add(clock.now().difference(sentAt).inMicroseconds / 1000);
    }
    read._received += data;
    _usedBytes += data;
    if (read._received >= total) _finish(read, reply: MediaReply(bytes, resourceLength));
  }

  /// A text message on the media channel: `read-error`.
  void onText(String text) {
    try {
      final message = jsonDecode(text);
      if (message is! Map || message['type'] != 'read-error' || message['id'] is! num) return;
      final read = _active[(message['id'] as num).toInt()];
      if (read == null) return;
      final code = message['code'] is String ? message['code'] as String : 'failed';
      final why = message['message'] is String ? message['message'] as String : "The PC couldn't send that.";
      _finish(read, error: MediaReadException(code, why));
    } on FormatException {
      return;
    }
  }

  /// The channel is gone: every read fails.
  void close([String reason = 'The connection to the PC closed.']) {
    if (_closed) return;
    _closed = true;
    _closedReason = reason;
    final all = [..._active.values, ..._waiting.map((w) => w.$1)];
    _active.clear();
    _idleIfDone();
    _waiting.clear();
    for (final read in all) {
      if (!read._done.isCompleted) read._done.completeError(MediaReadException('closed', reason));
    }
  }
}
