/// Error text before it leaves the phone in a crash report. Messages can quote files and folders (which name people's
/// videos and accounts), web and network addresses (servers, rooms, keys in queries) and long ids (pairing secrets,
/// keys); each is replaced by what it was. The same rules as the desktop app's ReportText, in the same order.
abstract final class ReportText {
  static final _webAddress = RegExp(r'''\b[a-z][a-z0-9+.-]*://[^\s"'<>]+''', caseSensitive: false);
  static final _uncPath = RegExp(r'''\\\\[^\\\s"'<>|]+\\[^\r\n"'<>|*?]*''', caseSensitive: false);
  static final _drivePath = RegExp(r'''\b[a-z]:[\\/][^\r\n"'<>|*?]*''', caseSensitive: false);
  static final _unixPath = RegExp(r'''(?<![\w.])/(?:home|Users|mnt|media|storage|sdcard|data|tmp|var|opt|srv|root)/[^\r\n"'<>|*?]*''');
  static final _networkAddress = RegExp(
    r'\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b|\b(?:[0-9a-f]{1,4}:){4,7}[0-9a-f]{1,4}\b|\b[0-9a-f]{1,4}(?::[0-9a-f]{1,4})*::(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4})*)?',
    caseSensitive: false,
  );
  static final _longId = RegExp(r'\b[0-9a-f]{20,}\b|\b[A-Za-z0-9_-]{32,}\b', caseSensitive: false);

  static String scrub(String text) {
    if (text.isEmpty) return text;
    text = text.replaceAll(_webAddress, '<url>');
    text = text.replaceAll(_uncPath, '<path>');
    text = text.replaceAll(_drivePath, '<path>');
    text = text.replaceAll(_unixPath, '<path>');
    text = text.replaceAll(_networkAddress, '<address>');
    return text.replaceAll(_longId, '<id>');
  }

  static String? scrubOrNull(String? text) => text == null ? null : scrub(text);
}
