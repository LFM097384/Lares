# 信令协议消息面审计

> 审计范围:`server/src/index.js`(1106 行全文)与客户端全部消费者
> (`signaling_client.dart` / `room_controller.dart` / `presence_pool.dart` /
> `recording_consent.dart` / `connection_test.dart` / `p2p/` / `main.dart`)。
>
> 起因:连续三次线上 bug,根因同一类 —— **信令层发了某条消息,上层没人处理**。
> 本文把整个消息面过了一遍,目的是把这一类缺口一次找完。

## 零、先读这一条:Dart 3 的 switch 语义

下面所有「谁处理了」的结论都压在这条语义上。`app/pubspec.yaml` 锁 `sdk: ">=3.8.0"`,
**case 不再 fall-through,非空 case 体执行完隐式跳出 switch**,控制流落到 switch 之后。

```dart
// signaling_client.dart:325-338
switch (json['t']) {
  case 'pong':
    _onPong();
    return;                  // ← 显式 return:被吞掉,下游永远看不到
  case 'challenge':
    _onChallenge(json);
    return;                  // ← 跳过 337,但 356 行自己补了一次 add
  case 'welcome':
    _onWelcome(json);        // ← 无 return → 隐式 break → 落到 337
  case 'error':
    _onProtocolError(json);  // ← 无 return → 隐式 break → 落到 337
}
_messages.add(json);         // ← welcome、error、以及**所有未知 t** 都到这儿
```

328/331 行与 333/335 行的这个不对称**就是整个路由设计**,不知道 fall-through
已被移除就看不出来。结论:`pong` 是唯一一条下游永远观测不到的服务端消息;
`challenge` 恰好抛一次(不是两次);未知 `t` 一律原样放行。

## 一、完整消息清单

### 1.1 服务端 → 客户端(25 种 `t`)

| 消息类型 | 谁发的 | 谁处理的 / **无人处理** |
|---|---|---|
| `challenge` | 每条连接建立即发(L431) | `signaling_client:329`、`connection_test:302` |
| `welcome` | `hello` 通过后(L464) | `signaling_client:332` + `room_controller:628` + `presence_pool:160` + `connection_test:341` |
| `room` | `joinCircle`(L852/864) | `room_controller:637` + `recording_consent:545` |
| `member_joined` | 新成员进房(L863,**仅新成员,加设备不发**) | `room_controller:662` |
| `member_left` | 踢人 L653 / 最后一个设备离开 L904 | `room_controller:668` + `recording_consent:547` |
| `member_updated` | `latency` L545 / 改名 L792 | `room_controller:678` |
| `member_status` | `status` L805 | `room_controller:673` |
| `member_loc` | `loc` L667 | `room_controller:779` |
| `member_loc_off` | `loc_off` L684(**无 `name`**,与 `member_loc` 不对称) | `room_controller:792` |
| `member_rec` | `rec_start` L702 / `rec_stop` L718 / 离房 L894 / 陈旧清扫 L170 | `recording_consent:543` |
| `member_available` | 大厅广播 L365 / `hello` 补发 L480 | `room_controller:722` + `presence_pool:169` |
| `member_unavailable` | `clearAvailable` → L360(**只有两个键**) | `room_controller:732` + `presence_pool:182` |
| `available_ok` | `available` 的直接回复(L520) | `room_controller:736` + `presence_pool:186` |
| `circle_summary` | `hello` L472 + 5 处大厅广播 | `room_controller:713` |
| `knock` | 敲门请求广播给房内(L495) | `room_controller:768` |
| `knock_waiting` | 敲门者收到的回执(L494) | `room_controller:753`(**armed 30s 超时**) |
| `kicked` | 被踢者的所有设备(L650) | `room_controller:775` |
| `reached` | 被找的人(L618) | `room_controller:740` + `presence_pool:190` |
| `reach_failed` | `reason: gone`(L597/600)/ `auth_scope`(L608) | `room_controller:746`(`_ =>` 兜底) |
| `p2p_signal` | 同圈中继(L578),`fromName` 由服务端补 | `main.dart:147` → `p2p_mesh.handleIncoming` |
| `token` | `joinCircle` L871 / 预热 L776(**预热才带 `prefetch:true`,进房路径该键缺失而非 false**) | `room_controller:688` |
| `pong` | `ping` 的回复(L810,**无鉴权门**) | `signaling_client:326`(吞掉,不外抛) |
| `rec_pong` | `rec_ping` 且**确实在录**才回(L737) | `recording_consent` 隐式 —— 见缺口 G7 |
| `note_added` | HTTP POST /notes 触发(L1040) | `room_controller:684` |
| `error` | 13 种 `message`,见下表 | **绝大多数无人处理** —— 见缺口 G1/G2 |

#### `error` 家族(13 种 `message`,全部不带 circleId / 关联 id)

| `message` | 行号 | 触发条件 | 关连接? | 谁处理 |
|---|---|---|---|---|
| `rtc_not_configured` | 877 | `joinCircle` 中 LiveKit 未配置 | 否 | `room_controller:705` ✅ |
| `token_failed` | 873 | `joinCircle` 中 mint token **抛异常** | 否 | **无人处理** 🔴 G1 |
| `auth_scope` | 489 | `join` 越权 | 否 | **无人处理** 🔴 G2 |
| `auth_scope` | 511/747/772 | `available` / `knock_mode_set` / `token_prefetch` 越权 | 否 | **无人处理** 🟠 |
| `say_hello_first` | 486/504/746 | `join` / `available` / `knock_mode_set` 早于握手 | 否 | **无人处理** 🟠 G2 |
| `already_in_room` | 513 | 已在房内还发 `available` | 否 | **无人处理** 🟡 G4 |
| `auth_required` | 452 | 开鉴权但 `msg.auth` 缺失 | **是 4401** | `signaling_client:444` ✅ |
| `auth_failed` | 452 | `verifyAuth` 的 8 种失败 | **是 4401** | `signaling_client:445` ✅ |
| `rate_limited` | 423/446 | IP 被封(>10 次/5min) | **是 4429** | `signaling_client:450` ✅ |
| `payload_too_large` | 569 | `p2p_signal` payload > 8192 | 否 | **无人处理** 🟡 |
| `too_large` | 435 | 帧 > 64KB | 否 | **无人处理** 🟡 |
| `bad_json` | 437 | JSON.parse 抛异常 | 否 | **无人处理** 🟡 |
| `userId_required` | 441 | `hello` 无 userId | 否 | **无人处理** 🟡 |

### 1.2 客户端 → 服务端(20 种,服务端全部认识)

| 消息类型 | 谁发的 | 服务端处理 |
|---|---|---|
| `hello` | `signaling_client:576`(唯一出口 `_sendHelloWithProof`) | L440 ✅ |
| `ping` | `signaling_client:409/414`(20s 心跳) | L809 ✅ |
| `join` | `signaling_client:584` | L485 ✅ |
| `leave` | `signaling_client:590` | L760 ✅ |
| `token_prefetch` | `signaling_client:588` | L765 ✅(**失败时什么都不回** —— G6) |
| `status` | `signaling_client:592` | L799 ✅(非法值静默变 `free`) |
| `available` | `signaling_client:596`、`presence_pool:166/214` | L502 ✅ |
| `unavailable` | `signaling_client:599`、`presence_pool:221` | L525 ✅ |
| `reach` | `signaling_client:603` | L589 ✅ |
| `p2p_signal` | `signaling_client:617` | L553 ✅ |
| `latency` | `room_controller:163`(Δ<50ms 节流) | L532 ✅ |
| `kick` | `room_controller:509` | L638 ✅ |
| `loc` / `loc_off` | `room_controller:582/576` | L659/679 ✅ |
| `knock_allow` | `room_controller:588` | L625 ✅ |
| `knock_mode_set` | `room_controller:601` | L742 ✅ |
| `profile` | `room_controller:613` | L783 ✅ |
| `rec_start` / `rec_stop` / `rec_ping` | `recording_consent:475/512/832` | L692/713/729 ✅ |

**没有客户端发了而服务端不认识的消息。** 但服务端的 `switch (msg.t)` **没有
`default:`**(L813),未知 `t` 完全静默丢弃 —— 新客户端加消息时拿不到任何反馈。

### 1.3 内部合成消息(`_` 开头,信令层自己造)

| 消息类型 | 合成位置 | 条件 | 消费者 |
|---|---|---|---|
| `_disconnected` | `signaling_client:484`,带 `closeCode` | 每次断开,**在 4401/4429 分叉之前** | `room_controller:816` ✅ / `recording_consent:549` ✅ / `presence_pool` ❌ G3 |
| `_rate_limited` | `signaling_client:495` | 仅 closeCode 4429 | `room_controller:812` ✅ / `presence_pool` ❌ G3 |
| `_auth_failed` | `signaling_client:519` | 仅**第二次** 4401(终局,此后不再重连) | `room_controller:808` ✅ / `presence_pool` ❌ G3 |

`AuthPhase.credentialRequired` 是第四种「终局态」,但它**只存在于 `authStatus`
这个 ValueNotifier 里,没有任何合成消息与之对应** —— 见缺口 G5。

## 二、缺口清单(按严重度排序)

### 🔴 G1 — `error: token_failed` 导致永久卡死

服务端 `joinCircle`(L867-878)先发 `room` 快照、并已向房内其他人广播
`member_joined`,**之后**才 mint token;mint 抛异常时发 `{t:'error',
message:'token_failed'}`。客户端 `room_controller:704` 的 `case 'error'` 只认
`rtc_not_configured`,**没有 else**,于是这条消息落进一个空 if 里消失。

**后果:** `_joinCompleter` 永不完成,`phase` 永远停在 `joining`,界面卡在
「正在进去…」且退不出来。更糟的是此时服务端已经把你登记进房、广播给别人了 ——
**房里其他人看到一个永远不出现的幽灵成员**。

触发条件真实存在:LiveKit API key/secret 配错、时钟偏移、LiveKit 侧故障。

### 🔴 G2 — `error: auth_scope` / `say_hello_first` 在 join 期间导致永久卡死

服务端 `join` 分支的两个前置检查(L486/489)只发一条 error 就 `return`,
**不关连接、不发 `room`、不发 `token`**。信令层 `_onProtocolError:455-458`
明确注释「连接还活着,什么都不做:交给上层按业务处理」,而上层从来没处理。

**后果:** 同 G1,永久卡在「正在进去…」。`auth_scope` 的现实触发场景是
「进一个自己没有口令的圈子」,这恰恰是最常见的误操作之一。

### 🔴 G3 — `PresencePool` 完全不处理三条内部消息

`presence_pool._onMessage:159` 只认 `welcome` / `member_available` /
`member_unavailable` / `available_ok` / `reached`,对 `_disconnected` /
`_auth_failed` / `_rate_limited` 一概不认。

**后果:**
1. **幽灵可约条目** —— 链路断了,`remote` 里那台服务器的人全部留着,UI 继续
   显示「有空」,点下去 `reach` 发进一个死 socket,什么都不会发生:一个看着
   能按、其实是死的按钮。
2. **链路状态撒谎** —— `_states[serverId]` 永远停在 `online`。而 `PresenceLinkState`
   的类注释(L59)白纸黑字写着它的存在意义是「用于 UI 如实呈现哪台服务器没连上」。
3. `_auth_failed` 是终局(信令层**彻底停止重连**),这台服务器会永远停在
   `online` 并挂着一整屏永远联系不上的人。

补充:订阅上的 `onError`(L140)盖不住 —— 它只在流真出错时才响,
而 `SignalingClient` 从不调 `_messages.addError`,所以 `failed` 分支**不可达**。

### 🔴 G5 — `AuthPhase.credentialRequired` 没有任何生产监听者

`authStatus`(ValueNotifier,L154)经全仓 grep 确认**只出现在
`signaling_client.dart` 自己和两个测试文件里,生产代码零监听**。
`AuthStatus.label`(L67-76,七条中文文案)是死代码。

`credentialRequired` 在两处设置:

- **站点 1(`connect():277`)** —— 凭据不全就不拨号。**已被补偿**:
  `room_controller.join():287` 有一份独立推导出来的重复守卫,直接读
  `SettingsStore` 并 `_failJoin`。
- **站点 2(`_sendHelloWithProof():382`)** —— **没有任何补偿,这是真缺口。**
  此时 **socket 已经打开且保持打开**,`AuthProof.build` 返回 null,客户端
  什么都不发、什么都不抛,直接 return。服务端在等一个永远不会来的 `hello`,
  也不会关连接 → **没有 `_disconnected`** → `room_controller` 等不到任何事件
  → 又一次永久卡在「正在进去…」。

站点 2 在站点 1 通过后仍可达:`connect()` 在拨号时检查 `cred.isComplete`,
而 `_sendHelloWithProof()` 在 challenge 到达时用 `_credentialNow()` **重新读**
凭据,两个时刻之间凭据可能变(用户改设置、vault 读失败、`authCircleId` 切换)。

### 🟠 G6 — `token_prefetch` 失败时服务端什么都不回

服务端 L773(`!RTC_CONFIGURED`)与 L777-779(mint 失败)**只 `console.error`,
不发任何消息**,与 `joinCircle` 路径(明确发 `rtc_not_configured` /
`token_failed`)不一致。

**影响:轻。** 预热是 fire-and-forget,`room_controller.prefetchToken` 不等
返回值,拿不到 token 只是退化成「进房时再 mint」,不卡死。**记录不修。**

这条不一致反而是 G2 修复的重要约束:因为预热失败**不发消息**,所以
join 期间收到的 `auth_scope` 绝大多数确实归属于 join 本身。

### 🟠 G7 — `rec_pong` 的处理是语句顺序的意外

`rec_pong` 这个字符串**在 `recording_consent.dart` 里一次都没出现**。它能生效
纯粹因为 `handleMessage:540` 的 `_kickLivenessWatchdog()` 写在 switch **之前**,
对任何字符串 `t` 都会喂一次狗。

`main.dart:362` 的注释说 `livenessTimeout` 敢开正是因为服务端会回 `rec_pong` ——
两者之间**没有任何代码或注释把这层依赖写下来**。把第 540 行挪到 switch 之后、
或加一个 `_` 前缀过滤,都会悄无声息地打断生产环境的活性看门狗。

**影响:当前行为正确,但极脆。** 建议补一条注释锁住这个依赖(见「未修」)。

### 🟡 G4 — 其余 error 静默失效(`already_in_room` 等)

- `already_in_room`(L513):`available` 被拒。用户以为自己挂上了「我有空」,
  实际没有,别人看不到他。**功能静默失效,不卡死。**
- `payload_too_large` / `too_large` / `bad_json` / `userId_required`:
  都是防御性的,正常客户端触发不到。`userId_required` 真触发说明客户端有 bug。

**影响:中到无害。记录不修。**

### 🟡 G8 — 未知 `t` 在 11 处分发点全部无日志

客户端 11 个 switch 无一记录未知类型,外加 3 处分发前的静默丢弃
(非 String 帧、JSON 解析失败、非 Map)。服务端 `switch (msg.t)` 同样无
`default:`。**这正是这一类 bug 反复上线却没人发现的根本原因。**

### 🟡 G9 — 协议不对称与字段陷阱(记录,不修)

- `token.prefetch`:预热为 `true`,进房路径**该键缺失而非 `false`**。
  客户端 `msg['prefetch'] == true` 恰好正确,但依赖的是「缺失 ≠ true」。
- `memberSnapshot.rec` 是 `{since}` **不带 `active`**,而 `member_rec` 用
  `active` + `since:0` —— **同一状态两种编码**。客户端两边分别按键存在性
  和 `active` 字段读,**当前是对的**(已核对 `_onRoomSnapshot`)。
- `member_available.circleIds` **按收件人过滤**,同一事件对不同客户端载荷不同。
- `member_loc_off` 不带 `name`,`member_loc` 带。
- `available_ok` 不带 `userId`/`since`。
- `rec_stop` 用 Dart 3 的 `'circleId': ?circleId` 空感知语法,circleId 为 null
  时**整个键消失**,服务端可能收到裸 `{"t":"rec_stop"}` —— 服务端 `rec_stop`
  分支恰好不读 circleId(与 `rec_start` 不对称),所以当前安全。
- `reach_failed` 不带 `userId`/`circleId`,并发 reach 无法关联。

### 🟡 G10 — 客户端热路径上的非空强转(记录,不修)

`room_controller:655` 的 `(loc['lat'] as num)` 和 `:689-690` 的
`msg['url'] as String` / `token as String` 都在任何守卫之前求值,畸形报文会
在流回调里抛异常。当前服务端不会发出这种报文,但这是脆的。

### 🟡 G11 — `connection_test` 与主客户端行为分叉(记录,不修)

`connection_test` 没有 challenge 超时兜底(主客户端有,`:361`),
面对不发 `challenge` 的老服务器,主客户端能正常连上而「测试连接」报
`unreachable` —— **告诉用户一个能用的地址是坏的**。另外它不校验 nonce
(主客户端在 `:347` 用 `isValidNonce`)。

不卡死(有 8s 超时 + `onDone` 按 close code 兜底),但会误导用户。

### 🟡 G12 — `PresenceLinkState` 没有任何 UI 读它(记录,不修)

`stateOf` / `linkStates` 在 `lib/` 里**零消费者**,`main.dart` 只用
`availableIn` 和 `reached`。所以 G3 修好之后,presence 链路鉴权失败时用户会
看到人「凭空消失」,但**得不到任何解释**。

诚实的说法:G3 的修复止住了「撒谎」,但还没做到「说出真话」。把
`linkStates` 接进服务器列表是自然的后续,属于 UI 工作,不在本次审计范围。

### 🟡 G13 — 被 `reach` 之后再抖一下会静默不再挂着(记录,不修)

`presence_pool:198` 的 `reached` 分支会 `_mine.remove(serverId)`,这是**有意**的
(被找到了就不再是「有空」)。但它与重连相互作用:被找到之后紧接着一次抖动,
`welcome` 补发时 `_mine` 已空,用户就在无声中不再挂着了。属既有行为,未改动。

## 三、修了哪些

### 已修 🔴 G1 / G2 —— `room_controller.dart` 的 `case 'error'`

改成**白名单 + `phase == joining` 闸门**(不是黑名单,也不是无差别兜底):

```dart
case 'error':
  if (reason == 'rtc_not_configured') { _failJoin(...); return; }
  // 同一条 socket 上还跑着聊天和图片,它们被拒与这次进房无关,
  // 所以先用 phase 把范围收死,再按名单逐条处理。
  if (phase != RoomPhase.joining) return;
  switch (reason) {
    case 'token_failed':      _failJoin(StateError('rtc_not_configured'));
    case 'auth_scope':
    case 'auth_required':
    case 'auth_failed':       _failJoin(StateError('auth_failed'));
    case 'rate_limited':      _failJoin(StateError('rate_limited'));
    case 'already_in_room':   _failJoin(StateError('already_in_room'));
    case 'say_hello_first':   _failJoin(StateError('handshake_lost'));
    default: break;  // 其余交给总超时兜底,不误伤
  }
```

`phase == joining` 这道闸门同时解决了「预热的 `auth_scope` 误杀正常 join」
这个担忧的绝大部分 —— 详见 G6 与下面「未修」一节对残余风险的说明。

### 已修 🔴 G3 —— `presence_pool` 的三条内部消息

新增 `_linkDown(serverId, state)`:清掉该服务器的 `remote` 条目并落状态,
**不退订、不 dispose**(那是 `_drop` 的职责,对一次抖动用 `_drop` 会把自动
重连一起销毁)。`_disconnected → connecting`、`_rate_limited → failed`、
`_auth_failed → failed`。

两个刻意的「不动」:
- **不清 `_mine`** —— 那是我自己的意图,不是观测来的事实;清了就会在一次抖动
  之后静默地不再挂着,是拿一个 bug 换一个更难发现的 bug。有专门的回归测试钉住。
- **不清 `reached`** —— 赴约走的是**主连接**(`main.dart:200-205`),轻连接断了
  不代表这个约不该赴;清掉等于凭空吞掉一次邀请。

顺带把 `onError` 回调也改走 `_linkDown`:它此前只改状态不清人,是同一类幽灵条目。

### 已修 🔴 G5 —— `credentialRequired` 现在会说话

`signaling_client` 新增 `_emitCredentialRequired()`,在**两处**站点都向
`messages` 流发 `{'t': '_credential_required', 'message': 'auth_required'}`;
`room_controller:950` 新增对应分支,在 `joining`/`inRoom` 时 `_failJoin`。

与 `_auth_failed` 的分工:那条是「试过了,被拒」,这条是「压根没去试」。

### 额外修复(超出原定范围,但确属同一病)

- **进房总超时 `joinTimeout`** —— 前三次卡死都是「某条具体路径漏了出口」,
  而漏的方式是无穷的:信令层拒发 hello 却不关连接、服务端收下 join 后因任何
  原因不回话,这些路径**不产生任何事件**,不可能靠「多处理一条消息」修好,
  只有时间能兜住。
- **`_joinEpoch` 代次守卫** —— `_connectRtc` 里 await 的是真实媒体连接,其间
  用户完全可能退房再进。旧那次返回时会把 `inRoom` 和新那次的 completer 一起
  提交掉。更糟的是会留下一条没人管的音频流:**用户明明已经离开,却还在被别人
  听见**。代次对不上就把连好的媒体拆掉再走。
- **`_abandonJoinCompleter`** —— `retryJoin` 的 force 路径会直接盖掉
  `_joinCompleter`,被盖掉的那个从此无人 complete,`await join()` 的调用方
  永远挂着。这是「卡在正在进去…」的一种隐身变体(UI 读 phase,所以界面看着正常)。
- **RTC 掉线后的 `_recoverMedia`** —— 此前只是 `phase = joining` 然后「等上层
  重进」,而从来没有哪个上层会重进。
- **`_onProtocolError` 的 `default:` 日志** —— 未识别的服务端 error 现在会
  `debugPrint`。纯诊断,不改控制流、不吞消息。G8 的一部分缓解:下一条没人处理的
  error 至少会在日志里露头,而不是彻底蒸发。

## 四、测试与验证

| 项目 | 基线 | 现在 |
|---|---|---|
| `flutter test` | 690 通过 / 0 失败 | **749 通过 / 0 失败**(+59) |
| `flutter analyze lib test` | No issues | **No issues** |

新增测试分布:`join_deadlock_test.dart`(新建,27 个)、
`presence_pool_test.dart`(11 → 18)、`signaling_auth_test.dart`(+7),
另修好 `moderation_ui_test.dart` / `passcode_entry_test.dart` 两个测试
辅助函数的计时器泄漏(它们 `join()` 之后不 dispose,总超时一上线就暴露了)。

**没有新增任何面向用户的文案**,因此没动 ARB、不需要 `gen-l10n` ——
所有失败路径都复用 `join_error.dart` 里已有的分类与措辞。

### 变异测试:确认这些测试真的在兜底

新测试最容易犯的错是「拿掉被测代码它照样绿」。对两处核心修复做了变异验证:

| 变异 | 结果 |
|---|---|
| 把 `_armJoinWatchdog` 改成直接 return | **转红**(超时兜底、welcome 恢复、重连不成、rtc.join 挂起、room→token 缺口) |
| **只**去掉 `case 'room'` 里的重新挂表 | **1 个测试转红**(敲门放行、room 到了但 token 不来) |
| 把 `case 'error'` 的白名单整段跳过 | **整个测试套件挂死超时** —— 正是线上那个症状本身 |

第二条是最要紧的:它证明那一行**单独**是承重的,测试隔离的正是那个缺口,
而不是靠 `join()` 挂的那块表蒙混过关。三处变异均已还原,还原后 749 全绿。

### ⚠️ 验证时的坑:不要并发跑 `flutter test`

`app/test/signaling_live_auth_test.dart` 会**绑定真实服务器端口**。两个
`flutter test` 同时跑会因端口争用产生**虚假失败** —— 本次审计中就有一次
被误判成「基线本来就有 7 个失败」。实测干净 HEAD(`git stash push -u` 后
单独跑)是 **690 通过 / 0 失败**。判断「某个失败是既有问题」之前,
务必回到干净 HEAD 单独实测一次,不要凭印象采信。

## 五、诚实交代:没修的部分

| 缺口 | 为什么不修 |
|---|---|
| G6 预热失败无回包 | fire-and-forget,不卡死,只退化成进房时再 mint |
| G4 `already_in_room` 等 | 功能静默失效(挂不上「我有空」),不卡死;改对要动服务端 |
| G8 未知 `t` 全线无日志 | 只在信令层 error 分支加了日志;11 处分发点全加属于另一次改动 |
| G9 协议不对称 | 当前客户端读法都正确,改任何一侧都要动生产服务端 |
| G10 热路径非空强转 | 当前服务端发不出这种报文;要改得连同防御式解析一起做 |
| G11 `connection_test` 缺 challenge 超时 | 会误导用户但不卡死;修它要动「测试连接」的判定逻辑,风险独立 |
| G12 无 UI 读 `PresenceLinkState` | 属 UI 工作。**G3 止住了撒谎,但还没做到说出真话** |
| G13 被 reach 后抖动会静默不挂着 | 既有行为,与本次缺口无关,未改动 |
| 服务端全部缺口 | 生产环境运行中,本次**一行未动** |

### 一个残余风险,明说

`auth_scope` 在 `phase == joining` 时会无条件终结进房。理论上一次
**针对另一个圈子的预热**被拒(`index.js:772`)可能落在这个窗口里,误杀一次
正常进房。没做关联消歧是权衡后的决定:服务端的 error **不带 circleId 也不带
关联 id**,要消歧就得在客户端自己维护一套在途预热表,复杂度和它自身的 bug 面
都超过收益;而代价只是一次**可恢复的误报**(用户重进即可),不是卡死。
真要根治,正确的位置是服务端给 error 加 `circleId` —— 那是一次向后兼容的
加字段改动,留给下次动服务端时一起做。
