import 'package:blackpearl_mobile/protocol/pair_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const pc = '0123456789ABCDEF0123456789ABCDEF';
  const code = 'ffeeddccbbaa99887766554433221100';

  test('parses a link as the PC writes it', () {
    final link = PairLinkParser.parse(
      'blackpearl://pair?v=1&pc=$pc&code=$code&server=${Uri.encodeComponent('https://rooms.example.com')}&name=${Uri.encodeComponent('Living room PC')}',
    );
    expect(link.pcId, pc);
    expect(link.code, code);
    expect(link.server, 'https://rooms.example.com');
    expect(link.name, 'Living room PC');
  });

  test('decodes percent-encoded names and servers with paths and ports', () {
    final link = PairLinkParser.parse(
      '  blackpearl://pair?v=1&pc=${pc.toLowerCase()}&code=${code.toUpperCase()}'
      '&server=https%3A%2F%2Fexample.com%3A8443%2Frooms&name=%D0%93%D0%BE%D1%81%D1%82%D0%B8%D0%BD%D0%B0%D1%8F%20%26%20%E2%98%85\n',
    );
    expect(link.pcId, pc, reason: 'the PC id is upper case on the wire');
    expect(link.code, code, reason: 'hex compares case-insensitively; keep one form');
    expect(link.server, 'https://example.com:8443/rooms');
    expect(link.name, 'Гостиная & ★');
  });

  test('a missing name gets a default', () {
    expect(PairLinkParser.parse('blackpearl://pair?v=1&pc=$pc&code=$code&server=https%3A%2F%2Fa.example').name, 'BlackPearl PC');
  });

  test('scheme and host are case-insensitive', () {
    expect(PairLinkParser.tryParse('BlackPearl://PAIR?v=1&pc=$pc&code=$code&server=https%3A%2F%2Fa.example'), isNotNull);
  });

  group('rejects', () {
    void rejects(String text, String messagePart) {
      expect(
        () => PairLinkParser.parse(text),
        throwsA(isA<PairLinkException>().having((e) => e.message, 'message', contains(messagePart))),
      );
    }

    test('other links', () {
      rejects('https://example.com', "isn't a BlackPearl pairing link");
      rejects('blackpearl://room?v=1', "isn't a BlackPearl pairing link");
      rejects('just some text', "isn't a BlackPearl pairing link");
    });

    test('other versions', () {
      rejects('blackpearl://pair?v=2&pc=$pc&code=$code&server=https%3A%2F%2Fa.example', 'Update BlackPearl Mobile');
      rejects('blackpearl://pair?v=0&pc=$pc&code=$code&server=https%3A%2F%2Fa.example', 'Update BlackPearl on the PC');
    });

    test('missing or malformed fields', () {
      rejects('blackpearl://pair?pc=$pc&code=$code&server=https%3A%2F%2Fa.example', 'incomplete');
      rejects('blackpearl://pair?v=1&code=$code&server=https%3A%2F%2Fa.example', 'incomplete');
      rejects('blackpearl://pair?v=1&pc=${pc.substring(1)}&code=$code&server=https%3A%2F%2Fa.example', 'incomplete');
      rejects('blackpearl://pair?v=1&pc=$pc&code=${code}00&server=https%3A%2F%2Fa.example', 'incomplete');
      rejects('blackpearl://pair?v=1&pc=$pc&code=zzeeddccbbaa99887766554433221100&server=https%3A%2F%2Fa.example', 'incomplete');
      rejects('blackpearl://pair?v=1&pc=$pc&code=$code', 'incomplete');
      rejects('blackpearl://pair?v=1&pc=$pc&code=$code&server=ftp%3A%2F%2Fa.example', "isn't a web address");
      rejects('blackpearl://pair?v=1&pc=$pc&code=$code&server=rooms.example.com', "isn't a web address");
    });
  });

  group('remote socket address', () {
    test('https becomes wss and http becomes ws', () {
      expect(remoteSocketUri('https://rooms.example.com').toString(), 'wss://rooms.example.com/remote');
      expect(remoteSocketUri('http://192.168.1.5:5000').toString(), 'ws://192.168.1.5:5000/remote');
    });

    test('keeps a base path and drops trailing slashes, queries and fragments', () {
      expect(remoteSocketUri('https://example.com/rooms/').toString(), 'wss://example.com/rooms/remote');
      expect(remoteSocketUri('https://example.com/?x=1#y').toString(), 'wss://example.com/remote');
      expect(remoteSocketUri('https://example.com:8443').toString(), 'wss://example.com:8443/remote');
    });

    test('refuses other schemes', () {
      expect(() => remoteSocketUri('ftp://example.com'), throwsFormatException);
    });
  });
}
