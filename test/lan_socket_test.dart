import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:blackpearl_mobile/connection/lan_socket.dart';
import 'package:blackpearl_mobile/connection/remote_connection.dart';
import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/storage/paired_pcs.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'connection_test.dart' show FakePeer, pcId, phoneId, secret;

String acceptFor(String key) => base64.encode(sha1.convert(ascii.encode('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11')).bytes);

/// Something answering at a PC's home address, on loopback. It reads the phone's upgrade request, answers it with
/// [answer] (given the right accept key; by default a proper 101), then does [behave].
class _Device {
  _Device._(this._server);
  final ServerSocket _server;
  String request = '';
  int sent = 0;
  final done = Completer<void>();

  Uri get uri => Uri(scheme: 'ws', host: '127.0.0.1', port: _server.port, path: '/remote');

  static String upgrade(String accept, {String extra = ''}) =>
      'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n$extra\r\n';

  static Future<_Device> start(Future<void> Function(_Device device, Socket socket, List<int> answer) behave, {String? Function(String accept)? answer}) async {
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
      final key = RegExp(r'Sec-WebSocket-Key: (\S+)').firstMatch(device.request)!.group(1)!;
      final text = (answer ?? (accept) => upgrade(accept))(acceptFor(key));
      try {
        await behave(device, socket, text == null ? const [] : ascii.encode(text));
      } catch (_) {
        // The phone hung up: what these tests want.
      }
      if (!device.done.isCompleted) device.done.complete();
      socket.destroy();
    });
    return device;
  }

  /// Sends pieces until the phone stops taking them, or [limit] bytes have gone.
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

List<int> textFrame(String text) {
  final bytes = utf8.encode(text);
  return [...frameHeader(1, bytes.length), ...bytes];
}

/// Answers the upgrade, then (after [pause], so the answer arrives in a read of its own) sends a 400 MB frame.
Future<void> Function(_Device, Socket, List<int>) _hugeFrame({Duration pause = Duration.zero, List<int> first = const []}) => (device, socket, answer) async {
  final piece = Uint8List(64 * 1024)..fillRange(0, 64 * 1024, 0x61);
  if (pause > Duration.zero) {
    socket.add([...answer, ...first]);
    await socket.flush();
    await Future<void>.delayed(pause);
    socket.add(frameHeader(1, 400 * 1024 * 1024));
  } else {
    // All at once: the answer, the frame's start and 300 KB of it in one write, as Linux may then read in one go.
    socket.add([...answer, ...first, ...frameHeader(1, 400 * 1024 * 1024), ...Uint8List(300 * 1024)]);
  }
  await device.stream(socket, () => piece, limit: 8 * 1024 * 1024);
};

void main() {
  test('a real exchange goes both ways, with no compression offered and a small receive buffer', () async {
    final device = await _Device.start((device, socket, answer) async {
      socket.add([...answer, ...textFrame('{"type":"remote-online"}')]);
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    // An unusual buffer size, so the check can tell it from the system's own.
    final socket = await LanSignaling.connect(device.uri, receiveBuffer: 48 * 1024);
    expect(await socket.messages.first.timeout(const Duration(seconds: 3)), '{"type":"remote-online"}');
    expect(device.request, isNot(contains('Sec-WebSocket-Extensions')), reason: 'no compression offered');
    expect(socket.received, lessThan(1024));
    // Linux reports double what was asked; others what was asked.
    expect(socket.receiveBufferSize(), anyOf(48 * 1024, 96 * 1024));
    await socket.close();
    await device.close();
  });

  /// Either way the budget can run out: during the upgrade ([LanSignaling.connect] throws) or after it (the message
  /// stream ends). [expected] names the one that must happen, or null when the operating system's reads decide.
  Future<void> expectCutOff(_Device device, {required String what, bool? duringUpgrade, int budget = LanSignaling.budget}) async {
    LanSignaling? socket;
    var refused = false;
    try {
      socket = await LanSignaling.connect(device.uri, budget: budget);
    } on LanBudgetExceeded {
      refused = true;
    }
    if (duringUpgrade != null) expect(refused, duringUpgrade, reason: what);
    if (socket != null) {
      final ended = Completer<void>();
      socket.messages.listen((_) {}, onError: (_) {}, onDone: () => ended.complete());
      await ended.future.timeout(const Duration(seconds: 10), onTimeout: () => fail('the socket was never cut off ($what)'));
      expect(socket.exhausted, isTrue, reason: what);
      expect(socket.received, lessThanOrEqualTo(budget), reason: 'no more than the budget is taken in ($what)');
    }
    await device.done.future.timeout(const Duration(seconds: 10));
    expect(device.sent, lessThan(8 * 1024 * 1024), reason: 'the device could not stream on ($what)');
    await device.close();
  }

  test('the budget running out during the upgrade refuses the connection', () async {
    // A budget smaller than the 101 itself: it runs out before the upgrade is read, on any system.
    await expectCutOff(await _Device.start(_hugeFrame()), what: 'during the upgrade', duringUpgrade: true, budget: 64);
  });

  test('the budget running out after the upgrade ends the message stream', () async {
    await expectCutOff(await _Device.start(_hugeFrame(pause: const Duration(milliseconds: 300))), what: 'after the upgrade', duringUpgrade: false);
  });

  test('one huge frame sent with the upgrade in one write is cut off, whichever read finds it', () async {
    await expectCutOff(await _Device.start(_hugeFrame()), what: 'a huge frame with the upgrade');
  });

  test('endless continuation frames are cut off at the budget', () async {
    final device = await _Device.start((device, socket, answer) async {
      socket.add([...answer, ...frameHeader(1, 100, fin: false), ...List.filled(100, 0x61)]);
      final piece = [...frameHeader(0, 1000, fin: false), ...List.filled(1000, 0x61)];
      await device.stream(socket, () => piece, limit: 8 * 1024 * 1024);
    });
    await expectCutOff(device, what: 'continuation frames');
  });

  test('a compressed frame nobody agreed to ends the socket; a device that answers with compression is refused', () async {
    final device = await _Device.start((device, socket, answer) async {
      // RSV1 marks a compressed message: a small deflate stream that would inflate to a great deal.
      final bomb = zlib.encode(Uint8List(16 * 1024 * 1024));
      socket.add(answer);
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

    final negotiating = await _Device.start((device, socket, answer) async {
      socket.add(answer);
      await socket.flush();
    }, answer: (accept) => _Device.upgrade(accept, extra: 'Sec-WebSocket-Extensions: permessage-deflate\r\n'));
    await expectLater(LanSignaling.connect(negotiating.uri), throwsA(isA<WebSocketException>()));
    await negotiating.close();
  });

  group('the upgrade answer', () {
    Future<void> expectRefused(String? Function(String accept) answer, {required String what, bool stream = false}) async {
      final device = await _Device.start((device, socket, text) async {
        socket.add(text);
        await socket.flush();
        if (stream) {
          final piece = ascii.encode('X-Padding: ${'a' * 1000}\r\n');
          await device.stream(socket, () => piece, limit: 1024 * 1024);
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }, answer: answer);
      await expectLater(LanSignaling.connect(device.uri, timeout: const Duration(seconds: 2)), throwsA(anything), reason: what);
      await device.close();
    }

    test('that never ends is refused', () => expectRefused((accept) => 'HTTP/1.1 101 Switching Protocols\r\n', what: 'endless', stream: true));
    test('that is complete but longer than 8 KiB, all in one write, is refused', () async {
      final device = await _Device.start((device, socket, text) async {
        socket.add(text);
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }, answer: (accept) => _Device.upgrade(accept, extra: 'X-Padding: ${'a' * 40000}\r\n'));
      await expectLater(LanSignaling.connect(device.uri), throwsA(isA<WebSocketException>().having((e) => e.message, 'message', contains('too long'))));
      await device.close();
    });
    test('that is no upgrade is refused', () => expectRefused((accept) => 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n', what: '404'));
    test('with the wrong accept key is refused', () => expectRefused((accept) => _Device.upgrade(base64.encode(List.filled(20, 7))), what: 'wrong key'));
    test('without an Upgrade header is refused',
        () => expectRefused((accept) => 'HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n\r\n', what: 'no Upgrade'));
    test('without a Connection header is refused',
        () => expectRefused((accept) => 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: $accept\r\n\r\n', what: 'no Connection'));
    test('that never comes is given up on within the time allowed', () async {
      final device = await _Device.start((device, socket, text) async {
        await Future<void>.delayed(const Duration(seconds: 3));
      }, answer: (accept) => null);
      final started = DateTime.now();
      await expectLater(LanSignaling.connect(device.uri, timeout: const Duration(milliseconds: 500)), throwsA(isA<TimeoutException>()));
      expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 2)));
      await device.close();
    });
  });

  // The phone's try with the real socket: the budget running out ends it as any failed try does, before the socket is
  // taken and after.
  group('a try on the home network', () {
    RemoteConnection connection(_Device device, {int budget = LanSignaling.budget}) => RemoteConnection(
      target: LinkTarget.paired(PairedPc(
        pcId: pcId,
        name: 'Living room',
        server: 'https://rooms.example.com',
        phoneId: phoneId,
        secret: secret,
        lan: LanEndpoints(port: device.uri.port, addresses: const ['127.0.0.1']),
      )),
      identity: const PhoneIdentity(appVersion: '1.2.3', device: 'Test phone'),
      connectSocket: (uri) async => throw const SocketException('Connection refused'),
      connectLanSocket: (uri) => LanSignaling.connect(uri, budget: budget),
      createPeer: (servers, relay) async => FakePeer(servers, relay),
    );

    Future<LinkStatus> firstFailure(RemoteConnection link) {
      final failed = Completer<LinkStatus>();
      link.addListener(() {
        if (link.status.phase == LinkPhase.failed && !failed.isCompleted) failed.complete(link.status);
      });
      return failed.future.timeout(const Duration(seconds: 10));
    }

    test('ends with the room server\'s failure when the budget runs out during the upgrade', () async {
      final device = await _Device.start(_hugeFrame());
      final link = connection(device, budget: 64);
      final failure = firstFailure(link);
      link.start();
      final status = await failure;
      expect(status.message, "Can't reach the room server. Check your internet connection.");
      expect(link.viaHomeNetwork, isFalse);
      expect(link.halted, isFalse);
      link.dispose();
      await device.close();
    });

    test('ends as a lost connection, and retries, when the budget runs out after the socket was taken', () async {
      final welcome = textFrame(jsonEncode({'type': 'remote-welcome', 'data': jsonEncode({'iceServers': [], 'forceRelay': false, 'session': 'ab' * 16})}));
      final device = await _Device.start(_hugeFrame(pause: const Duration(milliseconds: 500), first: [...welcome, ...textFrame('{"type":"remote-online"}')]));
      final link = connection(device);
      final failure = firstFailure(link);
      link.start();
      final status = await failure;
      expect(link.viaHomeNetwork, isTrue, reason: 'the socket had been taken');
      expect(status.message, 'Lost the connection to the PC.');
      expect(status.retryAt, isNotNull);
      expect(link.halted, isFalse);
      expect(status.needsPairing, isFalse);
      link.dispose();
      await device.close();
    });
  });
}
