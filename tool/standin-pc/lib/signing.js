// Signed signaling (PHONE-REMOTE.md, "Signed signals").
//
// Every signal carries an HMAC-SHA256 over `bp-remote-v1\n<direction>\n<phone>\n<session>\n<kind>\n<payload>`, keyed
// with the phone secret's bytes or, while pairing, the pairing code's bytes.
import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';

export const prefix = 'bp-remote-v1';

/** The exact text that is signed. */
export function canonical(direction, phone, session, kind, payload) {
  return `${prefix}\n${direction}\n${phone}\n${session}\n${kind}\n${payload}`;
}

export function isHex(text, length) {
  return typeof text === 'string' && text.length === length && /^[0-9a-fA-F]*$/.test(text);
}

function keyBytes(keyHex) {
  if (typeof keyHex !== 'string' || keyHex.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(keyHex)) throw new Error('Not a hex key');
  return Buffer.from(keyHex, 'hex');
}

/** `auth` for a signal: HMAC-SHA256 as base64url without padding. */
export function sign(keyHex, direction, phone, session, kind, payload) {
  return createHmac('sha256', keyBytes(keyHex)).update(canonical(direction, phone, session, kind, payload), 'utf8').digest('base64url');
}

/** Whether `auth` is the right signature, compared in constant time. */
export function verify(keyHex, direction, phone, session, kind, payload, auth) {
  if (typeof auth !== 'string' || auth.length === 0 || !/^[A-Za-z0-9_-]+$/.test(auth)) return false;
  let expected;
  try {
    expected = createHmac('sha256', keyBytes(keyHex)).update(canonical(direction, phone, session, kind, payload), 'utf8').digest();
  } catch {
    return false;
  }
  const supplied = Buffer.from(auth, 'base64url');
  return supplied.length === expected.length && timingSafeEqual(supplied, expected);
}

/** A new random lower-case hex string of `bytes` bytes. */
export function randomHex(bytes) {
  return randomBytes(bytes).toString('hex');
}

/** The PC id: the first 32 characters of the upper-case SHA-256 hex of the host key's UTF-8 bytes. */
export function pcIdOf(hostKey) {
  return createHash('sha256').update(hostKey, 'utf8').digest('hex').toUpperCase().slice(0, 32);
}

/**
 * A session id for the home-network socket (PHONE-REMOTE.md, "Its signatures and session"): 8 random bytes followed by
 * the first 8 bytes of HMAC-SHA256, keyed with the host key's UTF-8 bytes, over `bp-remote-lan\n` and those 8 bytes,
 * as 32 lower-case hex characters.
 */
export function lanSession(hostKey, random = randomBytes(8)) {
  const mac = createHmac('sha256', Buffer.from(hostKey, 'utf8')).update(Buffer.concat([Buffer.from('bp-remote-lan\n', 'utf8'), random])).digest();
  return Buffer.concat([random, mac.subarray(0, 8)]).toString('hex');
}

/** Whether `session` is one this PC handed out on its home-network socket. */
export function isLanSession(hostKey, session) {
  if (!isHex(session, 32)) return false;
  return lanSession(hostKey, Buffer.from(session.slice(0, 16), 'hex')) === session.toLowerCase();
}

/** One signed signal as carried in the envelope's `data`, or null for anything malformed. */
export function parseSignal(text) {
  if (typeof text !== 'string' || text.length === 0) return null;
  try {
    const value = JSON.parse(text);
    if (value === null || typeof value !== 'object') return null;
    const { phone, session, kind, payload } = value;
    const auth = value.auth ?? '';
    if ([phone, session, kind, payload, auth].some((field) => typeof field !== 'string')) return null;
    return { phone, session, kind, payload, auth };
  } catch {
    return null;
  }
}

/** Builds a signed signal's JSON text. */
export function signedSignal(keyHex, direction, phone, session, kind, payload) {
  return JSON.stringify({ phone, session, kind, payload, auth: sign(keyHex, direction, phone, session, kind, payload) });
}
