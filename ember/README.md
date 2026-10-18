# Ember · 炉灵

炉灵,意思是炉火之灵,英文名 Ember。它是一个坐在会里的 AI:能听、能答、能出纪要,记得大家同意留下的东西,但不记得是谁说的。规则受查塔姆规则启发,非官方,与 Chatham House 无隶属:会上说的话可以带出去,但不能说出是谁说的。

这个目录是炉灵的本体,与平台无关。它不依赖 Lares、LiveKit,也不依赖任何 npm 包,只用 Node ≥ 20 内置模块。接到哪个会议平台,由平台插件决定:Lares 的插件在 `../ember-lares/`,Zoom / Teams 目前只有 stub,在 `adapters/`。

## 三个平面

| 平面 | 内容 | 存在哪里 |
|---|---|---|
| 原话面 | 实时原话,带说话人 | 只在会话内存里,散会即焚 |
| 知识面 | 经 Gate 处理、k-of-n 签名放行的去名知识 | 文件记忆,按作用域(Lares 上是圈)存,不含说话人 |
| 个人面 | 我自己说过的话 | 只在我自己的设备上,炉灵不碰 |

外向插件(bot API、执行器)只能读知识面。详见 `INTERFACE.md`。

## 去名(脱敏)

```
音频 ─▶ ASR(只转已同意成员)─▶ IngestGate:L0 结构 · L1 PII + 名单 · L2 机构 · 说话人 → P1/P2 · L3 改写
      ─▶ 脱敏账本 ledger(内存)─▶ skills / LLM / 记忆只读 ledger
出门:L4 复核 → roleRisk 标记 → 审阅 → k 人 Ed25519 签名 → released + 写入记忆
```

- 原话缓冲在 L3 之后立即清空,最长保留 60 秒。假名映射只留在 IngestGate 内部。
- LLM 永远看不到名字或原话,测试里有断言。
- 规格见 `AGENT-V2.md` §5,Gate 各层的实现在 `core/gate/`,评测在 `eval/`。

## Skills

格式模仿 Agent Skills:`skills/<name>/SKILL.md`(front-matter 是 `name`、`description`、`outputs: room|release`)加 `run.mjs`。炉灵启动时加载这些 skill。客户端可以显式发 `skill`,也可以在 `ask` 里由 LLM 路由过去。

- `answer`:基于 ledger 和记忆回答问题,结果只留在房间里。
- `minutes`:去名会议纪要,要走草稿 → 审阅 → 签名放行。

## 文件记忆

`core/filememory.mjs`。只收已放行的条目,条目可以撤回,撤回后变墓碑。输出前过马赛克检查(`recallForOutput`)。宿主只读接口是 `readReleasedKnowledge(dir, q)`,Lares 服务端的 `/anonym/knowledge` 用的就是它。不给 `memoryDir` 时,记忆只放在内存里。

## 接到平台:port

平台插件实现一个 port,交给 `createEmber`:

```js
import { createEmber } from 'ember-agent'; // 仓库内用相对路径:'../ember/index.mjs'
const ember = await createEmber({ port, llm, asr, memoryDir, policy: { k: 2, convenerId, scopeId } });
await ember.start();
const receipt = await ember.done; // 散会回执(只有计数和哈希,没有内容)
```

- port 要提供这些能力:参与者进出与显示名、逐人音频帧、收发会话消息、`notifyHost`(只发元数据)、`join` / `leave`。完整规格见 `PORT.md`,形状检查在 `port.mjs`。
- `llm` 只要 `chat(messages, opts)` 就行,给 `null` 时走全确定性的 mock 路径。
- `asr` 是 `open({identity, onFinal, …})` 形式的 provider,`MockAsr` 可用于测试。

## 目录

```
index.mjs      公共 API(createEmber 及各模块再导出)
port.mjs       port 形状 / checkPort        PORT.md
agent/         会话(session)、IngestGate、ASR 分流、skills 加载、记忆接口、密封、音频工具、MockAsr
core/          Gate L0–L4、crypto、filememory、memory
skills/        answer、minutes
adapters/      zoom / teams stub
eval/  test/   评测与测试(node --test ember/)
INTERFACE.md  AGENT-V2.md  SEALING.md  IMPL-NOTES.md
```

真 LLM 测试默认跳过。需要时把 key 以内联环境变量的方式传入,不要写进文件:`$env:LARES_AI_LLM_KEY='…'; node --test ember/`。
