// 隐名之约 v2 · 密封密钥(AGENT-V2.md §2)。格式定义见 ember/SEALING.md —— Dart 客户端必须逐字节一致。
//
//   sealed = base64( 0x01 ‖ ephPub(32) ‖ nonce(12) ‖ ciphertext ‖ tag(16) )
//   shared = X25519(ephPriv, agentPub)
//   key    = HKDF-SHA256(ikm=shared, salt=ephPub ‖ agentPub, info="lares-anon-seal-v1:" + circleId, L=32)
//   AES-256-GCM(key, nonce, aad=utf8(circleId)) over utf8(mediaKeyHex)
import crypto from 'node:crypto';

export const SEAL_VERSION = 0x01;
export const SEAL_INFO_PREFIX = 'lares-anon-seal-v1:';
const b64url = (buf) => Buffer.from(buf).toString('base64url');

/// 32 字节原始 X25519 公钥 → KeyObject
export function x25519PublicFromRaw(raw) {
  const b = Buffer.isBuffer(raw) ? raw : Buffer.from(String(raw), 'base64');
  if (b.length !== 32) throw new Error('bad_x25519_pub');
  return crypto.createPublicKey({ key: { kty: 'OKP', crv: 'X25519', x: b64url(b) }, format: 'jwk' });
}
export const x25519RawPublic = (keyObject) => Buffer.from(keyObject.export({ format: 'jwk' }).x, 'base64url');

/// agent 的临时密钥对。pubB64 = 标准 base64(原始 32 字节),原样放进 anon_agent_hello.x25519Pub
export function generateX25519() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('x25519');
  const raw = x25519RawPublic(publicKey);
  return { publicKey, privateKey, pubRaw: raw, pubB64: raw.toString('base64') };
}

function deriveKey(shared, ephRaw, agentRaw, circleId) {
  const salt = Buffer.concat([ephRaw, agentRaw]);
  return Buffer.from(crypto.hkdfSync('sha256', shared, salt, Buffer.from(SEAL_INFO_PREFIX + circleId, 'utf8'), 32));
}

/// 圈主侧(测试 / e2e 用;Dart 客户端实现同一格式)
export function seal(mediaKeyHex, agentPubB64, circleId, { ephemeral = null, nonce = null } = {}) {
  const agentRaw = Buffer.from(String(agentPubB64), 'base64');
  const agentPub = x25519PublicFromRaw(agentRaw);
  const eph = ephemeral ?? crypto.generateKeyPairSync('x25519');
  const ephRaw = x25519RawPublic(eph.publicKey);
  const shared = crypto.diffieHellman({ privateKey: eph.privateKey, publicKey: agentPub });
  const key = deriveKey(shared, ephRaw, agentRaw, String(circleId));
  const iv = nonce ?? crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', key, iv);
  c.setAAD(Buffer.from(String(circleId), 'utf8'));
  const ct = Buffer.concat([c.update(Buffer.from(String(mediaKeyHex), 'utf8')), c.final()]);
  return Buffer.concat([Buffer.from([SEAL_VERSION]), ephRaw, iv, ct, c.getAuthTag()]).toString('base64');
}

/// agent 侧。任何不符(版本、长度、标签、circleId)都抛 'unseal_failed',不泄露原因细节。
export function unseal(sealedB64, keypair, circleId) {
  const fail = () => { throw new Error('unseal_failed'); };
  let b;
  try { b = Buffer.from(String(sealedB64), 'base64'); } catch { fail(); }
  if (!b || b.length < 1 + 32 + 12 + 16 + 1 || b[0] !== SEAL_VERSION) fail();
  const ephRaw = b.subarray(1, 33);
  const iv = b.subarray(33, 45);
  const tag = b.subarray(b.length - 16);
  const ct = b.subarray(45, b.length - 16);
  try {
    const shared = crypto.diffieHellman({ privateKey: keypair.privateKey, publicKey: x25519PublicFromRaw(Buffer.from(ephRaw)) });
    const key = deriveKey(shared, Buffer.from(ephRaw), keypair.pubRaw ?? x25519RawPublic(keypair.publicKey), String(circleId));
    const d = crypto.createDecipheriv('aes-256-gcm', key, iv);
    d.setAAD(Buffer.from(String(circleId), 'utf8'));
    d.setAuthTag(tag);
    const out = Buffer.concat([d.update(ct), d.final()]).toString('utf8');
    if (!/^[0-9a-f]{16,256}$/i.test(out)) fail();
    return out;
  } catch { return fail(); }
}
