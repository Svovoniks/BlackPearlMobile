import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'transport.dart';

/// The WebSocket to a PC's own home-network socket (PHONE-REMOTE.md, "On the home network"), made by hand so that what
/// answers at that address, which may be any device, can't make the phone hold more than [budget] bytes of it.
///
/// A WebSocket library parses frames and joins continuation frames into a message before anyone sees it, with no limit
/// on either, and offers compression; a device could stream hundreds of megabytes into one message the phone would
/// never get to refuse. Here every byte from the network is counted before the WebSocket parser sees it, across the
/// whole connection, the HTTP upgrade included. Past [budget] the socket is destroyed, which ends its message stream
/// like any closed socket: the try ends. Compression is neither offered nor accepted.
class LanSignaling implements SignalingSocket {
  LanSignaling._(this._socket, this._counter, this.messages);

  /// Bytes one home-network socket may receive in all. A real exchange is the welcome and `remote-online` (a few hundred
  /// bytes), the PC's signed answer and candidates (a few kilobytes), and a `pong` about every 25 seconds (some 60
  /// bytes each): 256 KiB covers more than a day of a link's pongs. Past it, a link already up keeps going without
  /// the socket.
  static const budget = 256 * 1024;

  /// The longest HTTP answer to the upgrade.
  static const _headerLimit = 8 * 1024;

  final WebSocket _socket;
  final _CountingSocket _counter;
  @override
  final Stream<String> messages;

  /// Bytes taken from the network so far, never more than [budget].
  @visibleForTesting
  int get received => _counter.received;

  /// Whether the budget ran out.
  @visibleForTesting
  bool get exhausted => _counter.exhausted;

  /// Opens `ws://<host>:<port><path>` within [timeout], with at most [budget] bytes received over the connection's life.
  static Future<LanSignaling> connect(Uri uri, {int budget = LanSignaling.budget, Duration timeout = const Duration(seconds: 4)}) async {
    if (uri.scheme != 'ws') throw ArgumentError.value(uri, 'uri', 'Only ws:// on the home network');
    final raw = await Socket.connect(uri.host, uri.port, timeout: timeout);
    try {
      final key = base64.encode(List<int>.generate(16, (_) => Random.secure().nextInt(256)));
      final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
      raw.add(
        ascii.encode(
          'GET ${uri.path.isEmpty ? '/' : uri.path} HTTP/1.1\r\n'
          'Host: $host:${uri.port}\r\n'
          'Upgrade: websocket\r\n'
          'Connection: Upgrade\r\n'
          'Sec-WebSocket-Key: $key\r\n'
          'Sec-WebSocket-Version: 13\r\n'
          '\r\n',
        ),
      );
      final counter = _CountingSocket(raw, budget);
      final leftover = await counter.readHeader(_headerLimit).timeout(timeout);
      final accept = base64.encode(sha1.convert(ascii.encode('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11')).bytes);
      _checkUpgrade(leftover.$1, accept);
      counter.resume(leftover.$2);
      final socket = WebSocket.fromUpgradedSocket(counter, serverSide: false, compression: CompressionOptions.compressionOff);
      final messages = socket.where((frame) => frame is String).cast<String>();
      return LanSignaling._(socket, counter, messages);
    } catch (_) {
      raw.destroy();
      rethrow;
    }
  }

  static void _checkUpgrade(String header, String accept) {
    final lines = header.split('\r\n');
    if (lines.isEmpty || !RegExp(r'^HTTP/1\.1 101( |$)').hasMatch(lines.first)) throw const WebSocketException('The home-network socket refused the upgrade');
    final fields = <String, String>{};
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon > 0) fields[line.substring(0, colon).trim().toLowerCase()] = line.substring(colon + 1).trim();
    }
    if ((fields['upgrade'] ?? '').toLowerCase() != 'websocket' || !(fields['connection'] ?? '').toLowerCase().contains('upgrade')) {
      throw const WebSocketException('Not a WebSocket upgrade');
    }
    if (fields['sec-websocket-accept'] != accept) throw const WebSocketException('Wrong Sec-WebSocket-Accept');
    // Nothing was offered, so nothing may be taken: no compression.
    if (fields.containsKey('sec-websocket-extensions')) throw const WebSocketException('Extensions not offered');
  }

  @override
  void send(String text) => _socket.add(text);

  @override
  Future<void> close() async {
    try {
      await _socket.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    _counter.destroy();
  }
}

/// The TCP socket under [LanSignaling]: everything read from it is counted before it goes on, and once [budget] is
/// spent the socket is destroyed and its stream ends. Writing goes straight to the socket.
class _CountingSocket extends Stream<Uint8List> implements Socket {
  _CountingSocket(this._socket, this.budget);

  final Socket _socket;
  final int budget;
  int received = 0;
  bool exhausted = false;
  final StreamController<Uint8List> _out = StreamController<Uint8List>(sync: true);
  StreamSubscription<Uint8List>? _in;
  final BytesBuilder _header = BytesBuilder(copy: false);
  Completer<(String, Uint8List)>? _headerDone;
  int _headerLimit = 0;

  /// Reads the HTTP answer to the upgrade, up to [limit] bytes, and returns it with whatever came after it.
  Future<(String, Uint8List)> readHeader(int limit) {
    _headerLimit = limit;
    final done = _headerDone = Completer<(String, Uint8List)>();
    _in = _socket.listen(_onData, onError: _onError, onDone: _onDone, cancelOnError: true);
    return done.future;
  }

  /// After the header: hands what came after it on, then the rest of the socket.
  void resume(Uint8List leftover) {
    _headerDone = null;
    if (leftover.isNotEmpty) _out.add(leftover);
  }

  void _onData(Uint8List data) {
    // A piece that would go past the budget isn't taken: the socket goes instead.
    if (received + data.length > budget) {
      exhausted = true;
      destroy();
      return;
    }
    received += data.length;
    final header = _headerDone;
    if (header == null) {
      _out.add(data);
      return;
    }
    _header.add(data);
    final bytes = _header.toBytes();
    final end = _indexOfBlankLine(bytes);
    if (end < 0) {
      if (bytes.length > _headerLimit && !header.isCompleted) {
        header.completeError(const WebSocketException('The upgrade answer is too long'));
        destroy();
      }
      return;
    }
    _header.clear();
    if (!header.isCompleted) header.complete((latin1.decode(bytes.sublist(0, end)), Uint8List.fromList(bytes.sublist(end + 4))));
  }

  static int _indexOfBlankLine(Uint8List bytes) {
    for (var i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10) return i;
    }
    return -1;
  }

  void _onError(Object error, StackTrace stack) {
    final header = _headerDone;
    if (header != null && !header.isCompleted) header.completeError(error, stack);
    if (!_out.isClosed) _out.addError(error, stack);
    _finish();
  }

  void _onDone() {
    final header = _headerDone;
    if (header != null && !header.isCompleted) header.completeError(const SocketException('Closed before the upgrade'));
    _finish();
  }

  void _finish() {
    if (!_out.isClosed) unawaited(_out.close());
  }

  @override
  void destroy() {
    unawaited(_in?.cancel());
    _in = null;
    _socket.destroy();
    final header = _headerDone;
    if (header != null && !header.isCompleted) header.completeError(const SocketException('Closed'));
    _finish();
  }

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List event)? onData, {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      _out.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  // Writing, and the rest of Socket, as the socket itself.
  @override
  Encoding get encoding => _socket.encoding;
  @override
  set encoding(Encoding value) => _socket.encoding = value;
  @override
  void add(List<int> data) => _socket.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) => _socket.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _socket.addStream(stream);
  @override
  Future<void> close() => _socket.close();
  @override
  Future<void> get done => _socket.done;
  @override
  Future<void> flush() => _socket.flush();
  @override
  void write(Object? object) => _socket.write(object);
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) => _socket.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _socket.writeln(object);
  @override
  InternetAddress get address => _socket.address;
  @override
  int get port => _socket.port;
  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;
  @override
  int get remotePort => _socket.remotePort;
  @override
  bool setOption(SocketOption option, bool enabled) => _socket.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _socket.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
}
