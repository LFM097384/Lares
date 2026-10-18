// Crypto helpers for the Ember (炉灵) core (node:crypto only, no deps).
import { createHash, createPublicKey, generateKeyPairSync, sign as edSign, verify as edVerify, KeyObject } from 'node:crypto';

// Canonical JSON: object keys sorted recursively (by UTF-16 code unit order, i.e. default sort),
// no whitespace, arrays keep order, undefined-valued keys omitted (as JSON.stringify does).
export function canonicalJSON(v) {
  if (v === null || typeof v !== 'object') {
    if (typeof v === 'number' && !Number.isFinite(v)) throw new TypeError('canonicalJSON: non-finite number');
    return JSON.stringify(v);
  }
  if (Array.isArray(v)) return '[' + v.map((x) => (x === undefined ? 'null' : canonicalJSON(x))).join(',') + ']';
  const keys = Object.keys(v).filter((k) => v[k] !== undefined).sort();
  return '{' + keys.map((k) => JSON.stringify(k) + ':' + canonicalJSON(v[k])).join(',') + '}';
}

export const sha256hex = (data) => createHash('sha256').update(typeof data === 'string' ? Buffer.from(data, 'utf8') : data).digest('hex');

const b64ToUrl = (s) => String(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const urlToB64 = (s) => { const t = String(s).replace(/-/g, '+').replace(/_/g, '/'); return t + '='.repeat((4 - (t.length % 4)) % 4); };

// Accepts: KeyObject (public or private → public), PEM string, or base64/base64url raw 32-byte Ed25519 key.
export function toPublicKey(pubKey) {
  if (pubKey instanceof KeyObject) {
    const k = pubKey.type === 'private' ? createPublicKey(pubKey) : pubKey;
    if (k.asymmetricKeyType !== 'ed25519') throw new Error('not an ed25519 key');
    return k;
  }
  const s = String(pubKey || '').trim();
  if (!s) throw new Error('empty key');
  if (s.startsWith('-----BEGIN')) {
    const k = createPublicKey(s);
    if (k.asymmetricKeyType !== 'ed25519') throw new Error('not an ed25519 key');
    return k;
  }
  const raw = Buffer.from(urlToB64(s), 'base64');
  if (raw.length !== 32) throw new Error('raw ed25519 key must be 32 bytes');
  return createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: b64ToUrl(raw.toString('base64')) }, format: 'jwk' });
}

// Stable identity of a public key: base64 of its raw 32 bytes (used for TOFU comparison).
export function rawPublicKeyB64(pubKey) {
  return urlToB64(toPublicKey(pubKey).export({ format: 'jwk' }).x);
}

// verifyEd25519(pubKey, message:string|Buffer, sigB64) -> boolean. Never throws on bad input.
export function verifyEd25519(pubKey, message, sigB64) {
  try {
    const key = toPublicKey(pubKey);
    const sig = Buffer.from(urlToB64(sigB64), 'base64');
    if (sig.length !== 64) return false;
    return edVerify(null, typeof message === 'string' ? Buffer.from(message, 'utf8') : message, key, sig);
  } catch { return false; }
}

// ---- test helpers ----
export function generateEd25519() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const pubB64 = urlToB64(publicKey.export({ format: 'jwk' }).x);
  return { publicKey, privateKey, pubB64, pem: publicKey.export({ format: 'pem', type: 'spki' }) };
}
export const signEd25519 = (privateKey, message) =>
  edSign(null, typeof message === 'string' ? Buffer.from(message, 'utf8') : message, privateKey).toString('base64');

// The exact bytes an approver signs.
export const approvalMessage = ({ sid, draftId, draftHash, nonce }) => canonicalJSON({ sid, draftId, draftHash, nonce });
