# 灶语 port 接口

灶语(Hearthvoice)本体不认识任何平台。它通过一个 **port** 对象和「房间」打交道。port 负责三件事:

- 把房间里的声音、文字、名字、进出交进来;
- 把字幕、文字、状态发出去;
- 提供一条**出站音轨**,让灶语说话。

平台插件(例如 `../hearthvoice-lares/port.mjs`)实现 port,`createHearthvoice({ port, … })` 消费它。
写法参照炉灵的 `ember/PORT.md`。不同之处:灶语会说话,所以多了 `audioOut()`。

代码:`./port.mjs` 中的 `checkPort(port)` 做形状校验,`memoryPort()` 是测试与联调用的内存实现,`PORT_EVENTS` 是事件表。

## 成员

| 成员 | 必需 | 说明 |
|---|---|---|
| `selfId: string` | ✔ | 灶语自己在房间里的身份。它的声音和消息一律忽略 |
| `isHuman?(id): boolean` | | 平台规则:这个身份是不是真人。返回 false 的(别的 AI、机器人)不听也不答。缺省时全当真人。Lares 的实现是:`u_ai_*` 和 `bot:*` 不是真人 |
| `on(event, fn)` | ✔ | 订阅入站事件(见下表)。可返回一个退订函数 |
| `join(): Promise` | ✔ | 进房。`start()` 会先挂好全部处理器再调它,因为有的平台在连上之前就开始投递事件 |
| `leave(): Promise` | ✔ | 离房。`stop()` 调用,只调一次 |
| `audioOut(): AudioOut` | ✔ | 出站音轨。`join()` 成功后调一次 |
| `sendChat(text): any` | ✔ | 发一条文字消息,内容是回复或被打断后的「…」版本 |
| `publishCaption(cap): any` | ✔ | 发字幕 `{t:'cap', id, seq, text, final}`。一轮一个 `id`,`seq` 递增,最后一帧 `final:true` |
| `publishState?(frame): any` | | 发状态 `{t:'state', state:'idle'|'listening'|'thinking'|'speaking', seq}`。只在变化时发,不含任何文字 |
| `rename?(name): any` | | 配置里的名字变了,更新显示名 |

发送类方法可以返回 Promise。本体不等待它们,失败时静默吞掉,所以一条消息发不出去不会卡住回合。

### AudioOut(出站音轨)

```
{ captureFrame(pcm: Int16Array): any,   // 48 kHz、单声道、480 样本(10 ms)一帧;每帧是独立拷贝
  clear(): void,                        // 打断:清空尚未播出的队列(建议平台侧队列 ≤ 200 ms)
  queuedMs(): number }                  // 已交出、尚未播出的毫秒数(用来算「人实际听到哪儿」)
```

本体按实时节拍逐帧送入。`queuedMs()` 用来扣掉没播完的部分,从而得到「听到了什么」。这个值会影响历史记录、聊天和最终字幕的内容。

## 入站事件

| 事件 | 回调参数 | 说明 |
|---|---|---|
| `audio` | `(identity, pcm: Int16Array, sampleRate, channels)` | 一位参与者的一帧音频。任意采样率都行,本体自己重采样 |
| `chat` | `({id?, senderId, senderName?, body, bot?: boolean})` | 一条文字消息。`bot:true` 的不理 |
| `name` | `(identity, displayName)` | 得知或更新显示名。LLM 看到的提问格式是「名字: 问题」 |
| `joined` | `(identity)` | 有人进来。本体会补发一次当前状态 |
| `left` | `(identity)` | 有人离开。关掉他的 ASR,丢掉排队中的请求 |
| `capctl` | `(identity, {t:'capack'|'capreq', on?})` | 字幕控制。回过 `capack{on:false}` 的人,其声音不送 ASR |
| `disconnected` | `(reason)` | 与房间断开。**本体不处理**,由插件决定退出码或是否重连 |

## 生命周期

```
const hv = createHearthvoice({ port, asr, llm, tts, policy });
hv.dailyCapReached()  // 可选:今天额度已满就别进房
await hv.start()      // on(...) ×6 → join() → audioOut() → 补发状态
hv.setConfig(cfg)     // 热更新;名字变了调 rename()
await hv.stop()       // 退订 → 停播、关 ASR/TTS → leave()(幂等)
```

## 隐私约定(port 实现方的责任)

- `audio` 只交给本体房间里**正在发生**的声音,不要回放录音。
- 平台的「谁同意被转写」信号要转成 `capctl`。
- 正文(问题和回答)只出现在 `sendChat` 和 `publishCaption` 里。`publishState` 与本体发出的结构化事件默认不带正文(`policy.logText` 为真时才带)。
