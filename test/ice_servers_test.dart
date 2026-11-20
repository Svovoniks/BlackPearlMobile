import 'package:blackpearl_mobile/connection/transport.dart';
import 'package:blackpearl_mobile/protocol/ice_servers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stun passes through', () {
    expect(toWebRtcIceServer('stun:stun.cloudflare.com:3478'), {'urls': 'stun:stun.cloudflare.com:3478'});
    expect(toWebRtcIceServer('stun://stun.example.com:3478'), {'urls': 'stun:stun.example.com:3478'});
  });

  test('libdatachannel turn urls become urls, username and credential', () {
    expect(toWebRtcIceServer('turn://user:pass@turn.example.com:3478?transport=udp'), {
      'urls': 'turn:turn.example.com:3478?transport=udp',
      'username': 'user',
      'credential': 'pass',
    });
    expect(toWebRtcIceServer('turns://u:p@turn.example.com:443?transport=tcp'), {
      'urls': 'turns:turn.example.com:443?transport=tcp',
      'username': 'u',
      'credential': 'p',
    });
  });

  test('user and password are percent-decoded', () {
    // As the server writes them: Uri.EscapeDataString of each part.
    expect(toWebRtcIceServer('turn://g0a1%3Ab2%40c3:pw%2Fwith%3Dsymbols%2B%25%3A%40@turn.example.com:3478?transport=udp'), {
      'urls': 'turn:turn.example.com:3478?transport=udp',
      'username': 'g0a1:b2@c3',
      'credential': 'pw/with=symbols+%:@',
    });
  });

  test('turn without credentials, unknown schemes and junk are skipped', () {
    expect(toWebRtcIceServer('turn:turn.example.com:3478'), isNull);
    expect(toWebRtcIceServer('https://example.com'), isNull);
    expect(toWebRtcIceServer(''), isNull);
    expect(toWebRtcIceServer('turn://'), isNull);
    expect(toWebRtcIceServer('turn://u:%zz@host:3478'), isNull);
  });

  test('a list keeps order and drops what it cannot use', () {
    final servers = toWebRtcIceServers([
      'stun:stun.cloudflare.com:3478',
      'turn://a:b@turn.cloudflare.com:3478?transport=udp',
      'nonsense',
      'turns://a:b@turn.cloudflare.com:5349?transport=tcp',
    ]);
    expect(servers.map((s) => s['urls']), [
      'stun:stun.cloudflare.com:3478',
      'turn:turn.cloudflare.com:3478?transport=udp',
      'turns:turn.cloudflare.com:5349?transport=tcp',
    ]);
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

  test('media ids map to m-line indexes and back', () {
    const sdp =
        'v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=mid:0\r\nm=audio 9 RTP\r\na=mid:x\r\n';
    expect(mLineIndexForMid(sdp, '0'), 0);
    expect(mLineIndexForMid(sdp, 'x'), 1);
    expect(mLineIndexForMid(sdp, 'missing'), 0);
    expect(midForMLineIndex(sdp, 1), 'x');
    expect(midForMLineIndex(sdp, 5), isNull);
  });
}
