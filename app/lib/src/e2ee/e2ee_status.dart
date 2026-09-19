/// 圈子 E2EE 的**对外状态**与纯决策逻辑。
///
/// 这一层刻意不 import livekit_client、不 import shared_preferences ——
/// 「这次通话到底加没加密」是一道纯逻辑题,必须能被单测完整覆盖。
/// UI 也只读这里的枚举,不去猜。
library;

/// 一个圈子在**当前这台设备、当前这次连接**下的真实加密状态。
///
/// 纪律(安全功能的第一条):这个枚举描述的是**事实**,不是意图。
/// 用户开了开关 ≠ `encrypted`。任何一个前提不成立,都必须落到一个
/// 明确的「没加密 + 为什么」状态上,绝不允许含糊。
enum E2EEStatus {
  /// 这个圈子没开 E2EE(默认)。服务端可转录、炉灵可用。
  disabled,

  /// 真的加密了:平台支持、口令齐备、密钥已装好。
  encrypted,

  /// 开了,但**本平台不支持** E2EE。这次通话是明文。
  ///
  /// 为什么不直接拒绝进房:LiveKit 在平台不支持时 `room.connect()` 会抛
  /// `LiveKitE2EEException`,硬开等于把用户挡在房间外面。所以照常进,
  /// 但把「没加密」喊出来 —— 静默降级才是安全灾难,响亮降级不是。
  platformUnsupported,

  /// 开了,但没有这个圈子的口令(鉴权模式是 none/token,或口令还没填)。
  /// 密钥无从派生,这次通话是明文。
  noPasscode,

  /// 开了、平台支持、口令也有,但密钥装载失败(底层 frame cryptor 出错)。
  /// 这次通话是明文。
  failed,
}

/// ## 本地化状态(2026-xx 施工中)
///
/// [E2EEStatus] 本身**就是**语义 key —— 枚举值只存标识,不带任何文案,
/// 所以这一层不需要改造。按 `docs/l10n-guide.md` 的分层纪律,翻译查表
/// 放在 UI 层,不把 `BuildContext` 渗进这个纯逻辑文件。
///
/// 下面的 [E2EEStatusX.shortLabel] / [E2EEStatusX.explanation] 与
/// [kE2EECostNotice] 是**待迁移的遗留中文**:它们的消费方
/// (`ui/widgets/e2ee_badge.dart`、`ui/home_screen.dart`)以及
/// `test/e2ee_degrade_test.dart` 都不在本批范围内,现在删掉会让仓库编译不过。
/// 保留原样,由负责那些文件的后续改动一次性切换。
///
/// ARB 键与枚举值的对应关系(UI 层照此写 switch):
///
/// | E2EEStatus          | shortLabel                          | explanation                          |
/// |---------------------|-------------------------------------|--------------------------------------|
/// | disabled            | `e2eeShortLabelDisabled`            | `e2eeExplanationDisabled`            |
/// | encrypted           | `e2eeShortLabelEncrypted`           | `e2eeExplanationEncrypted`           |
/// | platformUnsupported | `e2eeShortLabelPlatformUnsupported` | `e2eeExplanationPlatformUnsupported` |
/// | noPasscode          | `e2eeShortLabelNoPasscode`          | `e2eeExplanationNoPasscode`          |
/// | failed              | `e2eeShortLabelFailed`              | `e2eeExplanationFailed`              |
///
/// [kE2EECostNotice] 对应 `e2eeCostNotice`。
extension E2EEStatusX on E2EEStatus {
  /// 是否**真的**加密了。UI 的锁图标只认这一个判断。
  bool get isEncrypted => this == E2EEStatus.encrypted;

  /// 用户开了开关却没能加密 —— 必须让他看见的状态。
  bool get isBrokenPromise => switch (this) {
        E2EEStatus.platformUnsupported ||
        E2EEStatus.noPasscode ||
        E2EEStatus.failed =>
          true,
        E2EEStatus.disabled || E2EEStatus.encrypted => false,
      };

  /// 一句话标题(房间页角标 / 圈子列表用)
  String get shortLabel => switch (this) {
        E2EEStatus.disabled => '未加密',
        E2EEStatus.encrypted => '端到端加密',
        E2EEStatus.platformUnsupported => '未加密(平台不支持)',
        E2EEStatus.noPasscode => '未加密(缺圈口令)',
        E2EEStatus.failed => '未加密(密钥装载失败)',
      };

  /// 完整解释。措辞纪律:降级态一律以「这次通话没有加密」开头,
  /// 不给任何「大概加了吧」的想象空间。
  String get explanation => switch (this) {
        E2EEStatus.disabled =>
          '这个圈子没有开启端到端加密。服务器能听到内容,炉灵也能用。',
        E2EEStatus.encrypted =>
          '这个圈子的语音和消息在你的设备上加密,密钥由圈口令派生、从不上传服务器。',
        E2EEStatus.platformUnsupported =>
          '这次通话没有加密:这个平台不支持端到端加密。'
              '你开了开关,但这台设备做不到 —— 换用手机或桌面客户端才能真正加密。',
        E2EEStatus.noPasscode =>
          '这次通话没有加密:密钥要从这个圈子的口令派生,而当前服务器档案里'
              '没有这个圈子的口令。去「设置 → 服务器」把圈口令填上。',
        E2EEStatus.failed =>
          '这次通话没有加密:密钥装载失败(底层加密模块没能初始化)。'
              '退出重进试试;一直失败就先别在这个圈子谈敏感内容。',
      };
}

/// 纯决策:三个前提 -> 一个事实。
///
/// 顺序是刻意的 —— 先问「用户想不想要」,再问「平台能不能做到」,
/// 最后才问「有没有料」。这样报给用户的原因永远是**最根本**的那一条,
/// 而不是一串次生问题。
E2EEStatus resolveE2EEStatus({
  required bool enabled,
  required bool platformSupported,
  required bool hasPasscode,
}) {
  if (!enabled) return E2EEStatus.disabled;
  if (!platformSupported) return E2EEStatus.platformUnsupported;
  if (!hasPasscode) return E2EEStatus.noPasscode;
  return E2EEStatus.encrypted;
}

/// 开启 E2EE 的代价(产品已决定,写死在这里当唯一文案源)。
/// 开关旁边必须原样展示 —— 用户点下去之前就该知道自己失去什么。
const String kE2EECostNotice =
    '开启后:服务器看不到任何内容,因此**无法转录**,'
    '「AI 炉灵」在这个圈子里也**不可用**(炉灵只在不开加密的圈子工作)。';
