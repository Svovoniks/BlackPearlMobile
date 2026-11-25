/// Checks the room server's ICE server list and writes each one the way libdatachannel reads it.
///
/// The server hands out URLs in libdatachannel's style, with the credentials in the URL:
/// `turn://user:pass@host:port?transport=udp`, where user and password are percent-encoded. Each comes back as
/// `turn:user:pass@host:port?transport=udp`, user and password percent-encoded again, and STUN URLs as
/// `stun:host:port`. TURN without credentials, unknown schemes and URLs that don't parse are skipped: libdatachannel
/// would refuse the whole configuration over one of them.
List<String> toIceServerUrls(Iterable<String> urls) {
  final result = <String>[];
  for (final url in urls) {
    final server = toIceServerUrl(url);
    if (server != null) result.add(server);
  }
  return result;
}

String? toIceServerUrl(String url) {
  final text = url.trim();
  final colon = text.indexOf(':');
  if (colon <= 0) return null;
  final scheme = text.substring(0, colon).toLowerCase();
  // libdatachannel knows no `stuns`.
  if (scheme != 'stun' && scheme != 'turn' && scheme != 'turns') return null;
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
  if (hostPort.isEmpty || hostPort.contains('/')) return null;
  // A port, when there is one, is a number libdatachannel can take.
  final portStart = hostPort.startsWith('[') ? hostPort.indexOf(']:') + 1 : hostPort.lastIndexOf(':');
  if (portStart > 0) {
    final port = int.tryParse(hostPort.substring(portStart + 1));
    if (port == null || port <= 0 || port > 65535) return null;
  }

  if (scheme == 'stun') return '$scheme:$hostPort';
  // A TURN server without credentials can't allocate anything.
  if (username == null || username.isEmpty) return null;
  return '$scheme:${Uri.encodeComponent(username)}:${Uri.encodeComponent(credential ?? '')}@$hostPort$query';
}
