import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'transport.dart';

const String channelLabel = 'remote-v1';

/// [PeerLink] over flutter_webrtc.
class WebRtcPeerLink extends PeerLink {
  WebRtcPeerLink._(this._pc, this._channel) {
    _pc.onIceCandidate = (candidate) {
      var line = candidate.candidate;
      if (line == null || line.isEmpty) return; // end of candidates
      if (line.startsWith('a=')) line = line.substring(2);
      final mid = candidate.sdpMid ?? midForMLineIndex(_localSdp, candidate.sdpMLineIndex) ?? '0';
      onLocalCandidate?.call(line, mid);
    };
    _pc.onConnectionState = (state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _finish('The connection to the PC failed.');
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _finish('The connection to the PC closed.');
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          // ICE often recovers from a short gap by itself; give it a moment before calling the link lost.
          _disconnectTimer ??= Timer(const Duration(seconds: 6), () => _finish('Lost the connection to the PC.'));
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _disconnectTimer?.cancel();
          _disconnectTimer = null;
        default:
          break;
      }
    };
    _channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _open = true;
        onOpen?.call();
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _finish('The PC closed the connection.');
      }
    };
    _channel.onMessage = (message) {
      if (!message.isBinary) onMessage?.call(message.text);
    };
  }

  static Future<PeerLink> create(List<Map<String, dynamic>> iceServers, bool forceRelay) async {
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'iceTransportPolicy': forceRelay ? 'relay' : 'all',
      'sdpSemantics': 'unified-plan',
    });
    final channel = await pc.createDataChannel(channelLabel, RTCDataChannelInit()..ordered = true);
    return WebRtcPeerLink._(pc, channel);
  }

  final RTCPeerConnection _pc;
  final RTCDataChannel _channel;
  String? _localSdp, _remoteSdp;
  Timer? _disconnectTimer;
  bool _open = false, _finished = false;

  void _finish(String reason) {
    if (_finished) return;
    _finished = true;
    _disconnectTimer?.cancel();
    onClosed?.call(reason);
  }

  @override
  bool get alive {
    if (_finished) return false;
    final state = _pc.connectionState;
    return state != RTCPeerConnectionState.RTCPeerConnectionStateFailed && state != RTCPeerConnectionState.RTCPeerConnectionStateClosed;
  }

  @override
  Future<String> createOffer() async {
    final offer = await _pc.createOffer({});
    await _pc.setLocalDescription(offer);
    _localSdp = offer.sdp;
    return offer.sdp ?? '';
  }

  @override
  Future<void> setAnswer(String sdp) async {
    await _pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    _remoteSdp = sdp;
  }

  @override
  Future<void> addRemoteCandidate(String candidate, String? mid) async {
    final line = candidate.startsWith('a=') ? candidate.substring(2) : candidate;
    // The protocol carries only the media id. Android's flutter_webrtc also wants the m-line index, so take it from the
    // PC's answer.
    final effectiveMid = mid ?? midForMLineIndex(_remoteSdp, 0) ?? '0';
    await _pc.addCandidate(RTCIceCandidate(line, effectiveMid, mLineIndexForMid(_remoteSdp, effectiveMid)));
  }

  @override
  void send(String text) {
    if (_open && !_finished) _channel.send(RTCDataChannelMessage(text));
  }

  @override
  Future<NetworkPath> path() async {
    try {
      final reports = await _pc.getStats();
      final byId = {for (final report in reports) report.id: report};
      String? pairId;
      for (final report in reports) {
        if (report.type == 'transport' && report.values['selectedCandidatePairId'] is String) {
          pairId = report.values['selectedCandidatePairId'] as String;
        }
      }
      StatsReport? pair = pairId == null ? null : byId[pairId];
      if (pair == null) {
        for (final report in reports) {
          if (report.type != 'candidate-pair') continue;
          final values = report.values;
          if (values['selected'] == true || (values['state'] == 'succeeded' && values['nominated'] == true)) {
            pair = report;
            break;
          }
        }
      }
      if (pair == null) return NetworkPath.unknown;
      final local = byId[pair.values['localCandidateId']];
      final remote = byId[pair.values['remoteCandidateId']];
      String? text(StatsReport? report, String key) => report?.values[key] is String ? report!.values[key] as String : null;
      return classifyPath(
        text(local, 'candidateType'),
        text(remote, 'candidateType'),
        localAddress: text(local, 'address') ?? text(local, 'ip'),
        remoteAddress: text(remote, 'address') ?? text(remote, 'ip'),
      );
    } catch (_) {
      return NetworkPath.unknown;
    }
  }

  @override
  Future<void> close() async {
    _finished = true;
    _disconnectTimer?.cancel();
    onLocalCandidate = null;
    onOpen = null;
    onMessage = null;
    onClosed = null;
    try {
      await _channel.close();
    } catch (_) {}
    try {
      await _pc.close();
    } catch (_) {}
    try {
      await _pc.dispose();
    } catch (_) {}
  }
}

/// [SignalingSocket] over web_socket_channel.
class WebSocketSignaling implements SignalingSocket {
  WebSocketSignaling._(this._channel) : messages = _channel.stream.where((frame) => frame is String).cast<String>();

  static Future<SignalingSocket> connect(Uri uri) => open(WebSocketChannel.connect(uri));

  /// Waits for [channel] to connect. One that doesn't within [timeout] is closed, and so is one that connects later:
  /// the caller has moved on and nothing would ever read or close it.
  @visibleForTesting
  static Future<SignalingSocket> open(WebSocketChannel channel, {Duration timeout = const Duration(seconds: 15)}) async {
    try {
      await channel.ready.timeout(timeout);
    } catch (_) {
      void close() => unawaited(channel.sink.close().then((_) {}, onError: (_) {}));
      close();
      unawaited(channel.ready.then((_) => close(), onError: (_) {}));
      rethrow;
    }
    return WebSocketSignaling._(channel);
  }

  final WebSocketChannel _channel;
  @override
  final Stream<String> messages;

  @override
  void send(String text) => _channel.sink.add(text);

  @override
  Future<void> close() async {
    try {
      await _channel.sink.close();
    } catch (_) {}
  }
}
