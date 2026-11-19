# ember-meet · 真 Teams 会议冒烟清单

目的：在一个真实的 Teams 会议里确认：炉灵能以访客身份进会，能打开实时字幕，能把「测试用户」念的两句话（英文一句、中文一句）按说话人送进 Ember，聊天命令也能用。

本仓库**不创建 Teams 账号，也不创建会议**。会议由你创建，链接由你粘贴，放行也由你来做。

## 准备

1. 用你自己的账号建一个会：免费版在 <https://teams.live.com>（「会议 → 立即开会」或「安排会议」），工作 / 学校账号也可以。复制会议链接，形如 `https://teams.live.com/meet/<数字>?p=<口令>` 或 `https://teams.microsoft.com/l/meetup-join/…`。
2. 会议选项：
   - **允许匿名用户加入**（工作 / 学校租户可能被管理员关掉）
   - 谁可以绕过大厅：保持默认（访客进大厅），由你手动放行
   - 允许实时字幕
3. 你自己（组织者）用 Teams App 或另一个浏览器先进会。
4. 可选：要用 LLM 的话，在当前终端设好 `LARES_AI_LLM_*`（只用 DeepSeek）。不设也行，走确定性路径。
5. 第一次运行会自动用 Windows SAPI 生成 `.data/ember-meet/speaker.wav`（离线），也可以先手动跑 `pwsh -File ember-meet/sim/make-wav.ps1`。

## 一条命令

```powershell
node ember-meet/tool/live.mjs --url "<你的 Teams 会议链接>"
```

它会拉起两个有头 Chromium：先是**炉灵**，8 秒后是**测试用户**（假麦克风循环播放 WAV）。两个子进程的元数据事件带着 `[炉灵]` / `[测试用户]` 前缀打印出来。按 Ctrl+C，两个都会离会。可选参数：`--headless`、`--minutes 15`、`--no-speaker`。

在 WSL2 里跑（Xvfb 有头）：`pwsh -File ember-meet/env/run-wsl.ps1 -Url "<链接>" -Speaker`

## 检查清单

| # | 你做什么 | 期望看到 |
|---|---|---|
| 1 | 等 10–30 秒 | 终端：`[炉灵] {"ev":"state","state":"launcher"}` → `prejoin` → `joining` → `lobby` |
| 2 | 在 Teams 里**从大厅放行「炉灵」**（访客标记） | `[炉灵] … "state":"in-meeting"`，之后是 `captions-on`、`chat-open`，以及 `{"ev":"ready",…,"captions":true,"chat":true}` |
| 3 | 看会议聊天 | 炉灵发出公告：说明它是 AI、只读实时字幕不录音、聊天公开并会留在记录里、要 `@炉灵 同意` |
| 4 | 放行「测试用户」 | `[测试用户] … "state":"in-meeting"`、`{"ev":"ready","name":"测试用户",…}`；Teams 里能看到测试用户开着麦、在说话（假麦克风） |
| 5 | 看 Teams 自己的字幕 | 每隔大约 16 秒出现「测试用户」念的英文句子；中文句子能不能识别，取决于会议口语设置（默认英文时中文会变成乱码） |
| 6 | 在聊天里发 `@炉灵 同意` | 炉灵回复「已同意 1 人…」；你成为召集人 |
| 7 | 还没人替测试用户同意时 | 终端有 `caption_final` 事件，`speaker` 是测试用户的 id，`acked:false`，这句不会进账本 |
| 8 | 测试用户的字幕要进账本，需要「测试用户」本人同意：在测试用户的浏览器窗口里手动打开聊天，发 `@炉灵 同意`（或者用 `node ember-meet/sim/speaker.mjs --url "<链接>" --say "@炉灵 同意"` 单独再跑一次） | 炉灵：「已同意 2 人」；之后测试用户的 `caption_final` 是 `acked:true` |
| 9 | 发 `@炉灵 问 他们说了什么` | 一条【炉灵·回答】，内容与英文那句有关（产品发布、周五、预算），**不带名字** |
| 10 | 发 `@炉灵 纪要`，然后 `@炉灵 批准 D1` | 草稿 D1；需要 k 人批准（默认 2 人会议 k=2），只有你批准时「未放行」 |
| 11 | 发 `@炉灵 结束` | 炉灵：「散会…」，然后**它自己离开**；会议**不会**被结束，你和测试用户都还在 |
| 12 | Ctrl+C | 测试用户离会；两个子进程打印 `exited code=0` |

## 失败时看什么

- 卡在 `prejoin` 或 `join_timeout`：网页改版或选择器失效。用有头模式看浏览器停在哪一步，然后去改 `adapters/teams-selectors.mjs`。
- 被拒（`denied`），或者提示只有登录用户能加入：租户禁止匿名访客。
- `ready` 里 `captions:false`：会议禁用了字幕，或者「更多 → 语言和语音 → 打开实时字幕」的菜单项变了。
- 字幕里中文全是乱码：会议口语没设成中文，这是 Teams 的限制。
- 把结果（选择器哪一步失效、`state` 序列）记到 README 的「验证了什么」。不要提交 `.data/` 里的 profile 或 WAV。
