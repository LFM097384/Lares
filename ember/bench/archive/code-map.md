# EmberBench / Ember 代码地图

本文只列路径和一句话作用，不复制源码。作用说明取自各文件的头注释。路径相对仓库根目录 `D:\Projects\Lares`。

## 闸门（`ember/core/gate/`）

| 路径 | 作用 |
|---|---|
| `ember/core/gate/gate.mjs` | Gate v2 总控：编排 L0P/L0–L4，导出 `runGate`、`verifyClaims`、`NOTICE`、`DROP` 等；`llm` 由调用方注入，`null` 时走 mock |
| `ember/core/gate/llm.mjs` | 注入式 LLM 接口；`createDeepSeekLLM`（OpenAI 兼容的 /chat/completions）、`parseJSON`、`chatJSON`；key 不会写进日志 |
| `ember/core/gate/l0.mjs` | L0 结构清洗：去掉说话人字段和时间戳，按话题聚类，用带种子的随机数打乱 |
| `ember/core/gate/pseudonym.mjs` | L0P 全量化名 + `reveal_name` 确定性裁决（v5，METHOD §10.1–§10.2），只在公开模式下生效 |
| `ember/core/gate/l1.mjs` | L1 确定性 PII：正则加名单字典，占位符不编号 |
| `ember/core/gate/l2.mjs` | L2 机构与职务脱敏；公开模式下的公共事实处理 |
| `ember/core/gate/l3.mjs` | L3 去归属改写（LLM），输入已经过 L1+L2 脱敏 |
| `ember/core/gate/l4.mjs` | L4 归属攻击 + 定向泛化循环 + 语气检查 |
| `ember/core/gate/guard.mjs` | 确定性输出守卫，闸门、记忆、房内回答三处共用 |
| `ember/core/gate/shield.mjs` | 公共实体护盾：公共世界知识默认保留，除非它指回某个参与者 |
| `ember/core/gate/binding.mjs` | 公开模式下对机构、席位、自我特征做绑定感知处理（v3，METHOD §8.1） |
| `ember/core/gate/strictness.mjs` | 严格度旋钮 0–3（v4，METHOD §9.8），1 为默认且与原行为相同，只在公开模式下生效 |

## 会话核心（`ember/core/`）

| 路径 | 作用 |
|---|---|
| `ember/core/index.mjs` | 会话核心 `createSession`：原始文本只存在于 Session 闭包内；`draft()` 把 `policy.publicContext/strictness/pseudonym` 传给 `runGate` |
| `ember/core/crypto.mjs` | 规范化 JSON、Ed25519 等加密工具（只用 node:crypto） |
| `ember/core/memory.mjs` | 持久化的去标识知识库，只收 k-of-n 放行的条目 |
| `ember/core/filememory.mjs` | 基于文件、非向量的圈子记忆 |
| `ember/core/mock-llm.mjs` | 符合注入式 LLM 接口的离线测试替身 |

## 产品入口

| 路径 | 作用 |
|---|---|
| `ember/index.mjs` | 炉灵公共 API `createEmber({port, llm, asr, memoryDir, policy})`，与平台无关；重新导出 `createDeepSeekLLM` 等 |
| `ember/agent/session.mjs` | v2 agent 会话核心（AGENT-V2.md §4–§7） |
| `ember/agent/ingest_gate.mjs` | 入口脱敏 IngestGate（L0/L1/L2，AGENT-V2.md §5） |
| `ember-lares/index.mjs` | 炉灵在 Lares 上的进程入口；`llmFromEnv` 读取 `LARES_AI_LLM_*` 并构造 DeepSeek LLM |

## 基准主体（`ember/bench/`）

| 路径 | 作用 |
|---|---|
| `ember/bench/run.mjs` | EmberBench CLI（`--split / --track / --schema v4|v5 / --strictness / --seal / --mock` 等） |
| `ember/bench/harness.mjs` | 对单条转写或圈子运行被测单元（raw / ideas-only / +L4 / agent），再交给攻击者和评审 |
| `ember/bench/attack.mjs` | v1–v3 攻击者（insider / acquaintance / outsider / ideas-only）与评审，每个都有 mock |
| `ember/bench/providers.mjs` | LLM provider 规格 `provider:model`，可按角色配置，key 从环境变量读取 |
| `ember/bench/chatgpt.mjs` | ChatGPT（Codex）订阅 provider `chatgpt:<model>`，P12 探针用 |
| `ember/bench/data.mjs` | 数据集加载、split 完整性检查、哈希固定、test 封存 |
| `ember/bench/metrics.mjs` | v2 确定性指标（纯函数） |
| `ember/bench/metrics-v3.mjs` | v3 绑定感知确定性指标（METHOD §8.4） |
| `ember/bench/metrics-v5.mjs` | v5 全量化名下的硬零（METHOD §10.4–§10.5），约束位置检测与闸门相互独立实现 |
| `ember/bench/bootstrap.mjs` | 带种子的 bootstrap CI 与运行间离散度汇总 |
| `ember/bench/trustcard.mjs` | 汇总逐条结果，套用预注册阈值，渲染信任卡 |
| `ember/bench/rescore-v3.mjs` | 对已存的 public 记录做 v3 确定性重算，不调用 LLM |
| `ember/bench/METHOD.md` | 预注册方法与修订记录（快照见 `method/METHOD.md`，快照时最后一条为 P12） |

## v4 / v5 计分（`ember/bench/v4/`、`ember/bench/v5/`）

| 路径 | 作用 |
|---|---|
| `ember/bench/v4/estimator.mjs` | 陌生人比特泄露估计器（METHOD §9.2–§9.3，纯函数） |
| `ember/bench/v4/attack-v4.mjs` | 陌生人分布攻击者、claim→说话人对齐器、记忆探针，每个都有 mock |
| `ember/bench/v4/score-v4.mjs` | v4 逐条计分与汇总 |
| `ember/bench/v4/score-v5.mjs` | 在 v4 机制上做 v5 汇总：P1、C 不变，硬零换成 T1 v5 / T2 v5 / T6 v5 |
| `ember/bench/v4/rescore-v4.mjs` | 对存档记录重算 v4，不调用闸门（`--run` / `--attack`） |
| `ember/bench/v4/frontier.mjs` | dev 上各严格度级别的隐私/效用前沿 |
| `ember/bench/v5/leak-audit.mjs` | P13 离线泄露审计 |
| `ember/bench/v5/replay-p13.mjs` | P13 离线回放 |

注：写本文件时 `ember/bench/v5/` 下还只有 `_probe.mjs`、`_probe2.mjs`（无头注释，未纳入），上面两个 P13 脚本是计划中的路径。

## 数据生成（`ember/bench/gen/`）

| 路径 | 作用 |
|---|---|
| `ember/bench/gen/specs.mjs` | 合成场景规格，split 写在规格里 |
| `ember/bench/gen/generate.mjs` | 合成场景生成器（写 `data/{dev,test}/<id>.json` 与 `.check.json`） |
| `ember/bench/gen/finalize.mjs` | 应用第二模型一致性检查的结果（确定性、幂等） |
| `ember/bench/gen/validate.mjs` | 转写 schema 与一致性校验 |
| `ember/bench/gen/import-legacy.mjs` | 把 10 段旧转写映射为 bench schema |
| `ember/bench/gen/import-public.mjs` | MeetingBank（Kaggle 派生版）导入器，确定性，不联网 |
| `ember/bench/gen/annotate-public.mjs` | public 轨金标标注（Speaker N → 姓名/职务/机构） |
| `ember/bench/gen/annotate-v3.mjs` | v3 绑定标注（机构/地点/标识 span） |

## 测试（`ember/test/`，`node --test ember/`）

| 路径 | 作用 |
|---|---|
| `ember/test/gate.test.mjs` | Gate v2 各层测试 |
| `ember/test/gate-pseudonym.test.mjs` | v5 L0P 化名、揭名裁决、事后检查、v5 指标 |
| `ember/test/gate-binding.test.mjs` | 公开模式下的绑定感知闸门机制（v3） |
| `ember/test/gate-publicfacts.test.mjs` | 公共事实默认保留，指回参与者时除外 |
| `ember/test/gate-selforg.test.mjs` | 会话内学到的自报机构，在整场会话中都要脱敏 |
| `ember/test/public-body.test.mjs` | 公开模式（`publicContext`，METHOD P3） |
| `ember/test/bench-harness.test.mjs` | harness 离线端到端（mock） |
| `ember/test/bench-metrics.test.mjs` | v2 指标、bootstrap、split、阈值、CLI 参数 |
| `ember/test/bench-public.test.mjs` | public 轨导入、名单映射、指标 |
| `ember/test/bench-v3.test.mjs` | v3 指标与选取 |
| `ember/test/bench-v4.test.mjs` | v4 估计器、校准、解析、严格度旋钮 |
| `ember/test/chatgpt-provider.test.mjs` | chatgpt provider（fetch 用 mock） |
| `ember/test/real_llm.test.mjs` | 真 LLM 抽查，无 key 时跳过 |
| `ember/test/agent.test.mjs` | `createEmber` + FakePort + MockAsr |
| `ember/test/session.test.mjs`、`memory.test.mjs`、`filememory.test.mjs`、`crypto.test.mjs`、`guard.test.mjs`、`gate-handle.test.mjs`、`eval-metrics.test.mjs` | 会话、记忆、加密、守卫等单元测试（无头注释，作用按文件名推断） |
