import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'transport.dart';

/// The budget of a home-network socket ran out ([LanSignaling.budget]), during the upgrade or after it.
class LanBudgetExceeded extends WebSocketException {
  const LanBudgetExceeded() : super('The home-network socket sent more than the phone takes');
}

/// The WebSocket to a PC's own home-network socket (PHONE-REMOTE.md, "On the home network"), made by hand so that what
/// answers at that address, which may be any device, can't make the phone hold more than [budget] bytes of it.
///
/// A WebSocket library parses frames and joins continuation frames into a message before anyone sees it, with no limit
/// on either, and offers compression; a device could stream hundreds of megabytes into one message the phone would
/// never get to refuse. Here every byte from the network is counted before the WebSocket parser sees it, across the
/// whole connection, the HTTP upgrade included. A read that would go past [budget] is not passed on: the socket is
/// destroyed, which ends the try ([connect] throws [LanBudgetExceeded] if it happens during the upgrade; after it, the
/// message stream ends). One read from the operating system can hold at most what the socket's receive buffer does,
/// which is set to [receiveBuffer] (Linux, and so Android, doubles it). Compression is neither offered nor accepted.
class LanSignaling implements SignalingSocket {
  LanSignaling._(this._socket, this._counter, this.messages);

  /// Bytes one home-network socket may receive in all. A real exchange is the upgrade, the welcome and `remote-online`
  /// (under 500 bytes together), the PC's signed answer and candidates (a few kilobytes), and a `pong` about every 25
  /// seconds (about 90 bytes framed): 256 KiB lasts some 19 hours of a link's pongs, and the PC ends such a socket after
  /// 6 (some 80 KB). Past it, a link already up keeps going without the socket.
  static const budget = 256 * 1024;

  /// The longest HTTP answer to the upgrade, blank line included.
  static const headerLimit = 8 * 1024;

  /// The receive buffer asked of the operating system, which bounds what one read can hold.
  static const receiveBuffer = 64 * 1024;

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
  static Future<LanSignaling> connect(
    Uri uri, {
    int budget = LanSignaling.budget,
    int headerLimit = LanSignaling.headerLimit,
    int receiveBuffer = LanSignaling.receiveBuffer,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    if (uri.scheme != 'ws') throw ArgumentError.value(uri, 'uri', 'Only ws:// on the home network');
    final raw = await Socket.connect(uri.host, uri.port, timeout: timeout);
    _limitReceiveBuffer(raw, receiveBuffer);
    final counter = _CountingSocket(raw, budget);
    try {
      final key = base64.encode(List<int>.generate(16, (_) => Random.secure().nextInt(256)));
      final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
      final header = counter.readHeader(headerLimit);
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
      final (answer, leftover) = await header.timeout(timeout);
      final accept = base64.encode(sha1.convert(ascii.encode('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11')).bytes);
      _checkUpgrade(answer, accept);
      counter.resume(leftover);
      final socket = WebSocket.fromUpgradedSocket(counter, serverSide: false, compression: CompressionOptions.compressionOff);
      final messages = socket.where((frame) => frame is String).cast<String>();
      return LanSignaling._(socket, counter, messages);
    } catch (_) {
      counter.destroy();
      rethrow;
    }
  }

  /// Asks for a small receive buffer, so one read can't bring in much more than [budget] allows. Best effort: a platform
  /// that refuses keeps its own, and the budget still holds for everything after that read.
  static void _limitReceiveBuffer(Socket socket, int size) {
    try {
      // SO_RCVBUF: 8 on Linux and Android, 0x1002 on Windows and Apple's systems.
      final name = Platform.isLinux || Platform.isAndroid ? 8 : 0x1002;
      socket.setRawOption(RawSocketOption.fromInt(RawSocketOption.levelSocket, name, size));
    } catch (_) {}
  }

  /// The receive buffer the operating system reports for [socket], for the tests.
  @visibleForTesting
  int receiveBufferSize() {
    final name = Platform.isLinux || Platform.isAndroid ? 8 : 0x1002;
    final value = _counter.getRawOption(RawSocketOption(RawSocketOption.levelSocket, name, Uint8List(4)));
    return ByteData.sublistView(value).getInt32(0, Endian.host);
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

/// The TCP socket under [LanSignaling]: everything read from it is counted before it goes on, and once [budget] would be
/// passed the socket is destroyed and its stream ends. Writing goes straight to the socket.
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

  /// Reads the HTTP answer to the upgrade, at most [limit] bytes up to and including its blank line, and returns it with
  /// whatever came after it.
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
    // A read that would go past the budget isn't taken: the socket goes instead.
    if (received + data.length > budget) {
      exhausted = true;
      _end(const LanBudgetExceeded());
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
    // Too long, whether or not its end has come.
    if ((end < 0 ? bytes.length : end + 4) > _headerLimit) {
      _end(const WebSocketException('The upgrade answer is too long'));
      return;
    }
    if (end < 0) return;
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

  /// Destroys the socket; an upgrade still being read fails with [reason].
  void _end(Object reason) {
    final header = _headerDone;
    if (header != null && !header.isCompleted) header.completeError(reason);
    destroy();
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
