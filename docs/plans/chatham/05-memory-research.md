# 隐名之约 · 非向量、基于文件的 agent 记忆：现状调研与推荐设计

> 受 Chatham House 规则启发 · 非官方。与 Chatham House 无隶属。
> 状态：调研 + 设计建议(2026-10)。**不改代码**。现有实现 `ember/core/memory.mjs`(单个 JSON 文件 + 字符二元组相似度 + 马赛克启发式 + L4 复核)是本设计的起点；客户端协议见 `client-memory-protocol.md`。
> 约束回顾：只存经放行、去名、无说话人的知识(idea / decision / todo / fact)；放行人可撤回，撤回必须**真删**；用于房间内答问和按需出会议纪要；每圈一份纯文件(markdown/JSON)，由 agent 自己维护；**不用 embedding、不用向量库、不加 npm 依赖**；Node.js ESM；LLM 为 DeepSeek `deepseek-flash`(便宜，128k 上下文，OpenAI 兼容)；规模为每圈几十场会、几百到几千条。

---

## 0. 一句话结论

**推荐「原子条目为唯一真相 + 派生文件可重建」的三层文件结构**：`items/*.jsonl` 存经放行的原文(只有它是真相)，`topics/*.md`、`meetings/*.md`、`MEMORY.md` 全是**带来源 id 的派生物**，`log.jsonl` 只记操作、不记正文。检索分三步：先读索引，再在进程内对条目做 BM25(复用现有字符二元组分词)，最后让 LLM 在几十条候选里挑选并作答，出门前照旧过马赛克检查和 L4。整理工作参照 ACE 的做法：LLM 只输出结构化的 delta 操作，由代码确定性地应用，**LLM 永远不改写已放行的原文**。撤回时先物理删除条目，同步删掉引用它的派生文件，再从剩余条目**从零重新生成**，不在旧摘要上"抹掉"那一条。

---

## 1. 调研：各路做法

### 1.1 Anthropic Claude memory tool(`/memories`)与上下文工程

- **机制**：客户端工具。Claude 发出 `view / create / str_replace / insert / delete / rename` 等文件操作，由应用在自己控制的存储上执行，`/memories` 只是一个路径前缀，应用可以映射到每用户目录或数据库键。开启后 Claude 会在任务开始前**先查看记忆目录**，之后按需读取，官方称之为 just-in-time context retrieval([文档](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool))。文档要求做路径穿越防护，并建议把它和 context editing、compaction 配合使用。
- **上下文工程指导**：Anthropic 认为上下文是有限资源，应维护"最小高信号 token 集"，用轻量标识符(路径、查询)在运行时加载数据，长任务靠结构化笔记、压缩和子 agent 撑住([Effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents))。
- **对我们的启示**：存储位置和格式由宿主决定；「先看目录再读文件」的两段式读取；删除就是普通的文件操作。但它没有提供来源追踪，也没有处理派生物的删除。

### 1.2 Claude Code CLAUDE.md / auto memory，Codex AGENTS.md：层级指令文件

- **Claude Code**：CLAUDE.md 由人写，按 managed policy → 用户 → 项目 → 子目录的顺序加载；auto memory 由 Claude 自己写。两者每次会话都加载，auto memory 只加载**前 200 行或 25KB**。官方建议单个 CLAUDE.md 不超过 200 行，超长会降低遵循度；`@import` 只帮助组织内容，不减少上下文占用([Claude Code memory 文档](https://code.claude.com/docs/en/memory))。
- **Codex AGENTS.md**：从全局 `~/.codex` 开始，沿项目根到当前目录逐层拼接，越近的文件越靠后、优先级越高；合并后上限 `project_doc_max_bytes` 默认 32 KiB([Codex AGENTS.md 文档](https://learn.chatgpt.com/docs/agent-configuration/agents-md.md))。
- **启示**：有两个可以直接照搬的工程常数：**常驻索引必须有硬上限**(200 行 / 25–32KB 量级)，细节放到按需加载的文件里。这类文件属于"程序性记忆"(怎么做事)，不是"事实库"，它们几乎没有删除语义。

### 1.3 Letta / MemGPT：memory blocks + archival memory + 文件系统基准

- **机制**：MemGPT 仿照操作系统做分层：core memory(常驻上下文的 memory blocks，每块有 label、value 和字符上限，agent 用工具自改)、对话记忆、archival memory(外部长期存储，按需 insert/search)、外部文件([Letta 文档：context hierarchy](https://docs.letta.com/v1-sdk/memory/context-hierarchy)、[memory blocks](https://docs.letta.com/v1-sdk/memory/memory-blocks))。
- **文件系统基准**：Letta 2025-08 把 LoCoMo 对话历史直接作为文件交给 agent，工具只有 `grep`、`search_files`、`open/close`，用 `gpt-4o-mini` 得到 **74.0%**，高于 Mem0 自报最好的 68.5%。他们的解释是：agent 会自己改写查询、迭代检索，而且这些工具在训练数据里常见([Letta blog 转录](https://raw.githubusercontent.com/lhl/agentic-memory/refs/heads/main/benchmarks/sources/letta-blog-benchmarking.md)，原文 <https://www.letta.com/blog/benchmarking-ai-agent-memory>)。
- **必须说清的一点**：Letta 实验里的 `search_files` **是语义(向量)检索**，规则还要求第一步必须调它。所以这**不是**"纯 grep 打赢向量"的证据，它证明的是「文件 + 会用工具的 agent」不比专用记忆系统差。

### 1.4 Manus："file system as context"

- **机制**：把文件系统当作无限大、可持久、agent 可直接操作的外部记忆。大块观察(网页、文件)写入沙盒，上下文只保留路径或 URL。压缩必须**可恢复**，丢正文时保留指针。另一个做法是反复改写 `todo.md`，把目标"背诵"到上下文末尾以维持注意力；同时强调 KV-cache 命中率，保持前缀稳定、上下文只追加([Manus 博客](https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus)；[中文摘要](https://raw.githubusercontent.com/jerrylususu/bookmark-summary/refs/heads/main/202507/2025-07-21-ai%E4%BB%A3%E7%90%86%E7%9A%84%E4%B8%8A%E4%B8%8B%E6%96%87%E5%B7%A5%E7%A8%8B%EF%BC%9A%E6%9E%84%E5%BB%BAmanus%E7%9A%84%E7%BB%8F%E9%AA%8C%E6%95%99%E8%AE%AD.md))。
- **启示**：可恢复压缩，即摘要永远指回原子条目；常驻前缀(系统提示 + MEMORY.md)保持稳定，可以吃到 DeepSeek 的前缀缓存。这些全是工程经验，**没有基准数据**。

### 1.5 ACE(Agentic Context Engineering，Stanford / SambaNova 等，ICLR 2026)

- **机制**：把上下文当作不断演化的 playbook，由 Generator、Reflector、Curator 三个角色维护。论文点名两种失败：**brevity bias**(为求简洁丢掉领域细节)和 **context collapse**(反复整篇重写导致细节逐步流失)。对策是 **incremental delta updates**：上下文由带 id 的条目(bullet)组成，Curator 只输出少量增删改条目，用非 LLM 逻辑合并；再配合 **grow-and-refine**，定期去重和剪枝([arXiv 2510.04618](https://arxiv.org/abs/2510.04618)，[HTML v3](https://arxiv.org/html/2510.04618v3))。
- **证据**：论文报告 agent 任务 +10.6%、金融任务 +8.6%；AppWorld 上用较小的开源模型追平榜首的生产级 agent。**注意**：任务是"学策略、学经验"(程序性记忆)，不是"记会议事实"。我们借的是它的**更新纪律**，不是它的效果数字。

### 1.6 Sleep-time compute 与离线整理("做梦")

- **论文**：Letta / UC Berkeley 2025-04 提出，在查询到来之前离线"预想"可能的问题并预先算好中间结果。在 Stateful GSM-Symbolic / AIME 上，同等准确率所需的测试时计算约降到 **1/5**，多问题摊销后单问成本降 2.5 倍；**用户问题越可预测，收益越大**([arXiv 2504.13171](https://arxiv.org/abs/2504.13171))。
- **产品化**：Anthropic 2026-05 在 Claude Managed Agents 推出 **Dreaming**(research preview)：在工作间隙读取记忆库和最多 100 段历史对话，合并重复、替换过期内容、跨 agent 提炼模式。**整理结果写入一个新记忆库，不改原库**，不满意可以直接删掉([量子位 / 36kr 报道](https://eu.36kr.com/en/p/3798898634677250)，官方链接 <https://claude.com/blog/new-in-claude-managed-agents>)。厂商称的提升(Harvey 约 6 倍完成率)属于客户证言，**弱证据**。
- **启示**：会后、离线整理；「整理产物与原始数据分开存放、可丢弃可重建」这一点正好对上我们的撤回需求。会议纪要和主题摘要可预测性高，适合在会后预先算好。

### 1.7 A-MEM(Zettelkasten 式互链笔记)

- **机制**：每条记忆是一张原子笔记(内容、上下文描述、关键词、标签、时间、embedding)；写入时检索 top-k 候选，由 LLM 决定是否建链；新笔记还会触发旧笔记的"演化"，即改写旧笔记的属性([分析笔记](https://raw.githubusercontent.com/lhl/agentic-memory/32e2bec4f65aa1286c81b6866fe815d7a61b71c2/ANALYSIS-arxiv-2502.12110-a-mem.md)，[arXiv 2502.12110](https://arxiv.org/abs/2502.12110))。
- **证据**：自报 LoCoMo 上 temporal F1 从 25.5 升到 45.9，token 用量是全文基线的约 1/7；但在 Mem0 论文的复跑中只有 **39.79%(J)**，排在多数系统之后([对比汇总](https://raw.githubusercontent.com/yonk-labs/stele/refs/heads/main/docs/benchmarks/findings/agentic-memory-comparison.md))。结果高度依赖评测方。
- **对我们**：原子笔记 + 显式链接这个思路有用；"演化"(静默改写旧笔记)**与我们正面冲突**，因为已放行的原文不得被 agent 改写，而且改写会让撤回无从追踪。链接候选依赖 embedding，我们要换成关键词重叠。

### 1.8 Karpathy 式 "LLM Wiki" / 索引文件

- **机制**：Karpathy 2026-04 的 gist 提出，LLM 不应在每次提问时从原始文档重新拼答案，而应**增量编译并维护一份互链的 markdown wiki**：`raw/`(不可变原始资料)、`wiki/`(LLM 维护的主题页)、`index.md`(总目录)、`log.md`(只追加的操作日志)；操作分 ingest / query / lint([gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)；社区实现 [karpathy-llm-wiki](https://raw.githubusercontent.com/Astro-Han/karpathy-llm-wiki/master/README.md))。
- **社区经验**：该实现明确**不做**向量或图检索，理由是"5–10 万 token 的精选 wiki 用 grep + read 更可靠，召回明显下降再加工具"；也**没做撤回机制**("还没发生过，到时手工处理")。
- **对我们**：目录结构几乎可以直接用；但我们必须补上它缺的两块：**来源追踪**和**撤回传播**。证据是一个约 100 篇规模的生产实践，属于**个案**。

### 1.9 LangMem：语义 / 情节 / 程序性三分

- **机制**：semantic(事实，分 collection 和 profile 两种形态)、episodic(过去经历、对话摘要、few-shot)、procedural(系统行为、提示规则)。每次记忆操作都是"读当前状态 → LLM 决定扩展或合并 → 输出新状态"；collection 型要处理新旧信息的删除、作废和合并，召回还应考虑重要性和新近度([LangMem 概念指南](https://raw.githubusercontent.com/langchain-ai/langmem/main/docs/docs/concepts/conceptual_guide.md))。
- **证据**：Mem0 论文复跑 LangMem 在 LoCoMo 上为 **58.10%**(同上对比汇总)，存储默认依赖语义检索。
- **映射到我们**：semantic 对应已放行条目(idea/decision/fact/todo)；episodic 对应每场会议的纪要；procedural 对应 agent 自身的行为规则(放在代码和提示里，**不写入圈子记忆**，避免和参与者数据混在一起)。

### 1.10 Agentic grep/BM25 vs 向量 RAG；长上下文 vs RAG

| 证据 | 结论 | 强弱 |
|---|---|---|
| Sen 等(PwC)2026-05，[arXiv 2605.15184](https://arxiv.org/abs/2605.15184) | 在 LongMemEval 的 **116 题**子集上，自研 harness 和 Claude Code / Codex / Gemini CLI 中，**grep 普遍高于向量检索**；但分数**强烈依赖 harness 和工具结果的呈现方式** | 中：样本小，单一作者团队；方向与其他证据一致 |
| LongMemEval-V2，2026-05，[arXiv 2605.12493](https://arxiv.org/abs/2605.12493) | 把轨迹存成文件、交给 coding agent 取证，得 **72.5%**；最强 RAG 基线 48.5%；现成 coding agent 69.3%；**代价是每问 140–186 秒**([笔记](https://raw.githubusercontent.com/hannesdelbeke/brain/refs/heads/main/2026-09-21%20longmemeval%20v2%20scores%20a%20coding%20agent%20over%20raw%20trajectories%20above%20every%20rag%20memory%20layer.md)) | 中强：原作者团队、451 道人工题；但领域是 web agent 轨迹，不是会议 |
| LongMemEval v1，[arXiv 2410.10813](https://arxiv.org/abs/2410.10813) | 约 115k token 历史全塞进去，长上下文模型比"只给相关会话"**低 30–60%**；GPT-4o 全文 60.6–64% vs oracle 87–92%；**以轮次为单位存储优于整段会话，也优于抽取后的原子事实**；"读"环节丢的分不比"检索"少，chain-of-note / JSON 结构化输出可挽回约 10 分 | 强：ICLR 2025，被广泛复现 |
| LoCoMo 各家数字，[对比汇总](https://raw.githubusercontent.com/yonk-labs/stele/refs/heads/main/docs/benchmarks/findings/agentic-memory-comparison.md) | gpt-4o-mini 作答时普遍落在 66–76%；Mem0 论文里的**全文基线 72.9% 是"天花板"**；同一系统由不同评测方跑可得 58 / 66 / 75% | 弱到中：厂商自跑，存在评测争议(Zep↔Mem0) |
| Mem0 自报 LongMemEval 94.4% vs 第三方 49% | 相差 45 分，无独立评分方 | **弱**，不应引用 |

**综合判断**：①「文件 + 关键词检索 + 会用工具的 LLM」**至少不输**向量 RAG，这一点有多方证据，方向一致；②在几千条短条目的规模下，长上下文全塞**可行但不最优**(LongMemEval 的退化主要发生在 10 万 token 以上的长历史)；③最好的结果来自**多轮 agentic 搜索**，但延迟高达分钟级，**不适合会议中实时答问**，所以我们只做"一次确定性检索 + 一次 LLM 挑选"，把多轮搜索留给离线整理。

### 1.11 2026 年新动向

- **派生记忆的删除语义**：Mahendrakar 2026-09([Zenodo 22425281](https://zenodo.org/records/22425281))把 "delete" 拆成五种操作：删条目、撤回派生物、禁止其支撑输出、使其不可推断、恢复到"从未写入"的状态。论文指出第二种就是数据库的视图删除问题；**删除本身也是一种推断信号**；对 LLM 驱动的整理，第五种没有定义，因为同样的输入在不同更新顺序下会产生不同的记忆。
- **执行态遗忘**：Yao 等 2026-09([arXiv 2609.04875](https://arxiv.org/abs/2609.04875))实测：**只删明文记忆记录，泄露不变**；靠指令让模型"忘掉"在诱导下完全失效(Leak@probes = 1.00)；只做源头删改，仍有 80% 的回合在利用已撤回的偏好；按来源图做选择性重放，效果与完全重置不可区分。**这是我们"撤回必须连带重建派生物"最直接的实证依据。**
- **Dreaming / Outcomes**(见 1.6)：离线整理进入商用，形态是"整理产物另存一库"。
- **LongMemEval-V2 与 grep 论文**(见 1.10)：2026 年的主流叙事从"选什么检索器"转向"harness 和工具形态更重要"。

---

## 2. 对比表

| 方案 | 机制 | 检索方式 | 更新与整理 | 删除 / 撤回支持 | 基准证据 | 对我们的适配 |
|---|---|---|---|---|---|---|
| Claude memory tool | 客户端文件 CRUD，`/memories` 前缀 | agent 先 `view` 目录再读文件 | agent 随手改，无整理流程 | 有 `delete`；**不处理派生物** | 无公开基准(官方文档) | ★★★ 借"先目录后文件"和宿主控制存储 |
| CLAUDE.md / AGENTS.md / auto memory | 层级 markdown，启动全量加载 | 不检索，全部常驻(有上限) | 人写；auto memory 由 agent 追加 | 手工删 | 无；200 行 / 25KB / 32KiB 是工程上限 | ★★ 借"常驻索引硬上限" |
| Letta / MemGPT | core blocks 常驻 + archival 外存 | archival 用语义搜索；blocks 常驻 | agent 用工具自改 blocks | 可删 passage；派生 blocks 不追踪 | 文件 agent LoCoMo 74.0%(含向量工具) | ★★ 借"常驻小块 + 外存大库"的分层 |
| Manus 文件即上下文 | 沙盒文件当外部记忆 | 路径指针，按需读 | 可恢复压缩、todo 背诵 | 未讨论 | 无(工程经验) | ★★ 借"摘要必须可回溯到原文" |
| ACE | 带 id 的条目式 playbook，三角色 | 整个 playbook 入上下文 | **delta 增量 + 定期去重**，防 collapse | 可删条目；未讨论派生 | AppWorld +10.6%，金融 +8.6%(策略学习) | ★★★ 借更新纪律 |
| Sleep-time / Dreaming | 离线预计算、整理 | 读预计算结果 | 离线合并、去重、换新；**另存新库** | 新库可整体丢弃 | 测试时计算降到约 1/5(数学题)；产品证言 | ★★★ 会后整理，派生物可重建 |
| A-MEM | 原子笔记 + LLM 建链 + 演化 | embedding top-k + 邻居扩展 | 静默改写旧笔记 | 无；演化让追踪更难 | 自报强，复跑仅 39.8% | ★ 只借原子笔记和链接 |
| LLM Wiki | raw/ + wiki/ + index.md + log.md | index 先行 + grep + read | ingest 编译、lint 体检 | **明确未做** | 个案(约 100 篇) | ★★★ 目录结构可直接用，需补撤回 |
| LangMem | 语义 / 情节 / 程序三分 | 语义检索 + 过滤 | LLM 合并 / 作废 | 支持作废 | LoCoMo 58.1%(复跑) | ★★ 借分类法 |
| grep/BM25 agentic 搜索 | 原文件 + 关键词工具 + agent 循环 | 多轮 grep / read | 无(只读) | 删文件即可 | 116 题上 grep 优于向量；LME-V2 72.5% vs 48.5% | ★★★ 检索核心；但只做单轮 |
| 长上下文全塞 | 全部条目进提示 | 模型自己找 | 无 | 删即生效 | LME v1 长历史掉 30–60%；LoCoMo 全文 72.9% | ★★ 小圈子(<约 3 万 token)可作为降级路径 |
| 执行态遗忘 / 删除语义(2026) | 来源图 + 选择性重放 | — | — | **派生物必须重算**；删除是推断信号 | 只删记录泄露不变(实证) | ★★★ 撤回设计的依据 |

---

## 3. 推荐设计

### 3.1 设计原则

1. **单一真相**：只有 `items/` 里经放行的原文是事实来源。其余文件全是派生物，随时可删、可从 items 重建。
2. **LLM 不改写原文**：放行过的文字一字不动。LLM 只能产出新的派生文字(主题摘要、纪要)和结构化操作(归类、去重链接、取代链接)。
3. **派生物必带来源**：派生文件里的每一行都引用 `[i:<id>]`，front matter 里列出 `sources`。没有来源的派生文字不许落盘。
4. **日志不记正文**：`log.jsonl` 只记操作类型、id 和时间，所以撤回不需要改写日志。
5. **撤回 = 删条目 + 删派生物 + 从零重建**，fail-closed：重建失败就保持删除状态，降级为直接列条目。
6. **会中便宜，会后用心**：会议中只做确定性检索加一次 LLM 调用；整理放在会后离线跑。

### 3.2 目录结构(每圈一个目录)

```
<DATA>/anonym-memory/<circleKey>/          # circleKey = sha256(circleId) 前 16 位，路径里不出现圈名
├── MEMORY.md            # 派生：常驻索引，≤ 150 行 / 8KB，每次回答都放进提示
├── items/               # 真相：经放行的原子条目
│   ├── 2026-10.jsonl    #   按放行月份分片，每行一条；撤回时整片原子重写
│   └── 2026-11.jsonl
├── releases.jsonl       # 真相：放行记录(k、签名数、approverHashes、itemIds)，供撤回鉴权
├── topics/              # 派生：主题页，由 consolidate 生成
│   ├── budget.md
│   └── onboarding.md
├── meetings/            # 派生：每场会的纪要(情节记忆)
│   └── s-7f3a.md
├── links.json           # 派生(可重建)：dupOf / supersedes / topic 归属
├── log.jsonl            # 只追加：操作日志，无正文
└── state.json           # 小状态：上次整理的游标、dirty 集合、schema 版本
```

为什么条目用 JSONL 分片而不是一条一个文件：几千个小文件在 Windows/NTFS 上遍历慢、不好备份；按月分片后，一次撤回只重写一片(几十 KB)，用"写 tmp + rename"保证原子性(沿用现有 `jsonFileStorage` 的做法)。为什么不是现在的单个 JSON：单文件下每次撤回都要重写全部数据，主题和纪要也无处安放。

### 3.3 文件格式

**items/2026-10.jsonl**(一行一条；字段白名单沿用现有 `addRelease`)

```json
{"id":"i_01J9Z8K2","kind":"decision","text":"下季度预算向用户研究倾斜，砍掉线下推广。","sid":"s-7f3a","releasedAt":1761900000000,"approvals":4,"topic":"budget"}
{"id":"i_01J9Z8K3","kind":"todo","text":"两周内整理一份竞品访谈提纲。","sid":"s-7f3a","releasedAt":1761900000000,"approvals":4,"topic":"user-research"}
```

- **不含**说话人、原话、审核理由、放行人身份。`topic` 是 consolidate 写回的归类，属于派生信息，可以重算。

**releases.jsonl**

```json
{"releaseId":"r_…","sid":"s-7f3a","releasedAt":1761900000000,"k":4,"approvals":4,"itemIds":["i_01J9Z8K2","i_01J9Z8K3"],"approverHashes":["9c1e…","a07b…"]}
```

**topics/budget.md**(派生物，代码渲染骨架，LLM 只写摘要那一段)

```markdown
---
topic: budget
title: 预算与投放
sources: [i_01J9Z8K2, i_01J9ZA11, i_01JA0C02]
generatedAt: 2026-11-02T03:10:00Z
gate: {mosaic: pass, l4: pass}
---
## 摘要
圈子倾向把预算从线下推广转向用户研究 [i:i_01J9Z8K2]；11 月复议后维持该方向 [i:i_01JA0C02]。

## 条目
- (decision, 2026-10-31) 下季度预算向用户研究倾斜，砍掉线下推广。 [i:i_01J9Z8K2]
- (fact, 2026-10-31) 去年线下推广转化率低于 1%。 [i:i_01J9ZA11]
- (decision, 2026-11-14) 复议后维持向用户研究倾斜。 [i:i_01JA0C02] (supersedes i_01J9Z8K2)
```

"条目"一节由代码从 items 直接渲染，不经 LLM；只有"摘要"一段是 LLM 写的，而且必须带 `[i:…]` 引用。渲染器会校验摘要里引用的 id 都在 `sources` 中且仍然有效，否则丢弃摘要。

**meetings/s-7f3a.md**(会议纪要，派生物)

```markdown
---
sid: s-7f3a
date: 2026-10-31
sources: [i_01J9Z8K2, i_01J9Z8K3, i_01J9ZA11]
generatedAt: …
gate: {mosaic: pass, l4: pass}
---
# 2026-10-31 会议纪要(去名 · 经放行)
## 决定
- 下季度预算向用户研究倾斜，砍掉线下推广。 [i:i_01J9Z8K2]
## 待办
- 两周内整理一份竞品访谈提纲。 [i:i_01J9Z8K3]
## 事实
- 去年线下推广转化率低于 1%。 [i:i_01J9ZA11]
```

纪要默认**只用原文拼装**(按 kind 分组、按时间排序)，零 LLM、零改写；用户要求"写成段落"时才调用 LLM 润色，润色结果只返回、不落盘，或者落盘但带 `sources`。

**MEMORY.md**(派生物，常驻提示)

```markdown
# 圈子记忆索引(自动生成，勿手改)
条目 412 条 · 会议 23 场 · 上次整理 2026-11-02
## 主题
- budget 预算与投放(14)：预算转向用户研究，11 月复议维持
- user-research 用户研究(37)：竞品访谈、招募渠道、访谈提纲
- …(≤ 40 个主题)
## 最近会议
- 2026-11-14 s-91c0(18 条) · 2026-10-31 s-7f3a(12 条) · …(≤ 10 场)
## 未结待办(≤ 15 条，仅 id 与前 30 字)
- [i:i_01J9Z8K3] 两周内整理一份竞品访谈提纲…
```

**log.jsonl**(只追加，**不含正文**)

```json
{"t":1761900000000,"op":"remember","ids":["i_01J9Z8K2","i_01J9Z8K3"],"sid":"s-7f3a"}
{"t":1762000000000,"op":"consolidate","ops":7,"regenerated":["topics/budget.md"]}
{"t":1763000000000,"op":"retract","id":"i_01J9Z8K2","regenerated":["topics/budget.md","meetings/s-7f3a.md","MEMORY.md"]}
```

日志里不写 `by`(谁撤回的)，也不写撤回前的文本，原因见 3.7。

### 3.4 检索算法(`recall`)

```
recall(q, {mode:'answer'|'minutes', sid?, budget=12k tokens})
 0. mode==='minutes' && sid → 直接读 meetings/<sid>.md(没有或已 dirty 就从 items 现拼)→ 第 5 步
 1. 索引先行：MEMORY.md 常驻在系统提示里(稳定前缀，吃 DeepSeek 前缀缓存)
 2. 降级路径：live 条目总 token < 3 万 → 跳过 3，所有条目按 topic 分组直接作为候选
 3. 确定性检索(进程内，零依赖)：
    a. 分词 = 现有 features()(中文字符二元组 + 拉丁词干 + 数字)
    b. BM25(k1=1.2, b=0.75)，对 live 条目打分；索引在启动时从 items 建倒排表，几千条 < 50ms
    c. 加权：命中 MEMORY.md 主题关键词的条目 ×1.3；kind 与问法匹配(「谁负责/待办」→todo，「定了什么」→decision)×1.2；
       被 supersede 的旧条目 ×0.5(仍可召回，用于回答"之前怎么定的")
    d. 时间提示(「上次」「十月」)→ 按 releasedAt 过滤 / 加权
    e. 取 top 40；按 dupOf 折叠重复条目
 4. LLM 选择 + 作答(一次 deepseek-flash 调用，JSON 输出)：
    输入 = MEMORY.md + 候选(只给 id、kind、日期、text)+ 问题
    输出 = {"use":[id…], "answer":"…[i:id]…", "insufficient":bool}
    规则：只能用候选里的内容；不知道就说不知道(LongMemEval 的 abstention 能力)；
    先逐条记 note 再作答(chain-of-note，LongMemEval 报告可挽回约 10 分)
 5. 出门：被引用的条目走 recallForOutput 那一套(mosaicHeuristic + L4 verifyClaims)；
    被丢弃的条目，连同引用它们的句子一起从答案里删掉；删完答不成就回答"这个我不能说"
```

可选的第二轮：LLM 返回 `insufficient:true` 且给出 `queries:[…]` 时，再跑一次第 3 步(最多 1 次)。这是 Letta / LME-V2 里"agent 自己改写查询"的低配版，把延迟控制在约 2 次 LLM 往返以内。**不在会议中跑多轮 agentic grep**：LME-V2 的 140–186 秒延迟在会议场景不可接受。

### 3.5 写入与整理规则

**`remember`(放行时，同步执行)**

1. 输入只能来自 Gate 放行的 release(k-of-n 已满足)；字段白名单，丢弃一切说话人信息。
2. 单条长度上限 300 字；超长直接拒绝写入(由 Gate 侧负责拆分，记忆层不擅自截断已放行的文字)。
3. 确定性去重：与同 kind 的 live 条目做 `similarity ≥ 0.85` → 仍然写入(它是另一次独立放行，放行人可能不同)，但在 links.json 记 `dupOf`。**不合并文本**。
4. 追加到当月分片；追加 releases.jsonl 和 log.jsonl；把 `meetings/<sid>.md` 和"未归类"标为 dirty。
5. 写入时马赛克检查(见 3.7)：新条目加上同 sid 的已有条目，一起跑 `mosaicHeuristic`。命中只打 flag，因为 Gate 已经放行过；但该条目在召回时会被重点复核。

**`consolidate`(会后离线 / 新条目 ≥ 30 条 / 每日一次，单写者)**

照搬 ACE 的分工，但去掉 Generator：

- **Reflector**(LLM，输入：未归类条目 + MEMORY.md 主题清单 + 每个相关主题的现有条目标题)，输出 **delta 操作 JSON**，不输出散文：
  ```json
  [{"op":"assign","id":"i_…","topic":"budget"},
   {"op":"new_topic","topic":"hiring","title":"招聘"},
   {"op":"dup","id":"i_…","of":"i_…"},
   {"op":"supersede","id":"i_new","old":"i_old"},
   {"op":"close_todo","todo":"i_…","by":"i_…"},
   {"op":"retitle","topic":"budget","title":"预算与投放"}]
  ```
- **Curator**(代码，非 LLM)：校验每个操作，包括 id 必须存在且有效、`supersede` 两条必须同 kind、`close_todo` 的 by 必须是后发且已放行的条目、主题总数不超过上限，然后**确定性地**应用到 links.json 和 items 的 `topic` 字段。
  - `close_todo` 只能由一条**新的放行条目**触发(例如"访谈提纲已完成")，agent 不能自己判定待办已完成。
- **重新渲染**受影响的 topics/*.md：条目节由代码渲染；摘要节交给 LLM，输入**只有该主题的现有条目**(不给旧摘要，避免 collapse 和残留)，≤ 120 字，必须带引用。
- **grow-and-refine**：主题超过 80 条时，由 LLM 提议拆分(仍以 delta 输出)；少于 3 条且 30 天没有新增的主题，并入相邻主题。
- 新生成的每份派生文件都要过**聚合马赛克检查**(3.7)，不通过就不写摘要，只留条目列表。
- 最后重建 MEMORY.md(纯代码，数字和标题来自 links.json 与主题 front matter)。
- 整理产物先写入 `.staging/`，全部校验通过后再逐个 rename 替换(参照 Dreaming"另存新库"的做法)。

### 3.6 撤回如何传播(`retract`)

```
retract(itemId, by):
  1. 鉴权：releases.jsonl 中该条目所属 release 的 approverHashes 含 hash(by)，或 by 是已确认圈主
  2. 取出该条目文本 T，仅在本次调用的内存里保留，用于第 6 步校验
  3. 物理删除：重写该条目所在的月分片(tmp + rename)，不留该行；
     写入墓碑行 {"id","retracted":true,"sid","retractedAt"}(无 text)，客户端协议需要它
  4. grep 所有派生文件中的 "i:<itemId>" 和 front matter 的 sources，得到受影响集合 D
     (topics/*、meetings/<sid>.md、MEMORY.md 总会被波及；links.json 中相关链接一并删除，
      被它 supersede 的旧条目恢复为"现行")
  5. 立刻删除 D 中的每个文件(fail-closed：此刻起，没有任何派生物还含有 T 的转述)
  6. 从剩余 live 条目**从零**重建 D 中的文件：
     - 条目节和纪要拼装节：纯代码，必然不含 T
     - LLM 摘要节：只喂剩余条目，不喂旧摘要；生成后做残留校验：
       similarity(新摘要, T) ≥ 0.35，或 T 中的数字 / 罕见二元组出现在新摘要里 → 丢弃摘要，只留条目列表
     - 重新过聚合马赛克检查
  7. 重建 MEMORY.md；log.jsonl 追加 {"op":"retract","id","regenerated":[…]}(不含 by，不含 T)
  8. 丢弃 T；广播 anon_mem_retracted{itemId}
  9. 失效内存中的 BM25 索引和 DeepSeek 前缀缓存(下一次调用自然换新前缀)
```

第 5 步的顺序是关键：**先删派生文件再重建**，不是在旧文件上"编辑掉那一条"。理由有两条：其一，Yao 等的实验表明，只删记录或靠指令"忘掉"都会让信息继续泄露；其二，让 LLM 改写一段含 T 的旧摘要，等于又把 T 交给 LLM 转述了一次。从剩余条目重建的派生物，从定义上就与"T 从未写入"等价(在条目节这一层严格成立；摘要节由于 LLM 有随机性，只能做到"不依赖 T"，做不到逐字等同于反事实，见 Mahendrakar 的第五种操作)。

**必须写明的已知残留**(不在文件层能解决的)：

- 已经发往 DeepSeek 的请求里含过 T：提供方的日志和缓存我们控制不了，在用户说明里照实写。
- 已经在房间里说出的回答、参与者自己的记忆和截图：协议之外。
- 文件系统层面：rename 之后旧数据块可能仍留在磁盘或备份里。若要更强的保证，v2 可以加**逐条加密 + 删钥**(crypto-shredding，用 `node:crypto` AES-GCM，钥匙放在单独的 `keys.json`，撤回时删钥)。代价是文件不再能直接用肉眼阅读。v1 建议先不做，但备份策略必须排除这个目录，或者备份也走同样的删除流程。
- git：**这个目录绝不能纳入版本控制**。

### 3.7 规模上限与马赛克检查

| 项 | 上限 | 依据 / 理由 |
|---|---|---|
| 单条 text | 300 字 | 原子性；超长由 Gate 拆分 |
| MEMORY.md | 150 行 / 8KB | Claude Code 200 行 / 25KB、Codex 32KiB 的保守版；它每轮都进提示 |
| 主题数 | ≤ 40 | 索引放得下；超出时由 consolidate 合并 |
| 每主题条目 | ≤ 80，超出就拆分 | 主题页 ≤ 约 6k token |
| 主题摘要 | ≤ 120 字 | 防 brevity bias 的反面：摘要只是导航，细节靠条目 |
| 每圈 live 条目 | 软上限 3000，硬上限 5000 | 超过后提示圈主"归档旧会议"(归档 = 圈主确认的批量撤回) |
| 单次召回上下文 | ≤ 12k token(候选 40 条) | 便宜、快；LongMemEval 显示上下文越长读得越差 |
| 全量直塞降级 | live 总量 < 3 万 token | 小圈子最省事，召回最高 |

**马赛克检查放在三个位置**(复用现有 `mosaicHeuristic` + L4 `verifyClaims`，roster 用该圈**全体成员**而不仅是在场者)：

1. **写入时**(弱，只打 flag)：新条目加上同 sid 的条目一起检查。
2. **整理时**(强，决定派生物能否落盘)：每份主题摘要和纪要是一次**新的聚合**，过去分散在各场会里的线索可能被摘要拼到一起。对整份派生文本跑马赛克 + L4，命中就丢弃摘要、只留条目列表，并把该主题标为 `gate: mosaic-fail`。条目列表本身在召回时还会再查一次。
3. **输出时**(强，现有逻辑)：召回结果组合起来的检查，这也是最后一道闸。

另外两条与删除相关的推断风险(Mahendrakar：删除本身是推断信号)：

- **不暴露谁撤回、谁放行**：日志不记 `by`；客户端只下发 `canRetract`，不下发 `approverIds`(与 `client-memory-protocol.md` 第 3 条的建议一致)。
- **墓碑只带 `id/sid/retractedAt`**：同一 sid 短时间内的大量墓碑本身也可能透露信息，但为了客户端一致性必须保留；墓碑可以设 30 天后物理清除(届时连 id 一起删)。

### 3.8 伪 API

```js
// 每圈一个实例；单写者(进程内串行队列)，所有写操作 tmp + rename
const mem = await openMemory({ dir, circleId, llm, roster, clock });

// 放行入库。返回入库条目(无说话人)
await mem.remember({ sid, draftId, k, approvals, approverIds, items: [{ text, kind }] });
//   -> [{ id, kind, text, sid, releasedAt, approvals }]

// 召回。answer：问答；minutes：会议纪要
await mem.recall(q, { mode: 'answer', budget: 12000 });
//   -> { answer, items: [{ id, kind, text, ... }], flags: [{ itemId, reason:'mosaic', confidence }], insufficient }
await mem.recall(null, { mode: 'minutes', sid: 's-7f3a', style: 'list' | 'prose' });
//   -> { markdown, sources: [ids], flags }

// 离线整理。返回应用了哪些 delta、重建了哪些文件
await mem.consolidate({ reason: 'session_end' | 'threshold' | 'daily', force: false });
//   -> { applied: [delta…], rejected: [delta…], regenerated: ['topics/budget.md', 'MEMORY.md'] }

// 撤回。鉴权失败 / 不存在 / 已撤回 → { ok:false, code }
await mem.retract(itemId, { by });
//   -> { ok: true, regenerated: [...], residueCheck: 'pass' | 'summary_dropped' }

// 列表(给「圈子记忆」页)
mem.list({ before, limit = 50, viewer });
//   -> [{ id, kind, text, sid, releasedAt, approvals, canRetract }] | [{ id, retracted: true }]
```

与现有 `createMemory` 的对应关系：`addRelease → remember`，`recall / recallForOutput → recall`(内部总是走输出闸)，`retract → retract`(多了派生物传播)，`list → list`(多了 `canRetract`)，`consolidate` 是新增的。迁移方式：把现有 JSON 的 `items` 按月拆进 `items/*.jsonl`，`releases` 写入 `releases.jsonl`，然后跑一次 `consolidate({force:true})`，派生物全部重新生成。

---

## 4. 证据强弱，坦白说

**较强(可以据此做决定)**

- LongMemEval v1：长历史全塞会掉 30–60%；"读"和"检索"同样重要；chain-of-note / 结构化输出有效；需要拒答能力。
- Yao 等(2026-09)：只删记录、不重建派生物，泄露不变。这是我们撤回设计最直接的依据(单篇，但实验设计扎实，结论与 Mahendrakar 的理论分析一致)。
- 多方证据方向一致：关键词 / 文件类检索在 agent 手里不输向量 RAG(Letta、Sen 等、LME-V2)。

**中等(方向可信，数字别照搬)**

- Sen 等：grep 优于向量，但只有 116 题，而且作者自己强调 harness 的影响更大。
- LME-V2：文件 + coding agent 72.5% vs RAG 48.5%，领域是 web 轨迹而非会议，延迟分钟级。
- ACE 的 delta 更新与防 collapse：结论来自策略 / 经验学习任务，迁移到事实型记忆是我们的推论。
- Sleep-time compute：数学题上的数字；"问题可预测时收益大"这条机制与会议纪要场景相符。

**弱(只当灵感)**

- Letta 74.0% 被当作"文件打赢专用系统"：其实用了向量工具，而且 LoCoMo 评测争议很大(同一系统 58–75%)。
- Mem0、A-MEM、各厂商的 LoCoMo / LongMemEval 自报数字：评测方不同可以差几十分。
- Dreaming 的客户证言(Harvey 6 倍)、Karpathy LLM Wiki 的个案经验、Manus 的工程经验：**没有对照实验**。

**我们自己的场景没有任何现成基准**：条目短、已去名、已原子化，问题多半是"上次定了什么 / 谁的待办"(这里的"谁"只会回答成"待办内容"，不对应到人)。LongMemEval 发现"抽成原子事实"会降低整体准确率；我们出于隐私**只能**存原子事实，这个代价是主动接受的。**建议上线前自建一个约 100 题的小评测集**：用合成会议生成放行条目，覆盖单条事实、跨会议聚合、时间、待办状态、被取代的决定、撤回后不得再答出这几类。比较三种方式：全量直塞、BM25 + LLM 选择、纯 BM25。撤回类题目是**硬门槛**：撤回后的任何回答、纪要、摘要都不得出现被撤回的内容。

---

## 5. 落地顺序建议

1. 存储拆分：items/jsonl 分片、releases、log，加上迁移脚本。行为与现有实现等价，测试照旧通过。
2. 进程内 BM25(复用 `features`)+ 全量直塞降级 + LLM 选择作答(JSON + chain-of-note)。
3. meetings/ 纪要(先做纯拼装版，零 LLM)。
4. retract 的派生物传播：先删后建、残留校验，补齐对应测试。
5. consolidate：delta 操作 + Curator 校验 + topics/ + MEMORY.md + 聚合马赛克检查。
6. 自建评测集；视结果决定是否开启第二轮查询改写，以及是否做 crypto-shredding。
