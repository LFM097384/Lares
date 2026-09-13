# App Store 审核合规调研报告

**调研对象**：iOS 语音通话 app（小圈子常驻语音房），个人开发者，免费无内购
**特征**：无账号体系（邀请码/口令 + 本地昵称）｜实时语音+文字+图片，服务器不落盘纯转发｜允许自定义服务器地址｜自建 WebRTC/LiveKit｜有 GitHub Releases 自动更新模块（Win/Android）

**方法说明**：所有 Guideline 原文均于本次调研当天从 Apple 官方页面抓取。`developer.apple.com` 的指南页与 help 页为 JS 渲染，直接抓取会在 §1.1.6 截断或只返回导航壳；完整正文通过文本代理 `r.jina.ai/<原URL>` 取得**同源官方页面**。非官方来源均已明确标注为二手。

> ⚠️ **免责**：本报告是合规研究，不是法律意见。Q5（美国出口管制）与 Q6（中国大陆备案）尤其应在落地前咨询专业人士。
>
> 📅 **时点提示**：抓取到的 Apple 页面 `Published Time` 显示当前约为 **2026 年 9 月**。部分"即将实行"的要求可能已生效。

---

## 🔴 最高优先级发现（先看这个）

**Apple 于 2026-02-06 专门修订 Guideline 1.2，明确将「random or anonymous chat」纳入 1.2 管辖，并已在 2026-06 据此下架真实 app。**

Apple 官方新闻原文（https://developer.apple.com/news/?id=d75yllv4 ，2026年2月6日）：

> "The App Review Guidelines have been revised to clarify that apps with **random or anonymous chat** are subject to the 1.2 User-Generated Content guideline."

执法案例：2026年6月，Apple 以 1.2 为由下架 ShareChat（Mohalla Tech）旗下语音/视频社交 app **Vibely**。开发方公开抗辩"我们不是匿名聊天"无效，该 app 随后全平台关停。
来源：https://www.medianama.com/2026/06/223-apple-removes-sharechat-vibely-app-store/

媒体对该修订的执法解读（https://www.medianama.com/2026/02/223-apple-app-store-guidelines-anonymous-chat-apps/ ）：
> "Apple will remove apps primarily used for anonymous or random interactions... **even if developers implement the required safeguards**: reinforcing Apple's view that certain design features themselves create heightened risks."

**本项目的「无账号 + 实时语音」组合正落在这条刚刚收紧、且 Apple 正在主动执法的线附近。这是全部 10 个问题中风险最高的一项，高于自定义服务器，高于自动更新。**

---

## Q1. Guideline 1.2 (User-Generated Content) 确切要求文本

### 结论

**你记的四项措施完全正确，措辞已逐字核实。但有两个必须纠正的认知：**

1. **不存在任何「服务器不存储 / 纯实时转发」的例外条款。** 已对指南全文检索 ephemeral / real-time / live audio / not stored / disappear / VoIP 等关键词——**全文没有任何基于"是否落盘"的豁免**。VoIP 一词仅出现在 2.5.4（后台模式）与 3.1.3(f)（IAP 豁免），均与安全条款无关。
2. **1.2 的触发条件是「或」结构**："apps with user-generated content **or social networking services**"。即便论证实时语音流不算 UGC，"social networking service" 这一支仍可独立触发。

### 原文（verbatim，来源 https://developer.apple.com/app-store/review/guidelines/ ）

> **1.2 User-Generated Content**
>
> Apps with user-generated content present particular challenges, ranging from intellectual property infringement to anonymous bullying. To prevent abuse, apps with user-generated content or social networking services must include:
>
> - A method for filtering objectionable material from being posted to the app
> - A mechanism to report offensive content and timely responses to concerns
> - The ability to block abusive users from the service
> - Published contact information so users can easily reach you
>
> Apps with user-generated content or services that end up being used primarily for pornographic content, Chatroulette-style experiences, random or anonymous chat, objectification of real people (e.g. "hot-or-not" voting), making physical threats, or bullying do not belong on the App Store and may be removed without notice. If your app includes user-generated content from a web-based service, it may display incidental mature "NSFW" content, provided that the content is hidden by default and only displayed when the user turns it on via your website.
>
> It is your responsibility to remove content that violates this guideline, your terms of service, or your community standards. If we find such content, we will ask you to remove it, and provide a plan to improve your compliance with this guideline. Based on your response, your app may be removed from the App Store until you can demonstrate improvements that bring your app into compliance. Egregious or repeated behavior is grounds for immediate removal of your app from the App Store, and from the Apple Developer Program.

**1.2.1 明确把 audio 算作 UGC**（同一 URL）：
> "Such creator content may include video, articles, **audio**, and even casual games... **treated as user-generated content by App Review**."

中文官方版（https://developer.apple.com/cn/app-store/review/guidelines/ ）四项为：「采用相应的方法来过滤令人反感的内容，以免这些内容在 App 中发布」「制定一个机制，以举报攻击性内容并在出现问题时及时作出回应」「若用户发布攻击性内容，可以取消其使用服务的资格」「公布联系信息，以便用户与你联系」。

### 「不落盘」架构如何满足这四项

关键洞察：**这四项义务的对象是「服务」和「人」，不是「已存储的文件」。** 第三项原文是 "block abusive users **from the service**"——纯转发服务器完全做得到。

| 要求 | 不落盘架构下的最小可行实现 |
|---|---|
| 过滤令人反感的内容 | 文字/图片在**发送端或转发时实时过滤**（关键词表、客户端图片审核），无需存储；语音提供房主静音/踢出 + 客户端本地静音；配合 EULA + 社区准则 |
| 举报机制 + 及时响应 | App 内举报按钮。举报载荷由**客户端本地缓存最近 N 秒/N 条**上下文随举报一并提交（不落盘架构下唯一可行路径），发到邮箱/工单。必须实际做到及时响应 |
| 屏蔽滥用用户 | 无账号 ≠ 无身份。可用：房主踢出/封禁当前 session、**邀请码吊销**、设备级本地拉黑、per-room 会话标识封禁 |
| 公布联系方式 | App 内 + App Store 支持 URL 均放可用联系方式（1.5 另有独立要求）|

⚠️ **实操**：无论如何都要实装举报按钮 + 拉黑 + EULA + 联系方式，且**审核员必须能在 App 内肉眼看到**。成本远低于一次被拒。

### 佐证：自己不存内容照样被要求整改

第三方 Twitter 客户端（内容全在 Twitter 服务器，app 自身零存储）收到的拒信原文：
> "Guideline 1.2 - Safety - User Generated Content. We found in our review that your app includes user-generated content but does not have all the required precautions... - Require that users agree to terms (EULA) and these terms must make it clear that there is no tolerance for objectionable content or abusive users - A mechanism for users to flag objectionable content"

来源：https://api.github.com/repos/daneden/Twift/issues/48

→ 判定锚点是「App 内是否呈现他人产生的内容」，而非「你的服务器是否保存它」。

---

## Q2. 实时语音/通话类 app 是否适用 1.2

### 结论：**适用。且匿名/随机形态是当前最高危类别。**

风险分层（真正的 it-depends 所在）：

- **匿名/随机撮合陌生人的语音房 → 最高危**。2026 年起可被**无预警下架**，据媒体解读"已实现全部安全措施"亦不保证幸免。
- **用户连接已知服务器/熟人小群（Mumble、TeamSpeak、Nextcloud Talk 模式）→ 实践中宽松得多**，但这是**执法裁量，不是成文豁免**。

### 在架案例表

| App | 在架 | URL | 内置举报/拉黑 | 证据 |
|---|---|---|---|---|
| Clubhouse | 是 | [id1503133294](https://apps.apple.com/us/app/clubhouse/id1503133294) | 不确定 | 商店页自述 "100% live audio"；纯直播音频形态今日仍在架 |
| Zello | 是 | [id508231856](https://apps.apple.com/us/app/zello-walkie-talkie/id508231856) | 部分证实（服务端封禁权）| [ToS](https://zello.com/legal/terms/) 保留 "suspending or terminating your account"、"blocking your IP address"；App 内举报按钮未核实 |
| TeamSpeak 3 | 是（$0.99）| [id577628510](https://apps.apple.com/ca/app/teamspeak-3/id577628510) | 商店页未提 | 描述含 "**Use Anonymously**"、"Use on public or your own private server" |
| Mumblefy（Mumble 客户端）| 是 | [id858752232](https://apps.apple.com/us/app/mumblefy/id858752232) | 商店页未提 | 分类 Social Networking；纯自托管语音，开发者不存内容 |
| Nextcloud Talk | 是 | [id1296825574](https://apps.apple.com/us/app/nextcloud-talk/id1296825574) | 商店页未提 | "fully on-premise"、"End-to-end Encrypted calls"——提供方技术上无法审核，仍在架 |
| Element (Classic) | 是 | [id1083446067](https://apps.apple.com/us/app/element-classic/id1083446067) | 不确定 | 在架确认；Matrix 侧 ignore/report 能力未取得一手证据 |

**案例的正确解读**：Mumblefy / TeamSpeak 3 / Nextcloud Talk 这类「自托管 + 开发者零存储 + 无可见审核 UI」的客户端确实长期在架——但应理解为**低风险画像下的执法裁量**（无陌生人撮合、无公开发现入口、非增长型社交产品），**而不是成文豁免**。

> ⚠️ TeamSpeak 3 商店描述公开使用 "Use Anonymously" 且仍在架——但该 app 上架远早于 2026-02 修订，**不应据此推断新提交也安全**。

---

## Q3. 自定义服务器地址是否违规

### 结论：**不违规。** 允许用户输入任意 `wss://` 地址本身不构成任何现行条款的违规。

1. **无对应条文**。通读现行指南全文，不存在要求"服务器端点必须硬编码/白名单"的条款。
2. **大量先例在架**（下表经真实 HTTP 请求验证返回 200）。
3. **真正咬人的不是"自定义服务器"**，而是 1.2（UGC）、2.1（审核期后端须可用）、4.2.2（最小功能）。

### Guideline 4.7 原文（verbatim）
> **4.7 Mini apps, mini games, streaming games, chatbots, plug-ins, and game emulators**
> Apps may offer certain software that is not embedded in the binary, specifically HTML5 and JavaScript mini apps and mini games, streaming games, chatbots, and plug-ins. Additionally, retro game console and PC emulator apps can offer to download games. You are responsible for all such software offered in your app, including ensuring that such software complies with these Guidelines and all applicable laws. Software that does not comply with one or more guidelines will lead to the rejection of your app. You must also ensure that the software adheres to the additional rules that follow in 4.7.1 through 4.7.5.
>
> **4.7.1** Software offered in apps under this rule must: follow all privacy guidelines...; **include a method for filtering objectionable material, a mechanism to report content and timely responses to concerns, and the ability to block abusive users**; and follow Guideline 3.1...
> **4.7.2** Your app may not extend or expose native platform APIs or technologies to the software without prior permission from Apple.
> **4.7.3** Your app may not share data or privacy permissions to any individual software offered in your app without explicit user consent in each instance.
> **4.7.4** You must provide an index of software and metadata available in your app. It must include universal links that lead to all of the software offered in your app.
> **4.7.5** Your app must provide a way for users to identify software that exceeds the app's age rating, and use an age restriction mechanism based on verified or declared age to limit access by underage users.

### 4.7 是否适用于「连接用户选定的服务器」？→ **不适用**

- 规制对象是 "software ... **offered in your app**"：app 作为**分发渠道**提供可执行的第三方软件单元。品类清单是穷举式的，非"任何远程内容"。
- **4.7.4 是决定性反证**：要求提供"软件索引 + universal links"。连接用户自填服务器的协议客户端**结构上无法**满足——不存在"可索引的软件目录"。立法者设想的是小程序商店，不是协议客户端。
- **"chatbots" 易被误读**：指 app 内**上架的一个个 bot 条目**（bot 目录），不是"app 连到某个聊天服务器"。判别标准：**你是否在 app 内提供可浏览、可选择的第三方软件目录？**

> ⚠️ 注意 4.7.1 的措辞与 1.2 四件套高度重合——反向印证 Apple 在任何"承载他人内容"场景下都要同一套治理措施。

**2.5.2 的分界线 = data vs. code**：服务器返回**数据**（JSON/消息/媒体）安全，无论来自哪台服务器；服务器下发**改变 app 功能**之物（可解释脚本、动态 UI 驱动出审核时不存在的功能）才有风险。

### 在架案例表（全部经真实 HTTP 请求确认 200）

**🥇 最强单条证据 —— Element X 的上架文案本身。** Apple 审核并**批准了一段以"连接任意服务器"为核心卖点**的商店描述（逐字提取自 App Store 页面 JSON description）：
> "Choose where to host your data - from any public server (the largest free server is matrix.org, but there are plenty of others to choose from) to creating your own personal server and hosting it on your own domain. **This ability to choose a server is a large part of what differentiates us from other real time communication apps.**"

来源：https://apps.apple.com/us/app/element-x-secure-chat-call/id1631335820 （HTTP 200 确认）
→ 若该能力违规，Apple 不会放行以此为**主打宣传语**的 listing。

| App | 允许任意服务器 | 证据 |
|---|---|---|
| [**Element X**](https://apps.apple.com/us/app/element-x-secure-chat-call/id1631335820) | **YES ★** | 见上，以此为核心卖点 |
| [Ice Cubes for Mastodon](https://apps.apple.com/us/app/ice-cubes-for-mastodon/id6444915884) | **YES ★** | "You can connect to **any** Mastodon instance" |
| Mastodon 官方 | **YES ★** | "you can even host your data on your own infrastructure" |
| [Nextcloud](https://apps.apple.com/us/app/nextcloud/id1125420102) | **YES ★** | "Host it yourself or with a company you trust" |
| [Swiftfin (Jellyfin)](https://apps.apple.com/us/app/swiftfin/id1604098728) | **YES ★** | "you must have a Jellyfin server set up and running" |
| Jellyfin Mobile (id1480192618) | **YES** | 在架确认 |
| [Home Assistant](https://apps.apple.com/us/app/home-assistant/id1099568401) | **YES ★** | "runs locally in your home via ... Raspberry Pi" |
| [Infuse](https://apps.apple.com/us/app/infuse-video-player/id1136220934) | **YES ★** | "Connect with Plex, Emby, Jellyfin, Kodi... and other media servers" |
| [Termius (SSH)](https://apps.apple.com/us/app/termius-ssh-client/id549039908) | **YES** | 连接完全任意主机并执行远程命令 |
| [Prompt 3 (Panic)](https://apps.apple.com/us/app/prompt-3/id1594420480) | **YES** | SSH 本质为任意主机 |
| [WireGuard](https://apps.apple.com/us/app/wireguard/id1441195209) | **YES** | 配置格式即用户自填 Endpoint |
| Flux Feed for Miniflux / Flux-News | **YES ★** | 均明写 "requires a self hosted Miniflux instance to work" |
| Plex | **PARTIAL** | 经 plex.tv 账号中介发现服务器，非首启自由填 URL |
| Reeder.（新版 id6475002485）| **NO** | 仅 iCloud 同步——**保留此反例以证明本表非无差别收录** |

（★ = 从 Apple 商店页面逐字提取；共验证 30 款，全部 HTTP 200）

> **另一有力论据：SSH 客户端（Termius、Prompt 3）让用户连接完全任意主机并执行远程命令，长期在架。**

### 公开被拒案例：**未找到以"自定义服务器"为理由的案例**

约 20 轮定向检索仍无命中。但检索找到了**真实被拒案例，其引用条款全部是 2.1 / 4.2.2 / 2.5.2 / 4.3**：

| 案例 | 条款 | 真实原因 |
|---|---|---|
| **Pi-hole 客户端**（2026-02，最贴近本议题）<br>[forums/thread/815919](https://developer.apple.com/forums/thread/815919) | **2.1** | 开发者原文："my app was rejected under... 2.1 with a request to provide access information so the app, domain, and live query features can be reviewed." 其答复 Apple："**There is no external backend, no public API endpoint, and no default domain or credentials that can be provided.**" → **Apple 要的是能测试的入口，从未质疑"让用户指向自己服务器"这一功能** |
| 动态 DNS 后端连不上（2023-03）<br>[thread/726643](https://developer.apple.com/forums/thread/726643) | 功能性 2.1 | Apple DTS："I suspect that this is because you're using **dynamic DNS**."；建议固定 DNS 名 + 443 + 系统信任证书 |
| 域名在 Apple 内网被改道（2025-01）<br>[thread/773444](https://developer.apple.com/forums/thread/773444) | 功能性 2.1 | Apple DTS："Our network does block ports... **use the standard port numbers**" |
| **iSH（Linux shell）**（2020-11）<br>[ish.app/blog/app-store-removal](https://ish.app/blog/app-store-removal) | **2.5.2** | Apple："is not self-contained and has **remote package updating functionality**"；要求移除 "wget or curl, or other remote network commands" → **反对的是下载可执行代码，明确不是自定义服务器 URL**。申诉当日撤销 |
| Ice Cubes（2023-01）| **4.2.2** | "your app only includes links, images, or content aggregated from the Internet with limited or no native iOS functionality... does not sufficiently differ from a mobile web browsing experience"（[Daring Fireball](https://daringfireball.net/2023/01/ice_cubes_app_store_limbo)）|

**关键旁证**：Apple DTS 于 2024-08 回复一位**允许用户自行添加流媒体链接**的 IPTV 开发者时（[thread/762911](https://developer.apple.com/forums/thread/762911)），全程**无人质疑该功能**，讨论只围绕 ATS key。

> 🎯 **重要修正：真正的风险不是「自定义服务器」，而是「可审查性」。** 这是全部真实案例的共同死因。

### ATS / NSAllowsArbitraryLoads

Apple 官方（https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads ）：
> "You must supply a justification during App Store review if you set the key's value to [YES]... Use this key with caution because it significantly reduces the security of your app."

**Apple 的 ATS 文档主动接纳"用户自填主机"形态**（https://developer.apple.com/documentation/security/preventing-insecure-network-connections ）：
> "Examples of justifications eligible for consideration are: ... The app must support connecting to devices that cannot be upgraded to use secure connections, and that must be **accessed using public host names**."

→ Apple 在官方文档层面**已预设并接纳**该 app 形态。

**摩擦点，非禁令。且大概率你根本不需要它**——若只用 `wss://`(TLS)，ATS 默认已允许。**"用户可填任意主机名"本身不需要任何 ATS 例外**。

- ATS 强制期限已于 2016-12-21 取消且**从未重设**（https://developer.apple.com/news/?id=12212016b ）
- 但 justification 要求**从未撤销**，现行措辞是 "requires you to provide justification, and **might** trigger additional App Store review"（注意是 might 非 will）
- ⚠️ 网传"justification 已无限期暂停"是论坛用户措辞**非 Apple 原话**，不应引用

**→ 强烈建议：只支持 `wss://`，拒绝明文 `ws://`。** 一举解决 ATS 与安全两个问题。

### Q3 实操清单（按优先级）

1. 不要因"自定义服务器"担心 4.7 或 2.5.2 —— 只要不下发可执行代码
2. **【最高优先级】解决 2.1 可审查性**——提供**你自己运行、审核期保证在线**的演示服务器 + 演示账号或内置 demo 模式。**绝不能**像 Pi-hole 案那样答复"本 app 无公共端点、无法提供凭据"
3. **演示服务器须对 Apple 内网友好**：固定 DNS 名（**勿用动态 DNS**）、**443 端口**、系统信任 TLS 证书；非标准端口须在 Review Notes 写明
4. **切勿**内置 `wget`/`curl` 式**通用远程获取并执行**能力（iSH 的教训，会真正引爆 2.5.2）
5. 只用 `wss://` 绕开 ATS
6. 隐私政策如实说明数据流向用户自选端点

---

## Q4. iOS 上的自动更新 / 版本检查

### Guideline 2.5.2 原文（verbatim，Apple 官方）

> **2.5.2** Apps should be self-contained in their bundles, and may not read or write data outside the designated container area, nor may they download, install, or execute code which introduces or changes features or functionality of the app, including other apps. Educational apps designed to teach, develop, or allow students to test executable code may, in limited circumstances, download code provided that such code is not used for other purposes. Such apps must make the source code provided by the app completely viewable and editable by the user.

### (a) 仅检查版本号 + 提示 + 跳 App Store → ✅ **合规，是通行做法**

无任何条文禁止读取版本号或展示"有新版本"提示并跳转。生态证据：**Siren**（ArtSabintsev，https://github.com/ArtSabintsev/Siren ）是长期维护、广泛采用的库，其 README 指出审核员永远看不到该弹窗——因为线上版本号恒低于送审版本。前身 Harpy 已于 2018-12 并入 Siren。

⚠️ **但措辞有真实风险**——见 (b)。

### (b) 强制更新弹窗 → ⚠️ **无明文禁止，但有实际被拒记录**

- **没有**任何 guideline 明文禁止强制更新。**注意**：3.2.2(x) 字面只覆盖强迫下载 "other apps" 与 store-related actions，**不能扩大解释为禁止自我强制更新**——请勿如此引用。
- **实际被拒案例**（开发者自述，2016）：拒绝理由原文被引述为 "**Your app includes an update button or alerts the user to update the app. To avoid user confusion, app version updates must utilize the iOS built-in update mechanism.**" 原帖 https://stackoverflow.com/questions/37310731 （SO 直连 403，正文经镜像读取，**属二手**）。
- **关键洞察：被拒的触发点是「自建更新按钮/下载入口」的呈现方式，不是版本检查本身。**
- **实务风险**：审核员测试的永远是送审版，线上版本号更低，强制墙在审核时通常**不触发**；但若服务端配置错误把审核构建挡在墙外，会直接撞 2.1 App Completeness。

### (c) 从 GitHub 下载并安装 → ❌ **明确违规**

- **条文正面命中 2.5.2**："may not **download, install, or execute code** which introduces or changes features or functionality of the app, including other apps"。GitHub Releases 安装包正是此类 code；唯一豁免是教学类可编辑源码场景，不适用。
- **技术现实**：App Store 分发的 iOS App **无法**从自身内部安装 .ipa。代码签名与 provisioning 约束使其只能经 App Store / TestFlight / MDM / 企业分发 / Xcode 侧载。
- **唯一合法例外**：欧盟 DMA 下的替代分发（https://developer.apple.com/support/dma-and-apps-in-the-eu/ ），需 Apple 授权 + Notarization + MarketplaceKit，**仅限 EU**，且 Notarization 条款同样写明 "They cannot download executable code"。与"从 GitHub 拉 installer"完全不是一回事。

### 推荐做法

1. **iOS 端编译期剔除更新器**——不是运行时 if 掉。理由：2.3.1(a) 禁 "hidden, dormant, or undocumented features"，二进制残留下载-安装逻辑是可被静态扫描的风险面。
2. iOS 路径只做两件事：读版本号（iTunes Lookup API 或自托管 JSON）+ `itms-apps://` 深链跳转。
3. **文案避免"下载更新 / 立即安装"字样和自建下载进度条**（正是 2016 那例被拒的触发点），改为"前往 App Store 更新"，并提供"稍后"出口。
4. 不做硬性强制墙；确需最低版本门槛时，阈值配置成 ≤ 当前已上架版本，保证审核构建永远在门槛之上。

---

## Q5. ITSAppUsesNonExemptEncryption 该怎么填

> ⚠️ **本节不是法律意见。** 出口管制责任最终在开发者自己（Apple 原文即如此声明）。

### 结论：填 `NO`

这个 key 问的**不是**"你用没用加密"，而是"你用没用**非豁免**加密"。该 app 确实**使用**加密（DTLS-SRTP 是真正的数据机密性加密，AES-128），但落入豁免。

ASC 问卷流程上：第一问 "Does your app use encryption?" 诚实答 **Yes**；后续问到是否仅限豁免类别 / 是否 mass market 时，答案使其落入豁免，最终 plist 写 `ITSAppUsesNonExemptEncryption = NO`。

### 逐条对照 Apple 的豁免项

| 豁免项 | 是否适用 | 说明 |
|---|---|---|
| **仅使用 Apple OS 提供的加密** | ❌ **被 libwebrtc 打破** | Apple 原文要求 "including any **third-party libraries** it links against"。libwebrtc 自带 BoringSSL 做 DTLS-SRTP，不是 `URLSession` |
| 密钥不超过 56 bit 对称 | ❌ | AES-128 远超 |
| **仅用于认证（authentication）** | ✅ 对 HMAC-SHA256 成立 | HMAC 是 MAC 不是加密，无机密性，连 5A002 的门都进不去。**但救不了 WebRTC** |
| **Mass Market（Cryptography Note / Note 3）→ ECCN 5D992.c** | ✅ **真正的落点** | 免费、App Store 公开电子交易分发、用户不能轻易改动加密功能、无需供应商额外支持 —— 符合 Note 3 全部条件 |

🔑 **关键澄清（这是最容易搞混的地方）**：*"打破 OS-only 豁免" ≠ "变成 non-exempt"*。bundling 第三方加密库只是让你失去最简单那条安全港，把你推入 mass market 分析——但分析结果仍是豁免。

### 「仅用 Apple 加密」vs「标准算法 + 自研协议」的区别

| | 触发什么 |
|---|---|
| 只用 Apple OS 加密 | 最干净的安全港，无需分析 |
| **标准算法 + 自己实现协议**（本 app）| **不触发 non-exempt。** EAR 的 "non-standard cryptography" 指**专有/未公开的密码学功能（算法本身）**，不是专有的应用层报文封装。自定义 WebSocket 协议里调用标准 HMAC-SHA256 ≠ 非标准密码学 |
| 专有/未公开算法 | 这才是真正的 non-exempt 触发器 → 需 CCATS + 上传文档 |

Apple 官方对 "non-standard cryptography" 的定义（https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance ）：
> "The US Government defines 'non-standard cryptography' as any implementation of 'cryptography' involving the incorporation or use of **proprietary or unpublished cryptographic functionality**, including encryption algorithms or protocols that have not been adopted or approved by a duly recognized international standards body (e.g., IEEE, IETF, ISO, ITU, ETSI, 3GPP, TIA, and GSMA) and haven't otherwise been published."

### CCATS：**不需要**（高置信度）

只用公开标准算法（TLS、DTLS-SRTP、AES、HMAC-SHA256），落在 §740.17(b)(1) **可自我分类**路径。CCATS 仅在 (b)(2)/(b)(3) 类别才强制（非公开源码、为政府定制、量子密码、渗透工具、**非标准密码学**、密码库/工具包等）。

Apple 的文档要求表（https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption ）：

| 加密算法 | 所需文档 |
|---|---|
| 仅限 Apple 操作系统内的加密 | 无需文档 |
| 行业标准算法，非 Apple OS 提供 | 上传**法国加密声明**¹ |
| 专有算法，未被国际标准机构接受 | 上传 **CCATS** + 法国加密声明¹ |

¹ 仅在法国区上架时需要。

⚠️ **本 app 落在第二行**——若在法国上架，可能需要法国加密声明。这是个**容易被忽略的实务点**。

### Annual Self Classification Report：⚠️ **不确定**

规则（§740.17(e)(3)）：适用于按 5A992/5D992 自我分类的 mass market 加密产品，**截止次年 2 月 1 日**，需**同时**发 BIS (crypt-supp8@bis.doc.gov) **和** NSA (enc@nsa.gov)。

但有两个真实的解释困难，**不应替你消除**：
- **(a)** "free and anonymous download" 豁免写在 **§740.17(e)(1)(iii)(C)**，管的是**半年度销售报告 (e)(1)**，**不是** (e)(3) 年度报告。网上大量说法把两者混为一谈。
- **(b)** (e)(3) 中 'executable software' 定义为 "software in executable form, **from an existing hardware component**... **does not include complete binary images** of the software running on an end item"。一个 iOS app 恰恰是 complete binary image，按字面读**可能不落入** (e)(3)。

Apple 自己的措辞也留有余地：
> "If your app uses exempt forms of encryption, you **might** alternatively be required to submit a year-end self-classification report to the U.S. government."

**实务建议**：报送成本极低（一封 CSV 邮件）。想彻底安心可照报，但这一点应咨询出口管制律师。

### §742.15(b) 开源通知：**不适用**

该条管的是**发布**公开加密源代码，且通知义务仅在所发布源码含 **non-standard cryptography** 时触发。**在自己二进制里使用** libwebrtc ≠ 发布源码，且 libwebrtc 用的是标准密码学。

### 关键法规原文（均经 eCFR 逐字核对）

[15 CFR 774 Supp.1, **Technical Note 1 to 5A002.a**](https://www.ecfr.gov/current/title-15/subtitle-B/chapter-VII/subchapter-C/part-774/appendix-Supplement%20No.%201%20to%20Part%20774)：
> "'cryptography for data confidentiality' means 'cryptography' that employs digital techniques and performs any cryptographic function **other than** any of the following: 1.a. '**Authentication**;' 1.b. Digital signature; 1.c. Data integrity; 1.d. Non-repudiation..."
>
> **5D992.c**: "'Software' classified as mass market encryption software in accordance with § 740.17(b) of the EAR."

⚠️ **更正一个常见错误**：认证解控位于 **Technical Note 1 to 5A002.a**，**不是 "Note 2"**（Note 2 是智能卡/银行设备/无绳电话/PAN/OAM 清单）。

其他：[§772.1 "Authentication" 定义](https://www.ecfr.gov/current/title-15/subtitle-B/chapter-VII/subchapter-C/part-772/section-772.1)｜[§740.17 License Exception ENC](https://www.ecfr.gov/current/title-15/subtitle-B/chapter-VII/subchapter-C/part-740/section-740.17)｜[§742.15](https://www.ecfr.gov/current/title-15/subtitle-B/chapter-VII/subchapter-C/part-742/section-742.15)｜[BIS Encryption Controls](https://www.bis.gov/learn-support/encryption-controls)

### 需要专业意见的点

1. **Annual Report 是否真的必须报**——条文本身冲突（见上 a/b）
2. **libwebrtc 是否可能被解读为 "cryptographic library/toolkit"**（→ §740.17(b)(3)(i)(B)，那会需要 CCATS）。倾向否（你分发的是终端 app，不是开发工具包），但边界值得确认
3. **法国 ANSSI**——Apple 明确提到法国对加密 app 另有管制，且 **Secure Communications 是其管制项之一**。本 app 正是通信 app，**值得单独评估**
4. **禁运国**——License Exception ENC 不适用于 Country Group E:1/E:2（古巴、伊朗、朝鲜、叙利亚等），App Store 分发范围应排除

---

## Q6. 中国大陆开发者上架的区域限制

### Q6-1. 个人开发者能否不在中国大陆上架？→ **能，完全可以**

App Store Connect 的销售范围按国家/地区逐一勾选，中国大陆只是 175 个 storefront 之一，**没有任何针对个人开发者的限制阻止取消勾选**。

来源：https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/manage-availability-for-your-app-on-the-app-store
> "Before submitting your app for review on the App Store, you must set its availability. You can release your app in any of the **175 countries or regions** where the App Store is available."
>
> "**Note:** When you deselect a country or region where your app was available, the app will be removed from the App Store in that country or region. Users who previously downloaded your app... will continue to receive app updates."

Apple 同页明确承认地区不可用是常态：
> "Your app may not be available for download or use in some countries or regions due to legal or regulatory requirements."

**排除中国区的代价**：Apple 文档中**未发现**任何惩罚、审核歧视或功能限制。唯一代价是纯商业性的——放弃中国大陆市场。

### Q6-2. ICP 备案时间线：你记的基本正确，需修正两处

⚠️ **文件名更正**：你提到的「移动互联网应用程序备案管理工作方案」在 miit.gov.cn **未能找到**。真实的一次法规是：

**《工业和信息化部关于开展移动互联网应用程序备案工作的通知》（工信部信管〔2023〕105号）**，成文 2023-07-21，发布 2023-08-04。
来源：https://www.miit.gov.cn/zwgk/zcwj/wjfb/tz/art/2023/art_920db564162e4312916a01bed6540ad8.html

核心义务原文：
> "（一）在中华人民共和国境内从事互联网信息服务的APP主办者，应当依照《中华人民共和国反电信网络诈骗法》《互联网信息服务管理办法》（国务院令第292号）等规定履行备案手续，**未履行备案手续的，不得从事APP互联网信息服务**。"
>
> "（九）网络接入服务提供者、分发平台、智能终端生产企业**不得为未履行备案手续的APP提供网络接入、分发、预置等服务**。"

四阶段时间表（工信部原文）：

| 阶段 | 时间 |
|---|---|
| 工作准备 | 2023年8月底前 |
| 存量APP备案 | **2023年9月–2024年3月** |
| 监督检查 | **2024年4月–6月** |
| 常态化 | **2024年7月至长期** |

对你几项记忆的核对：
- ✅ MIIT 文件 2023-08 发布 —— 正确
- ✅ 存量 app 2024-03-31 前 —— 正确
- ✅ 2024-07-01 起常态化执法 —— 正确
- ⚠️ "新 app 从 2023-09 或 2024-04 起需备案" —— 这两个是 **Apple 侧**的执行卡口，不是 MIIT 的。工信部原文是"本通知发布后拟开展业务的APP，应**先履行备案手续后再开展业务**"
- ❌ 文件名不对（见上）

**Apple 侧两个实际节点**：2023-09-29 Apple 更新 ASC 文档要求新 App 提交 ICP 备案号（[Reuters 转引](https://www.straitstimes.com/asia/east-asia/apple-enforces-new-check-on-apps-in-china-as-beijing-tightens-oversight)、[IT之家](https://www.ithome.com/0/722/535.htm)）；2024-04-01 开启强校验（自动比对 App 名称与工信部备案记录）。

### Q6-3. 只适用于中国大陆 storefront？→ **是，Apple 措辞明确**

来源：https://developer.apple.com/help/app-store-connect/reference/app-information/app-information ，条目标题即为 "**Availability in China mainland**"：
> "Chinese law requires additional documentation for some apps **to be available on the App Store in China mainland**. China's Ministry of Industry and Information Technology (MIIT) requires that some apps possess a valid Internet Content Provider (ICP) Filing Number..."
>
> "**If you offer or plan to offer any of these on the App Store in China mainland**, you must provide the required information along with one or more supporting documents."

条件句 "If you offer … on the App Store in China mainland" —— **不在中国大陆上架即不触发**。

### Q6-4. 自然人能否办 ICP 备案？→ **能**（与"必须有营业执照"的传言相反）

**个人主体可以备案，不需要营业执照。真正的门槛是：必须有中国内地域名 + 中国内地服务器。**

[阿里云《ICP备案所需资料》](https://help.aliyun.com/zh/icp-filing/basic-icp-service/user-guide/required-materials) 明确分两类主体，个人备案必备资料只要求「**个人身份证件（原件）**：中国内地居民：身份证」——**个人备案栏里没有营业执照**，营业执照只出现在"企业单位备案"栏。阿里云另有专门的[《App备案快速入门》个人版文档](https://help.aliyun.com/zh/icp-filing/basic-icp-service/getting-started/quick-sta-rt-for-icp-filing-for-personal-app)。

**境外服务器 → 无法备案（确认）**：
> "若您的阿里云资源位于中国香港、海外节点等非中国内地节点服务器则无需备案。"

ECS 硬性要求：「中国内地的所有地域、计费方式为包年包月、已分配公网IP地址」。备案须通过**网络接入服务提供者**代办（工信部设计）——**没有中国内地接入商 = 没有代办通道 = 无法备案**。

**实操代价**：纯单机 app（无网络权限）也必须备案。开发者证言（[V2EX](https://global.v2ex.co/t/1064698)）：「我有几个 App 跟你一样，单机 App，网络权限都没有。也得备案……具体方案就是**阿里云买最便宜的域名，买最便宜的云主机**。」

**类别限制**：新闻、出版、教育、影视、宗教类需前置审批，个人实际无法取得；游戏需版号（ISBN），个人拿不到。**普通工具/社交类个人 app 不受此限**——但注意本项目是语音社交，是否会被归入需前置审批的类别**不确定**。

流程耗时：3–22 个工作日；另需自 app 开通之日起 30 日内完成**公安联网备案**。

### Q6-5. 未备案的下场 → 从中国大陆区移除

开发者一手证言（[V2EX «AppStore 开始下架没有备案的应用了», 2024-08-13](https://global.v2ex.co/t/1064698)）：
> 「中国大陆地区被下架：理由是：**缺少 ICP 备案号**」
> 「没有备案的都被下架了，**无论新旧**。苹果后台直接把没有备案号的 app 从中国大陆地区移除了，**且没有邮件通知**。」

⚠️ **需纠偏的常见错误**：网上流传的"苹果下架 29,800 款应用"是 **2020 年 7 月**、原因是**游戏版号**，**与 2024 年 ICP 备案无关，不可混用**。

### Q6-6. 是否被"强制"上架中国区？→ **否**

相关合规义务绑定的是**开发者身份/居住地**，不是 storefront 选择。《国务院令第810号》税务报送（https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-information-for-state-council-decree-no-810 ）：
> "Apple is required to report Chinese developers **who distribute apps through the App Store** from July 2025 onwards."

触发条件是"通过 App Store 分发"，**未限定中国区**；个人需提供身份证信息，与销售范围无关。另 Apple 说明："State Council Decree No. 810 doesn't change your tax obligations."

另一条中国大陆合规项（公示公司名称+统一社会信用代码）**只适用于组织，不适用个人**。

### 一句话结论

**个人开发者完全可以在 ASC 里不勾选中国大陆，从而彻底绕开 ICP 备案——这是 Apple 官方支持的正常配置，无任何惩罚。** 若要上中国大陆区，备案不可回避：个人**可以**备案（无需营业执照），但必须配中国内地域名 + 中国内地服务器（最低成本：阿里云最便宜域名 + 最便宜 ECS），流程 3–22 工作日，另需 30 日内完成公安联网备案；且 **App 名称必须与工信部备案记录逐字一致**，否则 ASC 强校验会直接拦下提审。

> 💡 **对本项目的建议**：鉴于该 app 是自建服务器的语音社交、且服务器很可能在境外，**不勾选中国大陆区是明显更简单的路径**。

---

## Q7. Guideline 2.3.1 (Hidden features) 原文

### 原文（verbatim，Apple 官方）

> **2.3.1**
> **(a)** Don't include any hidden, dormant, or undocumented features in your app; your app's functionality should be clear to end users and App Review. All new features, functionality, and product changes must be described with specificity in the Notes for Review section of App Store Connect (generic descriptions will be rejected) and accessible for review. Similarly, marketing your app in a misleading way, such as by promoting content or services that it does not actually offer (e.g. iOS-based virus and malware scanners) or promoting a false price, whether within or outside of the App Store, is grounds for removal of your app from the App Store or a block from installing via alternative distribution and termination of your developer account.
> **(b)** Egregious or repeated behavior is grounds for removal from the Apple Developer Program. We work hard to make the App Store a trustworthy ecosystem and expect our app developers to follow suit; if you're dishonest, we don't want to do business with you.

⚠️ **重要措辞更正**：现行文本是 **"hidden, dormant, or undocumented"**，含 **"dormant"（休眠的）**。网上广泛流传的 "hidden or undocumented features" 是**旧版措辞**，请勿引用。"dormant" 正是本题的关键词。

（2.3.2 与隐藏功能**无关**，是 IAP 披露条款。）

### 结论：分层回答

| 情形 | 定性 |
|---|---|
| **(i) 编译期常量剔除**（`#if` 让代码根本不进二进制，符号不存在、无任何运行时可达路径、无远程开启途径）| 文本上**不构成 "feature"**。2.3.1 落脚于 "functionality should be clear to end users and App Review"——不存在、不可激活的东西不是 functionality。**但仍有符号扫描风险，见下** |
| **(ii) 运行时 flag 门控**（代码在包里、当前不暴露、但具备被激活的能力）| **= "dormant" = 经典 2.3.1 违规**，除非在 Notes for Review 中披露且**对审核员可达** |

**核心判准不是"当前 UI 有没有入口"，而是"能否事后激活"。** 编译期剥离（真死）与运行时 flag 判断（休眠）在 2.3.1 下是完全不同的两类。

**决定性第三方证据**——LaunchDarkly（feature flag 厂商）官方文档：
> "Apple has, in the past, raised concerns about **code which is present in an app but which doesn't seem to be reachable during testing.** If you encounter this feedback, you may be able to resolve it by enabling all features for the app version being tested, allowing App Store reviewers to investigate your app, and then disabling unlaunched features before release."

来源：https://raw.githubusercontent.com/launchdarkly/LaunchDarkly-Docs/refs/heads/main/src/content/topics/sdk/concepts/apple-app-store.mdx

### Apple 是否做二进制扫描？→ **做**

**(1) Apple 官方承认自动化分析**：
- 指南引言："We also scan each app for malware and other software that may impact user safety, security, and privacy."
- [Apple Newsroom, 2022-06-01](https://images.apple.com/mt/newsroom/2022/06/app-store-stopped-nearly-one-point-five-billion-in-fraudulent-transactions-in-2021/)："The App Review process is multilayered, and combines computer automation with manual human review. App Review uses proprietary tools that leverage machine learning, heuristics..."
- 同页执法量：**"In 2021 alone, the App Review team rejected more than 34,500 apps for containing hidden or undocumented features."**

**(2) 决定性证据：Apple 按符号/selector 字符串扫描，不看可达性。** Apple 自动拒绝邮件原文（[Apache Cordova CB-12843, 2017-05](https://issues.apache.org/jira/browse/CB-12843)）：
> "Non-public API usage: The app references non-public selectors in XXX: `_terminateWithStatus:`
> **If method names in your source code match the private Apple APIs listed above, altering your method names will help prevent this app from being flagged** in future submissions. In addition, note that one or more of the above APIs may be **located in a static library that was included with your app. If so, they must be removed.**"

三点推论：① 触发条件是**名字文本匹配**——Apple 给的解法是"改你自己的方法名"，只有纯字符串扫描才会这样建议；② 明确预期符号来自**你没写的第三方静态库**；③ 该案中字符串来自 Google Toolbox 的**单元测试**代码，即本不该被链接的死代码。

**→ 结论：未调用、不可达的代码中的敏感符号照样触发拒绝（ITMS-90338）。这正是 Q4 建议"编译期剔除而非运行时 if 掉"更新器的实证理由。**

**(3) 但注意边界**：这套自动扫描针对的是 **private API 符号黑名单**。**没有证据表明 Apple 会自动扫描"未使用的业务代码路径"并据此判 2.3.1**——2.3.1 的触发在实践中是人工审核 + 事后行为监测。

### 远程 flag 本身允许吗？→ 允许，判准是 data vs. code

业界（Firebase Remote Config / LaunchDarkly）普遍使用。红线是**用它向 App Review 隐瞒功能**，以及 **Review Detection**（识别审核环境后变脸）——后者是账号级封杀线。

**案例**：Uber 地理围栏 Apple 总部（2015 事发 / 2017 曝光），对 Cupertino 范围内的设备混淆代码以规避审核，Tim Cook 召见 Kalanick 威胁下架。[MacRumors 转引 NYT](https://www.macrumors.com/2017/04/24/time-cook-threatened-to-pull-uber-from-app-store/)。
> ⚠️ 更正：此事起因是**设备指纹 + 地理围栏规避审核**，不是 Greyball。未找到 Apple 就 Greyball 采取行动的证据。

**2017 JSPatch / 热更新清洗** Apple 信件原文：
> "your app **contains code designed explicitly with the capability to change your app's behavior or functionality after App Store Review approval**, which is not in compliance with... App Store Review Guideline 2.5.2."

注意 "**capability**（具备能力）"——不要求已实际使用。**→ 不要引入 JSPatch / CodePush 类热更新 SDK。**

### 实操建议

1. **首选编译期彻底剥离**：用 `#if` 让代码根本不进二进制。发布 target 应能通过 `strings`/`nm` 验证相关符号已消失。
2. **提交前自检**：对 IPA 跑 `strings` / `nm` / `otool -oV`，检查 ① private selector 名撞库 ② 未上线功能的类名/接口路径/文案泄漏。这正是 Apple 扫描器看的东西。
3. **剔除 debug 菜单、摇一摇入口、隐藏 URL scheme、测试 target 依赖**（Cordova 案的根因就是误链单测文件）。
4. **必须保留远程 flag 时**：只切 data 不切代码；在 Notes for Review 中**逐项具体说明**（"generic descriptions will be rejected"）；审核期把 flag 全开保证审核员可达。
5. **绝对不要**基于 IP/地理位置/时间/测试账号识别审核环境并改变行为。

> **不确定**：Apple 是否对"未使用的**业务**代码路径"做可达性分析并据此判 2.3.1——已证实的只有 private API 符号黑名单扫描。Apple 从未公开说明检测实现机制。developer.apple.com/forums 全站有机器人墙，"Apple 员工在论坛认可 feature flag"这一流传说法**未能核实**。

---

## Q8. 隐私营养标签（App Privacy / Nutrition Labels）

### "Collect" 官方定义（verbatim）

来源 https://developer.apple.com/app-store/app-privacy-details/ ——**你引述的措辞完全正确**：

> "'Collect' refers to transmitting data off the device in a way that allows you and/or your third-party partners to access it for a period longer than what is necessary to service the transmitted request in real time."

**决定性的补充条款**（同页 Additional guidance → "You collect data to service a request but do not retain it after servicing the request"）：

> "'Collect' refers to transmitting data off the device and **storing it in a readable form** for longer than the time it takes you and/or your third-party partners to service the request. For example, if an authentication token or IP address is sent on a server call and not retained, or if **data is sent to your servers then immediately discarded after servicing the request, you do not need to disclose this** in your answers in App Store Connect."

> "Data that is processed only on device is not 'collected' and does not need to be disclosed in your answers."

### 结论：**可以选 "Data Not Collected"，但有前提，且存在一处无法用 Apple 文本消解的冲突**

**支持方**：纯内存转发不构成 collect——Apple 明确以 "**storing it in a readable form**" 为门槛，并点名 "sent to your servers then immediately discarded" 无需申报。昵称仅本地存储属 "processed only on device"。

**反对方（必须正视）**：同一页另一条 Additional guidance 说：
> "**You offer in-app private messaging between users that are not SMS text messages.** Declare emails or text messages on your label. Text messages refer to both SMS and non-SMS messages."

此条**未写"除非不留存"的豁免**。两条指引直接冲突，Apple 未公开优先级 → **不确定**。

> 判断：文义上"不留存"方占优（collect 是全局定义，私信条目是场景提示）；但审核实务风险在于**审核员无法验证服务端不落盘**，一个核心功能就是即时通讯的 App 打 "Data Not Collected" 观感异常，被 5.1.1 质询的概率不低。

### 可以选 Data Not Collected 的前提清单（须全部成立）

1. 服务器**零写盘**：无消息历史、无媒体落地、无数据库、**无离线消息队列**（离线暂存 = 落盘 = 必须申报）
2. nginx / LiveKit / WebSocket **access log 关闭或不记录 IP**
3. 无崩溃上报 SDK、无自建 telemetry、无第三方分析
4. 邀请码/口令**不在服务端与设备建立可留存映射**
5. **CDN / 反向代理 / 云厂商同样不保留日志**（第三方基础设施日志属 "third-party partners ... access it"）
6. 昵称仅存本地

### 逐项风险点

**IP / 服务器日志 —— 最高风险，也是绝大多数"我什么都不收集"声明真正翻车的地方。** Apple 原文：
> "**You collect and store IP address from your users.** Declare the relevant data types based on how you use IP address, such as precise location, coarse location, device ID, or diagnostics."

判定线是 **collect *and* store**。IP 出现在 TCP 握手中不算；写进 access.log 保留 7/30 天就跨线了。届时按用途申报 Device ID 或 Diagnostics（用途选 App Functionality）。

**Apple 自家分析无需申报**：
> "You are not responsible for disclosing data collected by Apple."

**Tracking 定义**（本 app 无广告无数据经纪 → 不构成 tracking，**无需 ATT 弹窗**）：
> "'Tracking' refers to linking data collected from your app about a particular end-user or device... with Third-Party Data for targeted advertising or advertising measurement purposes, or sharing data collected from your app about a particular end-user or device with a data broker."

### 隐私政策：**即使零收集也强制**

Guideline 5.1.1(i) 原文：
> "**(i) Privacy Policies:** All apps must include a link to their privacy policy in the App Store Connect metadata field **and within the app** in an easily accessible manner. The privacy policy must clearly and explicitly: Identify what data, **if any**, the app/service collects, how it collects that data, and all uses of that data... Explain its data retention/deletion policies and describe how a user can revoke consent and/or request deletion of the user's data."

注意 "**and within the app**"——App 内也要有可达入口，不只 ASC 字段。"what data, **if any**" 说明零收集也得写。

### Privacy Manifest：**很可能需要，但不是因为 SDK**

触发条件是 required-reason API（https://developer.apple.com/documentation/bundleresources/privacy-manifest-files ）。五类之一是 **User Defaults**——**本地存昵称若用 `UserDefaults` 就直接触发**，需声明 `NSPrivacyAccessedAPICategoryUserDefaults` + 理由码（自用一般 `CA92.1`）。典型最小清单：该类目 + `NSPrivacyTracking=false` + 空 `NSPrivacyCollectedDataTypes`。

WebRTC / LiveKit **不在** Apple 的 listed-SDK 名单（https://developer.apple.com/support/third-party-SDK-requirements/ ），故签名+清单强制条款不适用——但仍需自查其发行包是否调用 required-reason API。

---

## Q9. 麦克风类 app 的额外要求

### UIBackgroundModes: `audio` vs `voip`

`voip` 仍是官方有效值（**未废弃**），但 Apple 文档已把它完全指向 CallKit。官方表格原文（https://developer.apple.com/documentation/xcode/configuring-background-execution-modes ）：
- `audio` → "The app plays audible content in the background."
- `voip` → "The app provides Voice over IP services. **For more information, see the CallKit framework.**"

同页警告：*"Use background execution modes sparingly... If an alternative to executing in the background exists, use the alternative instead."*

**对前台语音房：正确选择是 `audio`，不是 `voip`。**

### PushKit + CallKit 的 iOS 13 强制规则 → 属实，但**你记的日期需要更正**

**触发条件是"链接 iOS 13 SDK 或更高"，即 2019 秋起，不是 iOS 13 发布后的某个 2021 日期。**

一级来源（PushKit 官方文档 Important aside）：
> "When linking against the iOS 13 SDK or later, your implementation of this method **must** report notifications of type `PKPushType.voIP` to the CallKit framework by calling the `reportNewIncomingCall(with:update:completion:)` method..."
>
> "**On iOS 13.0 and later, if you fail to report a call to CallKit, the system will terminate your app. Repeatedly failing to report calls may cause the system to stop delivering any more VoIP push notifications to your app.** If you want to initiate a VoIP call without using CallKit, register for push notifications using the User Notifications framework instead of PushKit."

另一份一级来源（https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit ）：
> "For apps built using the iOS 13 SDK or later, **PushKit requires you to use CallKit** when handling VoIP calls."

⚠️ **需纠正的常见混淆**：2021-04-26 的 deadline 是"所有提交必须用 Xcode 12 + iOS 14 SDK 构建"（https://developer.apple.com/news/?id=ib31uj1j ），**与 PushKit 规则无关**。

### 不用 push、只在前台通话 → **没有问题，且是最优解**

1. **CallKit 不是必需的**。强制条款的触发前提明确是"报 `PKPushType.voIP` 类型的 PushKit 通知"。不注册 `PKPushRegistry` → 条款不适用。Apple 自己给出替代路径：用 User Notifications framework。
2. **`voip` background mode 不必声明**，声明它反而是审核风险面。
3. **中国大陆 CallKit 被禁**（二手来源：https://cn.technode.com/post/2018-05-14/callkit-china/ ，2018年报道称工信部要求中国区 app 禁用 CallKit；微信 iOS 已于 2018-02 关闭）。**含义**：面向大陆时，绑定 CallKit 的 PushKit 方案本就走不通（PushKit 要求 CallKit，中国区禁 CallKit → 死锁），反过来强化了"前台 + 标准 APNs"方案。

### 后台音频滥用的审核条款

⚠️ **重要更正：不存在 Guideline 2.16。** 已逐条核对，指南第 2 节止于 2.5.18，无 2.6–2.16 任何编号。**请勿引用 2.16。**

**2.5.4 原文（verbatim）**：
> "Multitasking apps may only use background services for their intended purposes: VoIP, audio playback, location, task completion, local notifications, etc."

播放静音音频保活 = 用 `audio` 后台服务做非 audio playback 用途，正撞 2.5.4 + 2.5.1 "intended purposes"。

### 麦克风与录音

- `NSMicrophoneUsageDescription`：*"This key is required if your app uses APIs that access the device's microphone."* 缺失将导致崩溃。
- **5.1.1(ii)**：*"Ensure your purpose strings clearly and completely describe your use of the data."*
- **5.1.1(iii) Data Minimization**：*"Apps should only request access to data relevant to the core functionality of the app..."*
- **2.5.14（录音场景关键）**：*"Apps must request explicit user consent and provide a clear visual and/or audible indication when recording, logging, or otherwise making a record of user activity. This includes any use of the device camera, microphone, screen recordings, or other user inputs."*

### 推荐合规配置（前台语音房，无 push）

1. `UIBackgroundModes` **只填 `["audio"]`**，不加 `voip`
2. **不集成 PushKit** → 完全规避 iOS 13 CallKit 强制条款，也自动兼容中国大陆
3. **不集成 CallKit**（无 PushKit 前提下非必需，且中国区不可用）
4. `AVAudioSession` 设 `.playAndRecord` + mode `.voiceChat`（含回声消除），仅在用户主动进房时 `setActive(true)`，离开时 `setActive(false, options: .notifyOthersOnDeactivation)`
5. **绝不播放静音音频保活**
6. 来电/邀请通知用标准 APNs alert（Apple 文档指定的 non-CallKit 路径）
7. `NSMicrophoneUsageDescription` 写具体用途，避免"需要麦克风权限"这类空泛文案
8. App 描述 + 审核备注说明音频后台用途（呼应 2.5.1）

---

## Q10. 新开发者账号的时间成本

### 费用与流程

**99 USD/年**（https://developer.apple.com/programs/enroll/ ）：
> "The Apple Developer Program is 99 USD per membership year. Prices may vary by region and are listed in local currency during the enrollment process."

个人**无需 D-U-N-S**。关键差异（https://developer.apple.com/support/enrollment/ ）：
> "Individuals and sole proprietors/single-person businesses can review the license agreement and purchase a membership **at the time of enrollment**. Organizations can review the license agreement and purchase a membership **once Apple Developer Support verifies** the enrollment information..."

→ 个人是**先付款后审核**。

⚠️ **需更正的premise：Apple 官网不存在 "2 business days" 审核承诺。** 已逐字检索 enroll/、support/enrollment/、identity-verification 三页。唯一时限表述是：
> "If you haven't received a membership confirmation **within 24 hours** of your purchase, contact us."

这是**超时投诉阈值，不是审核时长承诺**。

**信用卡陷阱**（对个人尤其重要）：
> "If you're paying by credit card and enrolling as an individual, you must use **your own** credit card... If you do not, your enrollment will be delayed and you'll be asked for a copy of your government-issued photo identification."

### 身份验证：中国大陆被官方点名

https://developer.apple.com/help/account/membership/identity-verification ：
> "Verification of your legal identity is **currently required** in order to enroll... **In some cases**, you may be asked for your government identification number or an image of your photo ID."
>
> "Identity verification is **required for Account Holders based in China mainland** and developers based in certain regions..."

⚠️ 注意照片 ID 是 "**in some cases**"，并非普遍强制——原假设偏强。

大陆实际提交物（二手，两篇独立来源一致）：**身份证号 + 自拍照**（非护照扫描），姓名须用拼音/英文字母填写。来源：[掘金 2025-07](https://juejin.cn/post/7529496810265575458)、[掘金 2026-07](https://juejin.cn/post/7664482758841073705)。

### 大陆个人注册实际耗时（均为二手）

| 来源 | 日期 | 耗时 |
|---|---|---|
| [V2EX #1196059](https://global.v2ex.co/t/1196059) | 2026-03 | "一天就审核过了" |
| 同帖另一回复 | 2026-03 | "2-3 天左右，慢的一周，前提材料没问题" |
| [掘金](https://juejin.cn/post/7664482758841073705) | 2026-07 | "快的话几小时，慢的一两天" |

→ 收敛：材料无误时 **数小时–3 天**，异常可至一周。

**常见延迟原因**（按证据强度）：①姓名与法定姓名不符（Apple 官方三处重复警告）②非本人信用卡（Apple 官方）③自拍照不清晰/姓名与身份证对不上（二手）④信用卡未开通境外支付；**不能用 Apple ID 余额支付**（二手）。

### App Review 时长 ✅ 逐字证实

https://developer.apple.com/distribute/app-review/ （`/app-store/review/` 重定向至此）：
> "**On average, 90% of submissions are reviewed in less than 24 hours.**"

**首次提交主要拖慢因素**（官方同页）：
> "On average, **over 40% of unresolved issues are related to guideline 2.1: App Completeness**"

具体：崩溃、失效链接、占位内容、**未提供 demo 账号**、隐私政策不合规、purpose string 缺失、4.2 功能过弱。

### 首次上架的一次性关卡（免费 app）

| 关卡 | 免费 App 是否需要 | 依据 |
|---|---|---|
| Paid Apps Agreement | **否** | "To **sell** your apps... the Account Holder must sign the Paid Apps Agreement" |
| 税务表格 + 银行信息 | **否**（仅收款时）| "To receive payments from Apple... you'll first need to sign a Paid Apps Agreement" |
| 年龄分级问卷 | **是** | "An Unrated app can't be published on the App Store" |
| 出口合规/加密声明 | **是** | 见 Q5 |
| 隐私政策 URL + App Privacy 披露 | **是** | 见 Q8 |
| **EU trader 申报** | **是（即使不发欧盟）** | 见下 |

### ⚠️ EU DSA trader status（容易被忽略的强制项）

Apple 官方（https://developer.apple.com/news/?id=6agg0lja ，2025-02-18）：
> "As of today, apps without trader status have been removed from the App Store in the European Union (EU) until trader status is provided and verified by Apple."

合规帮助页：
> "**Even if you don't distribute apps in the EU, you'll still need to declare a trader status.**"
> "You're unlikely to be a trader... if you're acting 'for purposes which are outside your trade, business, craft, or profession.' For example, **if you're a hobbyist and you developed your app with no intention of commercializing it, you may not be considered a trader**."

**对本项目（免费无内购）的含义**：①申报动作无法回避；②纯免费无变现 → 可合法选 non-trader，**无需公开住址电话**；③一旦加入 IAP/广告 → 即属 trader，**住址+电话+邮箱将公开显示在欧盟 App Store 页面**（对个人开发者是实质隐私成本）。

### 「从零到上架」时间线估算（个人 / 大陆 / 免费 app，不含开发）

| 阶段 | 乐观 | 典型 | 悲观 |
|---|---|---|---|
| 备料（Apple ID + 双因素 + 信用卡 + 身份证）| 0.5 天 | 1 天 | 3 天 |
| 提交注册 → 账号激活 | 数小时 | 1–3 天 | 7 天+ |
| ASC 配置（App 记录、分级、隐私、出口合规、trader）| 0.5 天 | 1–2 天 | 3 天 |
| 构建上传 + TestFlight 自测 | 0.5 天 | 1–2 天 | 5 天 |
| **首次 App Review（单轮）** | **<24h** ✅官方 | **<24h** | 3–7 天 |
| 被拒 → 修复 → 复审 | 0 轮 | 1 轮（+2–4 天）| 2–3 轮（+1–2 周）|
| **合计** | **约 2–3 天** | **约 1–2 周** | **约 4–6 周** |

---

# 📋 「我不确定 / 需要进一步验证」清单

## 🔴 高影响 —— 会改变产品决策

1. **「邀请码私密小圈子」是否会被审核员归入 1.2 的 "random or anonymous chat"** —— 这是全报告最关键的不确定项。条文未定义 "anonymous"；产品实质（无陌生人撮合）与表面特征（无账号、昵称任填）指向相反结论。Vibely 的抗辩无效说明**审核员的归类判断可能压过开发者的架构解释**。**无法从文本推定，建议提审前通过 Apple 的 App Review Appointment（30 分钟 Webex 咨询）当面确认。**
2. **Apple 是否要求实时语音具备"可审查/可留证"能力** —— 未找到任何 Apple 官方要求（包括对 Clubhouse）。**未能证实亦未能证伪。** 请勿宣称 Apple 强制要求录音。
3. **隐私标签冲突：「不留存」豁免 vs「私信须申报 Emails or Text Messages」** —— 两条 Apple 指引直接冲突，官方未公开优先级。影响 Data Not Collected 能否选。
4. **Annual Self-Classification Report 是否对普通 iOS app 强制** —— 条文自身冲突（'executable software' 定义排除 complete binary images；free-download 豁免位于错误段落）。**唯一真正需要律师的点。**
5. **语音社交类是否属中国 ICP 备案的前置审批类别** —— 未核实。若走中国区需确认。

## 🟡 中等影响 —— 影响实现细节

6. **Apple 是否对"未使用的业务代码路径"做可达性分析并据此判 2.3.1** —— 已证实的只有 private API 符号黑名单扫描；通用死代码检测**无证据**。
7. **强制更新墙在 2026 年的实际通过率** —— 仅有 2016 年一例二手拒信（SO 原页 403，经镜像读取）。Apple 论坛 4 个相关帖因反爬墙**正文未取到**。
8. **仅记录 IP 但从不反查地理位置，是否触发 Coarse Location** —— 文义倾向否，Apple 无明文。
9. **CDN / 云厂商日志是否必须视为 "third-party partners" 收集** —— Apple 无专条。
10. **WebSocket 离线消息缓冲**（哪怕几秒内存队列）是否越过 "necessary to service the request in real time" —— 无明文。
11. **LiveKit / WebRTC 二进制是否调用 required-reason API、是否自带 PrivacyInfo.xcprivacy** —— **需自行检查发行包**，Apple 文档不决定。
12. **libwebrtc 是否可能被解读为 "cryptographic library/toolkit"**（→ 需 CCATS）—— 倾向否，边界值得确认。
13. **法国 ANSSI 对通信类 app 的具体要求** —— 未研究。Apple 明确提到法国对 Secure Communications 另有管制，**本 app 正是通信 app**。
14. **中国大陆 CallKit 禁用** —— 仅有 2018 年中文媒体转述开发者收到的审核邮件，**Apple 无任何官方文档**；运行期确切行为未经一级来源验证。
15. **海外主体开发者在中国区是否已被要求 ICP 备案** —— 2024-04 时免除，业内预期收紧，**未能验证是否已发生**。

## ⚪ 方法学局限

16. **developer.apple.com/forums 全站有机器人墙** —— 多个相关贴仅确认标题存在，**正文均未取到**。"Apple 员工在论坛认可 feature flag"这一流传说法**未能核实**。
17. **Reddit / HN 检索为空** —— 既可能是真实不存在，也可能是工具限制（Reddit 基本不可抓取）。**此处"未找到"不应完全等同于"不存在"。**
18. **ASC 加密问卷的逐字文本** —— 当前 Apple Help 页**已不再包含**旧版豁免 bullet list，该列表现仅存于登录后的问卷 UI，**无法验证，故未逐字引用**。请勿从本报告引用那些 bullet 的"原文"。
19. **指南页面不暴露修订日期** —— 判断为现行版本（含 Notarization / MarketplaceKit / 第三方 AI 披露等近期条款），残余风险为代理返回缓存副本。
20. **4.7 "chatbots" 的边界解读** —— 基于 4.7.4「软件索引」所作的**结构性推断，非 Apple 明示表态**。

## ❌ 已排除的错误说法（勿再引用）

- ~~Guideline 2.16~~ —— **不存在**。指南第 2 节止于 2.5.18。
- ~~"hidden or undocumented features"~~ —— 旧版措辞。现行为 **"hidden, dormant, or undocumented"**。
- ~~PushKit/CallKit 强制自 2021-04 生效~~ —— 实为**"链接 iOS 13 SDK 或更高"**。2021-04-26 是无关的 Xcode 12/iOS 14 SDK 截止日。
- ~~Apple 承诺 2 个工作日内审核开发者账号~~ —— **官网不存在此承诺**。只有"24 小时未收到确认请联系我们"（投诉阈值）。
- ~~「移动互联网应用程序备案管理工作方案」~~ —— 未找到此文件。正确名称见 Q6。
- ~~"苹果因未备案下架 29,800 款应用"~~ —— 该事件是 **2020 年 7 月游戏版号**问题，与 ICP 备案无关。
- ~~认证解控位于 "Note 2 to 5A002.a"~~ —— 实为 **Technical Note 1 to 5A002.a**。
- ~~3.2.2(x) 禁止强制更新~~ —— 其字面只覆盖 "other apps" 与 store-related actions，**不可扩大解释**。
- ~~Uber 因 Greyball 被 Apple 威胁下架~~ —— 实因**设备指纹 + 地理围栏规避审核**。
- ~~ATS justification 要求已无限期暂停~~ —— 论坛用户措辞非 Apple 原话。期限取消 ≠ justification 要求撤销。

---

# ✅ 落地行动清单

## 必做（不做大概率被拒）

- [ ] **实装 1.2 四件套**：举报按钮、拉黑/踢出、EULA（明示 no tolerance for objectionable content or abusive users）、App 内可见联系方式
- [ ] **解决 2.1 可审查性**：自运行的演示服务器（固定 DNS、443 端口、系统信任证书、审核期保证在线）+ 演示邀请码，或内置 fully-featured demo 模式
- [ ] **iOS 端编译期剔除 GitHub 更新器**（`#if`，不是运行时 if），提交前用 `strings`/`nm` 验证符号已消失
- [ ] `UIBackgroundModes` **只填 `["audio"]`**，不加 `voip`；不集成 PushKit/CallKit
- [ ] 隐私政策 URL（ASC 字段 **+ App 内可达入口**），即使零收集也要写
- [ ] 最小 `PrivacyInfo.xcprivacy`（存昵称若用 UserDefaults 即触发 `NSPrivacyAccessedAPICategoryUserDefaults` + `CA92.1`）
- [ ] `ITSAppUsesNonExemptEncryption = NO`
- [ ] EU trader status 申报（选 non-trader，前提是保持免费无变现）
- [ ] 年龄分级问卷（新 13+/16+/18+ 体系）
- [ ] 具体的 `NSMicrophoneUsageDescription`

## 强烈建议（降低最高风险项）

- [ ] **产品文案全面去"匿名/随机/陌生人"化**：App Store 描述、截图、审核备注一律强调 closed / invite-only / private group / known contacts
- [ ] **砍掉任何陌生人发现、随机匹配、公开房间广场功能**——这是与 Vibely 的关键区别，必须可证明
- [ ] 审核备注中主动与 1.1.6 "anonymous phone calls" 切割，说明这是熟人私密群组而非匿名通话工具
- [ ] **只支持 `wss://`**，拒绝明文 `ws://`
- [ ] 服务端 + CDN 关闭 IP access log（或确保不落盘），保留一份书面数据流说明备查
- [ ] **不勾选中国大陆区**（绕开 ICP 备案；服务器在境外时备案实际不可行）
- [ ] 做足原生功能，避免被误判为 4.2.2 内容聚合器

## 考虑

- [ ] 提审前预约 **App Review Appointment**（30 分钟 Webex），就"邀请码私密语音房是否属 random/anonymous chat"当面确认——鉴于这是最高风险项且条文无法自证，这可能是最有价值的一步
- [ ] 咨询出口管制律师：Annual Self-Classification Report + 法国 ANSSI
- [ ] 若在法国上架：准备法国加密声明

---

*报告生成于本次调研会话。所有 Apple 原文均于当天抓取。*
