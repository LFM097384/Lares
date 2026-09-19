# ARB 重建任务 · 共享规范（所有 module agent 必读）

## 背景

Flutter 项目 `D:\Projects\Lares\app`。此前有 agent 把 `lib/src/` 下的中文 UI
字符串改成了 `AppLocalizations` 调用，但**没有写 ARB**。现在要从代码和
git diff 里把 ARB 重建出来。

**绝对不要修改 `lib/src/` 下的任何 Dart 文件。**
**绝对不要修改 `lib/l10n/app_zh.arb` 或 `app_en.arb`。**
你只写自己那两个 fragment 文件，由 orchestrator 统一合并。

## 中文原文从哪来（按优先级）

1. **`git diff`**：在 `D:\Projects\Lares` 下跑
   `git diff -- app/<你的源文件路径>`。被删掉的 `-` 行里就是原来的中文。
   例如：
   ```
   -  label: const Text('加个圈子'),
   +  label: Text(l10n.homeAddCircle),
   ```
   → `homeAddCircle` 的中文是 `加个圈子`。

2. **`lib/l10n/gen/app_localizations_zh.dart` 和 `_en.dart`**（当前工作区版本，
   **未提交**）。之前的 agent 手改过这两个生成物，里面已经有一部分 key 的
   完整中英文定义，形如：
   ```dart
   String get recordingStop => '停止录音';
   String recordingSomeoneRecording(String name) { return '「$name」正在录音'; }
   ```
   这些是**可信的已有译文**，直接采用（英文同理，见 `_en.dart`）。
   注意：`flutter gen-l10n` 会覆盖这些文件，所以必须搬进 ARB。

3. 如果两处都找不到某个 key 的原文：**不要编造**。按上下文写一个合理的中文，
   并在最终报告的 `uncertain` 列表里列出该 key + 你的依据。

## 输出：两个 JSON 文件

写到 `D:\Projects\Lares\app\.l10nwork\<GROUP>.zh.json` 和 `<GROUP>.en.json`。
`<GROUP>` 是下面 prompt 里指定的组名。

**两个文件都是扁平 JSON 对象，不要 `@@locale`**（orchestrator 会加）。

### zh fragment 格式

每个 key 一条值 + 一条 `@key` 元数据（description 必写，中文）：

```json
{
  "homeAddCircle": "加个圈子",
  "@homeAddCircle": {
    "description": "主屏幕上新建圈子的按钮"
  },
  "roomPeopleHere": "{count, plural, =0{没有人} other{{count} 人在里面}}",
  "@roomPeopleHere": {
    "description": "房间里的人数",
    "placeholders": {
      "count": { "type": "int" }
    }
  }
}
```

### en fragment 格式

**只有键和值，绝对不要任何 `@` 开头的条目。**

```json
{
  "homeAddCircle": "New circle",
  "roomPeopleHere": "{count, plural, =0{Nobody here} =1{1 person} other{{count} people}}"
}
```

## 占位符规则（gen-l10n 会严格校验，错了就编译不过）

分配给你的 key 清单里，标了 `CALL(...)` 的是**带参数**的，括号里是调用点的
实参表达式。你必须：

- **声明的 placeholder 数量 = 调用点实参数量**，一个不多一个不少。
- **顺序必须一致**：gen-l10n 按 ARB 里 `placeholders` 的**书写顺序**生成位置参数。
  例如 `CALL(online, waitingNames)` → placeholders 里第一个必须对应 online，
  第二个对应 waitingNames。
- placeholder 的**名字**可以自己起（有意义即可，调用点是位置传参），
  但 **type 必须对**：
  - 数字（计数、字节数、HTTP 状态码、秒数）→ `"type": "int"`
  - 文本（名字、版本号、错误文本）→ `"type": "String"`
- 用 ICU plural 的那个 placeholder **必须声明成 `int`**。
- 中英文两个文件里，**同一个 key 的占位符名字必须完全一致**。

判断实参类型看调用点表达式：`f.number ?? 0` / `code.length` / `count` /
`seconds` → int；`f.text ?? ''` / `m.name` / `state.info?.latestDisplay ?? ''`
→ String。拿不准就去源文件里看那个变量的声明。

## 复数

中文没有复数变化，但**如果英文侧要用 plural，中文侧也必须是 plural 结构**
（ARB 模板决定生成的方法签名）。中文可以所有分支写一样的话：

```json
"roomPeopleHere": "{count, plural, other{{count} 人在里面}}"
```

英文**必须**写全 ICU plural，不能只给一个形式：

```json
"roomPeopleHere": "{count, plural, =0{Nobody here} =1{1 person} other{{count} people}}"
```

只有在文案里真的出现「数量」且英文单复数会变时才用 plural。
纯粹把数字嵌进去、单复数不变的（比如「第 3 步」「HTTP 404」）用普通占位符就行。

## ICU / JSON 转义陷阱

- JSON 里换行写 `\n`，不要写真实换行。
- **带占位符或 plural 的消息里避免用英文撇号**（`'` 在 ICU 里是转义字符，
  会把后面的内容变成字面量）。`You're recording` 这种如果**该消息带占位符**，
  改写成 `You are recording` 或把撇号写成两个 `''`。
  不带任何占位符的纯字符串里，撇号可以正常用。
- 文案里要出现字面的 `{` `}` 时，用 `'{'` `'}'` 包起来。
- 中文标点（，。「」？：）直接写，不用转义。
- 严格合法 JSON：不能有尾逗号、不能有注释。

## 英文语气（硬性要求）

产品语气是**克制、口语、不用力**。中文原文刻意避开了营销腔，英文要保持同样调子。

| 中文 | ✅ | ❌ |
|---|---|---|
| 算了 | Never mind | Cancel |
| 加个圈子 | New circle | Create New Circle! |
| 挂着 | Stay open | Keep Alive |
| 没人时留句话 | Leave a note | Voice Message Feature |

禁止：感叹号；滥用 Title Case（只有按钮文字可以首字母大写，句子式文案用
sentence case）；`Powerful` `Seamless` `Effortlessly` `Unlock` 这类营销词。
错误提示要像人话，不要像堆栈跟踪。

## 已有的 9 个 key（不要重复产出，除非在你的清单里）

`appTitle` `commonCancel` `commonConfirm` `commonDone` `homeAddCircle`
`homeAddCircleHint` `homePasteInvite` `homeKickedBy` `homeKickedByAdmin`

它们已在 ARB 中，值分别是：炉灵/Lares、算了/Never mind、好/OK、完成/Done、
加个圈子/New circle、比如:家人、死党群、考研搭子 / Family, close friends,
study group…、有邀请链接?粘贴进圈 / Have an invite link? Paste it、
你被{who}请出了房间 / {who} removed you from the room、管理员 / An admin。
**如果这些 key 出现在你的清单里，按上面的原值照抄输出**（保证合并后一致）。

## 自检（交付前必做）

1. 你的两个 JSON 文件都是合法 JSON——用
   `Get-Content x.json -Raw | ConvertFrom-Json` 验证，别只靠眼睛看。
2. zh 和 en 的**键集合完全相同**（en 少一个键，untranslated.json 就会有内容，
   验收不过）。en 里没有任何 `@` 条目。
3. 清单里的每个 key 都出现了，一个都不能少。
4. 每个带 `CALL(...)` 的 key，placeholders 数量和顺序都对上了。

## 报告

返回一个简短总结：产出多少 key、哪些 key 的原文是**推断**而非从 diff/gen
直接拿到的（列出来）、发现的任何可疑情况（同一文案两个 key 名、疑似笔误的
key 名、无法还原的原文）。
