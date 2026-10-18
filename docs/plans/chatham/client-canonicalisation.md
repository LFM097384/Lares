# 隐名之约 · 客户端签名规范(canonicalisation / nonce / 测试向量)

> 受 Chatham House 规则启发 · 非官方。与 Chatham House 无隶属。
> 实现:`app/lib/src/anonym/anonym_crypto.dart`(库级 doc comment 与本文一致)。
> 服务器对端:`server/anonym-agent/core/crypto.mjs`(`canonicalJSON` / `approvalMessage` / `verifyEd25519`)。

## 密钥

- 每场会话(每个 `sid`)在本机新生成一把 **Ed25519** 密钥;只存内存,不落盘。
- 同意加入时发 `anon_ack{circleId, pubKey}`,`pubKey` = 32 字节原始公钥,**标准 base64(带 `=` 填充)**。
- 散会(`anon_ended`)、会话变 inactive、换了 sid、离房 / 换圈时立刻 wipe:私钥种子与展开私钥字节清零,之后 `sign` 抛 `StateError`。
- Dart 包:`ed25519_edwards`(纯 Dart,RFC 8032,无 FFI,手机 / 桌面 / Web 都能跑)。

## 规范化 JSON(与服务器 `canonicalJSON` 字节一致)

- 对象:键按 **UTF-16 code unit** 升序(= JS 默认 `sort()`)递归排序;值为 `undefined` 的键省略(Dart 侧没有 undefined,`null` 原样写 `null`)。
- 数组:保持顺序,元素递归规范化。
- 无任何空白。
- 字符串 / 数字 / 布尔 / null 按 `JSON.stringify` 写法(Dart `jsonEncode` 对这些标量输出相同;非 ASCII 字符原样 UTF-8,不转义)。
- 非有限数(NaN / ±Infinity)拒绝。

## 签名消息

```
approvalMessage = canonicalJSON({ sid, draftId, draftHash, nonce })
               = {"draftHash":…,"draftId":…,"nonce":…,"sid":…}
sig = Ed25519.sign(privateKey, utf8(approvalMessage))   // 64 字节,标准 base64
```

发送:`anon_approve{circleId, draftId, draftHash, nonce, sig}`。`sid` 不随消息发送,由服务器从会话上下文取。

## nonce

- **16 字节** `Random.secure()` 随机数,**base64url、无填充** → 恒为 22 个字符,字符集 `[A-Za-z0-9_-]`。
- 每次签名换新 nonce;服务器用它防重放。

## 测试向量(已与 node:crypto 及服务器 `verifyEd25519` 交叉验证)

| 项 | 值 |
|---|---|
| seed | 字节 `00 01 02 … 1f`(0..31) |
| pubKey | `A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=` |
| sid / draftId / draftHash | `S1` / `d1` / `h` |
| nonce | `AAECAwQFBgcICQoLDA0ODw`(字节 0..15) |
| message | `{"draftHash":"h","draftId":"d1","nonce":"AAECAwQFBgcICQoLDA0ODw","sid":"S1"}` |
| sig | `C4fR1aepz6LZ0oEc5B+yelRCzW64Ujp43mSgWkayEd5lvwHWR91fWq3W1lHglmC+DCrocIpB7wue0EzI+ChTBQ==` |

Node 复现:

```js
import crypto from 'node:crypto';
const seed = Buffer.from([...Array(32).keys()]);
const key = crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]), format: 'der', type: 'pkcs8' });
const msg = '{"draftHash":"h","draftId":"d1","nonce":"AAECAwQFBgcICQoLDA0ODw","sid":"S1"}';
console.log(crypto.sign(null, Buffer.from(msg), key).toString('base64'));
```

Dart 回归测试:`app/test/anonym/anonym_crypto_test.dart`。

## 待服务器确认

1. `verifyEd25519` 已接受 base64 与 base64url,客户端发标准 base64;nonce 用 base64url 无填充 —— 服务器若对 nonce 有格式校验需对齐。
2. 断线重连且 `anon_state` 显示同一 sid 下我未 ack:客户端用**同一把公钥**重发 `anon_ack`(私钥仍在内存)。
