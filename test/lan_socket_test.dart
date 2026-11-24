import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:blackpearl_mobile/connection/lan_socket.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Something answering at a PC's home address, on loopback: it upgrades the connection (or not), then does [behave].
class _Device {
  _Device._(this._server);
  final ServerSocket _server;
  String request = '';
  int sent = 0;
  final done = Completer<void>();

  Uri get uri => Uri(scheme: 'ws', host: '127.0.0.1', port: _server.port, path: '/remote');

  static Future<_Device> start(Future<void> Function(_Device device, Socket socket) behave, {String? extraHeader, bool upgrade = true}) async {
    final device = _Device._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
    device._server.listen((socket) async {
      final buffer = BytesBuilder();
      final headerRead = Completer<void>();
      socket.listen((data) {
        if (headerRead.isCompleted) return;
        buffer.add(data);
        final text = latin1.decode(buffer.toBytes());
        if (text.contains('\r\n\r\n')) {
          device.request = text;
          headerRead.complete();
        }
      }, onError: (_) {}, onDone: () {});
      await headerRead.future;
      if (upgrade) {
        final key = RegExp(r'Sec-WebSocket-Key: (\S+)').firstMatch(device.request)!.group(1)!;
        final accept = base64.encode(sha1.convert(ascii.encode('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11')).bytes);
        socket.add(ascii.encode('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n${extraHeader ?? ''}\r\n'));
      }
      try {
        await behave(device, socket);
      } catch (_) {
        // The phone hung up: what these tests want.
      }
      if (!device.done.isCompleted) device.done.complete();
      socket.destroy();
    });
    return device;
  }

  /// Sends [bytes] in pieces until the phone stops taking them, or [limit] bytes have gone.
  Future<void> stream(Socket socket, List<int> Function() piece, {required int limit}) async {
    while (sent < limit) {
      final bytes = piece();
      socket.add(bytes);
      await socket.flush();
      sent += bytes.length;
    }
  }

  Future<void> close() => _server.close();
}

/// A server frame (unmasked): [opcode] with FIN as given, and a payload length as given (the payload follows).
List<int> frameHeader(int opcode, int length, {bool fin = true, bool rsv1 = false}) {
  final first = (fin ? 0x80 : 0) | (rsv1 ? 0x40 : 0) | opcode;
  if (length < 126) return [first, length];
  if (length < 65536) return [first, 126, length >> 8, length & 0xff];
  return [first, 127, ...List.generate(8, (i) => (length >> (8 * (7 - i))) & 0xff)];
}

void main() {
  test('a real exchange goes both ways, with no compression offered', () async {
    final device = await _Device.start((device, socket) async {
      final text = utf8.encode('{"type":"remote-online"}');
      socket.add([...frameHeader(1, text.length), ...text]);
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    final socket = await LanSignaling.connect(device.uri);
    final first = await socket.messages.first.timeout(const Duration(seconds: 3));
    expect(first, '{"type":"remote-online"}');
    expect(device.request, isNot(contains('Sec-WebSocket-Extensions')), reason: 'no compression offered');
    expect(socket.received, lessThan(1024));
    await socket.close();
    await device.close();
  });

  Future<void> expectCutOff(_Device device, {required String what}) async {
    final socket = await LanSignaling.connect(device.uri);
    final ended = Completer<void>();
    socket.messages.listen((_) {}, onError: (_) {}, onDone: () => ended.complete());
    await ended.future.timeout(const Duration(seconds: 10), onTimeout: () => fail('the socket was never cut off ($what)'));
    await device.done.future.timeout(const Duration(seconds: 10));
    expect(socket.exhausted, isTrue, reason: what);
    expect(socket.received, lessThanOrEqualTo(LanSignaling.budget), reason: 'no more than the budget is taken in ($what)');
    expect(device.sent, lessThan(8 * 1024 * 1024), reason: 'the device could not stream on ($what)');
    await device.close();
  }

  test('one huge frame is cut off at the budget, before any message is delivered', () async {
    final device = await _Device.start((device, socket) async {
      // A 400 MB text frame, sent 64 KiB at a time.
      socket.add(frameHeader(1, 400 * 1024 * 1024));
      final piece = Uint8List(64 * 1024)..fillRange(0, 64 * 1024, 0x61);
      await device.stream(socket, () => piece, limit: 8 * 1024 * 1024);
    });
    await expectCutOff(device, what: 'a huge frame');
  });

  test('endless continuation frames are cut off at the budget', () async {
    final device = await _Device.start((device, socket) async {
      socket.add([...frameHeader(1, 100, fin: false), ...List.filled(100, 0x61)]);
      final piece = [...frameHeader(0, 1000, fin: false), ...List.filled(1000, 0x61)];
      await device.stream(socket, () => piece, limit: 8 * 1024 * 1024);
    });
    await expectCutOff(device, what: 'continuation frames');
  });

  test('a compressed frame nobody agreed to ends the socket; a device that answers with compression is refused', () async {
    final device = await _Device.start((device, socket) async {
      // RSV1 marks a compressed message: a small deflate stream that would inflate to a great deal.
      final bomb = zlib.encode(Uint8List(16 * 1024 * 1024));
      socket.add([...frameHeader(1, bomb.length, rsv1: true), ...bomb]);
      await socket.flush();
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    final socket = await LanSignaling.connect(device.uri);
    final messages = <String>[];
    final ended = Completer<void>();
    socket.messages.listen(messages.add, onError: (_) {}, onDone: () => ended.complete());
    await ended.future.timeout(const Duration(seconds: 10), onTimeout: () => fail('a compressed frame was taken'));
    expect(messages, isEmpty);
    expect(socket.received, lessThanOrEqualTo(LanSignaling.budget));
    await device.close();

    final negotiating = await _Device.start((device, socket) async {}, extraHeader: 'Sec-WebSocket-Extensions: permessage-deflate\r\n');
    await expectLater(LanSignaling.connect(negotiating.uri), throwsA(isA<WebSocketException>()));
    await negotiating.close();
  });

  test('an upgrade answer that never ends, or is no upgrade, is refused', () async {
    final endless = await _Device.start((device, socket) async {
      final piece = ascii.encode('X-Padding: ${'a' * 1000}\r\n');
      socket.add(ascii.encode('HTTP/1.1 101 Switching Protocols\r\n'));
      await device.stream(socket, () => piece, limit: 1024 * 1024);
    }, upgrade: false);
    await expectLater(LanSignaling.connect(endless.uri), throwsA(anything));
    await endless.close();

    final plain = await _Device.start((device, socket) async {
      socket.add(ascii.encode('HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n'));
      await socket.flush();
    }, upgrade: false);
    await expectLater(LanSignaling.connect(plain.uri), throwsA(isA<WebSocketException>()));
    await plain.close();
  });
}
