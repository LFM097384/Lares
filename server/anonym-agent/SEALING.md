# 隐名之约 v2 · 密封媒体密钥格式（sealed key）

E2EE 圈里，托管的隐名之约 agent 不知道口令，所以拿不到 LiveKit 媒体密钥。流程如下：

1. agent 连上信令并 `join` 之后，生成**一次性** X25519 密钥对，发 `anon_agent_hello {circleId, x25519Pub}`。
2. 服务器把 `anon_agent_keyreq` 转给在线圈主。圈主客户端用下面的格式把**媒体密钥 hex 串**封给 `x25519Pub`，再发 `anon_agent_key {circleId, sealed, x25519Pub}`。
3. 服务器只转发、看不懂。agent 解封后用这个 hex 串作 `sharedKey`（UTF-8 字节，同真人客户端）连 LiveKit。

实现：`server/bots/anonym-agent/sealing.mjs`（`seal` / `unseal`）。**Dart 客户端必须逐字节一致。**

## 编码

- `x25519Pub`：32 字节原始 X25519 公钥，**标准 base64（带 `=`）**，44 字符。
- `sealed`：标准 base64（带 `=`），解码后为：

```
offset  len   field
0       1     version = 0x01
1       32    ephPub    封装方一次性 X25519 公钥（原始 32 字节）
33      12    nonce     AES-GCM IV，随机
45      n     ciphertext
45+n    16    tag       AES-GCM 认证标签
```

## 算法

```
shared = X25519(ephPriv, agentPub)                      // 32 字节
key    = HKDF-SHA256(ikm  = shared,
                     salt = ephPub ‖ agentPub,           // 64 字节，原始公钥拼接
                     info = UTF8("lares-anon-seal-v1:" + circleId),
                     L    = 32)
ciphertext ‖ tag = AES-256-GCM(key, nonce, aad = UTF8(circleId), plaintext = UTF8(mediaKeyHex))
```

- `mediaKeyHex` 就是真人客户端 `e2eeKeyHex(passcode, circleId)` 得到的小写 hex 串（**hex 文本本身**，不是解码后的字节）。agent 接受 16–256 个 hex 字符。
- 每次封装都要用新的 ephPub 和新的 nonce。
- 任何不符都只报 `unseal_failed`：版本、长度、标签、circleId 或公钥。agent 会忽略 `x25519Pub` 不等于自己当前公钥的 `anon_agent_key`（那是封给旧实例的）。
- agent 的私钥只在内存里，进程退出即失效。重启后重新 hello、重新封装。

## 测试向量

X25519 私钥按 RFC 7748 输入（32 字节标量，未 clamp 的原值）：

| 字段 | 值 |
|---|---|
| circleId | `c_test` |
| agentPriv (hex) | `1111111111111111111111111111111111111111111111111111111111111111` |
| agentPub (b64) | `e06Qm75//kTEZaIgA31gjuNYl9Me+XLwf3SJLLD3PxM=` |
| ephPriv (hex) | `2222222222222222222222222222222222222222222222222222222222222222` |
| ephPub (b64) | `D6poTtKIZ7l/Smot7l34zpdOdrcBjj8iocTPJnhXDyA=` |
| nonce (hex) | `000102030405060708090a0b` |
| mediaKeyHex | `a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90` |
| sealed | `AQ+qaE7SiGe5f0pqLe5d+M6XTna3AY4/IqHEzyZ4Vw8gAAECAwQFBgcICQoLV6kH+YsWDA/PgPHajRbfNoONuWPQ4318ZKZx72GgEa+fd4E7o7VISxdbjISF7DWzrNxdqwUSwCKG4Td8lcVU/0CoOIByJaypKN2eb+GvayI=` |

`server/bots/anonym-agent/test/sealing.test.mjs` 会复算这个向量。
