# 组件明细（2026-11）

环境变量只列名字，不写值。测试计数来自 2026-11-18 本机重跑，未设任何 key。依据是各目录的 README，下面不再逐条注明。

## app/ — Lares 圈子客户端（Flutter）

- 路径：`app/lib/`（`app/README.md` 仍是 Flutter 模板，真正的说明在根 `README.md`、`HANDOFF.md`、`设计.md`）。
- 平台：iOS / Android / Windows / macOS / Web。CI 是 `.github/workflows/ios-build.yml`，iOS 由 ASC API 自动签名后上传 TestFlight（commit `b9f87aa`），build number 取 `github.run_number`。
- 构建时参数：`LARES_SIGNALING`、`LARES_CIRCLE`、`LARES_CIRCLE_NAME`（`--dart-define`）。
- 运行：`cd app; flutter pub get; flutter run -d windows --dart-define=LARES_SIGNALING=ws://127.0.0.1:8787`。
- 测试：`cd app; flutter test`（本次未重跑）。
- TestFlight：仓库里没有记录构建号。记忆库记有 build 50（`2163493`）、51（`090a6b6`/`4eaa62c`）、53（`5eaed90`），build 52、54 没有记录。

## server/ — 信令与元数据服务（Node）

- 入口：`server/src/index.js`（`npm start`）。另有 AI 进程 supervisor：`server/src/ai_voice_supervisor.js`（灶语）、`server/src/anonym_supervisor.js`（炉灵）。
- 主要环境变量：`LARES_PORT`、`LARES_DATA_DIR`、`LARES_PUBLIC_URL`、`LARES_AUTH_MODE`、`LARES_AUTH_TOKEN`、`LARES_CIRCLE_PASSCODE(S)`、`LIVEKIT_URL`、`LIVEKIT_API_URL`、`LIVEKIT_API_KEY`、`LIVEKIT_API_SECRET`、`LARES_DASHSCOPE_API_KEY`（字幕和 AI 子进程）、`LARES_CAPTIONS_MODEL`、`LARES_AI_VOICE_ENTRY`、`LARES_ANONYM_AGENT_ENTRY`、`LARES_PUSH_*`、`LARES_TRUST_PROXY`。
- 测试：`cd server; npm test`，共 17 个脚本，包括 `ai_voice.mjs` 回合引擎大套件和 `anonym.mjs`。本次未重跑。
- 本机栈：`pwsh server/tool/local_stack.ps1 start|stop|status`（LiveKit dev 加信令，数据在 `.local-server/`）。
- 生产 e2e：`server/tool/anonym_v2_prod_e2e.mjs`、`server/tool/ai_voice_prod_e2e.mjs`，都支持 `--local`。

## lares-bridge/ — Lares 接入层

- 入口：`lares-bridge/index.mjs`（`LaresRoom`、鉴权、E2EE 密钥、帧编解码、`loadRtcNode()`）。
- 依赖：`ws`、`hash-wasm`，`@livekit/rtc-node` 可选，经 `deps.mjs` 从 `server/node_modules` 解析。
- 测试：`node --test lares-bridge/`，12/12。

## hearthvoice/ — 灶语本体

- 入口：`hearthvoice/index.mjs`（`createHearthvoice`）。port 规格见 `hearthvoice/PORT.md`。
- 本体不读环境变量。provider 有 DashScope ASR / TTS、OpenAI 兼容 LLM（DeepSeek 等）和 mock。
- 测试：`node --test hearthvoice/`，15/15。

## hearthvoice-lares/ — 灶语 Lares 插件（`lares.ai-voice`）

- 入口：`hearthvoice-lares/index.mjs`，契约见 `CONTRACT.md`。
- 环境变量：`LARES_SIGNALING`、`LARES_AI_AUTH_SECRET`、`LARES_AI_AUTH_V`、`LARES_AI_CONFIG`、`LARES_AI_USAGE_FILE`、`LARES_AI_PROVIDERS`、`LARES_DASHSCOPE_API_KEY`、`LARES_AI_LLM_BASE_URL`、`LARES_AI_LLM_KEY`（别名 `LARES_AI_LLM_API_KEY`）、`LARES_AI_LLM_MODEL`、`LARES_AI_LLM_EXTRA_BODY`、`LARES_AI_LLM_TIMEOUT_MS`、`LARES_AI_LOG_TEXT`。
- 运行（mock）：`node hearthvoice-lares/index.mjs --circle <cid> --signaling ws://127.0.0.1:8787/ws --passcode <p> --auth-v2 --providers mock`。
- 测试：`node --test hearthvoice-lares/`，8/8。

## ember/ — 炉灵本体

- 入口：`ember/index.mjs`（`createEmber`，并再导出 `createDeepSeekLLM`）。会话在 `ember/core/index.mjs` 的 `createSession`，闸门在 `ember/core/gate/gate.mjs` 的 `runGate`，化名在 `ember/core/gate/pseudonym.mjs`，agent 在 `ember/agent/`，skills（`answer`、`minutes`）在 `ember/skills/`。
- 规格：`PORT.md`、`INTERFACE.md`、`AGENT-V2.md`、`SEALING.md`。
- 本体零 npm 依赖，不读环境变量。LLM 由调用方注入，传 `null` 时走确定性 mock。
- 测试：`node --test ember/`，234 个，233 过、1 跳过、0 失败。跳过的是真 LLM 测试，需要内联 `LARES_AI_LLM_KEY`。
- adapters：`ember/adapters/zoom.mjs` 只是指向 `ember-zoom/` 的指针，调用即抛错；`ember/adapters/teams.mjs` 是 stub，设计见 `docs/plans/chatham/04-zoom-teams.md`。

## ember/bench/ — EmberBench

- 入口：`ember/bench/run.mjs`。不调 LLM 的示例：`node ember/bench/run.mjs --split dev --runs 3 --mock`。
- 存档：`ember/bench/archive/`，含 `README.md`、`code-map.md`、`method/`（METHOD 快照、seals、校准）、`results/`。`data/` 已 git-ignore。
- 状态：用户决定结束测试。只用 DeepSeek 时，评测会因攻击者与闸门同家族而拒跑（`--allow-same-family` 可以强制，但会写进卡片）。

## ember-lares/ — 炉灵 Lares 插件

- 入口：`node ember-lares/index.mjs --circle <cid> [--signaling …] [--passcode p] [--auth-v2] [--e2ee] [--sealed-key] [--k n] [--memory-dir d] [--asr dashscope|mock|none]`。
- 环境变量：`LARES_ANONYM_HOSTED`、`LARES_ANONYM_USER_ID`、`LARES_ANONYM_CONVENER`、`LARES_ANONYM_E2EE`、`LARES_ANONYM_K`、`LARES_ANONYM_MEMORY_DIR`、`LARES_AI_MEMBER_SECRET`、`LARES_AI_AUTH_SECRET`、`LARES_AI_AUTH_V`、`LARES_SIGNALING`、`LARES_DASHSCOPE_API_KEY`、`LARES_AI_LLM_BASE_URL`、`LARES_AI_LLM_API_KEY`（或 `LARES_AI_LLM_KEY`）、`LARES_AI_LLM_MODEL`。
- 退出码：0 结束，1 崩溃或断线，2 参数错误，3 鉴权失败。
- 测试：`node --test ember-lares/`，8/8。

## ember-zoom/ — 炉灵 Zoom 插件

- 入口：`node ember-zoom/index.mjs`，一个 HTTP 端口同时承载 webhook、侧边栏和 hub，默认 8790。模拟器：`node ember-zoom/sim/rtms_sim.mjs http://127.0.0.1:8790/webhook`。
- 环境变量：`ZOOM_CLIENT_ID`、`ZOOM_CLIENT_SECRET`、`ZOOM_WEBHOOK_SECRET`、`LARES_AI_LLM_*`、`EMBER_MEMORY_DIR`、`EMBER_K`、`EMBER_ZOOM_ASR`（`zoom` / `dashscope` / `mock`）、`EMBER_ZOOM_POST_CHAT`、`EMBER_ZOOM_LANG`、`EMBER_ZOOM_ALLOW_ORIGINS`、`EMBER_ZOOM_SCOPE`、`LARES_DASHSCOPE_API_KEY`（仅 `dashscope` 模式需要）。
- 测试：`node --test ember-zoom/`，27 个，26 过、1 跳过（可选真 LLM e2e）。
- 未验证：真 Zoom RTMS 和真 Zoom 客户端里的侧边栏。

## ember-jitsi/ — 炉灵 Jitsi 插件

- 入口：`node ember-jitsi/index.mjs --room <名> --url https://… [--k n] [--asr dashscope|mock|none] [--scope id] [--convener-name X]`。
- 依赖：Node ≥ 22，Playwright Chromium（`npx playwright install chromium`）。
- 环境变量：`JITSI_URL`、`JITSI_INSECURE`、`LARES_AI_LLM_*`、`LARES_DASHSCOPE_API_KEY`、`LARES_DASHSCOPE_HOST`、`EMBER_MEMORY_DIR`、`EMBER_K`、`EMBER_SCOPE`、`EMBER_CONVENER_NAME`、`EMBER_JITSI_ASR`、`EMBER_PLAYWRIGHT_DIR`、`EMBER_CHROMIUM_PATH`。
- 测试：`node --test ember-jitsi/`，31/31。真 e2e：`pwsh ember-jitsi/tool/run_e2e_wsl.ps1`，需要 WSL 里的 docker-jitsi-meet 和两个 key，2026-10-24 的结果是 8/8。

## ember-desk/ — 炉灵 Windows 托盘端

- 入口：双击 `ember-desk/start.cmd` / `start.vbs` 启动托盘（`tray.ps1`）；也可以单起守护进程 `node ember-desk/daemon.mjs`。另有 `node ember-desk/cli.mjs status|join|leave|ask|speak|channels|quit`、`mcp.mjs`（stdio MCP）和 `ember://` 协议。
- 需要 Windows 10/11、Node ≥ 22、PowerShell 7。
- 机密：`pwsh ember-desk/setup-secrets.ps1` 写入 `%APPDATA%\ember-desk\secrets.dpapi.json`（DPAPI，当前用户）；同名环境变量优先。
- 环境变量：`EMBER_DESK_HOME`、`LARES_AI_LLM_*`、`LARES_DASHSCOPE_API_KEY`、`LARES_DASHSCOPE_HOST`、`ZOOM_CLIENT_ID`、`ZOOM_CLIENT_SECRET`、`ZOOM_WEBHOOK_SECRET`、`EMBER_PLAYWRIGHT_DIR`、`EMBER_DESK_JITSI_ENTRY`、`EMBER_DESK_JITSI_ARGS`。
- 测试：`node --test ember-desk/`，37/37。经桌面端的 Jitsi e2e 是 9/9（2026-10-25）。

## deploy/ — 部署

- 文件：`docker-compose.yml`（Caddy + LiveKit + 信令）、`deploy.sh`、`preflight.sh`、`rollback.sh`、`.env.example`、`AZURE.md`、`ios-ci.md`、`pages-switch.md`、`systemd/`。
- 运行：`./deploy.sh`（会先跑 preflight）；升级用 `docker compose pull && docker compose up -d`。
- 现状：Azure 免费试用订阅已停用，生产 VM 停机（2026-10-18，来自记忆库）。

## site/ — 官网

- Astro：`cd site; npm run dev` / `npm run build`，由 Pages 流水线部署（commit `c0c83ea`）。合规页面（隐私、条款、支持）在 `docs/`，由 GitHub Pages 发布。

## docs/

- 对外文档：`privacy.md`、`terms.md`、`support.md`。
- 接口：`plugin-api.md`、`bot-api.md`、`available-protocol.md`、`recording-consent-protocol.md`。
- 设计：`docs/plans/`（含 `chatham/` 系列）。
- 其他：`docs/research/`、`docs/compliance/`、`docs/app-store/`、`signaling-audit.md`。
