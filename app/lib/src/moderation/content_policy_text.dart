/// 内容规范文案。
///
/// 首次启动的同意页和设置里的「再看一遍」读的是同一份来源,
/// 免得两边文案漂移 —— 审核员会逐条对着看。
///
/// ## 本地化状态(施工中)
///
/// 文案已全部进 ARB,取用请走本文件的 [contentPolicyTexts] —— 它按当前
/// 界面语言返回整套文案。下面那批 `kContentPolicy*` 常量是**迁移期的遗留**:
/// `ui/content_policy_screen.dart` 仍在 `const Text(...)` 里直接引用它们,
/// 那个文件不在本批次范围内,现在删常量会让它编不过。
///
/// 待 `content_policy_screen.dart` 改用 [contentPolicyTexts] 之后,
/// **整批 `kContentPolicy*` 常量连同这段说明一起删掉** ——
/// 同一句话留两份来源迟早会漂,这是已知债,不是设计。
library;

import 'package:flutter/widgets.dart';

import '../../l10n/gen/app_localizations.dart';

/// 规范里的一条。[title] 是小标题,[body] 是正文。
typedef ContentPolicyPoint = ({String title, String body});

/// 按当前界面语言取整套内容规范文案。
///
/// 条目顺序是**固定**的:零容忍 → 本人负责 → 违规移除 → 你手上有工具。
/// 这四条对应 App Store 审核指南 1.2 明确要求的四件事,别增删也别换序。
class ContentPolicyTexts {
  const ContentPolicyTexts._(this._t);

  factory ContentPolicyTexts.of(BuildContext context) =>
      ContentPolicyTexts._(AppLocalizations.of(context));

  final AppLocalizations _t;

  String get title => _t.policyTitle;

  String get summary => _t.policySummary;

  String get agreeLabel => _t.policyAgree;

  String get declineLabel => _t.policyDecline;

  List<ContentPolicyPoint> get points => <ContentPolicyPoint>[
        (title: _t.policyZeroToleranceTitle, body: _t.policyZeroToleranceBody),
        (title: _t.policyOwnContentTitle, body: _t.policyOwnContentBody),
        (title: _t.policyRemovalTitle, body: _t.policyRemovalBody),
        (title: _t.policyToolsTitle, body: _t.policyToolsBody),
      ];
}

/// 语法糖,读起来像 `contentPolicyTexts(context).title`。
ContentPolicyTexts contentPolicyTexts(BuildContext context) =>
    ContentPolicyTexts.of(context);

// ─────────────────────────────────────────────────────────────
// 以下为迁移期遗留常量,见文件头说明。新代码一律别再引用。
// ─────────────────────────────────────────────────────────────

const String kContentPolicyTitle = '社区内容规范';

const String kContentPolicySummary = '这是给熟人小圈子用的语音空间。想让它一直待得住,下面几条要守住。';

/// 规范正文条目。覆盖 App Store 审核指南 1.2 要求的几件事:
/// 零容忍声明、用户对自己内容负责、违规者移除、以及用户手上有哪些工具。
const List<ContentPolicyPoint> kContentPolicyPoints = [
  (
    title: '对滥用行为零容忍',
    body: '骚扰、人身攻击、仇恨或歧视言论、色情内容、暴力内容、违法信息,一律不允许出现在这里。语音、文字、图片、位置都算,没有例外。',
  ),
  (
    title: '你对自己发布的内容负责',
    body: '你说出口、发出去、分享出去的每一条内容,责任都在你自己身上。加入一个圈子,就是接受这条。',
  ),
  (
    title: '违规者会被移除',
    body: '违规的人会被移出圈子;情节严重的会被永久禁止使用本服务。收到举报后,我们在 24 小时内处理完并给出结果。',
  ),
  (
    title: '你手上有工具',
    body: '任何时候都可以在本机屏蔽某个人,屏蔽后不再收到对方的任何内容。要举报,可以在成员列表里选那个人,也可以长按具体那条消息。',
  ),
];

/// 明确的肯定动作,不能写成「知道了」这类含糊说法。
const String kContentPolicyAgreeLabel = '我已阅读并同意';

const String kContentPolicyDeclineLabel = '不同意';
