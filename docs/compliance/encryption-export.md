# 加密出口合规（EAR / BIS）

> 面向维护者，不是给用户看的页面。
> 最后更新：2026-09

## 结论速览

| 项 | 值 |
|---|---|
| ECCN | **5D992.c** |
| 授权类型 | **License Exception ENC — 740.17(b)(1)**（自分类） |
| `ITSAppUsesNonExemptEncryption` | **`true`** |
| 需要 CCATS？ | **不需要** |
| 需要 ERN？ | **不需要**（(b)(1) 自分类不要求） |
| 需要年度自分类报告？ | **需要，每年 2 月 1 日前** |

## 为什么不能填 `false`

App 实际用到的加密：

| 用途 | 实现 | 位置 |
|---|---|---|
| 端到端加密 | LiveKit `E2EEOptions.sharedKey()`，底层 AES | `app/lib/src/e2ee/` |
| 密钥派生 | Argon2id（`hashlib`），由圈子口令派生 E2EE 密钥 | `app/lib/src/e2ee/` |
| 信令鉴权 | HMAC-SHA256 挑战/应答 | `app/lib/src/net/signaling_client.dart` |
| 传输 | TLS（WSS）、WebRTC DTLS-SRTP | — |

只用 HTTPS/TLS 可以填 `false`。但 **E2EE 与 Argon2id 是我们自己实现的加密功能**，
超出该豁免范围。

### 两个曾经踩过的推理错误

**错误一：「属于 5D992.c，所以填 false」**

自相矛盾。5D992.c 正是走 740.17(b)(1) 这条**需要申报**的路。
填 `false` 的语义是「豁免、无需任何申报」，与自分类为 5D992.c 冲突。
选了 5D992.c，本键就必须是 `true`。

**错误二：「用的都是开源库，属于公开可得，不受 EAR 管辖」**

BIS 明确堵死了这条路。
[Encryption items not subject to the EAR](https://www.bis.gov/learn-support/encryption-controls/encryption-items-not-subject-to-ear)
**Note 2**：

> 一个物项不会仅仅因为它并入或调用了公开可得的开源代码就被视为公开可得。
> 相反，这构成了一个**具有加密功能的新物项**，必须作为整体重新评估。

补充一点顺序问题：免费 App 完成自分类**并且**公开发布后，确实可以不再受 EAR 管辖。
但顺序不能颠倒 —— 必须**先**自分类，公开发布才免除后续义务。

## App Store Connect 里怎么答

上传构建版本后会被追问，按此回答：

| 问题 | 答案 |
|---|---|
| 是否使用加密？ | 是 |
| 是否仅用 Apple 操作系统提供的加密？ | **否**（我们带了 libwebrtc 和 hashlib） |
| 算法是否为专有/自研？ | **否**，都是标准算法（AES、Argon2id、HMAC-SHA256） |
| 是否属于 Mass Market 免除类别？ | 是 —— 5D992.c，ENC 740.17(b)(1) |

`Info.plist` 里已写死 `ITSAppUsesNonExemptEncryption = true`，
所以每次上传不会再弹这个问题，但**首次**仍需在合规问卷里选一次分类。

## ⏰ 年度自分类报告（有硬 deadline）

某自然年内发生出口（**上架即算出口**）的，报告须在
**次年 2 月 1 日前**送达 BIS。

- **发到**：`crypt-supp8@bis.doc.gov` 和 `enc@nsa.gov`
- **格式**：CSV，**只接受 CSV**
- **依据**：[Supplement No. 8 to Part 742](https://www.bis.gov/regulations/ear/742#supplement-8-742)
- **说明页**：<https://www.bis.gov/learn-support/encryption-controls/annual-self-classification>

CSV 首行必须是这 12 个字段，**任一字段不得留空**
（无值填 `NONE` / `N/A`）：

```
PRODUCT NAME, MODEL NUMBER, MANUFACTURER, ECCN, AUTHORIZATION TYPE, ITEM TYPE,
SUBMITTER NAME, TELEPHONE NUMBER, E-MAIL ADDRESS, MAILING ADDRESS,
NON-U.S. COMPONENTS, NON-U.S. MANUFACTURING LOCATIONS
```

本项目对应取值：

- `PRODUCT NAME` = `Lares`
- `ECCN` = `5D992.c`
- `AUTHORIZATION TYPE` = `MMKT`
- `ITEM TYPE` = 从 Supp. 8 (a)(6) 的清单里选，本项目取
  `"network infrastructure"` 之外的应用类，通常为 `"mobile applications"`

同一产品**只在首次自分类那一年报一次**。
若与上一年相比无变化，发一封「与上次相比无变化」的邮件即可。
该年度无出口则无需提交。

## 免责

以上依据 BIS 公开条文整理，不构成法律意见。
如对边界有疑问（尤其是 E2EE 的分类），建议咨询出口管制律师。
