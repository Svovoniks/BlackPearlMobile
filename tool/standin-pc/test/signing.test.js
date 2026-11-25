// The test vectors of PHONE-REMOTE.md, "Signed signals".
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sign, verify, pcIdOf, lanSession, isLanSession, randomHex } from '../lib/signing.js';

const vectors = [
  ['000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f', 'phone', 'a1b2c3d4e5f60718a1b2c3d4e5f60718', '0123456789abcdef0123456789abcdef', 'sdp', '{"type":"offer","sdp":"v=0"}', 'AHCUPPyOcWPNmRtEBJ6D5PQUJwF9CV5-GHlhUpfTkX8'],
  ['ffeeddccbbaa99887766554433221100', 'pc', 'pair', '0123456789abcdef0123456789abcdef', 'ice', '{"candidate":"candidate:1 1 UDP 2122317823 192.168.1.20 50000 typ host","mid":"0"}', 'bIGb4K6s3ztFQAOUL2Q3Oof397tsk3TiGq_W2ZB3I_I'],
  ['000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f', 'phone-lan', 'a1b2c3d4e5f60718a1b2c3d4e5f60718', '0011223344556677d1e4a9c03b5f7e28', 'sdp', '{"type":"offer","sdp":"v=0"}', 'GdkJyJCxBUGJpiHHL2urH73n_M2RuZIlVaNTYTYwyhU'],
  ['000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f', 'pc-lan', 'a1b2c3d4e5f60718a1b2c3d4e5f60718', '0011223344556677d1e4a9c03b5f7e28', 'sdp', '{"type":"answer","sdp":"v=0"}', '8PfaZ2C-qbq-HCuNntwQO9rtwXUkaGyZa_cDuwxK3EI'],
];

test('signatures match the spec test vectors', () => {
  for (const [key, direction, phone, session, kind, payload, auth] of vectors) {
    assert.equal(sign(key, direction, phone, session, kind, payload), auth);
    assert.ok(verify(key, direction, phone, session, kind, payload, auth));
    assert.ok(verify(key.toUpperCase(), direction, phone, session, kind, payload, auth), 'hex keys compare case-insensitively');
    assert.ok(!verify(key, direction === 'phone' ? 'pc' : 'phone', phone, session, kind, payload, auth), 'another direction fails');
    assert.ok(!verify(key, direction, phone, session, kind, payload + ' ', auth), 'another payload fails');
    assert.ok(!verify(key, direction, phone, session, kind, payload, ''), 'an empty auth fails');
  }
});

test('the PC id is the first 32 upper-case hex characters of SHA-256(host key)', () => {
  const id = pcIdOf('a'.repeat(64));
  assert.match(id, /^[0-9A-F]{32}$/);
});

test('home-network session ids are recognised by their host key only', () => {
  const hostKey = randomHex(32);
  const session = lanSession(hostKey);
  assert.match(session, /^[0-9a-f]{32}$/);
  assert.ok(isLanSession(hostKey, session));
  assert.ok(isLanSession(hostKey, session.toUpperCase()));
  assert.ok(!isLanSession(randomHex(32), session));
  assert.ok(!isLanSession(hostKey, randomHex(16)));
});
