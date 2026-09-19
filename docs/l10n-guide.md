# 本地化施工规范

> 内部文档。App Store 主语言为 English，而 App 原本全中文——
> 元数据语言与实际语言不符会被 Guideline 2.3.7 / 4.0 拒。

## 结论先行

- **中文是事实来源**。所有文案先有中文，英文由中文翻译而来。
- 模板文件 `lib/l10n/app_zh.arb`，英文 `lib/l10n/app_en.arb`。
- 生成物在 `lib/l10n/gen/`，**纳入版本控制**（CI 上 gen-l10n 万一没跑，
  构建会以「找不到 AppLocalizations」失败在一个与本地化无关的地方）。

## 范围：只翻译用户看得见的

**要翻译**

- 按钮、标题、提示、占位符、SnackBar、对话框
- 权限说明、错误提示（用户可能看到的那些）
- 举报理由、内容规范

**不翻译**

- 代码注释（本仓库注释极详尽，翻译它们没有收益）
- `developer_section.dart` 里的开发者模式文案——连点 7 次版本号才能进，
  普通用户与审核员都不会到达
- 调试日志、`assert` 消息、异常的 `toString()`
- 测试文件里的字符串

判断标准：**普通用户在正常使用路径上会看到吗？**

## 命名约定

`<区域><具体含义>`，小驼峰：

```
homeAddCircle          主屏幕 - 加个圈子
settingsServerUrl      设置页 - 服务器地址
reportReasonHarassment 举报 - 骚扰
e2eeCostNotice         端到端加密 - 代价说明
commonCancel           通用 - 取消
```

区域前缀用文件所在模块：`home` `room` `settings` `chat` `report`
`e2ee` `update` `p2p` `note` `common`。

## 两种上下文，两种写法

### 一、Widget 内（大多数情况）

```dart
// 前
label: const Text('加个圈子'),

// 后
label: Text(AppLocalizations.of(context).homeAddCircle),
```

⚠️ **`const` 必须去掉**——本地化字符串不是编译期常量。
漏掉会得到一个指向别处的编译错误。

### 二、拿不到 context 的地方

`enum` 的 label、顶层常量、纯逻辑类里的字符串。**不要**强行传 context
进模型层，那会把 UI 依赖渗进业务代码。

做法是：**模型只存语义 key，翻译在 UI 层做**。

```dart
// 前:enum 直接带中文
enum ReportReason {
  harassment('骚扰或人身攻击'),
  ...
  const ReportReason(this.label);
  final String label;
}

// 后:enum 只留标识,翻译查表放 UI 层
enum ReportReason { harassment, hateSpeech, ... }

// 在 UI 层(如 moderation_menus.dart):
String reportReasonLabel(BuildContext c, ReportReason r) {
  final t = AppLocalizations.of(c);
  return switch (r) {
    ReportReason.harassment => t.reportReasonHarassment,
    ReportReason.hateSpeech => t.reportReasonHateSpeech,
    ...
  };
}
```

⚠️ 改 enum 前先搜它的全部使用点，尤其是**测试**和**序列化**
（举报邮件正文、持久化的 JSON）。序列化必须用 `.name` 这类稳定标识，
**绝不能**用翻译后的文本——否则换个语言，存量数据就读不出来了。

## 带参数的字符串

```json
"homeKickedBy": "{who} 把你请出了房间",
"@homeKickedBy": {
  "placeholders": { "who": { "type": "String", "example": "管理员" } }
}
```

```dart
Text(AppLocalizations.of(context).homeKickedBy(name))
```

**不要**用字符串拼接绕过占位符——语序在不同语言里会变。

## 复数

中文没有复数变化，英文有。涉及数量时用 ICU：

```json
"roomMemberCount": "{count, plural, =0{没有人} other{{count} 人在里面}}"
```

英文：

```json
"roomMemberCount": "{count, plural, =0{Nobody here} =1{1 person} other{{count} people}}"
```

## 英文翻译的语气

产品语气是**克制、口语、不用力**。中文文案刻意避开了营销腔，
英文也要保持同样的调子。

| 中文 | ✅ 好 | ❌ 差 |
|---|---|---|
| 算了 | Never mind | Cancel |
| 加个圈子 | New circle | Create New Circle! |
| 挂着 | Stay open | Keep Alive |
| 没人时留句话 | Leave a note | Voice Message Feature |

避免：感叹号、标题式大写（Title Case 只用于按钮）、
「Powerful」「Seamless」这类词。

## 验收

改完任何一批，跑：

```bash
cd app
flutter gen-l10n          # 重新生成
flutter analyze lib test  # 必须零问题
flutter test              # 必须全绿
```

`lib/l10n/untranslated.json` 列出了英文缺失的键，**提交前必须为空**。

## 已建立的基础设施

- `app/l10n.yaml` — 配置
- `app/lib/l10n/app_zh.arb` — 中文（模板）
- `app/lib/l10n/app_en.arb` — 英文
- `app/lib/l10n/gen/` — 生成物
- `main.dart` — 已接 `localizationsDelegates`，
  系统语言不支持时**回落英文**（不是中文，因为商店主语言是 English）
