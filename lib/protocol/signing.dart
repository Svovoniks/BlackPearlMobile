import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Signed signaling (PHONE-REMOTE.md, "Signed signals").
///
/// Every signal carries an HMAC-SHA256 over
/// `bp-remote-v1\n<direction>\n<phone>\n<session>\n<kind>\n<payload>`, keyed with the
/// phone secret's bytes or, while pairing, the pairing code's bytes.
class Signing {
  Signing._();

  static const String prefix = 'bp-remote-v1';

  /// The exact text that is signed.
  static String canonical(String direction, String phone, String session, String kind, String payload) =>
      '$prefix\n$direction\n$phone\n$session\n$kind\n$payload';

  /// `auth` for a signal: HMAC-SHA256 as base64url without padding.
  static String sign(String keyHex, String direction, String phone, String session, String kind, String payload) {
    final mac = Hmac(sha256, hexToBytes(keyHex)).convert(utf8.encode(canonical(direction, phone, session, kind, payload)));
    return base64UrlNoPadding(mac.bytes);
  }

  /// Whether [auth] is the right signature, compared in constant time.
  static bool verify(String keyHex, String direction, String phone, String session, String kind, String payload, String auth) {
    if (auth.isEmpty) return false;
    final Uint8List supplied;
    try {
      supplied = decodeBase64Url(auth);
    } on FormatException {
      return false;
    }
    final expected = Hmac(sha256, hexToBytes(keyHex)).convert(utf8.encode(canonical(direction, phone, session, kind, payload))).bytes;
    if (supplied.length != expected.length) return false;
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected[i] ^ supplied[i];
    }
    return difference == 0;
  }

  static String base64UrlNoPadding(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List decodeBase64Url(String text) {
    final padded = text.padRight((text.length + 3) ~/ 4 * 4, '=');
    return base64Url.decode(padded);
  }

  static bool isHex(String? text, int length) => text != null && text.length == length && RegExp(r'^[0-9a-fA-F]*$').hasMatch(text);

  static Uint8List hexToBytes(String hex) {
    if (hex.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(hex)) {
      throw FormatException('Not a hex key', hex);
    }
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  /// A new random lower-case hex string of [bytes] bytes, for session ids.
  static String randomHex(int bytes, [Random? random]) {
    final source = random ?? Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buffer.write(source.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

/// One signed signaling message, as carried in the envelope's `data`.
class SignedSignal {
  const SignedSignal({required this.phone, required this.session, required this.kind, required this.payload, required this.auth});

  final String phone;
  final String session;
  final String kind;
  final String payload;
  final String auth;

  /// Builds and signs a signal the phone sends.
  factory SignedSignal.fromPhone({
    required String keyHex,
    required String phone,
    required String session,
    required String kind,
    required String payload,
  }) => SignedSignal(
    phone: phone,
    session: session,
    kind: kind,
    payload: payload,
    auth: Signing.sign(keyHex, 'phone', phone, session, kind, payload),
  );

  /// Whether the PC signed this with [keyHex].
  bool verifyFromPc(String keyHex) => Signing.verify(keyHex, 'pc', phone, session, kind, payload, auth);

  Map<String, dynamic> toJson() => {'phone': phone, 'session': session, 'kind': kind, 'payload': payload, 'auth': auth};

  String encode() => jsonEncode(toJson());

  /// Parses a signal, or returns null for anything malformed.
  static SignedSignal? tryParse(String? text) {
    if (text == null || text.isEmpty) return null;
    try {
      final value = jsonDecode(text);
      if (value is! Map) return null;
      final phone = value['phone'], session = value['session'], kind = value['kind'], payload = value['payload'];
      final auth = value['auth'] ?? '';
      if (phone is! String || session is! String || kind is! String || payload is! String || auth is! String) return null;
      return SignedSignal(phone: phone, session: session, kind: kind, payload: payload, auth: auth);
    } on FormatException {
      return null;
    }
  }
}
