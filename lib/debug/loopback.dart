import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../protocol/signing.dart';

/// Debug builds only (`--preview=loopback`): a room server and a stand-in PC inside this process, so the app's real
/// connection code (WebSocket signaling, signed signals, flutter_webrtc offer/answer, trickled ICE, the data channel,
/// pairing and state) runs end to end on one machine. It is not the desktop app; it follows PHONE-REMOTE.md the same
/// way, and answers commands by changing a made-up state.
class LoopbackHarness {
  LoopbackHarness._(this._server, this.pc);

  final HttpServer _server;
  final LoopbackPc pc;
  final List<String> log = [];

  String get serverUrl => 'http://127.0.0.1:${_server.port}';

  String pairingLink() =>
      'blackpearl://pair?v=1&pc=${pc.pcId}&code=${pc.code}&server=${Uri.encodeComponent(serverUrl)}&name=${Uri.encodeComponent(pc.name)}';

  static Future<LoopbackHarness> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final relay = _Relay();
    server.listen((request) async {
      if (request.uri.path == '/remote' && WebSocketTransformer.isUpgradeRequest(request)) {
        relay.accept(await WebSocketTransformer.upgrade(request));
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    });
    final pc = LoopbackPc(serverUrl: 'ws://127.0.0.1:${server.port}/remote');
    await pc.connect();
    return LoopbackHarness._(server, pc);
  }
}

/// The `/remote` endpoint, as the room server does it: one PC, any number of phones, signals passed along.
class _Relay {
  WebSocket? _pc;
  String? _pcId;
  final Map<String, WebSocket> _phones = {};
  int _next = 0;

  void accept(WebSocket socket) {
    String? phoneId;
    socket.listen(
      (data) {
        if (data is! String) return;
        final message = jsonDecode(data) as Map<String, dynamic>;
        final type = message['type'];
        if (type == 'ping') {
          socket.add(jsonEncode({'type': 'pong', 'number': message['number'], 'data': '0'}));
        } else if (type == 'remote-pc') {
          _pc = socket;
          _pcId = sha256.convert(utf8.encode(message['data'] as String)).toString().toUpperCase().substring(0, 32);
          socket.add(
            jsonEncode({
              'type': 'remote-welcome',
              'target': _pcId,
              'data': jsonEncode({'iceServers': <String>[]}),
            }),
          );
          for (final phone in _phones.values) {
            phone.add(jsonEncode({'type': 'remote-online'}));
          }
        } else if (type == 'remote-phone') {
          phoneId = 'phone${_next++}';
          _phones[phoneId!] = socket;
          socket.add(
            jsonEncode({
              'type': 'remote-welcome',
              'target': phoneId,
              'data': jsonEncode({'iceServers': <String>[]}),
            }),
          );
          socket.add(
            jsonEncode({'type': _pc != null && (message['target'] as String).toUpperCase() == _pcId ? 'remote-online' : 'remote-offline'}),
          );
        } else if (type == 'signal') {
          if (socket == _pc) {
            _phones[message['target']]?.add(jsonEncode({'type': 'signal', 'sender': _pcId, 'data': message['data']}));
          } else if (phoneId != null) {
            _pc?.add(jsonEncode({'type': 'signal', 'sender': phoneId, 'data': message['data']}));
          }
        }
      },
      onDone: () {
        if (phoneId != null) {
          _phones.remove(phoneId);
          _pc?.add(jsonEncode({'type': 'peer-left', 'sender': phoneId}));
        }
      },
    );
  }
}

/// A PC that pairs one phone and plays a pretend video.
class LoopbackPc {
  LoopbackPc({required this.serverUrl});

  final String serverUrl;
  final String name = 'Loopback PC';
  final String hostKey = Signing.randomHex(32);
  final String code = Signing.randomHex(16);
  final String phoneId = Signing.randomHex(16);
  final String secret = Signing.randomHex(32);
  String get pcId => sha256.convert(utf8.encode(hostKey)).toString().toUpperCase().substring(0, 32);

  WebSocket? _socket;
  RTCPeerConnection? _peer;
  RTCDataChannel? _channel;
  String? _session, _signalAs, _key, _phoneConnection;
  bool _codeUsed = false;
  final List<String> commands = [];

  Map<String, Object?> state = {
    'type': 'state',
    'media': true,
    'title': 'Loopback Video',
    'detail': 'Served by the stand-in PC in this process',
    'playing': true,
    'positionMs': 61000,
    'durationMs': 1800000,
    'volume': 50,
    'muted': false,
    'loop': 'off',
    'fullscreen': false,
    'hasPrevious': false,
    'hasNext': true,
    'canControl': true,
    'room': null,
  };
  DateTime _stateAt = DateTime.now();

  Future<void> connect() async {
    final socket = await WebSocket.connect(serverUrl);
    _socket = socket;
    socket.add(jsonEncode({'type': 'remote-pc', 'data': hostKey, 'number': 1}));
    socket.listen((data) {
      final message = jsonDecode(data as String) as Map<String, dynamic>;
      if (message['type'] == 'signal') unawaited(_onSignal(message['sender'] as String, message['data'] as String));
    });
  }

  void _signal(String kind, String payload) {
    final signal = SignedSignal(
      phone: _signalAs!,
      session: _session!,
      kind: kind,
      payload: payload,
      auth: Signing.sign(_key!, 'pc', _signalAs!, _session!, kind, payload),
    );
    _socket?.add(jsonEncode({'type': 'signal', 'target': _phoneConnection, 'data': signal.encode()}));
  }

  Future<void> _onSignal(String sender, String data) async {
    final signal = SignedSignal.tryParse(data);
    if (signal == null) return;
    final key = signal.phone == 'pair' ? (_codeUsed ? null : code) : (signal.phone == phoneId ? secret : null);
    if (key == null) {
      if (signal.kind == 'sdp') {
        _socket?.add(
          jsonEncode({
            'type': 'signal',
            'target': sender,
            'data': SignedSignal(
              phone: signal.phone,
              session: signal.session,
              kind: 'rejected',
              payload: signal.phone == 'pair' ? 'pairing-expired' : 'unknown-phone',
              auth: '',
            ).encode(),
          }),
        );
      }
      return;
    }
    if (!Signing.verify(key, 'phone', signal.phone, signal.session, signal.kind, signal.payload, signal.auth)) return;
    _phoneConnection = sender;
    final payload = jsonDecode(signal.payload) as Map<String, dynamic>;
    if (signal.kind == 'sdp' && payload['type'] == 'offer') {
      await _peer?.close();
      _session = signal.session;
      _signalAs = signal.phone;
      _key = key;
      final peer = await createPeerConnection({'iceServers': <Map<String, dynamic>>[], 'sdpSemantics': 'unified-plan'});
      _peer = peer;
      peer.onIceCandidate = (candidate) {
        final line = candidate.candidate;
        if (line == null || line.isEmpty) return;
        _signal('ice', jsonEncode({'candidate': line.startsWith('a=') ? line.substring(2) : line, 'mid': candidate.sdpMid ?? '0'}));
      };
      peer.onDataChannel = (channel) {
        if (channel.label != 'remote-v1') return;
        _channel = channel;
        channel.onMessage = (message) => _onMessage(message.text);
      };
      await peer.setRemoteDescription(RTCSessionDescription(payload['sdp'] as String, 'offer'));
      final answer = await peer.createAnswer();
      await peer.setLocalDescription(answer);
      _signal('sdp', jsonEncode({'type': 'answer', 'sdp': answer.sdp}));
    } else if (signal.kind == 'ice' && signal.session == _session) {
      await _peer?.addCandidate(RTCIceCandidate(payload['candidate'] as String, payload['mid'] as String?, 0));
    }
  }

  void _send(Map<String, Object?> message) => _channel?.send(RTCDataChannelMessage(jsonEncode(message)));

  void _sendState() {
    final now = DateTime.now();
    if (state['playing'] == true) state['positionMs'] = (state['positionMs'] as int) + now.difference(_stateAt).inMilliseconds;
    _stateAt = now;
    _send(state);
  }

  void _onMessage(String text) {
    final message = jsonDecode(text) as Map<String, dynamic>;
    switch (message['type']) {
      case 'hello':
        _send({'type': 'welcome', 'protocol': 1, 'app': 'loopback', 'pc': name, 'pcId': pcId, 'canStart': true});
        if (_signalAs != 'pair') _sendState();
      case 'pair' when _signalAs == 'pair' && !_codeUsed:
        _codeUsed = true;
        _send({'type': 'paired', 'phoneId': phoneId, 'secret': secret, 'pc': name, 'pcId': pcId});
        _sendState();
      case 'command':
        final action = message['action'] as String;
        commands.add(action);
        _sendState();
        switch (action) {
          case 'toggle':
            state['playing'] = !(state['playing'] as bool);
          case 'seek-by':
            state['positionMs'] = ((state['positionMs'] as int) + (message['value'] as num).round()).clamp(0, 1800000);
          case 'seek-to':
            state['positionMs'] = (message['value'] as num).round();
          case 'volume':
            state['volume'] = (message['value'] as num).round();
          case 'mute':
            state['muted'] = !(state['muted'] as bool);
          case 'loop':
            state['loop'] = {'off': 'all', 'all': 'one', 'one': 'off'}[state['loop']];
          case 'fullscreen':
            state['fullscreen'] = !(state['fullscreen'] as bool);
          default:
            _send({'type': 'error', 'code': 'nothing-playing', 'message': 'The loopback PC can\'t do "$action".'});
            return;
        }
        _sendState();
    }
  }
}
