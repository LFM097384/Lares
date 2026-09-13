/// 内容规范的中文文案,集中放这一处。
///
/// 首次启动的同意页和设置里的「再看一遍」读的是同一份常量,
/// 免得两边文案漂移 —— 审核员会逐条对着看。
library;

const String kContentPolicyTitle = '社区内容规范';

const String kContentPolicySummary = '这是给熟人小圈子用的语音空间。想让它一直待得住,下面几条要守住。';

/// 规范正文条目。覆盖 App Store 审核指南 1.2 要求的几件事:
/// 零容忍声明、用户对自己内容负责、违规者移除、以及用户手上有哪些工具。
const List<({String title, String body})> kContentPolicyPoints = [
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
