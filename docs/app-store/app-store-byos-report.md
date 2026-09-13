# iOS「用户自填服务器地址」是否违反 App Store 规则 — 调查报告

## 一、明确结论

**不违反。** 允许用户输入任意服务器地址（含 `wss://`）并连接，本身**不构成**任何现行 App Store Review Guideline 的违规。

三点依据：

1. **无对应条文**。通读现行指南全文（2026-09 抓取），不存在任何要求"服务器端点必须硬编码/白名单"的条款。2.5.2 管的是**下载执行代码**，4.7 管的是**app 内分发第三方软件**，都不是"连接到哪个服务器"。
2. **大量先例在架**。下表 30 款 BYOS app 全部经直接 HTTP 请求确认 App Store 页面返回 200，其中多款在 Apple 自家商店描述里明写"connect to any instance"。**决定性证据：Element X 的上架文案直接向用户推销任意服务器选择**——"Choose where to host your data - from any public server ... to creating your own personal server and hosting it on your own domain." Apple 不仅批准了这个功能，还批准了以此为**卖点**的营销文案。
3. **真正咬人的是"可审查性"，不是"自定义服务器"**。约 20 轮定向检索未找到任何以自定义服务器为明示拒绝理由的案例；找到的全部真实被拒案例，引用的都是 **2.1**（审核员连不上后端）、**4.2.2**（最小功能）、**2.5.2**（下载可执行代码）、**4.3**（马甲包）。Pi-hole 客户端案最具代表性：Apple 要的是**能让审核员测试的入口**，从未质疑"让用户指向自己服务器"这一功能本身。

**额外佐证：Apple 在 ATS 文档中把"连接到必须用公共主机名访问的设备"明列为正当例外理由**——即 Apple 在官方文档层面已预设并接纳该 app 形态（详见第八节）。

---

## 二、Guideline 2.5.2 原文 (verbatim)

来源：<https://developer.apple.com/app-store/review/guidelines/>

> **2.5.2** Apps should be self-contained in their bundles, and may not read or write data outside the designated container area, nor may they download, install, or execute code which introduces or changes features or functionality of the app, including other apps. Educational apps designed to teach, develop, or allow students to test executable code may, in limited circumstances, download code provided that such code is not used for other purposes. Such apps must make the source code provided by the app completely viewable and editable by the user.

---

## 三、Guideline 4.7 原文 (verbatim)

来源：同上

> **4.7 Mini apps, mini games, streaming games, chatbots, plug-ins, and game emulators**
>
> Apps may offer certain software that is not embedded in the binary, specifically HTML5 and JavaScript mini apps and mini games, streaming games, chatbots, and plug-ins. Additionally, retro game console and PC emulator apps can offer to download games. You are responsible for all such software offered in your app, including ensuring that such software complies with these Guidelines and all applicable laws. Software that does not comply with one or more guidelines will lead to the rejection of your app. You must also ensure that the software adheres to the additional rules that follow in 4.7.1 through 4.7.5. These additional rules are important to preserve the experience that App Store customers expect, and to help ensure user safety.
>
> **4.7.1** Software offered in apps under this rule must:
> - follow all privacy guidelines, including but not limited to the rules set forth in Guideline 5.1 concerning collection, use, and sharing of data, and sensitive data (such as health and personal data from kids);
> - include a method for filtering objectionable material, a mechanism to report content and timely responses to concerns, and the ability to block abusive users; and
> - follow Guideline 3.1 in order to offer digital goods or services to end users.
>
> **4.7.2** Your app may not extend or expose native platform APIs or technologies to the software without prior permission from Apple.
>
> **4.7.3** Your app may not share data or privacy permissions to any individual software offered in your app without explicit user consent in each instance.
>
> **4.7.4** You must provide an index of software and metadata available in your app. It must include universal links that lead to all of the software offered in your app.
>
> **4.7.5** Your app must provide a way for users to identify software that exceeds the app's age rating, and use an age restriction mechanism based on verified or declared age to limit access by underage users.

---

## 四、4.7 是否适用于"连接用户选定的服务器"？

**不适用。** 精确理由：

- 4.7 的规制对象是 **"software ... offered in your app"**——app 作为**分发渠道**提供可执行的第三方软件单元。开篇限定语 "specifically HTML5 and JavaScript mini apps and mini games, streaming games, chatbots, and plug-ins" 是**穷举式**的软件品类清单，不是"任何远程内容"。
- **4.7.4 是决定性反证**：要求 "provide an index of software ... include universal links that lead to all of the software offered in your app"。一个连接用户自填服务器的客户端**在结构上无法**满足此条——因为根本不存在"可索引的软件目录"。这说明立法者设想的场景是小程序商店，而非协议客户端。
- 关于 **"chatbots"** 这个词（最容易被误读的点）：它指 app 内**上架的一个个 bot 条目**（如 bot 商店/目录），而非"app 连到某个聊天服务器"。判别标准是：**你是否在 app 内提供一个可浏览、可选择的第三方软件目录？** 若 app 只是一个说固定协议、把数据渲染出来的客户端，用户自己指定连哪台机器，则不落入 4.7。
- 4.7.2（不得向该软件暴露原生 API）同样预设了"宿主 app 承载受限执行环境"的架构，与普通网络客户端无关。

**2.5.2 是否咬人？** 分界线在 **data vs. code**：
- ✅ 安全：服务器返回的**数据**（JSON、消息、媒体、时间线）——无论来自哪台服务器。
- ⚠️ 风险：服务器下发**改变 app 功能**的东西——可解释脚本、动态 UI 描述驱动出审核时不存在的新功能、远程开关点亮休眠特性。判定不看"是否自定义服务器"，而看"审核看到的 app 与用户拿到的 app 是否是同一个"。

---

## 五、真正会咬 BYOS app 的条款（按风险排序）

| 排序 | 条款 | 为什么咬 |
|---|---|---|
| 1 | **1.2 UGC** | 若服务器内容是用户生成/社交，必须有过滤、举报、拉黑、公开联系方式四件套。这是 Mastodon/Matrix 类客户端的真实门槛。原文并有一句针对性豁免：*"If your app includes user-generated content from a web-based service, it may display incidental mature 'NSFW' content, provided that the content is hidden by default and only displayed when the user turns it on via your website."* |
| 2 | **2.1 App Completeness** | 审核时后端必须可达。Apple 明文要求 *"Enable backend services so that they're live and accessible during review"*。BYOS app 必须提供可用的演示服务器。 |
| 3 | **4.2 / 4.2.2 最小功能** | *"Other than catalogs, apps shouldn't primarily be marketing materials, advertisements, web clippings, content aggregators, or a collection of links."* ← **Ice Cubes 实际被拒引用的正是此条**。 |
| 4 | **5.1.1 隐私** | 隐私政策须说明数据流向；用户自填服务器意味着数据去向不由你控制，需如实披露。 |
| 5 | **2.5.2** | 仅当你真的下发代码/动态功能时。 |
| 6 | **4.2.7 远程桌面** | 仅当 app 是"镜像特定软件"的远程桌面时才触发（要求同一 LAN、host 为用户自有设备）。普通协议客户端不适用。 |

**1.1.6（虚假信息/恶作剧功能）**：与本议题无关，不构成风险点。

---

## 六、案例表（全部经直接 HTTP 请求确认返回 200）

所有 URL 均经 `Invoke-WebRequest` 直接请求确认返回 HTTP 200。标 ★ 的证据为**从 Apple 商店页面 JSON 的 description 字段逐字提取**（即 Apple 自己审核并批准的文案）。

| App | App Store URL | 允许任意服务器? | 证据 |
|---|---|---|---|
| **Element X - Secure Chat & Call** | [id1631335820](https://apps.apple.com/us/app/element-x-secure-chat-call/id1631335820) | **YES** | ★"Choose where to host your data - from any public server (the largest free server is matrix.org, but there are plenty of others to choose from) to creating your own personal server and hosting it on your own domain. This ability to choose a server is a large part of what differentiates us from other real time communication apps." |
| Mastodon 官方 | [id1571998974](https://apps.apple.com/us/app/mastodon/id1571998974) | **YES** | ★"You can sign up on our official server, or choose a 3rd party to host your data and moderate your experience." / "For advanced users, you can even host your data on your own infrastructure, since Mastodon is open-source." |
| Ice Cubes for Mastodon | [id6444915884](https://apps.apple.com/us/app/ice-cubes-for-mastodon/id6444915884) | **YES** | ★"You can connect to any Mastodon instance and use the various features this app offers." |
| Ivory (Tapbots) | [id6444602274](https://apps.apple.com/us/app/ivory-for-mastodon-by-tapbots/id6444602274) | **YES** | "You log into your Mastodon account directly through your instance server and they pass Ivory a token" — <https://tapbots.com/support/ivory/general/security> |
| Mona Classic（原名 Mona for Mastodon） | [id1659154653](https://apps.apple.com/us/app/mona-classic/id1659154653) | YES（间接） | ★"Your network connections to Mastodon servers are protected by HTTPS" |
| Mona 7 for Mastodon（当前主力版） | [id6755672518](https://apps.apple.com/us/app/mona-7-for-mastodon/id6755672518) | YES（间接） | ★同上措辞 |
| Element Classic（旧版 Element/Riot） | [id1083446067](https://apps.apple.com/us/app/element-classic/id1083446067) | **不确定** | 在架确认；未取得任何证实/证伪自填 homeserver 的文本 |
| FluffyChat (Matrix) | [id1551469600](https://apps.apple.com/us/app/fluffychat/id1551469600) | YES（间接） | "only want to change the default homeserver, then only modify the `defaultHomeserver` key" — [README](https://raw.githubusercontent.com/krille-chan/fluffychat/main/README.md) |
| Nextcloud | [id1125420102](https://apps.apple.com/us/app/nextcloud/id1125420102) | **YES** | ★"Host it yourself or with a company you trust" |
| ownCloud - File Sync and Share | [id1359583808](https://apps.apple.com/us/app/owncloud/id1359583808) | **YES** | ★"Your files. Your server. Your ownCloud." / "Connect to your ownCloud Infinite Scale (oCIS) or ownCloud Classic server… Open source, self-hosted, no third-party cloud required." |
| Swiftfin (Jellyfin) | [id1604098728](https://apps.apple.com/us/app/swiftfin/id1604098728) | **YES** | ★"To use the app, you must have a Jellyfin server set up and running." |
| Jellyfin Mobile（**确认在架**） | [id1480192618](https://apps.apple.com/us/app/jellyfin-mobile/id1480192618) | **YES** | ★"To use the app, you must have a Jellyfin server set up and running." |
| Home Assistant | [id1099568401](https://apps.apple.com/us/app/home-assistant/id1099568401) | **YES** | "Tap **Enter address manually** / Enter your Home Assistant URL" — [companion docs](https://companion.home-assistant.io/docs/getting_started/) |
| Infuse | [id1136220934](https://apps.apple.com/us/app/infuse/id1136220934) | **YES** | ★"Connect with Plex, Emby, Jellyfin, Kodi (XBMC), WMC and other media servers"；"Jellyfin requires a direct server login" — [Firecore](https://support.firecore.com/hc/en-us/articles/360006462093-Streaming-from-Plex-Emby-and-Jellyfin) |
| Plex: Find Movies and TV Shows | [id383457673](https://apps.apple.com/us/app/plex-find-movies-and-tv-shows/id383457673) | PARTIAL | ★"Streaming personal media requires Plex Media Server version 1.18.3 and higher installed and running"；服务器经 plex.tv 账号中介发现，非首启自由填 URL |
| Tailscale | [id1470499037](https://apps.apple.com/us/app/tailscale/id1470499037) | PARTIAL（支持自定义 control server） | "select `Use custom coordination server`. Enter your instance url" — [headscale docs](https://raw.githubusercontent.com/juanfont/headscale/main/docs/usage/connect/apple.md) |
| WireGuard | [id1441195209](https://apps.apple.com/us/app/wireguard/id1441195209) | **YES** | ★"you can create one from scratch… Please visit wireguard.com for a summary of the WireGuard protocol and how to set up your own WireGuard server for use with this app." |
| Prologue Audiobook Player | [id1459223267](https://apps.apple.com/us/app/prologue-audiobook-player/id1459223267) | **YES** | ★"The self-hosted audiobook player for Plex and Audiobookshelf." |
| Flux Feed for Miniflux（专用客户端） | [id6752505148](https://apps.apple.com/us/app/flux-feed-for-miniflux/id6752505148) | **YES** | ★"This app allows you to connect to your own Miniflux instance… requires a self hosted Miniflux instance to work" |
| Flux-News（专用客户端） | [id6761262233](https://apps.apple.com/us/app/flux-news/id6761262233) | **YES** | ★"Your data belongs to you. Flux News acts as a transparent window to your own server." / "Your credentials and content never pass through any external servers other than your own." |
| Fiery Feeds: News Reader | [id1158763303](https://apps.apple.com/us/app/fiery-feeds-news-reader/id1158763303) | PARTIAL | 支持列表含 Fever / Tiny Tiny RSS / FreshRSS / Nextcloud News，未点名 Miniflux（经其 Fever 兼容层连接） |
| Reeder Classic (iOS, $4.99) | [id1529445840](https://apps.apple.com/us/app/reeder-classic/id1529445840) | PARTIAL | Miniflux 官方客户端列表收录："Reeder Classic (iOS/macOS / Paid / Proprietary)" — <https://miniflux.app/docs/apps.html> |
| Reeder.（新版） | [id6475002485](https://apps.apple.com/us/app/reeder/id6475002485) | **NO** | ★仅 iCloud 同步，无自托管后端——**反例，说明本表并非无差别收录** |
| DS file (Synology) | [id416751772](https://apps.apple.com/us/app/ds-file/id416751772) | **YES** | "Address or QuickConnect ID: This can be either an internal or external IP address, DDNS hostname, or Synology QuickConnect ID" — Synology DSM 7.2 User's Guide（*检索索引文本，页面为 JS 渲染未能直取*） |
| DS video (Synology) | [id540949418](https://apps.apple.com/us/app/ds-video/id540949418) | **YES** | 同上地址栏 |
| Synology Drive | [id1267275421](https://apps.apple.com/us/app/synology-drive/id1267275421) | **YES** | 同上地址栏 |
| Synology Photos | [id1484764501](https://apps.apple.com/us/app/synology-photos/id1484764501) | **YES** | 同上地址栏 |
| Termius - Modern SSH Client | [id549039908](https://apps.apple.com/us/app/termius-modern-ssh-client/id549039908) | **YES**（SSH 主机全自填） | ★"no re-entering IP addresses, ports, and passwords"；"Connect through Proxy and jump servers" |
| Prompt 3 (Panic) | [id1594420480](https://apps.apple.com/us/app/prompt-3/id1594420480) | **YES**（SSH 主机全自填） | ★"SSH, Telnet, and Local (for Mac) Rock-solid and reliable connectivity to your hosts." |

> **最强论据一：Element X 的上架文案本身。** Apple 审核并批准了一段**以"连接任意服务器"为核心卖点**的商店描述——"Choose where to host your data - from any public server ... to creating your own personal server and hosting it on your own domain. **This ability to choose a server is a large part of what differentiates us**"。若该能力违规，Apple 不会放行以此为主打宣传语的 listing。
>
> **最强论据二：SSH 客户端（Termius、Prompt 3）。** 它们让用户连接完全任意主机**并执行远程命令**，长期在架。若"任意服务器"本身违规，这类 app 不可能存在。

---

## 七、公开被拒案例

经约 20 轮定向检索：**未找到**任何以"自定义服务器 URL / 任意服务器 / 自托管后端"为**明示拒绝理由**的公开案例。检索词含 "app rejected custom server url"、"self-hosted server rejection"、"guideline 4.7 rejection self hosted"、"app rejected because user can enter any server"、5.1.1 / 1.2 + 自托管、Mastodon/Matrix/SSH 客户端被拒等，**全部 未找到**。这一**空结果本身即是核心证据**。

但检索揭示了一个**真实且反复出现的摩擦点，且它不是"功能违规"而是"可审查性"**——即 **2.1**：审核员无法测试一个后端必须由用户自备的 app。

**案例 1｜Pi-hole 客户端（自托管 DNS）— 与本议题最贴近的真实案例**
<https://developer.apple.com/forums/thread/815919>（2026-02）
开发者原文：
> "my app was rejected under App Store Review Guideline 2.1 with a request to provide access information so the app, domain, and live query features can be reviewed."
> "The app connects exclusively to a locally hosted Pi-hole (dns) instance via its API... There is no external backend, no public API endpoint, and no default domain or credentials that can be provided."

引用条款 **2.1**。**关键定性：Apple 反对的不是"让用户指向自己的服务器"这个功能，而是"审核员没东西可连"。** 自托管架构间接造成问题，但从未被指为违规。**CONFIRMED-QUOTED。**

**案例 2｜动态 DNS 后端审核员连不上** — <https://developer.apple.com/forums/thread/726643>（2023-03）
开发者："The reviewers got error message of Error: cannot connect to server." / "I've been rejected over 10 times."
Apple DTS (Quinn)："on Apple's internal network I'm not... I suspect that this is because you're using dynamic DNS."，建议："HTTPS / Over port 443 / To a fixed DNS name / With a server whose TLS certificate is system-trusted."
真实原因：**DNS 可达性**，非政策。**CONFIRMED-QUOTED。**

**案例 3｜域名在 Apple 内网被改道** — <https://developer.apple.com/forums/thread/773444>（2025-01）
Apple DTS (Kevin Elliott)："Our network does block ports... Whenever possible, use the standard port numbers designated for that particular protocol. If you're using a standard but 'uncommon' port, then it can be helpful to include that port number in the review notes."
真实原因：**Apple 侧网络配置**。**CONFIRMED-QUOTED。**

**案例 4｜iSH（Alpine Linux shell）— 2.5.2 的真实边界，但不是自定义服务器案**
<https://ish.app/blog/app-store-removal> / <https://saagarjha.com/blog/2020/11/08/fixing-section-2-5-2/>（2020-11）
Apple 表述：app "is not self-contained and has remote package updating functionality"；要求移除 "wget or curl, or other remote network commands"；模板拒信："During review, your app installed or launched executable code, which is not permitted on the App Store."
引用 **2.5.2**。**定性：反对的是下载可执行代码，明确不是自定义服务器 URL。** 值得注意的警示：Apple 建议的修法是"移除远程网络功能"——即网络能力被当作代码执行问题的**附带物**。Apple 后经申诉当日撤销。**CONFIRMED-QUOTED。**

**案例 5｜Ice Cubes（Mastodon 客户端，2023-01）** — 六天内被拒七次。引用 **4.2.2 Minimum Functionality**，非 4.7、非 2.5.2。
> "We noticed that your app only includes links, images, or content aggregated from the Internet with limited or no native iOS functionality. Although this content may be curated from the web specifically for your users, since it does not sufficiently differ from a mobile web browsing experience, it is not appropriate for the App Store."

来源：<https://daringfireball.net/2023/01/ice_cubes_app_store_limbo>（Gruber，2023-01-19）；<https://www.igen.fr/app-store/2023/01/ice-cubes-le-nouveau-client-mastodon-quapple-eu-bien-du-mal-valider-135045>
**CONFIRMED-QUOTED。** 争点是"是否足够原生"，与"连哪台服务器"无关；Gruber 发文约两小时后获批。

**案例 6｜电台/网络电视流媒体 app（用户可配置流 URL）** — <https://developer.apple.com/forums/thread/85536>（2017-08）
Apple："It is no longer appropriate to submit multiple apps that provide the same or similar feature set."
引用 **4.3 / 4.2.6**，真实原因是**马甲包/模板 app**，非自定义服务器。**CONFIRMED-QUOTED。**

> **关键旁证：** Apple DTS 在 2024-08 回复一位 **app 允许用户自行添加流媒体链接**的 IPTV 开发者时（<https://developer.apple.com/forums/thread/762911>），全程**无人质疑"用户自填任意 URL"这一功能**，讨论只围绕 ATS key。这是 Apple 官方人员面对该功能形态时的态度实证。

---

## 八、NSAppTransportSecurity / NSAllowsArbitraryLoads

**必须区分两件被长期混淆的事：2017 年的最后期限已取消，但 justification 要求从未撤销。**

**(1) 期限已取消、且从未重设** — Apple 2016-12-21 公告：
> "At WWDC 2016 we announced that apps submitted to the App Store will be required to support ATS at the end of the year. To give you additional time to prepare, this deadline has been extended and we will provide another update when a new deadline is confirmed."

<https://developer.apple.com/news/?id=12212016b>（页面仍在线，此后从未有新期限公告）

**(2) justification 要求仍在现行文档中**（verbatim）：
> "You must supply a justification during App Store review if you set the key's value to [YES]... Use this key with caution because it significantly reduces the security of your app. In most cases, it's better to upgrade your servers to meet the requirements imposed by ATS, or at least to use a narrower exception."

<https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads>

> "Adding certain ATS exceptions to your app's [Info.plist] file requires you to provide justification, and **might** trigger additional App Store review for your app."

<https://developer.apple.com/documentation/security/preventing-insecure-network-connections>（注意 "might"，非 "will"）

**(3) ★ Apple 自己列举的可接受理由中，直接涵盖"用户自填主机"场景**（verbatim，经独立核实）：
> "Examples of justifications eligible for consideration are: The app must connect to a server managed by another entity that doesn't support secure connections. **The app must support connecting to devices that cannot be upgraded to use secure connections, and that must be accessed using public host names.** The app must display embedded web content from a variety of sources, but can't use a class supported by the web content exception. The app loads media content that is encrypted and that contains no personalized information."

这是**本报告最有力的单条官方表态之一**：Apple 把"连接到必须用公共主机名访问的设备"明列为**正当的 ATS 例外理由**——即 Apple 在文档层面预设并接纳了用户自填主机的 app 形态。

**(4) 实际上不存在正式申报流程** — Apple DTS (Quinn) 2024-08：
> "AFAIK the only official guidance on this is the Provide Justification for Exceptions section of Preventing Insecure Network Connections."

<https://developer.apple.com/forums/thread/762911>

**实践含义：摩擦点，不是禁令。** 若只用 `wss://`(TLS)，**根本不需要**此 key —— ATS 默认已允许。仅当支持明文 `ws://` 或自签证书时才需例外，此时应优先用更窄的 `NSExceptionDomains` / `NSAllowsLocalNetworking` 而非全局 `NSAllowsArbitraryLoads`，并在 Review Notes 写一段事实性说明。**"用户可填任意主机名"本身不需要任何 ATS 例外**——ATS 按实际连接的协议与 TLS 质量判定，与主机名是否硬编码无关。

**需排除的不可靠信源：** 网传"justification 已无限期暂停"的说法（<https://developer.apple.com/forums/thread/103592>）是论坛用户措辞，**非 Apple 原话**，属 ANECDOTAL 夸大。另有厂商博客给出所谓"ATS 自动拒信模板"，其自身标注为 "common patterns include"，无一手来源佐证，属 **SPECULATION，不应引用**。

---

## 九、不确定清单（unverified）

1. **Element Classic (id1083446067)**：在架已确认，但**未取得任何证实或证伪**其自填 homeserver 的文本 → 标 **UNVERIFIED，而非 NO**。（注：现役主力 Element X 已有 Apple 页面逐字证据，此项不影响结论。）
2. **Plex = PARTIAL**：属判读。商店文案显示服务器经 plex.tv 账号中介发现，但**未找到厂商文档证实或否认** iOS 端可自由填写服务器 URL。
3. **Tailscale = PARTIAL**：自定义 control server 证据来自 headscale 社区文档而非 Tailscale 官方 iOS 文档。
4. **Fiery Feeds / Reeder Classic 的 Miniflux 支持**：均为间接证据（Fiery Feeds 支持列表未点名 Miniflux，推测经 Fever 兼容层；Reeder Classic 仅见于 Miniflux 官方客户端列表）。
5. **Synology "Address or QuickConnect ID" 引文**：来自 DSM 7.2 User's Guide 的**检索索引文本**；kb.synology.com 为 JS 渲染，直接抓取仅得空壳，**未能逐字复核页面**。
6. **各 app 的开发者/发行商名称**：商店页面在 Information 区块前被截断，**未逐一核实**（app 名称与价格已确认）。
7. **Reddit / Hacker News 检索为空**：既可能是真实不存在，也可能是**工具限制**（Reddit 基本不可抓取）。不应把此处的"未找到"完全等同于"不存在"。
8. **审核员自由裁量空间**：以上分析基于指南**文本**。Ice Cubes 案证明条文正确 ≠ 不会被误拒。这一层风险**无法从文本推定**。
9. **4.7 中 "chatbots" 的官方解释边界**：Apple 未发布进一步释义文档。本报告解读基于 4.7.4"软件索引 + universal links"要求所作的**结构性推断，非 Apple 明示表态**。
10. **Apple 未公开**审核员是否代理/抓取 app 流量，故"自定义服务器会否引发额外隐性审查"无法确证。

---

## 十、实操建议

若你的 app 让用户填 `wss://` 地址：

1. **不要**因为"自定义服务器"而担心 4.7 或 2.5.2 —— 只要不下发可执行代码。
2. **最高优先级：解决 2.1 可审查性。** 这是全部真实案例的共同死因。必须在 App Review Notes 提供**一台你自己运行、审核期间保证在线的演示服务器 + 演示账号**，或内置 demo 模式。**绝不能**像 Pi-hole 案那样答复"本 app 无公共端点、无法提供凭据"——那正是被拒的原因。
3. **演示服务器须对 Apple 内网友好**（案例 2、3 的教训）：固定 DNS 名（**勿用动态 DNS**）、443 端口、系统信任的 TLS 证书；若用非标准端口，在 Review Notes 里写明。
4. **若服务器内容含 UGC/社交**，补齐 1.2 四件套：过滤、举报、拉黑、公开联系方式。
5. **做足原生功能**，避免被误判为 4.2.2 内容聚合器（Ice Cubes 的教训）。
6. **只用 TLS (`wss://`)** 即可完全绕开 ATS 例外与其 justification 要求；万一需要明文，用窄例外 + 引用 Apple 自己的 "accessed using public host names" 理由模板。
7. **切勿**为"方便连任意服务器"而内置 `wget`/`curl` 式的**通用远程获取并执行**能力——iSH 案表明这会把 2.5.2 真正引爆。
8. **隐私政策**如实说明：数据发往用户自行指定的服务器，开发者不控制该端点。
