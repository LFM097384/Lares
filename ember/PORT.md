# Ember 平台 port

Ember(炉灵)不认识任何会议平台。平台插件(`ember-lares/`、将来的 Zoom / Teams adapter)实现一个 **port** 对象,交给 `createEmber({ port, … })`。Ember 只通过它碰外部世界。代码定义与形状检查在 `port.mjs`(`checkPort`、`PORT_EVENTS`)。

## 形状

| 成员 | 类型 | 说明 |
|---|---|---|
| `selfId` | `string` | Ember 在该平台的身份。来自它自己的事件一律忽略。 |
| `isHuman(id)` | `(id) => boolean`,可选 | 是不是真人。机器人、其它 AI 返回 false,它们进不了名单,也发不了消息。缺省全当真人。 |
| `on(event, fn)` | 订阅 | 事件见下表。 |
| `participants()` | `() => [{id, name}]` | `join()` 之后当前在场的人。 |
| `nameOf(id)` | 可选 | 显示名。只在内存里用来做名单清洗,不出进程。 |
| `send(obj, toId?)` | `Promise<void>` | 会话消息通道。不给 `toId` 就广播,给了就只发给这个人。`obj` 是 INTERFACE.md / AGENT-V2.md §5 定义的协议消息(`state` / `draft` / `released` / `error` …)。 |
| `notifyHost(event)` | `Promise<void>` | 通知宿主平台,**只含元数据,绝不含会话文字**:`{type:'active', on}` 表示会话开 / 关,宿主据此停转写、录音和其它机器人;`{type:'released', itemIds}` 表示有条目放行进记忆。 |
| `join()` / `leave()` | 生命周期 | 进会 / 离会。`leave` 必须幂等。 |

## 事件

| 事件 | 参数 | 说明 |
|---|---|---|
| `joined` | `(id, name?)` | 有人进来 |
| `left` | `(id)` | 有人离开。最后一个真人离开时,Ember 自动散会。 |
| `name` | `(id, name)` | 得知或更新显示名 |
| `audio` | `(id, Int16Array pcm, sampleRate, channels)` | 逐人分轨的一帧音频。没 ack 的人,音频在 ASR 之前就丢掉。 |
| `message` | `(id, obj)` | 该参与者发来的一条协议消息,已解析成 JSON |
| `disconnected` | `(reason)` | 平台连接断了。Ember 本身不处理,由插件决定重连还是退出(退出码)。 |
| `transcript` | `(id, text)` | **可选**,只在 `port.transcripts === true` 时订阅(`OPTIONAL_PORT_EVENTS`)。平台自己出的带说话人定稿转写(Zoom RTMS)。与 ASR 定稿走同一个 `onTranscript`:没 ack 的人直接丢,其余立刻过 IngestGate(L0–L3 + 假名)进 ledger,原话不留引用。 |

## 生命周期

```js
const ember = await createEmber({ port, llm, asr, memoryDir, policy: { k, convenerId, scopeId } });
await ember.start();            // port.join() → participants() 入名单 → notifyHost({type:'active', on:true})
// … 会话进行 …
const receipt = await ember.done; // convener 发 end / 最后一人离开 → 回执;autoLeave(缺省开)时随后 port.leave()
await ember.stop('stop');       // 或宿主主动散会
```

`policy.scopeId` 是记忆作用域,Lares 上就是圈 id,同时进入密封 AAD 与记忆路径。`policy.k` 是放行门槛,`policy.convenerId` 是唯一能 `end` 的人。

## 各平台映射

| port | Lares(`ember-lares/port.mjs`) | Zoom(`ember-zoom/port.mjs`) | Teams(stub) |
|---|---|---|---|
| `send` | LiveKit data topic `lares.anon`,reliable | 侧边栏 WS hub | 侧边栏 |
| `message` | `lares.anon` 收到的 JSON | 侧边栏 WS hub | 侧边栏 |
| `audio` / `transcript` | LiveKit 每人音轨,48 kHz | RTMS 转写(msg 17,缺省)或每人 L16 16 kHz(msg 14) | 媒体侧车 |
| `notifyHost` active / released | 信令 `anon_active` / `anon_released_notice` | 侧边栏 `zoom_active` + stdout 元数据事件 | 平台「AI 在场」提示 |
| `isHuman` | `u_ai_*`、`bot:*` 不是人 | 除自身外都是人 | 平台 bot 标记 |
