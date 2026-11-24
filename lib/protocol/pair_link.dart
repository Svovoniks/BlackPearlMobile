import 'signing.dart';

/// A parsed `blackpearl://pair?...` link (PHONE-REMOTE.md, "Pairing link").
class PairLink {
  const PairLink({required this.pcId, required this.code, required this.server, required this.name});

  /// Upper case, 32 hex characters.
  final String pcId;

  /// 32 hex characters: the 16-byte key for the pairing session.
  final String code;

  /// The room server's base URL, such as `https://rooms.example.com`.
  final String server;

  final String name;

  static const int version = 1;
}

/// Why a link couldn't be used, as a sentence to show.
class PairLinkException implements Exception {
  const PairLinkException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PairLinkParser {
  PairLinkParser._();

  /// Parses pasted or scanned text. Surrounding whitespace is ignored.
  static PairLink parse(String text) {
    final trimmed = text.trim();
    final Uri uri;
    try {
      uri = Uri.parse(trimmed);
    } on FormatException {
      throw const PairLinkException("That isn't a BlackPearl pairing link.");
    }
    if (uri.scheme.toLowerCase() != 'blackpearl' || uri.host.toLowerCase() != 'pair') {
      throw const PairLinkException("That isn't a BlackPearl pairing link.");
    }
    final query = uri.queryParameters;
    final versionText = query['v'];
    final version = int.tryParse(versionText ?? '');
    if (version == null) throw const PairLinkException("That pairing link is incomplete. Copy it again from the PC.");
    if (version != PairLink.version) {
      throw PairLinkException(
        version > PairLink.version
            ? 'That PC uses a newer version of the phone remote. Update BlackPearl Mobile.'
            : 'That PC uses an older version of the phone remote. Update BlackPearl on the PC.',
      );
    }
    final pc = query['pc'], code = query['code'], server = query['server'];
    if (!Signing.isHex(pc, 32) || !Signing.isHex(code, 32) || server == null || server.isEmpty) {
      throw const PairLinkException('That pairing link is incomplete. Copy it again from the PC.');
    }
    final Uri serverUri;
    try {
      serverUri = Uri.parse(server);
    } on FormatException {
      throw const PairLinkException("The room server in that link isn't a web address.");
    }
    if ((serverUri.scheme != 'https' && serverUri.scheme != 'http') || serverUri.host.isEmpty) {
      throw const PairLinkException("The room server in that link isn't a web address.");
    }
    final name = (query['name'] ?? '').trim();
    return PairLink(pcId: pc!.toUpperCase(), code: code!.toLowerCase(), server: server, name: name.isEmpty ? 'BlackPearl PC' : name);
  }

  static PairLink? tryParse(String text) {
    try {
      return parse(text);
    } on PairLinkException {
      return null;
    }
  }
}

/// The `/remote` WebSocket address for a room server base URL: https becomes wss, http becomes ws,
/// and `/remote` is added to the base path.
Uri remoteSocketUri(String server) {
  final base = Uri.parse(server.trim());
  final scheme = base.scheme == 'https'
      ? 'wss'
      : base.scheme == 'http'
      ? 'ws'
      : throw FormatException('Not a web address', server);
  var path = base.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return Uri(
    scheme: scheme,
    userInfo: base.userInfo.isEmpty ? null : base.userInfo,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: '$path/remote',
  );
}

/// A PC's own `/remote` WebSocket on its home network (PHONE-REMOTE.md, "On the home network"): plain `ws`, as the
/// signals on it are signed.
Uri remoteLanUri(String address, int port) => Uri(scheme: 'ws', host: address, port: port, path: '/remote');
