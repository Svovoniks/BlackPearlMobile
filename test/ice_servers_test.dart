import 'package:blackpearl_mobile/connection/transport.dart';
import 'package:blackpearl_mobile/protocol/ice_servers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stun comes back as libdatachannel takes it', () {
    expect(toIceServerUrl('stun:stun.cloudflare.com:3478'), 'stun:stun.cloudflare.com:3478');
    expect(toIceServerUrl('stun://stun.example.com:3478'), 'stun:stun.example.com:3478');
    expect(toIceServerUrl('STUN:stun.example.com'), 'stun:stun.example.com');
  });

  test('turn keeps its credentials in the url, and its transport', () {
    expect(toIceServerUrl('turn://user:pass@turn.example.com:3478?transport=udp'), 'turn:user:pass@turn.example.com:3478?transport=udp');
    expect(toIceServerUrl('turns://u:p@turn.example.com:443?transport=tcp'), 'turns:u:p@turn.example.com:443?transport=tcp');
  });

  test('user and password stay percent-encoded, so libdatachannel decodes them to what the server meant', () {
    // As the server writes them: Uri.EscapeDataString of each part.
    expect(
      toIceServerUrl('turn://g0a1%3Ab2%40c3:pw%2Fwith%3Dsymbols%2B%25%3A%40@turn.example.com:3478?transport=udp'),
      'turn:g0a1%3Ab2%40c3:pw%2Fwith%3Dsymbols%2B%25%3A%40@turn.example.com:3478?transport=udp',
    );
  });

  test('what libdatachannel would refuse, and turn without credentials, are skipped', () {
    expect(toIceServerUrl('turn:turn.example.com:3478'), isNull);
    expect(toIceServerUrl('https://example.com'), isNull);
    expect(toIceServerUrl(''), isNull);
    expect(toIceServerUrl('turn://'), isNull);
    expect(toIceServerUrl('turn://u:%zz@host:3478'), isNull);
    expect(toIceServerUrl('stuns:stun.example.com:5349'), isNull, reason: 'libdatachannel knows no stuns');
    expect(toIceServerUrl('stun:stun.example.com:port'), isNull);
    expect(toIceServerUrl('stun:stun.example.com:70000'), isNull);
    expect(toIceServerUrl('stun:stun.example.com/path'), isNull);
  });

  test('an IPv6 address keeps its brackets', () {
    expect(toIceServerUrl('stun:[2001:db8::1]:3478'), 'stun:[2001:db8::1]:3478');
    expect(toIceServerUrl('turn://u:p@[2001:db8::1]:3478'), 'turn:u:p@[2001:db8::1]:3478');
  });

  test('a list keeps order and drops what it cannot use', () {
    expect(
      toIceServerUrls([
        'stun:stun.cloudflare.com:3478',
        'turn://a:b@turn.cloudflare.com:3478?transport=udp',
        'nonsense',
        'turns://a:b@turn.cloudflare.com:5349?transport=tcp',
      ]),
      [
        'stun:stun.cloudflare.com:3478',
        'turn:a:b@turn.cloudflare.com:3478?transport=udp',
        'turns:a:b@turn.cloudflare.com:5349?transport=tcp',
      ],
    );
  });

  test('candidate lines give their type and address', () {
    expect(parseCandidate('candidate:1 1 UDP 2122317823 192.168.1.30 50000 typ host'), (type: 'host', address: '192.168.1.30'));
    expect(
      parseCandidate('a=candidate:2 1 UDP 1686052607 203.0.113.4 61000 typ srflx raddr 0.0.0.0 rport 0'),
      (type: 'srflx', address: '203.0.113.4'),
    );
    expect(parseCandidate('candidate:3 1 UDP 16777215 2001:db8::7 3478 typ relay raddr :: rport 0'), (type: 'relay', address: '2001:db8::7'));
    expect(parseCandidate('candidate:1 1 UDP 1 host'), isNull);
    expect(parseCandidate('m=application 9'), isNull);
    expect(parseCandidate(null), isNull);
  });

  group('path classification', () {
    test('host pairs on private addresses are home', () {
      expect(classifyPath('host', 'host', localAddress: '192.168.1.20', remoteAddress: '192.168.1.5'), NetworkPath.home);
      expect(classifyPath('host', 'prflx', localAddress: '10.0.0.3', remoteAddress: '10.0.0.9'), NetworkPath.home);
      expect(classifyPath('host', 'host', localAddress: 'fe80::1', remoteAddress: 'abc.local'), NetworkPath.home);
    });

    test('reflexive pairs are away, relay pairs are relayed', () {
      expect(classifyPath('srflx', 'host', localAddress: '203.0.113.4', remoteAddress: '192.168.1.5'), NetworkPath.away);
      expect(classifyPath('prflx', 'srflx'), NetworkPath.away);
      expect(classifyPath('relay', 'host'), NetworkPath.relayed);
      expect(classifyPath('host', 'relay'), NetworkPath.relayed);
    });

    test('host pairs on public addresses cross the internet', () {
      expect(classifyPath('host', 'host', localAddress: '2a00:1450::1', remoteAddress: '2001:db8::5'), NetworkPath.away);
    });

    test('nothing selected yet is unknown', () {
      expect(classifyPath(null, 'host'), NetworkPath.unknown);
    });
  });
}
