import 'dart:async';
import 'dart:typed_data';

/// How the link reaches the PC, from the selected ICE candidate pair.
enum NetworkPath {
  unknown,

  /// Both ends on the local network (host candidates, or peer-reflexive ones with private addresses).
  home,

  /// Directly across the internet (server-reflexive candidates).
  away,

  /// Through the TURN relay.
  relayed,
}

/// The room server's WebSocket, as text frames.
abstract class SignalingSocket {
  Stream<String> get messages;
  void send(String text);
  Future<void> close();
}

typedef SocketConnector = Future<SignalingSocket> Function(Uri uri);

/// One WebRTC peer connection with its `remote-v1` data channel.
abstract class PeerLink {
  /// Creates the offer, sets it as the local description and returns its SDP.
  Future<String> createOffer();
  Future<void> setAnswer(String sdp);
  Future<void> addRemoteCandidate(String candidate, String? mid);
  void send(String text);

  /// Which path the link uses now. [NetworkPath.unknown] until ICE has picked a pair.
  Future<NetworkPath> path();

  /// Whether the peer connection is still usable.
  bool get alive;
  Future<void> close();

  /// A local ICE candidate line (without `a=`) and its media id.
  void Function(String candidate, String mid)? onLocalCandidate;
  void Function()? onOpen;
  void Function(String text)? onMessage;

  /// The link is gone (channel closed, ICE failed or stayed disconnected). Called at most once.
  void Function(String reason)? onClosed;

  // The `media-v1` channel beside `remote-v1`, for video and picture bytes. A link without one never opens it.

  /// Sends a text message on the media channel.
  void sendMedia(String text) {}
  void Function()? onMediaOpen;
  void Function(Uint8List data)? onMediaBinary;
  void Function(String text)? onMediaText;

  /// The media channel closed, as it does at once on a PC that doesn't know it.
  void Function()? onMediaClosed;
}

typedef PeerFactory = Future<PeerLink> Function(List<Map<String, dynamic>> iceServers, bool forceRelay);

/// Classifies a candidate pair by the two candidates' types and addresses.
NetworkPath classifyPath(String? localType, String? remoteType, {String? localAddress, String? remoteAddress}) {
  if (localType == null || remoteType == null) return NetworkPath.unknown;
  if (localType == 'relay' || remoteType == 'relay') return NetworkPath.relayed;
  if (localType == 'srflx' || remoteType == 'srflx') return NetworkPath.away;
  // Host candidates with global addresses (IPv6 on a mobile network, say) still cross the internet.
  bool local(String type, String? address) =>
      (type == 'host' && (address == null || address.isEmpty || isPrivateAddress(address))) ||
      (type == 'prflx' && isPrivateAddress(address));
  if (local(localType, localAddress) && local(remoteType, remoteAddress)) return NetworkPath.home;
  return NetworkPath.away;
}

/// Private, link-local, loopback and unique-local addresses, and mDNS host names.
bool isPrivateAddress(String? address) {
  if (address == null || address.isEmpty) return false;
  final a = address.toLowerCase();
  if (a.endsWith('.local')) return true;
  if (a.contains(':')) {
    return a == '::1' || a.startsWith('fe80:') || a.startsWith('fc') || a.startsWith('fd');
  }
  final parts = a.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((p) => p == null)) return false;
  final p0 = parts[0]!, p1 = parts[1]!;
  return p0 == 10 || p0 == 127 || (p0 == 172 && p1 >= 16 && p1 <= 31) || (p0 == 192 && p1 == 168) || (p0 == 169 && p1 == 254);
}

/// The index of the m-section with media id [mid] in [sdp], or 0 when it isn't there.
int mLineIndexForMid(String? sdp, String? mid) {
  if (sdp == null || mid == null) return 0;
  var index = -1;
  for (final raw in sdp.split('\n')) {
    final line = raw.trimRight();
    if (line.startsWith('m=')) index++;
    if (line.startsWith('a=mid:') && line.substring(6) == mid) return index < 0 ? 0 : index;
  }
  return 0;
}

/// The media id of m-section [index] in [sdp], or null.
String? midForMLineIndex(String? sdp, int? index) {
  if (sdp == null || index == null) return null;
  var current = -1;
  for (final raw in sdp.split('\n')) {
    final line = raw.trimRight();
    if (line.startsWith('m=')) current++;
    if (current == index && line.startsWith('a=mid:')) return line.substring(6);
  }
  return null;
}
