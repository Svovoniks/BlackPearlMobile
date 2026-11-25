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

/// Makes a [PeerLink] with the room server's STUN and TURN servers, as libdatachannel URLs (see `toIceServerUrls`).
typedef PeerFactory = Future<PeerLink> Function(List<String> iceServers, bool forceRelay);

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

/// The type (`host`, `srflx`, `prflx`, `relay`) and address of an ICE candidate line, with or without `a=`, or null
/// for a line that isn't one.
({String type, String address})? parseCandidate(String? line) {
  if (line == null) return null;
  var text = line.trim();
  if (text.startsWith('a=')) text = text.substring(2);
  if (!text.startsWith('candidate:')) return null;
  // candidate:<foundation> <component> <transport> <priority> <address> <port> typ <type> …
  final fields = text.substring('candidate:'.length).split(' ').where((f) => f.isNotEmpty).toList();
  if (fields.length < 8 || fields[6] != 'typ') return null;
  return (type: fields[7], address: fields[4]);
}

/// The phone's Wi-Fi or Ethernet network, for reaching the PC on its home network (PHONE-REMOTE.md, "On the home
/// network").
abstract class LocalNetworkAccess {
  /// Whether the phone is on Wi-Fi or Ethernet now.
  Future<bool> available();

  /// Runs [attempt] with the sockets it opens going out on that network, also while Android has made mobile data the
  /// default because the Wi-Fi has no internet (which is when the room server can't introduce the two). Sockets opened
  /// in it stay on that network afterwards.
  Future<T> run<T>(Future<T> Function() attempt);
}
