# 录音同意与指示器协议(需求⑧ 配套)

本文件是**交给 owner 应用的补丁说明**。录音功能自身的代码在 `app/lib/src/recording/`,
但同意广播要落在信令服务器与若干 UI/状态文件里 —— 那些文件不归录音模块所有,
故在此给出**逐字可用的片段**。

## 0. 为什么走信令服务器,而不是 LiveKit participant metadata

两条通道都能广播"我在录音",实测后选定**信令服务器**,理由按权重排序:

1. **LiveKit 通道当前是坏的。** `server/src/index.js:295` 签发 token 时的授权是
   `{roomJoin, room, canPublish, canSubscribe, canPublishData}` —— **没有
   `canUpdateOwnMetadata`**。客户端调 `setAttributes()` 会被服务端拒绝。
   要走那条路就得放宽 token 授权面,为了一个布尔值不值得。
2. **`setAttributes()` 语义危险。** 读 SDK 源码(`local.dart:690`)确认它是
   **整表替换**且会连带重发 `name`/`metadata`;并发写会互相覆盖。
   另外它 5 秒超时后抛 `TimeoutException`,调用方不 catch 就是未捕获异步异常。
3. **信令连接本来就常驻。** App 启动即 `preconnect()`,而 LiveKit 只在进房期间在。
   `RoomController` 还存在"媒体降级"态(LiveKit 断开、信令仍在),
   那种状态下 LiveKit 通道根本没法广播。
4. **后进房的人必须被告知。** 信令服务器已有 `roomSnapshot()` 机制,
   把录音态挂进成员快照是顺手的事;LiveKit attributes 要另做一套。

**结论:信令服务器是录音态的唯一权威。** 不做双通道 —— 两个真相源迟早会打架,
而"指示器说谎"正是本功能最不能出的事故。

## 1. 线协议

客户端 → 服务器:

```json
{"t": "rec_start", "circleId": "<id>"}
{"t": "rec_stop",  "circleId": "<id>"}
{"t": "rec_ping",  "circleId": "<id>"}
```

服务器 → 圈内所有人(含发起者自己,**回显是放行采集的前提**):

```json
{"t": "member_rec", "circleId": "<id>", "userId": "<uid>",
 "name": "<显示名>", "active": true, "since": 1757701234567}
```

后进房者:录音态随 `roomSnapshot()` 的成员对象下发(见 §2.2)。

### 1.1 关键不变量:先广播,后采集

客户端发出 `rec_start` **不代表**房间已被告知 —— `SignalingClient` 在未连接时
会把消息塞进 `_outbox` 静默排队(`signaling_client.dart:97`)。
因此客户端**必须等服务器把 `member_rec{userId: 自己, active: true}` 回显回来**
才允许开始采集音频。等不到(默认 5 秒)就**失败**,绝不"先录着再说"。

硬失败很烦人,静默失败是伦理事故 —— 选烦人。

## 2. `server/src/index.js` 需要的改动

### 2.1 成员快照带上录音态

`memberSnapshot()`(约 237 行)末尾追加一行:

```js
function memberSnapshot(member) {
  return {
    userId: member.userId,
    name: member.name,
    status: member.status,
    deviceCount: member.devices.size,
    // 位置共享:有则带上(后进房的人也能看到)
    ...(member.loc ? { loc: member.loc } : {}),
    // 录音态:有则带上 —— 后进房的人必须立刻知道房间正在被录(伦理红线)
    ...(member.rec ? { rec: { since: member.rec.since } } : {}),
  };
}
```

### 2.2 三个新 case

加在 `case 'loc_off':` 之后、`case 'knock_mode_set':` 之前:

```js
      case 'rec_start': {
        // 录音开始:登记 + 广播。回显给发起者自己是**放行采集的前提**,
        // 所以这里不能用 broadcast 的 exceptWs 参数把他排除掉。
        if (!session.circleId || !session.userId) return;
        if (msg.circleId !== session.circleId) return; // 防跨圈误报
        const member = getCircle(session.circleId).get(session.userId);
        if (!member) return;
        // 已在录则只续期,不重置 since(重连补发 rec_start 会走到这里,
        // 重置会让"已录 N 分钟"倒退)
        if (!member.rec) member.rec = { since: Date.now(), seen: Date.now() };
        else member.rec.seen = Date.now();
        broadcast(session.circleId, {
          t: 'member_rec',
          circleId: session.circleId,
          userId: session.userId,
          name: member.name,
          active: true,
          since: member.rec.since,
        });
        break;
      }

      case 'rec_stop': {
        if (!session.circleId || !session.userId) return;
        const member = getCircle(session.circleId).get(session.userId);
        if (!member || !member.rec) return; // 幂等:没在录就当无事发生
        delete member.rec;
        broadcast(session.circleId, {
          t: 'member_rec',
          circleId: session.circleId,
          userId: session.userId,
          name: member.name,
          active: false,
          since: 0,
        });
        break;
      }

      case 'rec_ping': {
        // 活性心跳:录音端每 15s 一发。只更新 seen,不广播(否则平白放大流量)。
        if (!session.circleId || !session.userId) return;
        const member = getCircle(session.circleId).get(session.userId);
        if (member?.rec) member.rec.seen = Date.now();
        break;
      }
```

### 2.3 录音端崩溃后的过期清理(复用已有心跳 timer)

录音端进程被杀时不会发 `rec_stop`,若不清理,房间会**永远显示有人在录**——
指示器一旦说过谎就再没人信。在已有的 30s `heartbeat`(约 741 行)里顺带扫一遍,
**不另起 timer**:

```js
const heartbeat = setInterval(() => {
  for (const ws of wss.clients) {
    if (ws._laresAlive === false) { ws.terminate(); continue; }
    ws._laresAlive = false;
    ws.ping();
  }
  sweepNonces();
  sweepRateLimits();
  sweepStaleRecordings();   // ← 新增这一行
}, 30_000);
```

配套函数(放在 `broadcastLobbySummary()` 附近即可):

```js
// 录音端崩溃/断网不会发 rec_stop。45s 没收到 rec_ping 就判定它死了,
// 撤掉录音标记 —— 宁可少显示,也不能让指示器停在一个不存在的录音上。
// 阈值取心跳间隔(15s)的 3 倍,容忍两次丢包。
const REC_STALE_MS = 45_000;

function sweepStaleRecordings() {
  const now = Date.now();
  for (const [circleId, circle] of circles) {
    for (const member of circle.values()) {
      if (!member.rec) continue;
      if (now - member.rec.seen <= REC_STALE_MS) continue;
      delete member.rec;
      broadcast(circleId, {
        t: 'member_rec', circleId, userId: member.userId,
        name: member.name, active: false, since: 0,
      });
    }
  }
}
```

### 2.4 成员离开时清理

`leaveCircle()`(约 561 行)在 `circle.delete(session.userId)` 之前补一段:
成员整个被移除时 `rec` 随对象一起没了,但**广播必须补发**,否则其他端的
指示器会停在旧状态。最简做法是在 `member_left` 广播之前加:

```js
    if (member.devices.size === 0) {
      // 录音者直接掉线:先撤录音指示,再报离开
      if (member.rec) {
        delete member.rec;
        broadcast(session.circleId, {
          t: 'member_rec', circleId: session.circleId, userId: session.userId,
          name: member.name, active: false, since: 0,
        });
      }
      circle.delete(session.userId);
      broadcast(session.circleId, { t: 'member_left', circleId: session.circleId, userId: session.userId });
      // ...原有逻辑不变
```

### 2.5 ⚠️ 已知缺口:`rec_ping` 无 ack

当前 `rec_ping` 是**单向**的。TCP 半开(连接已死但本机未察觉)时客户端不会收到
`_disconnected`,心跳打进虚空,于是它一边采集、房间那边可能早已不知情。

客户端侧的防护机制(`livenessTimeout`)**已实现但默认关闭**,因为在当前协议下
无法安全地默认开启:服务器只在状态**变化**时广播 `member_rec`,安静的房间可以
几分钟零入站消息,贸然开启会误杀正常长录音。

**要真正堵上,二选一即可**(建议前者,改动更小):

- 给 `rec_ping` 回一条 ack:`send(ws, { t: 'rec_pong', now: Date.now() })`;
- 或在录音期间由 `sweepStaleRecordings` 周期性重播 `member_rec`。

任选其一后,把客户端 `RecordingConsentController` 的 `livenessTimeout`
设为略大于该周期即可闭合。**在那之前这是一个已记录在案的缺口,不是静默的洞。**

## 3. `lib/src/state/room_controller.dart` 需要的改动

### 3.1 持有控制器并转发消息

`RoomController` 已经在 `_onSignalingMessage` 里集中处理所有信令消息,
录音态只需**转发**给同意控制器 —— 不要在 `RoomController` 里重复实现状态机。

构造函数里新增(字段 + 初始化):

```dart
  /// 录音同意控制器:录音态的唯一权威,UI 指示器直接读它。
  /// 注入而非内建,是为了让 RoomController 的测试不必关心录音。
  final RecordingConsentController? recordingConsent;
```

在 `_onSignalingMessage(Map<String, dynamic> msg)` 的 **switch 之前**加一行转发
(而不是在 switch 里加 case:录音控制器要看的 `room` / `member_left` /
`_disconnected` 都是已有分支,转发在前面做最省事且不影响原逻辑):

```dart
  void _onSignalingMessage(Map<String, dynamic> msg) {
    // 录音态:原样转发给同意控制器(它自己挑需要的 t 处理)。
    // 放在 switch 之前,'room' / 'member_left' / '_disconnected' 这些
    // 已有分支就不必各自再记得调一次。
    recordingConsent?.handleMessage(msg);

    switch (msg['t']) {
      // ...原有分支完全不变
```

### 3.2 出房时停录

`leave()` 里,在 `_signaling.leave()` **之前**补一行 —— 离开房间必须停止录音,
否则会出现"人已走、录音还在"的荒谬状态:

```dart
  Future<void> leave() async {
    recordingConsent?.stop();   // ← 新增:先停录再退,顺序不能反
    _idleTimer?.cancel();
    // ...原有逻辑不变
```

同理 `_downgradeMedia()`(闲时媒体降级)也应停录:媒体都断了,再"录"下去
录到的只有静音,而指示器还亮着 —— 是另一种形式的说谎。

## 4. `lib/src/ui/room_screen.dart` 需要的改动

把指示器横幅挂在 `_KnockBanner` 之后、`Expanded` 之前 —— 与敲门横幅同级,
位于成员网格正上方,**进房即入眼,划不走、点不掉**。

```dart
                _RoomHeader(
                  controller: controller,
                  circleName: widget.circleName,
                  showMap: _showMap,
                  onToggleMap: widget.locationShare == null
                      ? null
                      : () => setState(() => _showMap = !_showMap),
                ),
                _KnockBanner(controller: controller, settings: widget.settings),
                // 录音指示器:房间里有人在录音时对**所有人**常驻显示。
                // 这是本 App 唯一刻意「吵」的组件 —— 安静的设计 ≠ 藏起来。
                if (widget.recordingConsent != null)
                  RecordingIndicatorBanner(
                    controller: widget.recordingConsent!,
                  ),
                Expanded(
                  // ...原有内容不变
```

配套在 `RoomScreen` 加一个可空字段(与 `chat` / `locationShare` 同样的降级方式:
为 null 时整块不渲染):

```dart
  /// 录音同意控制器。为 null 时不渲染指示器(与 chat 同样的降级方式)
  final RecordingConsentController? recordingConsent;
```

## 5. `lib/src/ui/settings_sheet.dart` 需要的改动

录音开关放设置页,**默认关**,点击走确认对话框而不是直接开。

```dart
              const Divider(),
              // ── 录音与转写(需求⑧)──
              // 默认关闭。打开前必过确认对话框:录同伴的声音是有伦理与法律
              // 分量的事,不做成一个可以手滑打开的开关。
              ListTile(
                leading: const Icon(Icons.fiber_manual_record_rounded),
                title: const Text('录音与转写'),
                subtitle: Text(
                  recordingConsent?.room.anyoneRecording == true
                      ? '房间正在录音中'
                      : '默认关闭;开启时所有人都会看到提示',
                ),
                trailing: FilledButton.tonal(
                  onPressed: () async {
                    final c = recordingConsent;
                    final circleId = controller.circleId;
                    if (c == null || circleId == null) return;
                    if (c.captureAllowed) {
                      c.stop();
                      return;
                    }
                    final ok = await showRecordingConsentDialog(
                      context,
                      memberCount: controller.members.length,
                    );
                    if (!ok) return;
                    final started = await c.requestStart(circleId);
                    if (!started && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(c.message ?? '录音未能开始')),
                      );
                    }
                  },
                  child: Text(
                    recordingConsent?.captureAllowed == true ? '停止录音' : '开始录音',
                  ),
                ),
              ),
              // 本地语音模型:未安装时如实说明,不假装功能存在
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: const Text('离线语音模型'),
                subtitle: Text(sttAvailability?.message ?? '未检测'),
                onTap: () { /* 引导下载,见 stt_sherpa.dart 的 checkAvailability */ },
              ),
```

`showSettingsSheet()` 的签名相应增加两个可选参数
(`RecordingConsentController? recordingConsent` 与 `SttAvailability? sttAvailability`)。

## 6. 失败模式一览(设计意图,便于 review)

| 情形 | 行为 | 理由 |
|---|---|---|
| 发了 `rec_start` 但 5s 内无回显 | **不采集**,状态 failed,给中文提示;并补发 `rec_stop` | 补发是为了撤掉"服务器收到了但回显丢了"留下的幽灵录音标记 |
| 录音中信令断开 | 宽限 10s;期内恢复则无缝续录,超时**自动停采**并告警 | 2 秒抖动不该毁掉录音;但久失联就不能再假装房间知情 |
| 反复断线 | 宽限期**不续期** | 否则一条抖动的连接可以让采集永远活着却从不重新确认 |
| 服务器回显 `active:false` 而我在录 | **立即撤销**,不给宽限 | 房间的指示器已经灭了而我的麦还热着 —— 正是要防的事故 |
| 快照里没有我(但没有显式 false) | 走宽限期,不立即停 | 重连后服务器可能先发快照再处理我的 `rec_start`,立即停会导致每次重连都断录 |
| 录音端崩溃 | 服务器 45s 后自动撤标记 | 见 §2.3 |
| 用户点停止 | **同步立即**停采,不等网络 | 停止永远不能被网络阻塞 |

## 7. 未经真实多人会话验证的部分

以下只有真机多人跑一次才能确认,**不要当成已验证**:

- 20 路并发 renderer 的 CPU/GC(спайк 只验了 2 路)。
- 真实人声下 VAD 门限的实际效果(当前门限是合成信号上调出来的)。
- 服务器 `rec_*` 三个 case 与过期清理的真实行为(本文只给出片段,未在真服务器上跑过)。
- 多设备同一用户同时录音的表现(协议按 userId 建键,设备维度无法表达)。
- TCP 半开场景 —— 见 §2.5,当前是已知缺口。
