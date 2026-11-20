/// Converts the room server's ICE server list to WebRTC's `RTCIceServer` form.
///
/// The server hands out URLs in libdatachannel's style, with the credentials in the URL:
/// `turn://user:pass@host:port?transport=udp`, where user and password are percent-encoded.
/// WebRTC wants `{urls: 'turn:host:port?transport=udp', username: 'user', credential: 'pass'}`.
/// STUN URLs pass through as `{urls: 'stun:host:port'}`. Anything else is skipped.
List<Map<String, dynamic>> toWebRtcIceServers(Iterable<String> urls) {
  final result = <Map<String, dynamic>>[];
  for (final url in urls) {
    final server = toWebRtcIceServer(url);
    if (server != null) result.add(server);
  }
  return result;
}

Map<String, dynamic>? toWebRtcIceServer(String url) {
  final text = url.trim();
  final colon = text.indexOf(':');
  if (colon <= 0) return null;
  final scheme = text.substring(0, colon).toLowerCase();
  if (scheme != 'stun' && scheme != 'stuns' && scheme != 'turn' && scheme != 'turns') return null;
  var rest = text.substring(colon + 1);
  if (rest.startsWith('//')) rest = rest.substring(2);
  if (rest.isEmpty) return null;

  // Split off the query (?transport=…) before looking for credentials, so a '@' or ':' in it can't confuse us.
  final queryStart = rest.indexOf('?');
  final authority = queryStart < 0 ? rest : rest.substring(0, queryStart);
  final query = queryStart < 0 ? '' : rest.substring(queryStart);

  String? username, credential;
  var hostPort = authority;
  final at = authority.lastIndexOf('@');
  if (at >= 0) {
    final userInfo = authority.substring(0, at);
    hostPort = authority.substring(at + 1);
    final separator = userInfo.indexOf(':');
    try {
      username = Uri.decodeComponent(separator < 0 ? userInfo : userInfo.substring(0, separator));
      credential = separator < 0 ? '' : Uri.decodeComponent(userInfo.substring(separator + 1));
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
  }
  while (hostPort.endsWith('/')) {
    hostPort = hostPort.substring(0, hostPort.length - 1);
  }
  if (hostPort.isEmpty) return null;

  final isTurn = scheme.startsWith('turn');
  final server = <String, dynamic>{'urls': '$scheme:$hostPort${isTurn ? query : ''}'};
  if (isTurn) {
    // A TURN server without credentials can't allocate anything.
    if (username == null || username.isEmpty) return null;
    server['username'] = username;
    server['credential'] = credential ?? '';
  }
  return server;
}
