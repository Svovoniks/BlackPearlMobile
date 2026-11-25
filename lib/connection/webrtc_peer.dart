import 'dart:async';

import 'package:blackpearl_datachannel/blackpearl_datachannel.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'transport.dart';

const String channelLabel = 'remote-v1';
const String mediaLabel = 'media-v1';

/// [PeerLink] over libdatachannel (packages/blackpearl_datachannel), as the desktop app's side is.
class WebRtcPeerLink extends PeerLink {
  WebRtcPeerLink._(this._pc, this._channel, this._media) {
    _media.onOpen = () {
      onMediaOpen?.call();
    };
    _media.onClosed = () {
      onMediaClosed?.call();
    };
    _media.onBinary = (data) => onMediaBinary?.call(data);
    _media.onText = (text) => onMediaText?.call(text);
    _pc.onCandidate = (candidate, mid) {
      final line = candidate.startsWith('a=') ? candidate.substring(2) : candidate;
      if (line.isEmpty) return;
      onLocalCandidate?.call(line, mid.isEmpty ? '0' : mid);
    };
    _pc.onDescription = (sdp, type) {
      final waiting = _description;
      if (waiting != null && !waiting.isCompleted) waiting.complete(sdp);
    };
    _pc.onState = (state) {
      switch (state) {
        case RtcState.failed:
          _finish('The connection to the PC failed.');
        case RtcState.closed:
          _finish('The connection to the PC closed.');
        case RtcState.disconnected:
          // ICE often recovers from a short gap by itself; give it a moment before calling the link lost.
          _disconnectTimer ??= Timer(const Duration(seconds: 6), () => _finish('Lost the connection to the PC.'));
        case RtcState.connected:
          _disconnectTimer?.cancel();
          _disconnectTimer = null;
        default:
          break;
      }
    };
    _channel.onOpen = () {
      _open = true;
      onOpen?.call();
    };
    _channel.onClosed = () => _finish('The PC closed the connection.');
    _channel.onText = (text) => onMessage?.call(text);
  }

  static Future<PeerLink> create(List<String> iceServers, bool forceRelay) async {
    final pc = RtcPeer.create(iceServers: iceServers, relayOnly: forceRelay);
    try {
      final channel = pc.createChannel(channelLabel);
      final media = pc.createChannel(mediaLabel);
      return WebRtcPeerLink._(pc, channel, media);
    } catch (_) {
      unawaited(pc.close());
      rethrow;
    }
  }

  /// How long making the offer may take.
  static const offerTimeout = Duration(seconds: 10);

  final RtcPeer _pc;
  final RtcChannel _channel;
  final RtcChannel _media;
  Completer<String>? _description;
  Timer? _disconnectTimer;
  bool _open = false, _finished = false;

  void _finish(String reason) {
    if (_finished) return;
    _finished = true;
    _disconnectTimer?.cancel();
    onClosed?.call(reason);
  }

  @override
  bool get alive => !_finished && !_pc.closed && _pc.state != RtcState.failed && _pc.state != RtcState.closed;

  @override
  Future<String> createOffer() async {
    final description = _description = Completer<String>();
    // The description comes as an event while this runs, and the ICE sockets are open once it returns.
    await _pc.setLocalDescription('offer');
    return description.future.timeout(offerTimeout);
  }

  @override
  Future<void> setAnswer(String sdp) => _pc.setRemoteDescription(sdp, 'answer');

  @override
  Future<void> addRemoteCandidate(String candidate, String? mid) =>
      _pc.addRemoteCandidate(candidate.startsWith('a=') ? candidate.substring(2) : candidate, mid);

  @override
  void send(String text) {
    if (_open && !_finished) _channel.sendText(text);
  }

  @override
  void sendMedia(String text) {
    if (!_finished) _media.sendText(text);
  }

  @override
  Future<NetworkPath> path() async {
    try {
      final pair = await _pc.selectedPair();
      if (pair == null) return NetworkPath.unknown;
      final local = parseCandidate(pair.local), remote = parseCandidate(pair.remote);
      return classifyPath(local?.type, remote?.type, localAddress: local?.address, remoteAddress: remote?.address);
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
    onMediaOpen = null;
    onMediaBinary = null;
    onMediaText = null;
    onMediaClosed = null;
    try {
      await _pc.close();
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
