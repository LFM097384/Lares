# EmberBench archive — data/ 索引

本目录是本机原始运行记录与数据集的**本地副本**（git 忽略，只有本 README 入库）。来源：`.data/emberbench-public/`（MeetingBank 公开市议会转写及其标注、运行记录，复制而非移动）与 `ember/bench/results/<run-id>/records.jsonl`（合成轨运行记录）。`.data/kaggle-meeting/` 不属于 EmberBench，未复制。

安全抽查：对全部文件 grep `sk-…`、`apiKey`、`api_key`、`Bearer`、e-mail 地址。唯一 `Bearer` 命中为正文 "standard-bearer"（误报）；合成轨记录中的 e-mail 均为合成数据集中预埋的虚构标识（如 `chenjing@example.com`，见 `ember/bench/data/dev/*.json`）。未跳过任何文件。

合计：988 个文件，79.3 MB（不含本 README）。

## emberbench-public/（顶层）

| 路径 | 文件数 | MB |
|---|---:|---:|
| `emberbench-public/ann/` | 48 | 1.86 |
| `emberbench-public/ann-v3/` | 21 | 0.82 |
| `emberbench-public/ann-v3-binding/` | 156 | 1.69 |
| `emberbench-public/ann-v4/` | 74 | 2.80 |
| `emberbench-public/ann-v5/` | 76 | 2.87 |
| `emberbench-public/data/` | 174 | 5.11 |
| `emberbench-public/data-v2-dev-pristine/` | 18 | 0.41 |
| `emberbench-public/raw/` | 49 | 0.58 |
| `emberbench-public/raw-v3/` | 22 | 0.25 |
| `emberbench-public/raw-v4/` | 75 | 0.89 |
| `emberbench-public/raw-v5/` | 77 | 0.91 |
| `emberbench-public/runs/` | 45 | 45.22 |
| `emberbench-public/test-v3-base/` | 18 | 0.43 |
| `emberbench-public/test-v4-base/` | 60 | 1.33 |
| `emberbench-public/test-v5-base/` | 60 | 1.31 |
| `emberbench-public/ann-v3.log` | 1 | 0.00 |
| `emberbench-public/annotation-cost.json` | 1 | 0.00 |

## emberbench-public/runs/（公开轨每次运行的 records）

| 路径 | 文件数 | MB |
|---|---:|---:|
| `runs/2026-10-30T0224-public-dev/` | 2 | 1.10 |
| `runs/2026-10-30T0239-public-test/` | 1 | 0.81 |
| `runs/2026-11-03T0101-public-test/` | 1 | 1.01 |
| `runs/2026-11-03T0227-public-dev/` | 1 | 1.01 |
| `runs/2026-11-03T0245-public-dev/` | 1 | 0.02 |
| `runs/2026-11-03T0250-public-dev/` | 1 | 0.03 |
| `runs/2026-11-03T0305-public-dev/` | 1 | 1.01 |
| `runs/2026-11-03T0334-public-dev/` | 1 | 1.03 |
| `runs/2026-11-03T0349-public-dev/` | 2 | 1.12 |
| `runs/2026-11-03T0416-public-test/` | 1 | 1.01 |
| `runs/2026-11-05T0719-public-dev/` | 2 | 1.15 |
| `runs/2026-11-05T0737-public-dev/` | 2 | 1.15 |
| `runs/2026-11-05T0804-public-dev/` | 2 | 0.95 |
| `runs/2026-11-07T1730-public-dev/` | 3 | 2.79 |
| `runs/2026-11-07T1756-public-test/` | 1 | 1.09 |
| `runs/2026-11-13T0910-public-dev-mock/` | 2 | 1.03 |
| `runs/2026-11-13T0950-public-dev/` | 1 | 1.75 |
| `runs/2026-11-13T0952-public-dev/` | 1 | 1.78 |
| `runs/2026-11-13T0953-public-dev/` | 1 | 1.74 |
| `runs/2026-11-13T1042-public-test/` | 1 | 5.50 |
| `runs/2026-11-13T2018-public-dev/` | 1 | 0.04 |
| `runs/2026-11-13T2024-public-dev/` | 2 | 1.57 |
| `runs/2026-11-13T2259-public-dev/` | 2 | 1.79 |
| `runs/2026-11-14T0417-public-dev/` | 2 | 1.80 |
| `runs/2026-11-14T0453-public-test/` | 1 | 3.36 |
| `runs/2026-11-14T2241-public-dev/` | 2 | 0.02 |
| `runs/2026-11-14T2246-public-dev/` | 2 | 1.45 |
| `runs/2026-11-15T0408-public-dev/` | 2 | 1.09 |
| `runs/2026-11-15T2050-public-dev/` | 2 | 1.27 |
| `runs/2026-11-17T0037-public-test/` | 1 | 5.76 |

## synthetic-runs/（合成轨 records.jsonl）

| 路径 | 文件数 | MB |
|---|---:|---:|
| `synthetic-runs/2026-10-28T2314-dev/` | 1 | 0.91 |
| `synthetic-runs/2026-10-28T2336-dev/` | 1 | 0.92 |
| `synthetic-runs/2026-10-28T2337-test/` | 1 | 0.92 |
| `synthetic-runs/2026-10-29T0416-dev/` | 1 | 0.99 |
| `synthetic-runs/2026-10-29T1639-dev/` | 1 | 1.16 |
| `synthetic-runs/2026-10-29T1744-test/` | 1 | 0.93 |
| `synthetic-runs/2026-11-03T0349-dev/` | 1 | 1.17 |
| `synthetic-runs/2026-11-03T0431-test/` | 1 | 0.93 |
| `synthetic-runs/2026-11-07T1730-dev/` | 1 | 1.17 |
| `synthetic-runs/2026-11-13T0928-dev/` | 1 | 1.17 |
| `synthetic-runs/2026-11-13T2024-dev/` | 1 | 1.02 |
| `synthetic-runs/2026-11-13T2335-dev/` | 1 | 1.16 |
| `synthetic-runs/2026-11-14T0417-dev/` | 1 | 0.39 |
