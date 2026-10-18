# 隐名之约 v2 · 客户端密封媒体密钥

**规范来源**：`ember/SEALING.md`。参考实现是 `ember/agent/sealing.mjs`。本文只说明 Flutter 客户端怎样落地，格式以 SEALING.md 为准，必须逐字节一致。

代码：`app/lib/src/anonym/anonym_seal.dart`（`anonSeal` / `anonUnseal` / `parseX25519Pub`）。
测试：`app/test/anonym/anonym_seal_test.dart`（官方向量）和 `anonym_controller_test.dart` 的 `E2EE keyreq` 组。

## 什么时候封

1. 圈主邀请 AI 入房（`anon_agent_invite {circleId,k}`）后，agent 生成一次性 X25519 密钥对，发 `anon_agent_hello`。
2. 服务器把 `anon_agent_keyreq {circleId, x25519Pub}` 转给在线圈主。
3. 圈主客户端弹确认面板（`AnonymKeyRequestSheet`），附说明：「托管 AI 运行期间会在内存里持有本圈媒体密钥；如需完全排除运营方，可在自己的设备上运行独立模式」。
4. 圈主同意后，客户端取本圈媒体密钥 hex（`E2eeController.sharedKeyFor(circleId)`，与 LiveKit `sharedKey` 用的是同一个串），封给 `x25519Pub`，然后发：

```json
{"t":"anon_agent_key","circleId":"…","sealed":"<base64>","x25519Pub":"<原样回显 keyreq 的公钥>"}
```

如果圈主拒绝，客户端什么也不发。本机没有该圈的媒体密钥时，报 `no_media_key`，同样不发。`x25519Pub` 原样回显，agent 据此忽略封给旧实例的密钥。

## 格式

```
shared = X25519(ephPriv, agentPub)
key    = HKDF-SHA256(ikm=shared, salt=ephPub ‖ agentPub, info=UTF8("lares-anon-seal-v1:" + circleId), L=32)
ct‖tag = AES-256-GCM(key, nonce(12 随机), aad=UTF8(circleId), plaintext=UTF8(mediaKeyHex))
sealed = base64std( 0x01 ‖ ephPub(32) ‖ nonce(12) ‖ ct ‖ tag(16) )
```

- plaintext 是小写 hex **文本本身**，不是解码后的字节，也不是口令。
- 每次封装都用新的临时密钥和新的 nonce（`Random.secure()`）。
- 公钥解析兼容标准 base64、url-safe base64（有无 `=` 均可）和 64 位 hex，长度必须是 32 字节。
- 实现是纯 Dart（`cryptography` 包的 `DartX25519` / `DartHkdf` / `DartAesGcm`），全平台行为一致，不依赖平台插件。

## 测试向量（取自 SEALING.md）

| 字段 | 值 |
|---|---|
| circleId | `c_test` |
| agentPriv (hex) | `11` × 32 |
| agentPub (b64) | `e06Qm75//kTEZaIgA31gjuNYl9Me+XLwf3SJLLD3PxM=` |
| ephPriv (hex) | `22` × 32 |
| ephPub (b64) | `D6poTtKIZ7l/Smot7l34zpdOdrcBjj8iocTPJnhXDyA=` |
| nonce (hex) | `000102030405060708090a0b` |
| mediaKeyHex | `a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90` |
| sealed | `AQ+qaE7SiGe5f0pqLe5d+M6XTna3AY4/IqHEzyZ4Vw8gAAECAwQFBgcICQoLV6kH+YsWDA/PgPHajRbfNoONuWPQ4318ZKZx72GgEa+fd4E7o7VISxdbjISF7DWzrNxdqwUSwCKG4Td8lcVU/0CoOIByJaypKN2eb+GvayI=` |

Dart 侧用 `newKeyPairFromSeed` 导入私钥：它在内部按 RFC 7748 做 clamp，与 node 导入未 clamp 原值的结果相同。

## 用 Node 复算

```js
// node seal_vec.mjs —— 依赖 ember/agent/sealing.mjs
import crypto from 'node:crypto';
import { seal, unseal } from '../../../ember/agent/sealing.mjs';
const pkcs8 = (hex) => crypto.createPrivateKey({
  key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.from(hex, 'hex')]),
  format: 'der', type: 'pkcs8',
});
const agent = pkcs8('11'.repeat(32));
const eph = pkcs8('22'.repeat(32));
const agentPubB64 = crypto.createPublicKey(agent).export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
const sealed = seal('a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90', agentPubB64, 'c_test', {
  ephemeral: { privateKey: eph, publicKey: crypto.createPublicKey(eph) },
  nonce: Buffer.from('000102030405060708090a0b', 'hex'),
});
console.log(agentPubB64, sealed);
console.log(unseal(sealed, { privateKey: agent, publicKey: crypto.createPublicKey(agent) }, 'c_test'));
```

> 早期草稿（SEALING.md 出来之前）用过没有版本字节、salt 为空、info 不含 circleId、没有 AAD 的方案。该方案已作废，客户端不再兼容。
