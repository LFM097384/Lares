# Lares 炉灵 —— 界面设计调研与可执行规范

> 写于 2026-09-14。纯调研文档，不含代码改动。
>
> **阅读约定 —— 全文严格三分：**
> - **【实证】** 已抓到来源原文，附 URL。官方文档 / 开源源码 > 第三方拆解 > 社区。
> - **【实测】** 我在本机对本仓库代码、Flutter SDK 源码、色彩数学的直接验证，可复现。
> - **【判断】** 我的设计决定，非来源陈述。**照抄前请先质疑。**
> - **【未找到可靠来源】** 查不到就这么写。本文不编造任何 hex、像素、动画时长。
>
> 调研中**证伪了三条流传很广的说法**（Clubhouse 脉冲环、Clubhouse 按钮在右上、X Spaces 房内紫色脉冲环），见 §1.2。这类"人人都在说但没人给得出出处"的细节，是设计规范里最危险的东西。

---

## 0. 摘要：这次调研改变了什么

调研前的问题清单假定这是一次**审美问题**。调研后我的结论是：**七条硬伤里有四条是工程缺陷，两条是 token 缺口，只有一条是真正的审美问题。**

| # | 现象 | 实际性质 | 根因（我实测定位） |
|---|---|---|---|
| 1 | RIGHT OVERFLOWED BY 2014 PIXELS | **布局 bug** | 无约束 `Row` 子 `Text` 承接了未截断的异常字符串 |
| 2 | 原始异常甩给用户 | **工程缺陷** | `errorMessage = '进房失败:$e'` 直接插值 |
| 3 | 挂断键浅蓝 | **token 缺口** | `ColorScheme` 未定义 `secondaryContainer` → 回退到 `secondary` = presence 蓝 |
| 4 | 底部切换器亮色描边 | **token 缺口** | 同上，`SegmentedButton` 选中态也吃 `secondaryContainer` |
| 5 | 状态切换器"出现两次" | **信息架构错误** | 代码只有一个；是三处状态文本在视觉上打架 |
| 6 | 背景浑浊棕色 | **审美问题** | 品牌橙 5% 叠在紫黑底上 → 合成脏棕，见 §3.2 实测 |
| 7 | 下方三分之二全空 | **布局策略缺失** | `GridView` 固定 140px 格子，无人数自适应 |

**第 3、4 条是同一个 bug**，改 theme.dart 一处即可，无需触碰任何页面。**这大概是本次调研投入产出比最高的一条发现。**

**关于第 5 条需要先说清楚**：状态切换器在**当前代码中只有一个**（我核对了代码与 git 历史）。用户的感受是真的，但归因不同 —— 屏幕上有三处状态文本在互相打架。截图里那个"顶部半透明切换器"我无法从任何版本的代码解释，**建议先重新截图确认它是否还存在**。详见 §3.3 末节。

同时发现：仓库里**已经存在一个完成度很高的视觉原型** `app/tool/hearth/`（围炉布局 + 三档降帧时钟 + 火星粒子），带 7 张截图与 302 行 SPEC。**我看过截图，2/5/20 人的排布都成立。** 本文的房间页方案 A 直接建立在它之上，而不是从零另起一套 —— 见 §3.3。

---

## 1. 第一步：真实产品的语音房间界面

### 1.1 Telegram 群组语音聊天 —— 本次调研中唯一可以逐行读源码的产品

Telegram Android 客户端完全开源，因此这一节的数值不是"据报道"，而是**源码常量**。这是全文可信度最高的一段。

**成员排布：单列纵向列表，不是网格。**【实证】[`GroupCallUserCell.java`](https://github.com/DrKLO/Telegram/blob/master/TMessagesProj/src/main/java/org/telegram/ui/Cells/GroupCallUserCell.java)
- 头像 **46×46 dp**，`setRoundRadius(dp(24))`
- 行高硬编码 **58 dp**（`makeMeasureSpec(dp(58), EXACTLY)`）
- 名字 16sp 加粗，状态文字 15sp；分隔线左缩进 68 dp
- 状态文字是 **5 个 SimpleTextView 叠放**（listening / speaking / muted-for-me / wants-to-speak / bio），靠 alpha 交叉淡入切换，**180 ms**

**2/5/12/20 人时列数不变、纵向滚动延伸，不缩头像、不折叠 +N。**【实证】只有开视频后才变网格（[`GroupCallGridCell.java`](https://github.com/DrKLO/Telegram/blob/master/TMessagesProj/src/main/java/org/telegram/ui/Components/voip/GroupCallGridCell.java)：竖屏 `spanCount=2f`，横屏 `3f`，`CELL_HEIGHT=165`）。频道语音聊天已取消人数上限，支持"millions of live listeners"【实证】[Voice Chats 2.0](https://telegram.org/blog/voice-chats-on-steroids)。

**"谁在说话"：双层 blob 变形 + 头像本体缩放。**【实证】[`BlobDrawable.java`](https://github.com/DrKLO/Telegram/blob/master/TMessagesProj/src/main/java/org/telegram/ui/Components/BlobDrawable.java)

这是**全文最值得抄的一组数字**，因为它们全部来自生产环境源码：

| 参数 | 值 | 出处 |
|---|---|---|
| blob 层数与控制点 | `BlobDrawable(6)` + `BlobDrawable(8)` | GroupCallUserCell |
| blob 半径 | min 26 dp / max 29 dp（头像 46 dp，仅略外溢） | `AvatarWavesDrawable(dp(26), dp(29))` |
| blob 缩放 | `scaleBlob = 0.8 + 0.4 × amplitude` | BlobDrawable |
| **头像本体缩放** | `0.9 + 0.2 × amplitude`（静音 1.0，最大 1.1） | `getAvatarScale()` |
| blob 填充 alpha | **0.15** | `WaveDrawable.CIRCLE_ALPHA_2` |
| 说话触发阈值 | `value > 1.5f` | `setAmplitude()` |
| **静默回落** | **500 ms** 后 `isSpeaking=false, amplitude=0` | `runOnUIThread(updateRunnable, 500)` |
| 音量归一化 | `amplitude = value / 80f`，clamp 0–1 | 同上 |
| 波纹进出场 | `16/350f` → **约 350 ms** | 同上 |
| 静音配色过渡 | `16/150f` → **约 150 ms** | 同上 |
| 贝塞尔系数 | `L = (4/3)·tan(π/2N)` | BlobDrawable |

**驱动信号是单一标量 amplitude（RMS 类），不是频谱。**【实证】这一条直接决定了 Lares 的实现难度 —— 见 §4.2。

**官方配色**【实证】[`ThemeColors.java`](https://github.com/DrKLO/Telegram/blob/master/TMessagesProj/src/main/java/org/telegram/ui/ActionBar/ThemeColors.java)：说话绿 `0xff77EE7D`、聆听蓝 `0xff4DB8FF`、静音灰 `0xff6F7980`、被管理员静音红 `0xffFF7070`、离开按钮 `0x7dF75C5C`、列表背景 `0xff1C2229`、顶栏 `0xff0F1317`。blob 会在这些色之间 `blendARGB` 插值。

**静默态不降透明度。**【实证】源码只改 scale 与 blob 显隐。空场由**中央超大圆形麦克风按钮**及其自身波纹占据视觉重心。

**⚠️ 最该抄的一条：官方自带省电开关。**【实证】`BlobDrawable.update()` 与 `draw()` 开头即 `if (!LiteMode.isEnabled(liteFlag)) return;`（默认 `FLAG_CALLS_ANIMATIONS`）。**Telegram 自己就认为这个动画在省电模式下应该整块不跑。**

### 1.2 Clubhouse —— 三条流传甚广的说法被证伪

**房间结构：官方只说两段，实际三段。**【实证】官方措辞是「A Clubhouse Room has two sections: a **Stage** of speakers and an **Audience** of listeners」（[Apple App Store 编辑部指南](https://apps.apple.com/us/story/id1572679604)）。但听众区实际再分两层，英文原标签为 **The Stage** / **Followed by the speakers** / **Others in the Room**（[CharityComms](https://www.charitycomms.org.uk/how-charities-could-use-clubhouse)、[INMA](https://www.inma.org/blogs/product-initiative/post.cfm/what-is-clubhouse-and-why-should-media-companies-care) 独立佐证；中文侧[中時新聞網](https://www.chinatimes.com/realtimenews/20210225000909-260410?chdtv)）。

> ❌ **证伪 1：「发言者头像明显更大」——【未找到可靠来源】，且有反向证据。** 2021 年 UX 拆解明确批评「正在说话的人、主持人、台上的人**看起来都一样**」（[UX Planet](https://uxplanet.org/clubhouse-is-just-amazing-but-their-ux-some-work-3d0fbc813f7d)）。
>
> ❌ **证伪 2：「脉冲扩张环」——【未找到可靠来源】。** 可靠来源的措辞**只有静态细环**两种：「a **thin grey circle**」（[Espirian](https://espirian.co.uk/clubhouse/)）、「a **subtle ring**」（[INMA](https://www.inma.org/blogs/product-initiative/post.cfm/what-is-clubhouse-and-why-should-media-companies-care)）。没有任何来源用"脉冲/扩散/缩放"描述它。且 UX Planet 评价该指示「**几乎看不见**」。
>
> ❌ **证伪 3：「Leave quietly 在右上角」—— 错，在左下角。** 两个独立语种来源一致：「a leave quietly button in the **bottom left**」（[INMA](https://www.inma.org/blogs/product-initiative/post.cfm/what-is-clubhouse-and-why-should-media-companies-care)）、「**unten links** einen Button」（[SZ jetzt](https://www.sueddeutsche.de/jetzt/meine-theorie/das-beste-an-clubhouse-ist-der-leave-quietly-button-jzt.ckk715bla01i00lvu887fzoss)）。**该按钮的胶囊造型、配色、✌️ emoji 均【未找到可靠来源】，不要写进 spec。**

**官方原文可确认的两个徽章**【实证】（Clubhouse 官方 Notion 已下线，经 Wayback 取得）：
- 主持人 = **green star**，在名字**左侧**（[New User Guide 存档](https://web.archive.org/web/20211029172722/https://www.notion.so/New-User-Guide-ae9236f3fe29416ea45274529d987855)）
- 新人 = party hat 贴纸叠在**头像上**，持续 **7 天**（同上）

**「Leave quietly」为什么值得学 —— 这是本节对 Lares 最重要的一条。**【实证】[SZ jetzt](https://www.sueddeutsche.de/jetzt/meine-theorie/das-beste-an-clubhouse-ist-der-leave-quietly-button-jzt.ckk715bla01i00lvu887fzoss) 的论点：现实退场有两难 —— 打断谈话引人注目、或偷溜显得失礼。该按钮消解了两难。最精辟的是关于**在场感**的一句：Clubhouse 本可在右上角放个「X」了事，但偏偏做成这样一个按钮，因为**它先让你意识到自己确实"在场"** —— 原文「Er macht uns die eigene Anwesenheit im digitalen Raum überhaupt erst bewusst」。

**沉默听众没有反馈通道，于是用户自己发明了信令。**【实证】**快速连点**麦克风＝鼓掌，**慢速连点**＝想接话（[Espirian](https://espirian.co.uk/clubhouse/)）；同行评审论文亦记载 speakers 反复开关静音标记来示意想发言（[Bajpai et al., arXiv 2107.09008](https://ar5iv.labs.arxiv.org/html/2107.09008)）。**这是本次调研最尖锐的一条教训**，见 §4.4。

### 1.3 X / Twitter Spaces

**人数**【实证】[help.x.com](https://help.x.com/en/using-x/spaces)：发言席上限 **13**（1 主持 + 10 speaker + 2 co-host）；听众**无上限**（[旧帮助页存档](https://web.archive.org/web/20211101173415/https://help.twitter.com/en/using-twitter/spaces)）。

**排布**：按 **Host / Speakers / Listeners** 三段标题分组的头像网格。**听众末位用溢出计数 "+26"**【实证】（官方 Spaces Social Narrative，已从现网移除，存于上述存档）。官方同时声明听众数「**may not match** the actual number of listeners」，因为存在匿名与登出收听。

**"剩余发言位"是真实存在的 UI**【实证】：VoiceOver 逐字稿还原出确切字符串「Speakers heading, **0 speakers · 10 open spots**」（[Living Blindfully](https://www.livingblindfully.com/malp120transcript/)）。

> ❌ **证伪 4：「X Spaces 房间内紫色脉冲环」——【未找到可靠来源】。** 官方文档中唯一被描述为 pulsing 的紫色轮廓是**时间线入口**，不是房间内发言态：「a profile photo with a **purple, pulsing outline** at the top of my timeline」。**房间内"正在说话"的环色、脉冲、缩放规格，X 从未公布。**

**emoji 反应是官方一等公民，且强调互见性**【实证】：「When someone says something I want to react to, I can choose an emoji… **I will be able to see when other people react as well.**」（官方 Social Narrative）。这正是与 Clubhouse 的关键差异 —— Clubhouse 靠"连点麦克风"模拟鼓掌，Spaces 原生给了通道。

**官方还发布了 Sensory Guide（感官强度表）**【实证】，把"以听众身份进入对话"标注为 Sound: Medium / Motion: 关字幕 Low、开字幕 Medium。**这是罕见的官方"氛围强度"文档**，对长时挂机产品很有参考价值。

**离开按钮文案是 "Leave"，在右上角**【实证】（官方 Social Narrative）；主持端为 "End"。**"Leave quietly" 在 X Spaces 不存在**，与 Clubhouse 混淆了。

### 1.4 Apple FaceTime / SharePlay

**32 人上限；溢出者降级为底部可横向滑动的小格带，不是分页。**【实证】[Apple 支持 111767](https://support.apple.com/en-us/111767)：「Tiles that can't fit on the screen appear in a **row at the bottom**. To find a participant you don't see, **swipe through the row**.」

**"说话者变大" = Automatic Prominence，且可关闭。**【实证】触发条件含**手语与手动点按**：「When a participant speaks (**verbally or by using sign language**) or **you tap the tile**, that tile becomes highlighted or more prominent.」macOS 设置项逐字为「Automatic prominence while speaking」（[FaceTime 设置 · Mac](https://support.apple.com/en-nz/guide/facetime/fctm8aeeba85/mac)）。该开关于 iOS 13.5 加入，因大型通话中自动放大体验不佳（[MacRumors](https://www.macrumors.com/how-to/disable-automatic-prominence-facetime/)）。

> **这一条对 Lares 影响很大**：Apple 把"谁在说"做成了**可关闭的辅助线索**，而不是硬状态。【判断】长时挂机场景下，"谁在说"更不该是唯一的层级来源。

**无视频参与者的回退链**【实证】：视频 → 联系人照片/Memoji → **姓名首字母**（「The participant's **initials** may appear in the tile if an image isn't available.」）。**这正是 Lares 目前在用的方案**，且是 Apple 唯一明文承诺的无视频表征 —— 可作最安全的设计基线。

**边框/描边样式**：Apple 只用 highlight / more prominent / larger 三个词，**未描述任何边框、色值或动画时长 —— 【未找到可靠来源】**。

### 1.5 Discord —— 数据质量最差的一个，但有一条硬发现

Discord 闭源，官方 [Brand Assets](https://discord.com/branding) **只公布 Blurple `#5865F2`**，且明文禁止仿制其观感。因此本节多处只能写【未找到可靠来源】。

**Stage Channel 信息架构**【实证】[官方 FAQ](https://support.discord.com/hc/en-us/articles/1500005513722-Stage-Channels-FAQ)：「Speakers are displayed at the top and the audience members are listed below」。容量：纯音频发言无上限、听众最高 **10,000**；开视频时最多 5 人开摄像头、1 路 Go Live。

**最该抄的一条社交设计**【实证】：「there are **no enter or leave sounds** in Stage channels」，并提供 **"Exit Quietly"** 按钮（左下角举手、右下角 Exit Quietly），官方理由是让用户"not feel like you're bothering people"。**与 Clubhouse 的 Leave quietly 殊途同归 —— 两个头部产品独立收敛到同一个设计。**

**说话指示器：2px 内环 + 3px 隔离环。**【实证·第三方】Discord 未公布，但第三方主题为覆盖原生规则而抄录了它（[BD-AnimatedSpeakingRings base.css](https://p0rtl6.github.io/BD-AnimatedSpeakingRings/src/base.css)）：

```css
box-shadow: inset 0 0 0 2px hsl(139, calc(var(--saturation-factor,1)*47.3%), 43.9%),
            inset 0 0 0 3px var(--background-secondary);
```

`hsl(139, 47.3%, 43.9%)` 换算即 **#3BA55D**（旧版；新版状态绿为 `#23a55a`）。注意是**内嵌**阴影 —— 环画在头像内部，不撑大布局。

> ⚠️ **易踩的坑**：同一份 CSS 里的 `animation: rotate-speaking 1s linear infinite` 是**主题作者新增的**，不是 Discord 原生。**别把它当官方行为引用。**

**【未找到可靠来源】**：Discord 宫格重排断点、"+N" 折叠规则、语音激活 dB 阈值与衰减、控制栏按钮顺序、断连红的 design token（`#ed4245` 出自 discord.js 库而非品牌页）。

### 1.6 Ambient / co-presence 类产品

**Zenly** —— 被广泛当作"陪伴感"标杆。**公司事实**【实证】：2017 年被 Snap 以 2.13 亿美元收购（[TechCrunch](https://techcrunch.com/2017/08/11/snap-sec-doc-confirms-acquisition-of-social-maps-app-zenly-for-213m/)），2022 年 4 月 3500 万 MAU，**2023 年 2 月 3 日关停**。

真正可引用的机制是**自研地图引擎 "Wonka"**（2019 年启动，仅 10 人）【实证】[TechCrunch 2022-05-18](https://web.archive.org/web/20231128141913/https://techcrunch.com/2022/05/18/social-maps-app-zenly-rolls-out-its-own-maps/)：道路上算法生成**移动的小汽车、卡车、船、鸭子**；河流可点击触发水花；太阳位置按真实时间计算、阴影随之变化；**无加载屏**。

【判断】**这才是 Zenly"活着"的真正机制：屏幕上永远有非你触发的微动作在发生。** 但注意 —— 这套东西的成本是一个 10 人专职引擎团队。Lares 不可能复制，也不应该试。

> ⚠️ **风险提示**：广为流传的 Zenly「头像涟漪/光环」「电量共享」「睡眠状态」等细节 **【未找到可靠来源】**。另外中文拆解（[优设网](https://www.uisdc.com/zenly-5-0)）称 5.0 是"超大字号 + 大胆渐变"，而 TechCrunch 一手采访称是"**thin, elegant fonts**" —— **两者冲突，以一手采访为准。**

**Gather.town —— 在场是连续量，不是布尔值。**【实证】这是本次调研里可量化程度最高的 co-presence 模型：
- 空间音视频按**格距**衰减：「You begin connecting with someone who is **five tiles** from you, and you are fully connected when you are within **two tiles**」（[帮助中心](https://support.gather.town/articles/4624155403-overview-of-spatial-audio-video)）
- **Bubbles**：泡外的人**仍能很轻地听见，且视频半透明** ——「very softly (and with transparent video)」（[来源](https://support.gather.town/articles/3330510961-talk-in-a-bubble)）
- **Idle Time**：绿色状态旁一个数字，表示"Available 但未在窗口活动"的时长
- **Ambient Desks** 官方目标写明 "increase the **sense of presence** from people around you"，并新增 **"In Focus"** 状态 —— 屏蔽噪音但仍可被触达（[来源](https://support.gather.town/articles/4022229898-ambient-desks-beta)）

**Locket / Yope / Airbuds —— 在场推送到系统层，且都取消了计数。**【实证】Locket 好友上限 20，「**We don't count or track the reactions**」（[App Store](https://apps.apple.com/us/app/locket-widget/id1600525061)）；Yope 落在**锁屏**，「stay connected **without opening the app**」「**no likes. no rankings.**」（[App Store](https://apps.apple.com/us/app/yope-friends-only-social-game/id1600195477)）。

【判断】三者共同的设计判断是：**一旦引入计数，陪伴就退化成表演。**

**Focusmate —— 最纯粹的"沉默共在"。**【实证】50 分钟视频会话，开场各 ≤30 秒说目标，然后「Each partner works **silently** on their own individual projects」（[Daily.co 案例](https://www.daily.co/blog/how-focusmate-helps-people-be-their-best-selves-building-on-dailys-prebuilt-ui/)）。**整整 50 分钟的在场信号就是一个沉默的画面。**

### 1.7 横向对比：静默的房间靠什么填屏？

| 产品 | 填屏内容 | 沉默者的表达通道 | 共在感的承载物 |
|---|---|---|---|
| **Telegram** | 巨型中央麦克风按钮 + 其波纹 + 动态渐变背景 | 举手（Lottie 动画） | 顶部条实时显示"谁在说、多大声" |
| **Clubhouse** | 三段式头像阵列，全员头像＋姓名 | **无原生通道** → 逼出"连点麦克风"民间信令 | 头像阵列本身 + 能看到朋友在哪个房间当听众 |
| **X Spaces** | 分区头像网格 + "+N" + 实时字幕 + pin 的推文 | **emoji 反应，且强调互见** | 反应的互见性 |
| **FaceTime** | 等权重分格；无视频者显示姓名首字母 | iOS 17+ 手势 Reactions | **内容状态同步 + 各自本地控制权** |
| **Gather** | 空间地图 | 走近/走远本身即信号 | **距离衰减 + 半透明 = 程度化在场** |

**【判断】三条结论：**
1. **Apple 走的是另一条路** —— 靠内容状态同步表达共在，而非放大人像。这条路 Lares 用不上（没有共享内容）。
2. **头像阵列本身就是内容** —— Clubhouse/Spaces 都把"看见谁在"当作屏幕的主要负载。Lares 目前只放 2 个头像在顶部，等于**主动放弃了唯一的内容**。
3. **反应通道是刚需而非装饰** —— Clubhouse 的教训最尖锐：不给通道，用户会自己发明畸形信令。

---

## 2. 第二步：设计模式

### 2.1 深色 UI 的正确做法

**M3 深色表面的权威 tone 值 —— 我从 Flutter 随附的 `material_color_utilities` 源码直接读出。**【实测】

调研中 `m3.material.io` 正文为 JS 渲染无法抓取【未找到可靠来源】，但 Google 官方的 Dart 实现 `material_color_utilities-0.13.0/lib/dynamiccolor/material_dynamic_colors.dart` 就是规范的可执行版本，比二手文章更权威：

| 角色 | 深色 tone | 源码行 |
|---|---|---|
| `surfaceContainerLowest` | **T4** | L109–115 |
| `surface` / `surfaceDim` | **T6** | L91–98 |
| `surfaceContainerLow` | **T10** | L117–126 |
| `surfaceContainer` | **T12** | L128–137 |
| `surfaceContainerHigh` | **T17** | L139–148 |
| `surfaceContainerHighest` | **T22** | L150–159 |
| `surfaceBright` | **T24** | L100–107 |
| `onSurface` | **T90** | L161–167 |

**关键结论：M3 深色层级用 tone 4→24 的窄区间表达，且是靠"容器色"而非阴影。** `onSurface` 的 `ContrastCurve(4.5, 7, 11, 21)` 说明 M3 把 **4.5:1 作为默认档对比度下限** —— 与 WCAG AA 正文要求一致。

**WCAG 阈值**【实证】[WCAG 2.2 SC 1.4.3](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)：正文 **4.5:1**，大字（≥18pt 或 ≥14pt 粗体）**3:1**；[SC 1.4.11](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html)：UI 组件与图形 **3:1**。

**⚠️ 一条与直觉相反、但对本项目至关重要的证据。**【实证】[NN/g: Dark Mode vs. Light Mode](https://www.nngroup.com/articles/dark-mode/)：
- 正常/矫正视力人群在视敏度与校对任务上**浅色模式全面胜出**
- 两种模式在眼疲劳、头痛上**无显著差异**
- **最要命的一条**：参与者**主观感知不到**明暗模式的可读性差异，尽管客观表现有差
- NN/g 自述「**has not done its own research**」，是文献综述 —— 所以我追了原始研究：

**原始同行评审证据**【实证】：
- **Piepenbrock et al. (2014)**，*Human Factors* **56(5):942-951**，DOI 10.1177/0018720813515509：测试 8/10/12/14pt，「the positive polarity advantage **linearly increased with decreasing character size**」，作者原话：「**Especially with small font sizes, negative polarity displays should be avoided.**」
- **Piepenbrock et al. (2013)**，*Ergonomics* **56(7):1116-1124**：正极性优势**跨年龄成立**（18–33 与 60–85 两组）；**疲劳指标无显著差异**（[PubMed](https://pubmed.ncbi.nlm.nih.gov/23654206/)）
- **Buchner & Baumgartner (2007)**，*Ergonomics* **50(7):1036-1063**：「**colour contrast could not compensate for a lack of luminance contrast**」——**色相差不能替代亮度差**
- **Dobres et al. (2017)**，*Applied Ergonomics* **60:68-73**：**深色模式 + 暗环境是最差组合**
- **眼疲劳 RCT (2025, n=30)**：两模式无显著差异，**使用时长才是主因**（[开放获取](https://europepmc.org/articles/PMC12027292)）

> 【判断】**"暗色护眼"这个论证站不住。** 而且注意 Dobres 那条 —— **深色 + 暗环境是最差组合**，这恰恰就是 Lares 的典型场景（深夜挂机）。
>
> **所以必须付出的代价是明确的：小字号在暗色下损失最大，正文字号不能再小、对比度要留余量。** §3.1 的表面阶梯把正文对比度都做到 8:1 以上（而非压着 4.5:1 及格线），§3.4 把正文下限定在 14sp，都是为了对冲这一条。
>
> 另一条操作性结论：**不能靠用户自述来验收暗色模式** —— 用户主观感知不到差异。只能靠对比度数值。

**OLED 省电 —— 但幅度被严重夸大了，这条必须写清楚。**

【实证】Apple WWDC22 Session 10083（[逐字稿](https://nonstrict.eu/wwdcindex/wwdc2022/10083/)）称大面积深色背景"we expect **up to a 70% display power savings**"，注意是 **up to**，且明确前提是"when screen brightness is high"。

【实证】同行评审的实测数据给出了完全不同的日常图景 —— Purdue MobiSys 2021，Dash & Hu，DOI [10.1145/3458864.3467682](https://dl.acm.org/doi/10.1145/3458864.3467682)：

| 屏幕亮度 | 浅色→深色实测省电 |
|---|---|
| **30%–50%**（室内自动亮度的典型区间） | **仅 3%–9%** |
| 100% | 39%–47% |

Purdue 新闻稿原文：室内自动亮度「tends to keep brightness levels around **30%-40%**」，而该区间的节省「so small that **most users wouldn't notice**」（[Purdue](https://www.purdue.edu/newsroom/archive/releases/2021/Q3/dark-mode-may-not-save-your-phones-battery-life-as-much-as-you-think,-but-there-are-a-few-silver-linings.html)）。测试机型 Pixel 2 / Moto Z3 / Pixel 4 / Pixel 5。

> 【判断】**这条推翻了我原本的论证。** 结合 §2.1 开头 NN/g 的证据（暗色不护眼），**"暗色省电"和"暗色护眼"两条常见理由现在都站不住了。**
>
> **Lares 选暗色的正当理由只剩一条：夜间挂机的环境适配 —— 深夜盯着一块亮屏是真的不舒服，这是场景匹配，不是生理优化。** 这个理由本身足够充分，但**不要用省电或护眼去论证它**，那会在被追问时崩塌。
>
> 附带推论：既然省电收益在典型亮度下只有个位数，**就更没有理由为了省电去用纯黑** —— 选 `#181210` 这类深灰应基于视觉理由（见下）。

**为什么不用纯黑 —— M2 给了三条理由（原文）**【实证】[M2 dark-theme（Wayback 原始快照）](http://web.archive.org/web/20191114145551id_/https://material.io/design/color/dark-theme.html)：

> 「Dark gray surfaces can express a **wider range of color, elevation, and depth**, because it's easier to see **shadows on gray (instead of black)**. Dark gray surfaces also **reduce eye strain**, as light text on a dark gray surface has less contrast than light text on a black surface.」

M2 推荐值即 `#121212`。**`#000000` vs `#121212` 的精确功耗差：【未找到可靠来源】**，且 Purdue 论文证明功耗-颜色关系**非线性**，不能线性外推。

**纯黑还有一个实际代价**【实证】：黑色拖影（black smearing）源于面板响应时间，且记者记录该问题恰好出现在 **30% 亮度的滚动场景**（[GSMArena](https://www.gsmarena.com/google_pixel_2_xl_display_reportedly_has_black_smear_issues-news-27886.php)）—— 低亮度正是深色模式的典型使用条件。

**M2 elevation overlay 百分比表已核实**【实证】（00dp=0% / 1dp=5% / 2dp=7% / 3dp=8% / 4dp=9% / 6dp=11% / 8dp=12% / 12dp=14% / 16dp=15% / 24dp=16%），且与 Flutter 源码公式 `opacity = (4.5 * log(elevation + 1) + 2) / 100` 完全吻合（[elevation_overlay.dart](https://raw.githubusercontent.com/flutter/flutter/master/packages/flutter/lib/src/material/elevation_overlay.dart)）。

**但这套机制已被官方废弃，不要用。**【实证】Flutter breaking change（stable **3.22.0**）：「**replaces the old opacity-based model that applied a tinted overlay on top of surfaces based on their elevation**. The default `surfaceTintColor` for all widgets is now **null**」（[docs.flutter.dev](https://docs.flutter.dev/release/breaking-changes/new-color-scheme-roles)）；Android 措辞更硬：「**The maintenance to the elevation overlay has been discontinued.**」（[Color.md](https://raw.githubusercontent.com/material-components/material-components-android/master/docs/theming/Color.md)）。

→ **§3.1 的表面阶梯用 tone-based container 色，是当前正确做法。**

**去饱和规则（M2 原文）**【实证】同一来源：

> 「A dark theme should **avoid using saturated colors**... **Saturated colors also produce optical vibrations against a dark background, which can induce eye strain.**」

并给出可直接落地的品牌色适配公式：「**#1F1B24** is the result of combining the dark theme surface color #121212 and the **8% Primary color**」。**这正是 §3.1 用品牌色相构造中性阶的同一思路。**

**⚠️ 一条对本文所有对比度数字的重要限定。**【实证】WCAG 2 的对比度公式对前景/背景互换**完全对称**（[WebAIM](https://webaim.org/articles/contrast/)）。APCA 方（Andrew Somers，W3C Invited Expert）据此主张：「WCAG 2.x **far overstates contrast for dark colors** to the point that **4.5:1 can be functionally unreadable when a color is near black**... **WCAG 2.x contrast cannot be used for guidance designing "dark mode"**」（[WhyAPCA](https://git.apcacontrast.com/documentation/WhyAPCA)）。

> ⚠️ 该页自己声明"个人观点未必反映 W3C 立场"，**应标注为 APCA 研究方论断而非共识**。且 **APCA 目前不具规范性地位** —— WCAG 3.0 仍是 Working Draft，其对比度算法处仍为占位符 `@@[contrast measure to be determined]`（[W3C WAI](https://www.w3.org/WAI/WCAG3/informative/text-and-wording/text-appearance/text-contrast-sufficient-minimum/)）。
>
> 【判断】**实践结论：WCAG 2.2 的 4.5:1 是本项目的合规底线（必须过），但在暗色下它可能偏乐观，所以本文 §3.1 的表面阶梯把正文对比度都留在了 8:1 以上，而不是压着 4.5:1 及格线走。** 这个余量是刻意的。

**另一条 Recommendation 级警告**【实证】[Understanding 1.4.3](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)：抗锯齿会使「特别细或不常见的字体被渲染成比 CSS 中实际文字色**淡得多**的颜色」，导致**名义达标但实际不可读**。→ 直接支持 §3.4 的字重纪律。

### 2.2 玻璃拟态 / Liquid Glass —— 结论：Lares 不用

**Apple Liquid Glass 是什么**【实证】2025-06-09 发布（[Apple Newsroom](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/)），2025-09-15 上线。[WWDC25 Session 219](https://developer.apple.com/videos/play/wwdc2025/219/)：
- **是折射不是模糊**：「Where as previous materials scattered light, this new set of materials dynamically **bends, shapes, and concentrates light** in real time」
- **圆角用"同心"规则而非固定数值**：fixed / capsule（圆角＝高度一半）/ **concentric（圆角＝父容器圆角 − padding）**
- **排版更粗、左对齐**：「bolder and left-aligned to improve readability」
- **明确反拟物**：「a **new digital meta-material**」

**Apple 自己给玻璃划的两条硬禁令**【实证】[HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials)（注：不存在 `/human-interface-guidelines/liquid-glass` 页面，指引在 Materials 页）：

> 「**Don't use Liquid Glass in the content layer.**」
> 「**Use Liquid Glass effects sparingly.** ... Limit these effects to the **most important functional elements** in your app.」

且 `clear` 变体有一条很说明问题的规定：「If the underlying content is bright, consider adding a **dark dimming layer of 35% opacity**.」——【判断】**这等于 Apple 自己承认：纯半透明玻璃无法自证满足对比度，必须靠暗化层兜底。**

**Apple 已经在回退这个效果**【实证】：2025-07-07 beta 3 回调透明度（[TechCrunch](https://techcrunch.com/2025/07/07/ios-26-beta-3-dials-back-liquid-glass/)、[The Verge](https://www.theverge.com/news/700066/apple-liquid-glass-frosted-ios-26-developer-beta) 副标题"makes Apple's new UI **a little less transparent and easier to read**"）；**2025-11-03 iOS 26.1 干脆加了用户开关**，Apple release note 逐字：「choose between the default clear look or **a new tinted look which increases opacity of the material**」（[MacRumors 转载 Apple 原文](https://www.macrumors.com/2025/11/03/apple-releases-ios-26-1/)）。

**三方独立收敛于同一结论**【实证】：NN/g 要求模糊量「must **account for the many possible backgrounds**」（[NN/g Glassmorphism](https://www.nngroup.com/articles/glassmorphism/)）；Microsoft Fluent Acrylic 更直接 —— 「**Rendering acrylic surfaces is GPU-intensive**... **automatically disabled when a device enters Battery Saver mode**」，且「**Don't** put desktop acrylic on **large background surfaces**」（[Microsoft Learn](https://learn.microsoft.com/en-us/windows/apps/design/style/acrylic)）。**Apple、Microsoft、NN/g 都说：玻璃只用于瞬态/功能层。**

#### Flutter 的实际成本 —— 一处需要澄清的常见误传

⚠️ **必须说清楚**：网上常说"Flutter 官方性能文档警告 BackdropFilter 昂贵"，**这个说法不准确** —— [/perf/best-practices](https://docs.flutter.dev/perf/best-practices) 全文并未点名 BackdropFilter，它警告的对象是 **`saveLayer()`、`Opacity`、clipping**。

**但 widget 自己的 API 文档确实警告了。**【实测】我读了 `D:\flutter\packages\flutter\lib\src\widgets\basic.dart`：
- L583：`BackdropFilter`「This effect is **relatively expensive**, especially if the filter is non-local, such as a **blur**.」
- L588–596：能用 `ImageFiltered` 就别用 `BackdropFilter`，「the performance will be improved **dramatically** for complex filters like blurs」
- L240–243：`Opacity` 对非 0/1 值「relatively expensive because it requires painting the child into an **intermediate buffer**」

**真实的量化数据**【实证】[flutter#191207](https://github.com/flutter/flutter/issues/191207)（36 玻璃面板、blur sigma 15、1920×1017、60Hz、确定性滚动、profile 模式）：

| 用例 | Raster p50 | max | 超预算帧 |
|---|---|---|---|
| 未分组 unbounded（**Impeller**） | **11.233 ms** | 22.457 | 4/239 |
| **分组** unbounded（Impeller） | **3.853 ms** | 5.234 | 0/240 |
| 同场景 **Skia** 对照 | 4.061 ms | 6.515 | 0/239 |

未分组 blur 的 raster p50 占满 60Hz 帧预算（16ms）的约 **67%**，是 Skia 的 **2.77 倍**。

**根因值得记住**【实证】Flutter 引擎工程师原话：「Despite covering only a small region of the screen, **for Impeller we will process and restore the entire screen** to implement the backdrop.」（[flutter#149368](https://github.com/flutter/flutter/issues/149368)）→ **"面板小所以便宜"是错误直觉。**

**缓解手段存在**【实证】：`BackdropGroup` + `BackdropFilter.grouped`（**Flutter 3.29.0** 起）可把 p50 降 **65.7%**（[官方 API](https://api.flutter.dev/flutter/widgets/BackdropGroup-class.html)）。**硬约束**：iOS 上 Impeller 是「the **only supported** rendering engine... **no ability to switch to Skia**」（[官方](https://docs.flutter.dev/perf/impeller)）。

> **【判断】Lares 不采用毛玻璃。四条理由：**
> 1. **成本与场景直接冲突** —— 即便用上 `BackdropGroup` 把 raster 压到 3.85ms，那也是**每一帧**都在付的钱。挂机十几小时的界面，不该为装饰持续付费。
> 2. **Liquid Glass 的核心是实时折射**，Flutter 给不了；只能做出"模糊"这个 Apple 明确说不是它的东西。**做出来是廉价仿品，不是致敬。**
> 3. **Apple 自己都在回退**（beta 3 降透明度、26.1 加开关），此刻跟进一个正在被其发明者收回的效果，时机很差。
> 4. **深色底上的玻璃层会压缩本就狭窄的 tone 4–24 层级空间**，与 §3.1 的表面阶梯打架。
>
> **可以借鉴的只有一条**：同心圆角规则（子圆角 = 父圆角 − padding）。这条零成本，见 §3.5。

### 2.3 空状态设计

【实证】[NN/g: Designing Empty States in Complex Applications](https://www.nngroup.com/articles/empty-state-interface-design/)（Kaplan, 2021）：留白"may save development time... but it ultimately **creates confusion and decreases user confidence**"。空状态应承担三件事：**传达系统状态、提供学习线索、给出关键任务的直达路径**。

**最有害的反模式，且 Lares 正好踩了。**【实证】加载期间先显示"No records"、几秒后再被真实内容替换 —— NN/g 称这类不准确状态"**particularly harmful**"：最好情况是用户"develop a severe distrust of and distaste for the application"，最坏情况是"trigger-happy users (that is, most users) **never see the relevant content**"。

> 【实测】Lares `room_screen.dart` L394–398：`if (members.isEmpty)` 直接显示「房间里还空着，坐一会儿?」—— **进房过程中 `members` 必然短暂为空**，于是每次进房都会先闪一下"空房间"。**这正是 NN/g 点名的那个反模式。** 必须把空态与加载态拆成两个状态。

【实证】[Material 1 空状态](https://m1.material.io/patterns/empty-states.html)：图像应"subtle and neutral with respect to the background"，标语要"conveys the purpose of the app **without appearing to be actionable**"；三种避免真空的方案：**starter content / educational content / best match**。

"呼吸感作为特性""单焦点构图"等具体版式手法的权威论述：**【未找到可靠来源】**。

### 2.4 语音可视化

**驱动信号只有两类**【实证】[MDN Web Audio 可视化](https://developer.mozilla.org/en-US/docs/Web/API/Web_Audio_API/Visualizations_with_Web_Audio_API)：时域（波形）与频域（FFT 柱状）。**除均衡器柱与环形波形需频段数据外，其余模式全部只需一个标量幅度。**

**平滑属于信号层，不是动画层。**【实证】[`AnalyserNode.smoothingTimeConstant`](https://developer.mozilla.org/en-US/docs/Web/API/AnalyserNode/smoothingTimeConstant) 默认 **0.8**，设为 0 则"变化会明显得多（jarring）"。**先在信号侧做指数平滑，视觉侧就不需要靠高帧率抹抖动。** Telegram 的 `updateAmplitude(dt)` 是同一思路。

**帧率论证必须用耗电，不能用"人眼阈值"。**【实证】"人眼多少 fps 算流畅"「15–20fps 够用」均**【未找到可靠来源】**。但 Apple WWDC22 10083 有决定性的一条：

> 「**The display's refresh rate is determined by the animation with the highest frame rate in your app.** Your app may have secondary elements refreshing at a higher rate than necessary, causing the app as a whole to consume more battery than expected.」
>
> 量化案例：主内容 30fps + 一个 60fps 滚动小字 → 整屏被拉到 60fps；把小字降到 30fps 后「**we could save up to 20% of the battery drain**」。

**Flutter 实现的正确路径 —— 这是全文对实现最有价值的一条。**【实证】[CustomPainter 官方文档](https://api.flutter.dev/flutter/rendering/CustomPainter-class.html)：

> 「The most efficient way to trigger a repaint is to... supply a **`repaint` argument to the constructor**... the `CustomPaint` widget or `RenderCustomPaint` render object will listen to the `Listenable` and repaint whenever the animation ticks, **avoiding both the build and layout phases of the pipeline**.」

配套约束【实证】[Flutter 性能最佳实践](https://docs.flutter.dev/perf/best-practices)：
- `setState()` 会让**所有后代 rebuild**，必须下沉到真正变化的子树
- `AnimatedBuilder` 里不依赖动画的子树**每 tick 都会重建**，要用 `child` 参数外提
- 「**Avoid using the `Opacity` widget, and particularly avoid it in an animation.**」半透明简单图形应"just draw them with a semitransparent color"
- `RepaintBoundary` 必配，因为「`RenderObject.paint` may be triggered **even if its associated `Widget` instances did not change or rebuild**」（[官方](https://api.flutter.dev/flutter/widgets/RepaintBoundary-class.html)）—— 但要诚实：它只是"**may** choose to pay a one time cost of caching"，非零成本

**"真 idle"的技术定义**【实证】：[`SchedulerBinding.scheduleFrame`](https://api.flutter.dev/flutter/scheduler/SchedulerBinding/scheduleFrame.html) 首行即 `if (_hasScheduledFrame || !framesEnabled) return;`；[`Ticker`](https://api.flutter.dev/flutter/scheduler/Ticker-class.html) "initially disabled"。→ **无活跃 Ticker 且无 markNeedsPaint 时，无人调用 scheduleFrame，引擎不出帧。** 目标是静音时 `controller.stop()`，**而不是把幅度设为 0 继续空转**。

> ⚠️ 【实证】网上流传的「Flutter 循环动画占 60–80% CPU」（[flutter#121407](https://github.com/flutter/flutter/issues/121407)）是 **debug 构建**且已被标记 duplicate/not_planned 关闭，**不可当 release 数据引用**。

**Impeller**【实证】[官方](https://docs.flutter.dev/perf/impeller)：自 **3.27** 起为 iOS 与 Android API 29+ 默认渲染器。`FragmentProgram` 限制【实证】[官方](https://docs.flutter.dev/ui/design/graphics/fragment-shaders)：不支持 UBO/SSBO、仅 `sampler2D`、**无 vertex shader**；应 precache 并跨帧复用 `FragmentShader` 对象。

**【判断】Flutter 的 shader 不能自我动画** —— 时间必须由 Dart 侧每帧写 uniform，所以 shader **不是**绕开 ticker 的省电捷径。这一点常被误解。

### 2.5 长时间常亮 / 挂机界面

**Apple HIG《Always On》—— 这是与 Lares 场景最贴合的官方规范。**【实证】[developer.apple.com](https://developer.apple.com/design/human-interface-guidelines/always-on)，系统行为定义为「**dimming the display and minimizing onscreen motion**」。四条守则：
1. **Hide sensitive information**
2. **Keep important content legible and dim nonessential content** ——「consider **removing the images and using dimmed colors**」
3. **Maintain a consistent layout** ——「aim to make **infrequent, subtle updates**」。举例：体育 app 应暂停逐球更新、**只在比分变化时更新**。并特别警告：「people often put their device **face up on a surface**, making motion on the screen visible **even when they're not looking directly at it**」
4. **Gracefully transition motion to a resting state; don't stop it instantly**

> 【判断】第 3 条几乎是为 Lares 写的 —— 挂机十几小时的界面，**唯一该动的时刻就是状态真的变了**。第 4 条则否定了当前 `SpeakingRipple` 的 `_controller.stop()` 硬停（见 §6.3）。

**WCAG 2.2 SC 2.2.2 Pause, Stop, Hide（Level A）**【实证】[W3C](https://www.w3.org/WAI/WCAG22/Understanding/pause-stop-hide.html)：自动开始、**持续超过 5 秒**、与其他内容并置的移动/闪烁/滚动，**必须**提供暂停、停止或隐藏机制。最佳实践要求多个动效元素提供**单一统一**的控制。

**最有用的一条杠杆**【实证】[WCAG 2.1 SC 2.3.3](https://www.w3.org/WAI/WCAG21/Understanding/animation-from-interactions.html)：「Motion animation does not include changes of **color, blurring, or opacity** which do not change the perceived size, shape, or position of the element.」

> 【判断】**这意味着：极慢的明暗呼吸、色相漂移、模糊变化在规范定义下不算"运动动画"，是最安全的 idle 手法；位移、缩放、视差才是高风险项。** 这条直接决定了 §6 动效规范的形态。

**Calm Technology**【实证】Weiser & Seely Brown, *Designing Calm Technology*（Xerox PARC, 1995，[全文](https://calmtech.com/papers/designing-calm-technology)）：
- 「Calm technology engages both the **center** and the **periphery** of our attention」
- 「the periphery is **informing without overburdening**」
- **Dangling String**（Natalie Jeremijenko）：8 英尺塑料绳接以太网马达，「a busy network causes a madly whirling string... **a quiet network causes only a small twitch every few seconds**」
- 控制权准则：「**The individual, not the environment, must be in charge** of moving things from center to periphery and back.」「**will offer, but not demand.**」

Amber Case 八原则【实证】[calmtech.com](https://calmtech.com/)，其中第 1、5、7 条最切题：要求最少的注意力；**可以沟通，但不必说话**；恰当的技术量是解决问题所需的**最小量**。

**OLED 烧屏缓解与 Android Ambient Mode 具体条款：【未找到可靠来源】。**

### 2.6 中文排版

**行高：CJK 确实需要比拉丁更大，且有字形学论证。**【实证】[Material Design 排版规范](https://m1.material.io/style/typography.html)：

> 「English and English-like languages mostly use **a portion of the em box**, often the lower portion below the x-height. Chinese, Japanese, and Korean (CJK) ideographic characters use the **entire em box**... the line height needs to be **larger** than in English for tall and dense languages.」

Material 把 CJK 归为 **Dense** 类，给出精确调整量：**行高比英文大 0.1em**；**字号 Title 至 Caption 比英文大 1px**；**字重与英文相同**。

W3C clreq 提供支撑该论证的字形事实【实证】[clreq §1.2](https://www.w3.org/TR/clreq/#basic_features_of_chinese_script)：「汉字和标点符号比例皆为 **1:1 的正方形**，将其**无缝隙**并列排成版面」。

> ⚠️ **一条常见误传需要澄清**：网传"clreq 建议行间距为字号的 50%–100%"—— **经查证不存在**。[clreq §6.4](https://www.w3.org/TR/clreq/#h_baselines)「基线、行高等」是**空白占位章节**，正文后紧跟 `TBD: add more content about baseline`。

**Ant Design 的行高公式可直接对照**【实证】[genFontSizes.ts](https://raw.githubusercontent.com/ant-design/ant-design/master/components/theme/themes/shared/genFontSizes.ts)：`lineHeight = (fontSize + 8) / fontSize`。base=14 时输出 **12/20、14/22、16/24、20/28、24/32**。官方说明主字号定为 14 的依据是「电脑显示器阅读距离（**50 cm**）以及最佳阅读角度（**0.3**）」，并建议「字阶控制在 **3-5 种**之间」（[font-cn](https://ant.design/docs/spec/font-cn)）。

→ 换算成倍数：14px 对应 1.571，16px 对应 1.5。**当前 `theme.dart` 的 `height: 1.5` 落在这个区间内，是合理的。**

**最小字号**【实证】[Apple HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography)：iOS 最小 **11pt**（默认 17）、macOS **10pt**（13）。[微信小程序](https://developers.weixin.qq.com/miniprogram/design/)：常用字号 **22/17/15/14/12 pt**；其[适老化指南](https://developers.weixin.qq.com/miniprogram/design/elderly.html)要求对比度「至少 **4.5:1**（字号大于 **18 dp/pt** 时至少 **3:1**）」。

> ⚠️ **「中文正文最小 12px」这条广为流传的规定：【未找到可靠来源】** —— Ant Design、Apple HIG、Material、微信四份一手文档均无此硬性规定。**Apple 对中文的专门字号建议同样【未找到可靠来源】**（HIG typography 全页不含 "Chinese"）。

**字重 —— 我原本的判断方向搞反了，这里必须更正。**

我的直觉是"深色底上中文要加粗"。**这是错的。**【实证】[Google Fonts Knowledge](https://fonts.google.com/knowledge/choosing_type/exploring_typefaces_with_multiple_weights_or_grades)：

> 「When working on screen, **light type on a dark background appears to glare and its letterforms become bloated**. This is a concept known as **"halation"**... the type on the left [dark background] uses the **Regular** weight of Lato, while the type on the right [light background] uses the **Semibold** weight—and yet, optically, they appear the same.」

→ **屏幕上深色背景应「降」字重，不是「升」。印刷才相反**（油墨侵蚀使反白字变细，需加粗）。混淆两者会得出完全错误的规范。

**但"避免过细"仍然成立**，这是另一回事【实证】Apple HIG：「**avoid Ultralight, Thin, and Light** font weights, which can be difficult to see, **especially when text is small**」；[Ant Design](https://ant.design/docs/spec/font-cn)：「多数情况下，只出现 **regular 以及 medium** 两种字重，分别对应 **400 和 500**」。

思源黑体有 **7 个字重**：`ExtraLight / Light / Normal / Regular / Medium / Bold / Heavy`（⚠️ **Normal 与 Regular 是两个不同字重**，极易误写）【实证】[adobe-fonts/source-han-sans](https://github.com/adobe-fonts/source-han-sans/tree/release/SubsetOTF/CN)。

> 【判断】**综合成一条可执行规则：中文正文用 w400，避免 w300 及更细；不要因为是深色底就去加粗到 w600 —— halation 已经替你"加粗"了。** 只在字号 ≤12sp 时用 w500 补偿（此时字太小，笔画本身的可辨性压倒了 halation 效应）。**"≤12sp 用 w500"这一档是我的判断，无直接来源。**

**字间距：clreq 的立场是"密排为原则"。**【实证】[clreq §6.3.1](https://www.w3.org/TR/clreq/#principles_of_arrangement_of_han_characters)：「原则上应将字符外框**彼此紧贴**，这种做法称作**密排**」，疏排只限标题平衡、图表说明、诗词、儿童书籍 4 种书籍场景。唯一强制性规定在中西文交界处：「汉字与西文字母、阿拉伯数字间使用**不多于四分之一个汉字宽**的字距」（[clreq §2.1.3](https://www.w3.org/TR/clreq/#mixed_text_composition_in_vertical_writing_mode)）。

Ant Design 的 Font Token 中**完全没有 letterSpacing 这一项**【实证】[font.ts](https://raw.githubusercontent.com/ant-design/ant-design/master/components/theme/interface/maps/font.ts)。

> ⚠️ **中文正文 letter-spacing 推荐值（如 0.05em）：【未找到可靠来源】。** 结论：**中文不加字距**（保持 0），但这是"没有理由加"而非"有禁令"。

### 2.7 2025–2026 趋势

**抓取失败声明（诚实交代）**：Dribbble（HTTP 202，疑反爬）、Behance（JS 渲染）、Mobbin（正文截断）、Apple HIG 与 m3.material.io 正文（JS 渲染）**均未取到正文**。因此本节**不含任何具体作品名或设计师名**。

**两件有官方背书的大事**：
1. **Apple Liquid Glass**（见 §2.2）
2. **Material 3 Expressive**（2025 年 5 月）【实证】[官方博客](https://blog.google/products-and-platforms/platforms/android/material-3-expressive-android-wearos-launch/)、[Google Design 研究页](https://design.google/library/expressive-material-design-google-research)：46 项研究、逾 18,000 名参与者；18–24 岁偏好率 87%；关键 UI 元素定位"**up to four times faster**"。核心手法：**color, shape, size, motion, containment**。

> ⚠️ **M3 Expressive 构成对"安静 UI"的反证**：Google 的立场是"move beyond 'clean' and 'boring' designs"。但同页承认"**a strong minority of users preferred calmer, less intense versions**"。
>
> 【判断】**Lares 应当站在那个 minority 一边，并且清楚这是逆流而行的选择。** 理由：M3 Expressive 优化的是"快速定位关键元素"（4 倍速），这是**高频短时**交互的指标；Lares 是**低频长时**挂机，两者的目标函数根本不同。

**明确无据、请勿写入规范**【未找到可靠来源】：Bento grid、噪点/颗粒纹理、"Quiet UI"作为被权威命名的趋势、拟物复兴、大圆角的具体数值、Figma 年度报告结论。

---

## 3. 第三步：可执行规范

### 3.0 先修 bug，再谈美学

**这三条优先于本文所有视觉建议。** 一个溢出 2014 像素的布局，再好的配色也救不了。

#### Bug 1：布局溢出 —— 根因已定位到行

【实测】`room_screen.dart` L261–298，`_RoomHeader` 的 `Row`：

```dart
Row(                                   // L261 主轴无界
  children: [
    Column(                            // L263 ← 没有 Flexible/Expanded
      children: [
        Text(circleName, ...),         // L266 无 maxLines
        Text(                          // L267 无 maxLines / overflow
          switch (controller.phase) {
            RoomPhase.error => controller.errorMessage ?? '出错了',  // L272
          },
```

`Row` 给非 flex 子节点的横向约束是 **unbounded**，`Text` 于是按固有宽度单行铺开。当 L272 塞入 `'进房失败:$e'`（`$e` 是未截断的原始异常，常带 URL/token）时，单行宽度轻易达 2000+ 逻辑像素 —— **与 2014px 的数量级完全吻合**。

**修法**：`Column` 外包 `Expanded`；两个 `Text` 加 `maxLines` + `TextOverflow.ellipsis`。**并且错误根本不该出现在这个位置**（见 §3.6）。

#### Bug 2：挂断键浅蓝 —— 是 token 缺口，不是审美失误

【实测】我核对了 Flutter SDK 源码，链条完全确定：

1. `theme.dart` L33–43 构造 `ColorScheme` 时**只传 `secondary`，未传 `secondaryContainer`**
2. `D:\flutter\packages\flutter\lib\src\material\color_scheme.dart` **L1099**：`Color get secondaryContainer => _secondaryContainer ?? secondary;`
3. `icon_button.dart` **L1335/1340**：`IconButton.filledTonal` 背景取 `_colors.secondaryContainer`
4. `theme.dart` L37：`secondary: LaresColors.statusEars` = **`#6FA8D0`**

> **结论：挂断键的浅蓝 = "耳朵在"的 presence 状态色。一个语义色被当成了按钮容器色。**

【实测】同一条链还解释了**第 4 条硬伤**：`segmented_button.dart` **L1214** 选中态背景同样取 `secondaryContainer` —— 所以底部切换器的"亮色描边/高亮"也是同一个 bug。**改 theme.dart 一处，两条硬伤同时消失。**

#### Bug 3：空态与加载态混用

见 §2.3。`members.isEmpty` 必须区分 `RoomPhase.joining`（加载）与 `inRoom && isEmpty`（真空）。

---

### 3.1 深色表面层级规范

**方法**【实测】：取品牌色 `#FF8A5C` 的 HCT 色相（**H=39.08**，C=53.50，T=69.62），构造 **chroma=4** 的中性调色板，按 §2.1 表中 M3 官方 tone 值取色。这样整套灰阶带极轻微的暖偏，与"炉火"意象同源，而不是中性灰或现在的紫灰。

| Token | Hex | M3 tone | 用在哪 | 正文 `#F2EEE9` 对比 |
|---|---|---|---|---|
| `bgDeep` | `#120D0B` | T4 | 全屏底（房间页背景层） | 16.71:1 |
| **`bg`** | **`#181210`** | **T6** | **默认页面底** | **16.05:1** |
| `surfLow` | `#201A18` | T10 | 大面积容器、侧栏 | 14.87:1 |
| `surf` | `#251E1C` | T12 | 卡片、列表项（圈子卡片） | 14.19:1 |
| `surfHigh` | `#2F2826` | T17 | 浮起层：底部栏、bottom sheet、次级按钮底 | 12.52:1 |
| `surfHighest` | `#3B3331` | T22 | 输入框、选中态、悬浮态 | 10.67:1 |
| `surfBright` | `#3F3835` | T24 | 分隔线、描边、禁用态底 | 9.94:1 |

**层级纪律：**
- **相邻两层只差 1 档**（tone 差 2–5），不要跳档 —— 跳档会让界面看起来像贴了色块
- **深色下不用阴影表达高度，用容器色**（M3 的核心主张）
- **`bgDeep` 只在房间页用**：房间是唯一的"沉浸"场景，比其他页更暗半档
- **不要纯黑 `#000000`**：现有 `#121016` 的方向是对的，问题只在色相（紫）不在明度

**文字色**（配套调整，全部实测过对比度）：

| Token | Hex | 用途 | 对 `bg #181210` |
|---|---|---|---|
| `textPrimary` | `#F2EEE9` | 正文、名字 | 16.05:1 ✅ |
| `textSecondary` | `#B4ABA5` | 说明、次要信息 | 8.22:1 ✅ |
| `textTertiary` | `#8A817B` | 时间戳、极次要 | 4.6:1 ✅ 勉强达标，**仅用于 ≥14sp** |

> **注意现状的一个真实缺陷**【实测】：`statusAway #6E6878` 对当前背景只有 **3.52:1**，**未达 AA 正文标准**，而它正被用作 12sp 的状态文字（`avatar_orb.dart` L90–96）。**这是无障碍不合格项，不是风格问题。**

### 3.2 品牌色使用规则

**核心问题诊断**【实测】：品牌色不是"没用"，是**用在了看不见的地方**。`_BreathingBackground` 确实用了 ember，但 alpha 只有 5–10%。我算了合成结果：

| 前景 | alpha | 底色 | 合成结果 |
|---|---|---|---|
| `#FF8A5C` | 5% | `#121016` | **`#1E161A`** |
| `#FF8A5C` | 10% | `#121016` | **`#2A1C1D`** |

**`#2A1C1D` 就是用户说的"浑浊棕色"。** 根因是**冷紫底 + 暖橙光 = 脏**：两者色相相距约 100°，低 alpha 混合后既不暖也不紫，落进了灰褐区。

换成暖中性底 `#181210` 后同样 alpha 得到 `#2E1E17` —— 【判断】仍然偏弱但方向正确，因为底色与光源色相同源（都在 H≈39 附近）。**这就是 §3.1 要把底色从紫灰换成暖灰的真正理由 —— 不是审美偏好，是为了让品牌光晕不脏。**

#### 品牌色分配表

| 层级 | 用法 | 具体位置 | 面积预算 |
|---|---|---|---|
| **主** | 实心填充 `#FF8A5C` | **麦克风主按钮（未静音时）** —— 全屏唯一的实心品牌色块 | ≤ 3% |
| **次** | 说话态描边/辉光 | 说话者头像环、说话波纹 | ≤ 2%（且仅在有人说话时存在） |
| **点缀** | 小面积识别 | 未读圆点、主圈标记、focus ring | < 0.5% |
| **氛围** | 径向光晕 | 房间中心炉火（提纯为 `emberDeep`，见下） | 大面积但极低 alpha |

**总预算：静息态品牌色可见面积 ≤ 5%。**

#### 明确禁止

- ❌ **不做品牌色文字**（除非 ≥18pt）—— 8.14:1 虽然达标，但大段橙字在暗色下会晃眼
- ❌ **不做品牌色大色块背景**（卡片底、bottom sheet 底）—— 违反 §2.1 的"避免大面积饱和色"
- ❌ **不用品牌色表达 presence 状态** —— 状态色系与品牌色系必须分离，否则"在忙"的琥珀 `#E8B45A` 会与 ember 撞（这一点 `app/tool/palette/palettes.dart` L131 里已有同样的自我批评）
- ❌ **挂断/离开键绝不用品牌色，也绝不用状态色** —— 见下

#### 炉火光晕的提纯

【判断】氛围光晕不该用 ember 本身，而应用更饱和的火心色。我实测了合成结果：

| 前景 | alpha | 底 `#181210` | 结果 |
|---|---|---|---|
| `#FF5A2A` | 10% | | `#2E1912` |
| `#FF5A2A` | 18% | | `#411F14` |
| `#FF5A2A` | 28% | | `#582617` |

【判断】建议中心峰值 alpha **0.18**，向外 0.82 半径处衰减到 0（这条衰减规则来自仓库既有的 `hearth/SPEC.md` §4.1，是个好设计：**alpha 在硬边缘之前就归零，所以不用 blur 也没有硬边**）。

#### 状态色修订（全部实测达标）

| 状态 | 现值 | 对 `#181210` | 建议 | 新对比 |
|---|---|---|---|---|
| free 随时聊 | `#6FD08C` | 9.78:1 ✅ | `#7FD79A` | 10.67:1 |
| busy 在忙 | `#E8B45A` | 9.80:1 ✅ | `#F0BE6E` | 10.85:1 |
| ears 耳朵在 | `#6FA8D0` | 7.23:1 ✅ | `#8FC4E8` | 9.91:1 |
| **away 有事先走** | `#6E6878` | **3.46:1 ❌** | **`#A8A0B0`** | **7.34:1 ✅** |

**away 是必改项**（无障碍不合格）。其余三色是可选微调（提亮以适配新底色）。

> 【实证】仓库 `app/tool/palette/optimize_status.dart` L10 已记录："实测现有基线就在蓝色盲下把「随时聊」和「耳朵在」混成了 ΔE=7.41" —— **说明色盲可辨性已经是已知问题**。本文的建议值未做色盲仿真验证，**改色前应重跑该工具**。

### 3.3 房间页布局方案

#### 共同前提：先解决"下方三分之二全空"

【实测】根因是 `GridView.builder` + `SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 140)`（L400–406）：**格子宽度固定 140px，与人数无关**。2 人时两个 88px 头像贴在左上角，剩下全空。

【判断】**正确的模型是：头像尺寸与布局半径都应是人数的函数。** 三个方案都遵守这一点。

---

#### 方案 A：围炉环形（推荐）

**这不是新提案 —— 仓库 `app/tool/hearth/` 已经实现并出了图。** 我看过 7 张截图，2 人、5 人、20 人的排布都成立。

**布局算法**（源自 `hearth/SPEC.md` §6.1，已验证可跑）：

```
base = min(可用宽, 可用高)
d    = clamp(96 - (n-2) * 2.6, 52, 96)     // 头像直径，52 是触摸下限余量
R1 = base * 0.30,  R2 = base * 0.44,  R3 = base * 0.575
cap(R) = max(3, floor(2π·R / (d · 1.22)))
```

| 人数 | 排布 | 头像直径 |
|---|---|---|
| **2** | 单环对置（上下），中心炉火占据视觉重心 | 96 px |
| **5** | 单环五点 | 88 px |
| **12** | 双环：内 `ceil(12×0.38)=5`，外 7 | 70 px |
| **20** | 双环：内 8，外 12 | 53 px |
| **>cap** | 前 cap−1 正常显示，末位换 **`+N` 聚合芯片**（点击展开列表） | — |

**关键纪律**（这几条是方案 A 的灵魂）：
- **座位序在加入时分配，说话不重排。** 长期挂机的界面，**位置恒定才有熟悉感**。
- **说话者只做径向内移，不换角度。**
- 每环起始角错开 `-π/2 + i·π/ringCount`，避免内外环径向对齐显得死板。
- 人数变化时位置过渡 **400 ms `easeOutCubic`**。

**空白怎么用**：中心是炉火光晕。**空白本身成了"火塘"** —— 这是方案 A 最大的优势：它把"空"转化为语义，而不是填满它。

**说话状态的具体数值**（融合 Telegram 实证参数 + hearth SPEC）：

| 表现 | 数值 | 依据 |
|---|---|---|
| 头像位移 | `R × (1 − 0.10 × speech)` 径向内移 | hearth SPEC §6.3 |
| 头像缩放 | `1.0 → 1.06` | hearth SPEC（比 Telegram 的 1.1 更克制） |
| 说话环 | 在状态环外**加一圈 ember 描边，2 px** | 参考 Discord 的 2px 内环 |
| 环 alpha | 峰值 0.15 | Telegram `CIRCLE_ALPHA_2` |
| 起振 | 120 ms `easeOut` | 【判断】 |
| **静默回落** | **500 ms** | **Telegram 实证值** |
| 状态文字交叉淡入 | 180 ms | Telegram 实证值 |

**静默分级**（这是长时挂机的关键，Gather 的"程度化在场"思路）：

| 状态 | 半径 | 透明度 | 说明 |
|---|---|---|---|
| 说话中 | `R×(1−0.10×speech)` | 1.0 | |
| 正常在场 | `R` | 0.88 | |
| 静默 >2 min | `R×1.02` | 0.55 | 略微"退后" |
| 静默 >10 min | `R×1.04` | **0.34（硬下限）** | 名字文字 0.5 |

> **透明度不影响命中测试，所有成员始终可点。** 这条必须守住 —— 屏蔽/踢人入口不能因为对方安静就够不着。

**⚠️ 方案 A 的成立前提**【实测】：`Member` 模型**没有 `lastSpokeAt` 字段**，`RoomController` 也不记录。静默分级需要先补这个时间戳（纯客户端可算，不需要服务端改动）。

---

#### 方案 B：单列列表（Telegram 式）

**照抄 Telegram 的实证参数**：头像 46 dp，行高 58 dp，名字 16sp/w600，状态 15sp，分隔线左缩进 68 dp。

| 人数 | 表现 |
|---|---|
| 2 / 5 | 列表只占上半屏，**下半屏放大号麦克风按钮 + 圈子信息** |
| 12 / 20 | 纵向滚动，列数不变，不缩头像 |

**优点**：信息密度最高（名字全显、状态文字全显），实现最简单，20 人以上不劣化。
**缺点**：**完全没有"围坐"的感觉**，与"宅火守护神"的品牌意象无关。这是一个通话工具的样子，不是炉边的样子。

【判断】**方案 B 是安全牌，也是平庸牌。** 建议仅作为**桌面端侧栏**或**成员管理页**的形态，不作房间主视图。

---

#### 方案 C：中心焦点 + 边缘列（FaceTime 式）

中心一个大区域（放炉火/正在说话的人），溢出成员降级为**底部可横向滑动的小格带**（照抄 FaceTime 的实证做法）。

**缺点**【判断】：FaceTime 的 prominence 之所以成立，是因为有视频内容填充中心。Lares 中心没有内容可放，会退化成"一个大圆 + 一排小圆"，比方案 A 更空洞。**不推荐。**

---

#### 底部操作栏（三方案通用）

**先修 bug**：挂断键与语音便签键都是 `IconButton.filledTonal`，吃到了 presence 蓝（§3.0 Bug 2）。

| 按钮 | 尺寸 | 底色 | 图标 | 层级 |
|---|---|---|---|---|
| **麦克风（主）** | **72×72** | 未静音 `#FF8A5C` / 静音 `surfHigh #2F2826` | 32 px | **绝对主角** |
| 离开 | 52×52 | `surfHigh #2F2826`，图标 `textSecondary` | 24 px | 低调 |
| 语音便签 | 52×52 | `surfHigh #2F2826`，图标 `textSecondary` | 24 px | 低调 |

- **间距**：主按钮与两侧各 **28 px**；整栏底部内边距 24 px + SafeArea
- **触摸目标**：全部 ≥ 48×48（52 已满足）
- **离开键绝不用红色**【判断】—— Telegram 用红（`0x7dF75C5C`），但 Clubhouse/Discord 都刻意把"离开"做成低调的 quiet exit。**Lares 是熟人小圈子常驻房，"离开"是日常动作不是紧急动作**，用红色会制造不必要的紧张感。用中性 `surfHigh` + 次要图标色。

#### 状态切换器：从底部移走

【实测】用户报告的"出现两次"在**当前代码中不成立** —— `SegmentedButton` 只有一处（L515）。我核对了截图（`emu_room.png`，2026-09-11）与 git 历史（`9cafe07`），当时代码同样只有一个。

**但用户的感受是对的，只是归因错了。** 真实问题是【实测】屏幕上有**三处竞争性状态文本**：
1. `_RoomHeader` L267–276 的房间状态行
2. `AvatarOrb` L90–96 —— **每个头像下都有状态标签**，包括"我"自己的
3. `_ControlBar` L515 的 SegmentedButton 选中项

**"我"的状态因此同时出现在头像下和底部切换器上，显示同一个词。** 视觉上就是重复。

> ⚠️ 截图中顶部标题上方那个半透明切换器**无法从当前代码或 `9cafe07` 的代码解释**。可能是已修复的历史状态、热重载残留或渲染残影。【判断】**建议在按本文改版前，先用当前代码重新截图确认该现象是否仍存在** —— 不要为一个可能已不存在的问题设计解法。

**建议**【判断】：
- 底部**移除** SegmentedButton（它占了主按钮区的注意力，且中文三段在小屏易挤）
- 我的状态改为**点自己的头像**弹出切换（符合"状态属于人"的心智）
- `AvatarOrb` 下的状态标签**仅在非默认状态时显示** —— "随时聊"是默认态，不必人人都挂一个标签。这一条能立刻让 §1.7 说的"头像阵列即内容"变干净。

### 3.4 字阶与中文排版

| 角色 | 字号 | 字重 | 行高 | 用途 |
|---|---|---|---|---|
| `display` | 28 | w600 | 1.3 | 头像内首字素 |
| `title` | 20 | w600 | 1.4 | 圈子名、页面标题 |
| `body` | 16 | **w400** | **1.5** | 正文、成员名 |
| `bodySm` | 14 | **w400** | **1.57** | 说明文字（Ant Design 14/22） |
| `caption` | 12 | w500 | 1.4 | 状态标签、时间戳 |

**中文纪律**（依据见 §2.6，逐条标注强度）：
- **禁止 w300 及更细承载中文正文**【实证】Apple HIG：「avoid Ultralight, Thin, and Light... especially when text is small」
- **⚠️ 不要因为是深色底就加粗**【实证】halation 已经使反白字视觉变粗；Google Fonts 的对照示例是**深色底用 Regular、浅色底用 Semibold** 才视觉等重。**这一条与直觉相反，最容易做错。**
- **12sp 用 w500 补偿**【判断】—— 此时字号本身的可辨性压倒 halation
- 12sp 文字的颜色**必须 ≥4.5:1**（这就是 away 色必改的原因）【实证】WCAG 1.4.3
- 行高 1.5 起步，**不要压到 1.2**【实证】Material：CJK 用满 em box，行高需比英文大 0.1em
- **中文不加 letter-spacing**（保持 0）【实证】clreq 密排原则；Ant Design 无此 token
- **英文/数字与中文之间留 ≤1/4 汉字宽的间隙**【实证】clreq §2.1.3 —— 这是唯一有强制规定的字距场景

### 3.5 圆角

借鉴 Liquid Glass 的**同心规则**（§2.2，唯一值得抄的一条，且零成本）：**子圆角 = 父圆角 − padding**。

现有 `LaresRadii`（sm 10 / md 16 / lg 24 / xl 32）保留不动，只加一条使用纪律：卡片 `lg=24` + 内边距 8 → 内部元素圆角应为 16（`md`），而不是随手再取一个 24。

### 3.6 错误提示设计

**当前问题**【实测】：`room_controller.dart` L517–518 `errorMessage = '进房失败:$e'` → `room_screen.dart` L272 塞进**本该显示"3 个人在"的副标题位置**，用 `bodyMedium` 次要灰字，**无错误色、无图标、无重试入口、无 maxLines**。

**规范依据**【实证】：
- 结构只回答两个问题：「**What went wrong? How does the user fix that problem?**」（[Google 技术写作课](https://developers.google.com/tech-writing/error-messages)）
- 按严重度选载体：「**toast notifications, or banners** can be used for issues needing minimal user interaction, whereas **modal dialogs**... should be reserved for **severe errors**」（[NN/g](https://www.nngroup.com/articles/error-message-guidelines/)）
- 「**Hide or minimize the use of obscure error codes**; show them for technical diagnostic purposes only.」（同上）
- 不甩锅：避免 invalid/illegal/incorrect ——「The proper usage of any system lies with its creators and not with the system's users」（同上）
- **避免幽默**（高频错误下会迅速变刺耳）（同上）
- 「**never use exclusively color or animation** to indicate errors」（同上，全球约 3.5 亿色觉障碍者）

#### 异常 → 人话映射表

| 技术异常 | 用户看到 | 动作 |
|---|---|---|
| `SocketException` / `ClientException` | **连不上网络** ／ 检查一下 WiFi 或流量？ | 「重试」 |
| `TimeoutException` | **服务器没应答** ／ 可能网络不稳 | 「重试」 |
| HTTP 401/403 | **身份过期了** ／ 重新进一次 | 「重新登录」 |
| HTTP 5xx | **服务器出问题了** ／ 不是你的错，稍后再试 | 「重试」 |
| 缺少 `LIVEKIT_*` | **语音服务没配置好** | 「查看设置」（仅开发者模式显示详情） |
| 敲门超时 | **没人应门** ／ 稍后再敲 | 「再敲一次」 |
| 未分类 | **进不去房间** ／ 稍后再试 | 「重试」+ 折叠详情 |

**文案格式**：`{发生了什么}` 换行 `{怎么办}`。**都不超过 15 个字。**

#### 展示位置分级

| 严重度 | 载体 | 位置 | 例子 |
|---|---|---|---|
| 轻（可自愈） | **不提示** | — | <1 s 的抖动重连 |
| 中（进行中） | **顶部 banner**，`surfHigh` 底 + 品牌色进度条 | 标题下方，**不挤压布局** | "重新连接中…" |
| 重（阻断） | **居中卡片**，占据成员区 | 房间主区 | "进不去房间" + 重试按钮 |
| 致命 | **Dialog** | 覆盖 | 仅用于需用户决策的情形 |

**绝不使用**：`_RoomHeader` 的副标题位（当前做法）。

#### 断线重连的时间节奏

【实证】依据 [NN/g 响应时间三档](https://www.nngroup.com/articles/response-times-3-important-limits/) 与 [Progress Indicators](https://www.nngroup.com/articles/progress-indicators/)（spinner **仅适用 2–10 秒**，超过 10 秒用户无法判断系统是否还活着）：

| 时长 | 表现 |
|---|---|
| < 1 s | **不提示**（避免过早报错） |
| 1–10 s | 顶部 banner「重新连接中…」+ 循环指示 |
| **> 10 s** | **必须换态**：显示已重试时长/次数 + **手动重试** + **退出房间**出口 |

**离线时保留房间骨架**（成员、圈名）而非白屏 —— 【实证】[Material 1 Offline states](https://m1.material.io/patterns/offline-states.html)：「It's better to **load something than nothing**, while explaining that the internet connection is limited」。

#### 错误码

【实证】Google 要求「Log the error codes」，NN/g 要求默认隐藏。**两者不矛盾**：码存在、可复制给客服，但**默认折叠**。

**原始异常 `toString()` 永不直接呈现。** 开发者模式下可展开查看完整堆栈。

---

## 4. 动效规范

**这是长时间挂机的界面。本节的默认答案是"不动"。**

### 4.1 三条铁律

**铁律 1：静息态必须零 Ticker。**
【实证】无活跃 `Ticker` 且无 `markNeedsPaint` 时，无人调用 `scheduleFrame`，引擎不出帧（§2.4）。
→ **不是把幅度设为 0 继续空转，是 `controller.stop()`。**

**铁律 2：只有状态真的变了才动。**
【实证】Apple HIG Always On：「aim to make **infrequent, subtle updates**」，体育 app 应**只在比分变化时更新**。

**铁律 3：idle 期只用非位移属性。**
【实证】WCAG 2.1 SC 2.3.3 把 **color / blurring / opacity** 排除在"运动动画"之外。
→ **明暗呼吸可以，位移/缩放/视差不行。**

### 4.2 动效清单

| 位置 | 时长 | 曲线 | 触发 | 静息开销 |
|---|---|---|---|---|
| 说话环起振 | 120 ms | `easeOut` | speaking = true | 0 |
| **说话环回落** | **500 ms** | `easeIn` | speaking = false（Telegram 实证值） | 0 |
| 头像缩放 1.0→1.06 | 160 ms | `easeOutCubic` | 同上 | 0 |
| 状态文字交叉淡入 | 180 ms | `linear` | 状态变化（Telegram 实证值） | 0 |
| 成员进/离场 | 300 ms | `easeOutCubic` | 成员变化 | 0 |
| 座位重排 | 400 ms | `easeOutCubic` | 人数变化 | 0 |
| 页面转场 | 250 ms | `easeInOutCubic` | 导航 | 0 |
| banner 进出 | 200 ms | `easeOut` | 错误/重连 | 0 |
| **炉火呼吸** | **4.5 s 周期** | `sin`（**不是** `easeInOut` 反复） | 常驻 | **见 §4.3** |

**为什么呼吸用 `sin` 不用 `easeInOut` 往复**（来自 `hearth/SPEC.md` §4.2，是个好判断）：`easeInOut` 在端点停留太久，看起来**像喘气**。`sin` 才是均匀的呼吸。

**呼吸幅度必须克制**：亮度 0.82↔1.0，半径 ±3%。**这是长时间注视的界面，不要做成脉冲灯。**

### 4.3 炉火呼吸：唯一的常驻动画，必须分档

这是全文唯一允许常驻的动画，因此必须有降级。仓库 `hearth/SPEC.md` §3.1 已设计了三档时钟，我认为是对的：

| 档位 | 进入条件 | 重绘节流 | 呼吸周期 |
|---|---|---|---|
| `active` | 有人说话 / 粒子存活 / 3 s 内有事件 | 不节流（跟 vsync） | 4.5 s |
| `calm` | 静息 ≥ 3 s | ≥ 80 ms（≈12 fps） | 4.5 s |
| `deepIdle` | 静息 ≥ 90 s | ≥ 160 ms（≈6 fps） | 6.5 s（更"睡着"） |

**必须诚实的一点**（SPEC 里也写明了）：**节流省的是 raster+paint，不是 vsync。** ticker 运行时引擎仍走 vsync 回调。**完全停 ticker 才是真零。**

【判断】因此建议**增加第四档**：静息 ≥ 5 min → **`frozen`：`ticker.stop()`，保持最后一帧**。挂机十几小时的场景，绝大部分时间应该落在这一档。这一档才真正兑现"静息态接近零开销"的硬约束。

**并且必须提供用户可见的总开关**【实证】WCAG 2.2 SC 2.2.2 要求超过 5 秒的自动动画提供暂停机制，且**多个动效元素应有单一统一控制**。设置页加一项「**减少动效**」，开启后：炉火静止、说话态只用 color/opacity 变化（**保留可辨性，不是关掉反馈** —— 这是 MDN 对 `prefers-reduced-motion` 的官方做法：把 scale 脉冲**替换为** opacity dissolve，降级而非移除）。

### 4.4 绝对不要动的地方

- ❌ 底部按钮的常驻脉冲/呼吸
- ❌ 头像的常驻旋转（Discord 那个旋转环是**第三方主题**加的，不是原生 —— §1.5）
- ❌ 背景的持续位移/视差
- ❌ 未读圆点的闪烁
- ❌ 任何"为了显得活泼"的装饰动画

### 4.5 优雅停止

【实证】Apple HIG Always On：「**Gracefully transition motion to a resting state; don't stop it instantly.**」

> 【实测】当前 `speaking_ripple.dart` L42–43 是 `_controller.stop()` 硬停 —— **波纹会在任意相位突然定格**。应改为**播放到当前周期结束**或**在 500 ms 内衰减到 0** 后再停 ticker。这也正好与 Telegram 的 500 ms 回落一致。

---

## 5. 实现前必须知道的三条硬约束

### 5.1 拿不到音量幅度 —— 这条会砍掉一半的可视化方案

【实测】链条完全确定：
- `rtc_service.dart` L29：`Stream<Set<String>> get speakingIdentities` —— **只有一组 identity 字符串**
- `livekit_rtc_service.dart` L233：`_speaking.add(event.speakers.map((p) => p.identity).toSet())` —— **把 `audioLevel` 丢掉了**
- `room_controller.dart` L129：`Set<String> get speakingIds`
- `room_screen.dart` L429：`speaking: controller.speakingIds.contains(...)` —— **传给 UI 的是 bool**

**所以 Telegram 那套 `amplitude` 驱动的 blob，现在做不了。**

**但好消息是：数据源其实有。**【实测】我查了 `livekit_client-2.12.0/lib/src/core/room.dart` L880/L935：`p.audioLevel = speaker.level;` —— **LiveKit SDK 已经在维护 `Participant.audioLevel`，只是本项目没有向上暴露。**

【判断】**建议把 `speakingIdentities` 的类型从 `Stream<Set<String>>` 改为 `Stream<Map<String, double>>`（identity → level）。** 这是跨层改动（RTC 层 → controller → UI），不是 UI 层能自行补上的，但改动量很小，且**一次改动解锁全部幅度驱动的可视化**。

**在此之前**：说话态只能是开/关两态。§3.3 的数值表里凡涉及 `speech`（0–1 连续量）的，都需退化为 0/1，或**在客户端自行合成包络**（onset 快升、500 ms 衰减）—— 后者正是 `hearth` 原型的做法，且它在 SPEC §0 里诚实地标注了"这是合成的"。

### 5.2 没有 `lastSpokeAt`

【实测】`Member`（`models.dart` L27–53）只有 `userId / name / status / deviceCount`。§3.3 的静默分级（>2min / >10min）需要这个时间戳。**纯客户端可算**（监听 speaking 事件时记录），不需要服务端配合。

### 5.3 全库无 `RepaintBoundary`

【实测】`hearth/SPEC.md` §0 已记录这一事实，且指出「`ChangeNotifier` 一 notify 整层重建」。结合 §2.4 的官方要求，**任何自绘动画组件落地时必须补 `RepaintBoundary` 并走 `CustomPainter(repaint:)` 路径**。

现有 `speaking_ripple.dart` 的 `super(repaint: active ? progress : null)`（L71）**方向是对的** —— 这是个好底子，只是外层缺 `RepaintBoundary`。

---

## 6. 总结：只能改三件事的话

### 第一件：把 `ColorScheme` 补全，让品牌色真正出现在按钮上

**为什么是它**：这是**投入产出比最高的一条，改一处代码修两条硬伤**。

【实测】`theme.dart` L33–43 未定义 `secondaryContainer`，Flutter 回退到 `secondary`，而 `secondary` 被赋成了 presence 蓝 `#6FA8D0`。于是**挂断键浅蓝**和**底部切换器亮色高亮**是同一个 bug 的两个症状。

补上 `secondaryContainer: #2F2826`、`onSecondaryContainer: #F2EEE9`（以及 `primaryContainer` / `surfaceContainer*` 全家桶），两条硬伤同时消失，次级按钮回到中性暖灰，主麦克风按钮的 ember 立刻成为全屏唯一的实心品牌色块 —— **"品牌色一次都没出现"这个问题，本质上是它被淹没在了三个同样醒目的彩色按钮里。**

> 这一条**不改任何页面代码，不改任何布局**，风险最低，视觉收益最直接。

### 第二件：把背景从"紫底橙光"换成"暖底火心光"

**为什么是它**：它一次性解决"浑浊棕色"和"下方三分之二全空"两条。

【实测】现状 `#FF8A5C` @5% 叠在 `#121016` 上合成 `#1E161A` —— 冷紫底配暖橙光，色相相距约 100°，混出来必然是灰褐。**这不是审美偏好问题，是色彩数学。**

改成：底色换 §3.1 的暖中性阶（`bg #181210`，与品牌同色相 H≈39），光晕提纯为火心色 `#FF5A2A` 且中心 alpha 提到 0.18。合成结果 `#411F14` —— **暖、深、干净。**

同时把光晕从"顶部 -0.7 的偏心径向"移到**画面中心**，成员环绕它排布（§3.3 方案 A）。**大片空白就此变成"火塘"** —— 空白从缺陷变成了语义。仓库 `app/tool/hearth/shots/` 里的截图已经证明这个方向成立。

### 第三件：让错误不再撑破布局，也不再说黑话

**为什么是它**：这是**用户唯一会真正记恨的一条**。前两件是"不够好看"，这一件是"坏了"。

【实测】`errorMessage = '进房失败:$e'`（controller L518）→ 塞进无约束的 `Row` 子 `Text`（screen L261/263/272）→ **RIGHT OVERFLOWED BY 2014 PIXELS**。一条 bug 同时造成了截图上最刺眼的两个问题：**黄黑警示条**和**半截英文异常**。

改：异常按 §3.6 映射表转成人话；错误移出标题区、改用居中卡片或顶部 banner；`Column` 包 `Expanded`、`Text` 加 `maxLines`；原始异常收进开发者模式。

---

### 为什么是这三件，而不是别的

按"每单位改动带来的观感提升"排序，这三件的共同点是**都在修因，不在修果**：

- 第一件修的是 **token 层**（一个 ColorScheme 缺口辐射到所有次级按钮）
- 第二件修的是 **色彩系统的色相一致性**（底色与品牌色同源，之后所有叠加都不会脏）
- 第三件修的是 **数据流**（异常不经处理就进 UI）

相比之下，换字体、调间距、加动效这些都是**修果**：不改因，改完还会以别的形式冒出来。

**三件事的预计改动量**：第一件约 10 行；第二件约 30 行（tokens + 背景组件）；第三件约 60 行（映射函数 + 展示组件 + 布局约束）。**都不需要重写页面。**

---

## 附录 A：本文的证据强度分级

| 强度 | 来源类型 | 本文中的例子 |
|---|---|---|
| ★★★★★ | 开源生产代码 | Telegram `BlobDrawable` 全部常量；Flutter SDK `color_scheme.dart` L1099 |
| ★★★★★ | 本机实测 | 全部对比度数值；M3 tone 值（读 `material_color_utilities` 源码）；混色合成结果 |
| ★★★★ | 官方文档/规范 | WCAG、Apple HIG Always On、Flutter 性能文档、Gather 帮助中心 |
| ★★★ | 官方存档（产品已下线） | Clubhouse Notion（Wayback）、X Spaces Social Narrative（Wayback） |
| ★★ | 第三方拆解/媒体 | Discord `#3BA55D`（BetterDiscord 主题 CSS）、Clubhouse 三段结构 |
| ★ | 单一二手来源 | Zenly 5.0 交互细节（且与一手来源冲突，已标注） |

## 附录 A2：调研中被证伪／纠正的说法

**这些是本次调研最有价值的产出之一 —— 它们都是"听起来很对、传播很广、但查不到出处或与出处相反"的说法。**

| # | 流行说法 | 实际情况 |
|---|---|---|
| 1 | Clubhouse 说话者有"脉冲扩张环" | ❌ 可靠来源措辞只有 **thin grey circle** / **subtle ring**（静态），且被批"几乎看不见" |
| 2 | Clubhouse「Leave quietly」在右上角 | ❌ 在**左下角**（两个独立语种来源一致） |
| 3 | Clubhouse 发言者头像明显更大 | ❌ 无来源，且有反向证据（"看起来都一样"） |
| 4 | X Spaces 房内有紫色脉冲说话环 | ❌ 紫色 pulsing outline 是**时间线入口**，不是房内发言态 |
| 5 | Discord 说话环会旋转 | ❌ 旋转是 **BetterDiscord 主题作者加的**，非原生 |
| 6 | SharePlay 时参与者缩成小格 | ❌ Apple 未如此描述；实际靠 **PiP** + 各自独立播放控制 |
| 7 | 深色底上中文应该加粗 | ❌ **方向反了** —— halation 使反白字视觉变粗，屏幕上应"降"字重；印刷才相反 |
| 8 | Flutter 官方性能文档警告 BackdropFilter | ⚠️ 不准确 —— 官方性能页警告的是 `saveLayer`/`Opacity`/clipping；**BackdropFilter 的警告在 widget API 文档里**（我实测确认了后者） |
| 9 | clreq 建议行间距为字号 50%–100% | ❌ clreq §6.4 是 **`TBD` 空白占位章节** |
| 10 | 暗色模式护眼 | ❌ 同行评审显示疲劳指标**无显著差异**；浅色在视敏度/校对上反而更优 |
| 11 | 暗色模式显著省电 | ⚠️ 大幅夸大 —— 典型室内亮度（30–50%）下**只省 3%–9%** |
| 12 | Zenly 有头像涟漪/电量共享/睡眠态 | 【未找到可靠来源】—— 流传极广但无一手出处 |
| 13 | M2 的 15.8:1 是正文文字要求 | ⚠️ 是**基准表面的下限门槛**，非正文要求 |
| 14 | APCA 是 WCAG 3 的对比度算法 | ⚠️ WCAG 3 该处仍是占位符 `@@[to be determined]`；WCAG 2.2 是唯一正式标准 |

> 【判断】**第 7、8、10、11 条直接改写了我最初的草稿结论。** 这说明一件事：**设计规范里最危险的不是"不知道"，而是"以为自己知道"。** 本文所有【判断】标记的内容都应以同样的怀疑态度对待。

## 附录 B：明确"未找到可靠来源"清单

**不要在实现时把这些当事实引用：**

- Clubhouse：每行头像数；发言者头像更大；脉冲扩张环；静音图标所在角落；"Leave quietly"的造型/配色/emoji；房间人数上限（5,000 与 7,000 冲突）
- X Spaces：房内"正在说话"的环色/脉冲/缩放规格；新加入者徽章
- FaceTime：分格静音图标；活跃说话者的边框样式；控制条自动隐藏延时
- Discord：宫格重排断点；"+N"折叠规则；语音激活 dB 阈值与衰减；控制栏按钮顺序；断连红的官方 token
- Zenly：头像涟漪/光环、电量共享、睡眠状态（流传极广但无一手来源）；且 5.0 视觉方向的中文拆解与 TechCrunch 一手采访**互相冲突**
- 深色/OLED：`#000000` vs `#121212` 的**精确**功耗差；近黑灰阶 banding 测量数据；OLED 烧屏缓解条款；Android Ambient Mode 条款
- 中文排版：中文正文最小字号的硬性规定；中文正文 letter-spacing 推荐值；CJK 专属的 irradiation/反白变粗论述（Google 的 halation 说明未限定书写系统，图示均为拉丁）；中文字库厂商的可引用原文
- 无障碍：散光与光晕的**直接同行评审证据**（仅有一份 W3C 个人意见陈述，非研究）
- Liquid Glass：带实测对比度数字的专家分析；Reduce Motion 对其的具体作用
- 2025–26 趋势：Bento grid、噪点/颗粒纹理、"Quiet UI"作为被权威命名的趋势、拟物复兴、大圆角的具体数值

## 附录 C：抓取失败声明

以下来源在本轮调研中**无法取得正文**，相关论断一律标注"未找到可靠来源"而非补写：Dribbble（HTTP 202，疑反爬）、Behance（JS 渲染）、Mobbin（正文截断）、`m3.material.io`（JS 渲染 —— **已通过读 `material_color_utilities` 源码绕过**）、Apple HIG 部分页面（JS 渲染）、Medium 系（uxdesign.cc / uxplanet.org，Cloudflare 拦截，存档亦 403）。

## 附录 D：下一步建议

1. **先修 §3.0 的三个 bug**，再动视觉。
2. **用当前代码重新截图**，确认"顶部半透明状态切换器"是否仍存在（§3.3 存疑项）。
3. **改状态色前重跑** `app/tool/palette/optimize_status.dart` 做色盲仿真验证。
4. **`hearth` 原型已有 `measure_cpu.ps1`**，建议实测三档 + 新增 `frozen` 档的真实 CPU 占用，用数据确认"静息零开销"是否真的兑现。
5. **考虑把 `speakingIdentities` 升级为 `Map<String, double>`**（§5.1）—— 这一步不做，所有幅度驱动的可视化都只能是合成的。
