# EmberBench：炉灵（Ember）脱敏可信度基准

EmberBench 用来度量炉灵**放出去的一切**（不署名纪要、房内回答、知识库召回）能否让别人把观点对回到人。它是测量工具，不改闸门。方法、威胁模型和预注册阈值见 [METHOD.md](METHOD.md)。

## 目录

| 路径 | 作用 |
|---|---|
| `run.mjs` | CLI：跑一个 split，写出 trust card |
| `harness.mjs` | 被测单元：核心 `createSession`（L0–L4 + Ed25519 k-of-n 批准）→ released / ask / `recallForOutput`；对照组 `raw`、`ideas-only` |
| `attack.mjs` | 攻击者（insider / acquaintance / outsider / ideas-only）与评审（观点保留、立场、问答、注入），全部带离线 mock |
| `metrics.mjs` | 确定性指标：名字 / 机构 / 作品 / 长原话 / 准标识 / canary、效用、Cohen's κ |
| `bootstrap.mjs` | 固定 seed 的 bootstrap CI（均值、比值）与跨运行 spread |
| `trustcard.mjs` | 汇总、预注册阈值判定、卡片渲染 |
| `data.mjs` | 读数据、test manifest 校验、dev/test 不相交检查、封存 |
| `providers.mjs` | 可配置模型（`provider:model`）、计量、价格假设 |
| `gen/` | 数据生成：`specs.mjs`（场景规格）、`generate.mjs`（Kimi 生成 + Qwen 复核）、`validate.mjs`（确定性 schema 校验）、`import-legacy.mjs`（旧 10 段映射） |
| `data/dev/`、`data/test/` | 转写（`*.check.json` 是复核记录，`*.rejected.json` 是被拒稿，不属于数据集） |
| `data/test.manifest.json` | test 冻结：逐文件 SHA-256 + datasetHash |
| `data/test.seal.json` | 首次（调参前）test 运行后写入；之后再跑 test 需要 `--break-seal "<理由>"` |
| `results/<run-id>/` | `trustcard.md`、`trustcard.json`、`records.jsonl`（逐条记录，含放出文本） |

## 运行

```pwsh
# 离线（不联网，确定性 mock；数字不代表炉灵）
node ember/bench/run.mjs --split dev --runs 3 --mock

# 真跑：闸门 DeepSeek，攻击者 / 评审 Qwen（DashScope）
$env:LARES_AI_LLM_KEY = '…'            # DeepSeek，闸门
$env:DASHSCOPE_API_KEY = '…'           # 或 $env:DASHSCOPE_KEY_FILE = '<控制台导出的 csv>'
node ember/bench/run.mjs --split dev --runs 3 --configs +L4,ideas-only,raw --concurrency 6

# 调参前跑一次 test 并封存
node ember/bench/run.mjs --split test --runs 3 --configs +L4,ideas-only,raw --seal
```

常用参数：

- `--gate / --attacker / --judge / --alt-judge provider:model`：provider 可取 `deepseek`、`dashscope`、`mock`。
  - 默认值：闸门 `deepseek:deepseek-flash`，攻击者和评审 `dashscope:qwen-plus`，备评审 `deepseek:deepseek-flash`（只用于一致性统计）。
  - 攻击者或评审与闸门同一模型家族时，运行会拒绝启动，除非加 `--allow-same-family`。
- `--only id,…`：只跑指定转写，用于调试。带 `--only` 的 test 运行不会封存。
- `--agreement-sample N`：评审一致性抽样的段数，默认 10。
- `--seed`：bootstrap 的 seed。各次运行的 seed 依次为 1..N。

单元测试：`node --test ember/`（含 `ember/test/bench-*.test.mjs`）。

重新生成数据（会花钱，test 一旦封存就不要再动）：

```pwsh
node ember/bench/gen/generate.mjs --only g01-hospital-ops --gen dashscope:kimi-k3 --check dashscope:qwen-plus
node ember/bench/gen/import-legacy.mjs
```

## 读卡片

- **T1–T12** 是预注册阈值：隐私类看 CI 上界或零容忍，效用类看点估计。
- 「超额」= 看了炉灵输出的攻击者准确率 − 只看观点清单的攻击者准确率。两者同段、同 seed 配对。观点内容本身就会暴露专长，炉灵只对超额负责。
- raw 列是未脱敏的参照，用来检查攻击者和评审是否灵敏：raw 必须明显泄露，否则说明测量工具有问题。
- 只有 test 卡可以对外引用，dev 卡只用于调参。
