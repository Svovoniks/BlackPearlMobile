import 'package:blackpearl_mobile/protocol/signing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'spec_vectors.dart';

void main() {
  group('PHONE-REMOTE.md test vectors', () {
    // Read from the protocol file, so a change there that this app doesn't follow fails here.
    final vectors = readSpecVectors();

    test('the spec has both vectors', () {
      expect(vectors, hasLength(2));
      expect(vectors[0].keyHex, hexOf(List.generate(32, (i) => i)), reason: 'a 32-byte phone secret');
      expect(vectors[1].keyHex, hexOf(List.generate(16, (i) => 255 - 17 * i)), reason: 'a 16-byte pairing code');
    });

    for (final (index, vector) in vectors.indexed) {
      test('vector ${index + 1}: ${vector.parts[1]} ${vector.parts[4]} as ${vector.parts[2]}', () {
        final [prefix, direction, phone, session, kind, payload] = vector.parts;
        expect(prefix, Signing.prefix);
        expect(Signing.canonical(direction, phone, session, kind, payload), vector.text);
        expect(Signing.sign(vector.keyHex, direction, phone, session, kind, payload), vector.auth);
        expect(Signing.verify(vector.keyHex, direction, phone, session, kind, payload, vector.auth), isTrue);
        expect(
          Signing.verify(vector.keyHex.toUpperCase(), direction, phone, session, kind, payload, vector.auth),
          isTrue,
          reason: 'hex keys compare case-insensitively',
        );
        final signal = SignedSignal(phone: phone, session: session, kind: kind, payload: payload, auth: vector.auth);
        expect(
          direction == 'pc' ? signal.verifyFromPc(vector.keyHex) : !signal.verifyFromPc(vector.keyHex),
          isTrue,
          reason: 'only the PC direction verifies as from the PC',
        );
        if (direction == 'phone') {
          expect(
            SignedSignal.fromPhone(keyHex: vector.keyHex, phone: phone, session: session, kind: kind, payload: payload).auth,
            vector.auth,
          );
        }
      });
    }
  });

  group('verify', () {
    final key = hexOf(List.generate(16, (i) => 255 - 17 * i));
    const session = '0123456789abcdef0123456789abcdef';
    final auth = Signing.sign(key, 'pc', 'pair', session, 'sdp', '{"type":"answer","sdp":"v=0"}');

    test('accepts the right signature', () {
      expect(Signing.verify(key, 'pc', 'pair', session, 'sdp', '{"type":"answer","sdp":"v=0"}', auth), isTrue);
    });

    test('rejects a changed payload, kind, session, direction or key', () {
      expect(Signing.verify(key, 'pc', 'pair', session, 'sdp', '{"type":"answer","sdp":"v=1"}', auth), isFalse);
      expect(Signing.verify(key, 'pc', 'pair', session, 'ice', '{"type":"answer","sdp":"v=0"}', auth), isFalse);
      expect(Signing.verify(key, 'pc', 'pair', '1123456789abcdef0123456789abcdef', 'sdp', '{"type":"answer","sdp":"v=0"}', auth), isFalse);
      expect(
        Signing.verify(key, 'phone', 'pair', session, 'sdp', '{"type":"answer","sdp":"v=0"}', auth),
        isFalse,
        reason: "the phone's own signature must not be reflected back as the PC's",
      );
      expect(
        Signing.verify('00eeddccbbaa99887766554433221100', 'pc', 'pair', session, 'sdp', '{"type":"answer","sdp":"v=0"}', auth),
        isFalse,
      );
    });

    test('rejects empty, malformed and truncated auth', () {
      expect(Signing.verify(key, 'pc', 'pair', session, 'sdp', 'x', ''), isFalse);
      expect(Signing.verify(key, 'pc', 'pair', session, 'sdp', 'x', '!!!'), isFalse);
      expect(Signing.verify(key, 'pc', 'pair', session, 'sdp', '{"type":"answer","sdp":"v=0"}', auth.substring(0, 20)), isFalse);
    });

    test('auth has no padding and is url-safe', () {
      for (var i = 0; i < 50; i++) {
        final a = Signing.sign(key, 'phone', 'pair', session, 'ice', 'payload $i');
        expect(a, isNot(contains('=')));
        expect(a, isNot(contains('+')));
        expect(a, isNot(contains('/')));
        expect(a.length, 43);
      }
    });
  });

  test('signed signal round trip', () {
    final signal = SignedSignal.fromPhone(
      keyHex: hexOf(List.generate(32, (i) => i)),
      phone: 'a1b2c3d4e5f60718a1b2c3d4e5f60718',
      session: '0123456789abcdef0123456789abcdef',
      kind: 'sdp',
      payload: '{"type":"offer","sdp":"v=0"}',
    );
    final parsed = SignedSignal.tryParse(signal.encode())!;
    expect(parsed.phone, signal.phone);
    expect(parsed.payload, signal.payload);
    expect(parsed.auth, signal.auth);
    expect(SignedSignal.tryParse('not json'), isNull);
    expect(SignedSignal.tryParse('{"phone":"pair"}'), isNull);
  });

  test('random session ids are 32 lower-case hex characters', () {
    final id = Signing.randomHex(16);
    expect(Signing.isHex(id, 32), isTrue);
    expect(id, id.toLowerCase());
  });
}
