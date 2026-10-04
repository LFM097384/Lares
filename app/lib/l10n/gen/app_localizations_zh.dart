// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => '炉灵';

  @override
  String get chatCollapse => '收起消息';

  @override
  String get chatComposerHint => '说点什么,或者放张图';

  @override
  String get chatEmpty => '这里很安静。想说的话、一张图,都可以放这儿。';

  @override
  String get chatExpand => '展开消息';

  @override
  String get chatImageMissing => '这张图没收到';

  @override
  String get chatImageOpen => '图片,点开看大图';

  @override
  String get chatImagePickFailed => '没能打开图片';

  @override
  String get chatImagePickUnsupported => '当前版本暂不支持选图';

  @override
  String get chatImageSendFailed => '这张图没发出去';

  @override
  String get chatImageViewer => '图片大图,点空白处关闭';

  @override
  String get chatImageViewerClose => '关闭大图';

  @override
  String chatRemaining(int left) {
    String _temp0 = intl.Intl.pluralLogic(
      left,
      locale: localeName,
      other: '还能写 $left 个字',
    );
    return '$_temp0';
  }

  @override
  String get chatSend => '发送';

  @override
  String get chatSendFailed => '没发出去';

  @override
  String get chatSendImage => '发一张图';

  @override
  String get chatUnread => '有新消息';

  @override
  String get commonCancel => '算了';

  @override
  String get commonClose => '关掉';

  @override
  String get commonConfirm => '好';

  @override
  String get commonCopied => '复制好了';

  @override
  String get commonCopy => '复制';

  @override
  String get commonDone => '完成';

  @override
  String get commonGotIt => '知道了';

  @override
  String get commonListSeparator => '、';

  @override
  String get commonNoThanks => '不用了';

  @override
  String get commonSave => '存下';

  @override
  String get e2eeConfirmBody =>
      '加密只在**圈里每个人都打开**时才管用。只有你开着,别人听不见你说话,你也听不见他们的 —— 声音进不了同一把锁。先和圈里的人说一声,大家一起开。';

  @override
  String get e2eeConfirmTitle => '圈里每个人都要开';

  @override
  String get e2eeConfirmYes => '都说好了,开吧';

  @override
  String get e2eeCostNotice =>
      '开启后:服务器看不到任何内容,因此**无法转录**,「AI 炉灵」在这个圈子里也**不可用**(炉灵只在不开加密的圈子工作)。';

  @override
  String get e2eeEveryoneNotice => '圈里每个人都得打开,否则你和他们互相听不见。';

  @override
  String get e2eeKeyLocalNotice => '密钥从你的圈口令派生,只在设备本地,绝不上传服务器。';

  @override
  String get e2eeTitle => '端到端加密';

  @override
  String get homeAddCircle => '加个圈子';

  @override
  String get homeAddCircleConfirm => '建一个';

  @override
  String get homeAddCircleHint => '比如:家人、死党群、考研搭子';

  @override
  String get homeAvailable => '我有空';

  @override
  String get homeAvailableOffDesc => '挂出去,让圈友知道你现在能聊 · 长按可挑圈子';

  @override
  String homeAvailableOnDesc(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n 个圈子看得到 · 谁先来就跟谁聊,进去之后其他圈子就看不到了',
    );
    return '$_temp0';
  }

  @override
  String get homeAvailablePickBody =>
      '挂出去之后,这几个圈子的人会看到你有空。\n谁先来找你,就跟谁聊 —— 那一刻其他圈子就看不到你了。';

  @override
  String get homeAvailablePickConfirm => '就这几个';

  @override
  String get homeAvailablePickTitle => '对哪几个圈子可见';

  @override
  String get homeCircleEmpty => '暂无人在,进去等等看?';

  @override
  String homeCircleOnline(int online) {
    String _temp0 = intl.Intl.pluralLogic(
      online,
      locale: localeName,
      other: '$online 个人在',
    );
    return '$_temp0';
  }

  @override
  String homeCircleOnlineAndWaiting(int online, String waitingNames) {
    String _temp0 = intl.Intl.pluralLogic(
      online,
      locale: localeName,
      other: '$online 个人在 · $waitingNames 有空',
    );
    return '$_temp0';
  }

  @override
  String homeCircleOnlineWithNames(int online, String names) {
    String _temp0 = intl.Intl.pluralLogic(
      online,
      locale: localeName,
      other: '$online 个人在 · $names',
    );
    return '$_temp0';
  }

  @override
  String homeCircleWaitingOnly(String waitingNames) {
    return '$waitingNames 有空,等人来找';
  }

  @override
  String get homeDeleteCircle => '删除这个圈子';

  @override
  String get homeEmptyRoomHint => '点左边圈子,一键进圈';

  @override
  String get homeInviteBody => '把这段链接发给朋友,对方点一下就进圈(也可在 App 里粘贴):';

  @override
  String get homeInvitedCircleFallback => '朋友的圈';

  @override
  String get homeInviteFriends => '邀请朋友进圈';

  @override
  String get homeInviteFriendsDesc => '复制邀请链接发给朋友';

  @override
  String get homeInviteIncludePasscode => '把口令也放进链接';

  @override
  String get homeInviteIncludePasscodeE2ee =>
      '⚠️ 这个圈开了端到端加密 —— 口令就是解密密钥。链接被转发或截图,通话内容就不再是私密的。';

  @override
  String get homeInviteIncludePasscodeHint => '对方不用再单独问你要口令了';

  @override
  String homeInviteTitle(String circleName) {
    return '邀请朋友进「$circleName」';
  }

  @override
  String get homeJoinCircle => '进圈';

  @override
  String homeKickedBy(String who) {
    return '你被$who请出了房间';
  }

  @override
  String get homeKickedByAdmin => '管理员';

  @override
  String get homeKnockModeConfirmBody =>
      '这是整个圈子的设置,不是只对你 —— 改完圈里每个人都跟着变。圈里任何人也都能再改回去。';

  @override
  String get homeKnockModeConfirmTitle => '这会改掉所有人的';

  @override
  String get homeKnockModeConfirmYes => '就这么改';

  @override
  String get homeKnockModeDesc => '开启后,圈外人进来需要里面的人放行';

  @override
  String get homeKnockModeEveryoneNotice => '整个圈子共用这一个设置 —— 你改了,所有人都改了。';

  @override
  String get homeKnockModeOff => '敲门模式:关(点一下开启)';

  @override
  String get homeKnockModeOn => '敲门模式:开(点一下关闭)';

  @override
  String get homePasteInvite => '有邀请链接?粘贴进圈';

  @override
  String get homePasteInviteHint => 'lares://circle/… 或圈子 id';

  @override
  String get homePasteInvitePasscode => '圈子口令(朋友给了就填)';

  @override
  String get homePasteInvitePasscodeHint => '没有就空着,进不去的时候还能补';

  @override
  String get homePasteInviteTitle => '粘贴邀请链接';

  @override
  String get homePrimaryCircleAlready => '已是主圈子';

  @override
  String get homePrimaryCircleAlreadyDesc => '小组件、快捷设置、托盘点一下进的就是这个圈';

  @override
  String get homePrimaryCircleSet => '设为主圈子';

  @override
  String get homePrimaryCircleSetDesc => '主屏小组件点一下,直接进这个圈';

  @override
  String get homePrimaryCircleTooltip => '主圈子 · 小组件一键加入';

  @override
  String get homeRename => '改昵称';

  @override
  String get homeRenameConfirm => '就叫这个';

  @override
  String get homeRenameHint => '昵称';

  @override
  String get homeRenameTitle => '圈子里叫你什么?';

  @override
  String get moderationBlock => '屏蔽这个人';

  @override
  String get moderationBlockHint => '听不到他的声音,也不再显示他的消息';

  @override
  String get moderationBlockShort => '屏蔽';

  @override
  String get moderationNoUserId => '拿不到身份标识';

  @override
  String get moderationSuggestBlockBody => '屏蔽后你不会再听到他的声音,也不会看到他的消息。';

  @override
  String get moderationSuggestBlockTitle => '顺手屏蔽他?';

  @override
  String get moderationUnblock => '解除屏蔽';

  @override
  String get moderationUnblockHint => '他的声音和消息会重新出现';

  @override
  String noteListen(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '听 $count 条留言(长按留一条)',
    );
    return '$_temp0';
  }

  @override
  String get noteRecordHint => '长按留语音便签';

  @override
  String get p2pCaveatHasTurn => '另外约两三成的网络组合直连不了,会走你配的中继服务器。';

  @override
  String get p2pCaveatNoTurn => '另外约两三成的网络组合直连不了,需要在设置里填一台中继服务器(TURN)。';

  @override
  String get p2pCaveats => '⚠️ 只能一对一,而且这里没有文字、图片和加密标记 —— 那些功能依赖服务器。';

  @override
  String p2pCharCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 字符',
    );
    return '$_temp0';
  }

  @override
  String get p2pCodeCopied => '连接码已复制,发给对方吧';

  @override
  String get p2pCodeSendBack => '② 把这段回给对方';

  @override
  String get p2pCodeSendToPeer => '① 把这段发给对方';

  @override
  String get p2pConnect => '连接';

  @override
  String get p2pCopy => '复制';

  @override
  String get p2pErrorCorrupted => '连接码不完整,可能复制时少了一截';

  @override
  String get p2pErrorNotLaresCode => '这段文字不是 Lares 连接码,再确认一下?';

  @override
  String get p2pErrorVersionMismatch => '对方的 Lares 版本和你差太多,更新一下再试';

  @override
  String get p2pErrorWrongKind => '贴反了 —— 这是发起码,该贴的是对方回给你的应答码';

  @override
  String get p2pNoServerBody =>
      '你和对方互传一段连接码,声音就在两台设备之间直接走。\n连接码怎么传都行 —— 微信、短信、当面念都可以。';

  @override
  String get p2pNoServerTitle => '不经过任何服务器';

  @override
  String get p2pPasteFromClipboard => '从剪贴板粘贴';

  @override
  String get p2pPasteIncomingLabel => '① 贴入对方发来的码';

  @override
  String get p2pPasteReplyLabel => '② 贴入对方回给你的码';

  @override
  String get p2pPreparing => '正在准备连接信息…';

  @override
  String get p2pRoleAnswererBody => '把对方发来的连接码贴进来,生成一段回给他。';

  @override
  String get p2pRoleAnswererTitle => '对方发我码了';

  @override
  String get p2pRoleMeshBody =>
      '连接码由服务器转交,不用手动传。会自动挑一个人转发声音 —— 优先挑电脑,因为它插着电、网更稳。';

  @override
  String get p2pRoleMeshTitle => '圈里的人一起(最多 4 人)';

  @override
  String get p2pRoleOffererBody => '生成一段连接码发给对方,等对方回一段给你。';

  @override
  String get p2pRoleOffererTitle => '我先开口';

  @override
  String get p2pStatusClosed => '已断开';

  @override
  String get p2pStatusConnected => '连上了,可以说话';

  @override
  String get p2pStatusConnecting => '正在连接…';

  @override
  String get p2pStatusFailed => '没能连上';

  @override
  String get p2pStatusWaitingForPeer => '等对方那边动作';

  @override
  String get p2pTitle => '直连对话';

  @override
  String get policyAgree => '我已阅读并同意';

  @override
  String get policyDecline => '不同意';

  @override
  String get policyOwnContentBody =>
      '你说出口、发出去、分享出去的每一条内容,责任都在你自己身上。加入一个圈子,就是接受这条。';

  @override
  String get policyOwnContentTitle => '你对自己发布的内容负责';

  @override
  String get policyRemovalBody =>
      '违规的人会被移出圈子;情节严重的会被永久禁止使用本服务。收到举报后,我们在 24 小时内处理完并给出结果。';

  @override
  String get policyRemovalTitle => '违规者会被移除';

  @override
  String get policySummary => '这是给熟人小圈子用的语音空间。想让它一直待得住,下面几条要守住。';

  @override
  String get policyTitle => '社区内容规范';

  @override
  String get policyToolsBody =>
      '任何时候都可以在本机屏蔽某个人,屏蔽后不再收到对方的任何内容。要举报,可以在成员列表里选那个人,也可以长按具体那条消息。';

  @override
  String get policyToolsTitle => '你手上有工具';

  @override
  String get policyZeroToleranceBody =>
      '骚扰、人身攻击、仇恨或歧视言论、色情内容、暴力内容、违法信息,一律不允许出现在这里。语音、文字、图片、位置都算,没有例外。';

  @override
  String get policyZeroToleranceTitle => '对滥用行为零容忍';

  @override
  String recordingAlsoRecording(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '房间里还有 $count 人在录音',
    );
    return '$_temp0';
  }

  @override
  String get recordingConsentEveryoneNotified => '房间里每个人都会立刻收到通知,知道是你在录。';

  @override
  String get recordingConsentLocalOnly => '声音会被转写成文字,只保存在本地设备,不会上传。';

  @override
  String recordingConsentMemberCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '现在房间里有 $count 个人。',
    );
    return '$_temp0';
  }

  @override
  String get recordingConsentPersistentNotice => '录音期间,所有人的界面上都会一直显示录音提示,关不掉。';

  @override
  String get recordingConsentReconsider => '再想想';

  @override
  String get recordingConsentStart => '开始录音';

  @override
  String get recordingConsentTitle => '开始录音?';

  @override
  String recordingElapsedHours(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: '已录 $hours 小时',
    );
    return '$_temp0';
  }

  @override
  String recordingElapsedHoursMinutes(int hours, int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: '$hours 小时',
    );
    String _temp1 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes 分钟',
    );
    return '已录 $_temp0 $_temp1';
  }

  @override
  String recordingElapsedMinutes(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '已录 $minutes 分钟',
    );
    return '$_temp0';
  }

  @override
  String recordingElapsedSeconds(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: '已录 $seconds 秒',
    );
    return '$_temp0';
  }

  @override
  String get recordingListSeparator => ',';

  @override
  String get recordingNobodyRecording => '房间里没有人在录音';

  @override
  String get recordingNoticeAlreadyInProgress => '已有录音流程进行中,请先停止当前录音';

  @override
  String recordingNoticeArmingTimeout(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: '$seconds 秒',
    );
    return '未能确认房间已被告知录音开始,已取消录音(等待服务器回执超过 $_temp0)';
  }

  @override
  String get recordingNoticeCircleIdEmpty => '圈子 ID 为空,无法开始录音';

  @override
  String get recordingNoticeDisconnected => '信令连接已断开,正在尝试恢复;若无法恢复将自动停止录音';

  @override
  String recordingNoticeGraceExpired(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: '$seconds 秒',
    );
    return '信令中断超过 $_temp0仍未恢复,无法确认房间知情,已自动停止录音';
  }

  @override
  String get recordingNoticeRemovedFromRoom => '本机已被移出房间,已自动停止录音以免房间不知情';

  @override
  String get recordingNoticeServerMarkedInactive =>
      '服务器已将本机标记为未在录音,已自动停止录音以免房间不知情';

  @override
  String get recordingNoticeSignalingSilent => '长时间未收到信令消息,正在重新确认录音状态';

  @override
  String get recordingNoticeStateOutOfSync => '信令状态不同步,正在重新确认录音状态';

  @override
  String recordingSemanticsLabel(String body) {
    return '录音提示:$body';
  }

  @override
  String recordingSeveralRecording(String name, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$name 等 $count 人正在录音',
    );
    return '$_temp0';
  }

  @override
  String recordingSomeoneRecording(String name) {
    return '「$name」正在录音';
  }

  @override
  String get recordingStatusUnconfirmed => '录音状态未确认';

  @override
  String get recordingStop => '停止录音';

  @override
  String get recordingYouAreRecording => '你正在录音';

  @override
  String get reportAccepted => '已提交,我们会在 24 小时内处理';

  @override
  String get reportAction => '举报';

  @override
  String get reportActionHint => '把情况告诉我们,24 小时内处理';

  @override
  String get reportDeliveryBody =>
      '我们已经帮你把举报写好并打开邮件。确认后点发送即可。\n要是邮件没有自动打开,内容也已经放进剪贴板了 —— 手动新建一封,粘贴后发到:';

  @override
  String get reportDeliveryFollowUp => '收到后 24 小时内处理完,结果也回这个邮箱。';

  @override
  String get reportDeliveryTitle => '最后一步:把邮件发出来';

  @override
  String reportDialogTitle(String targetName) {
    return '举报「$targetName」';
  }

  @override
  String get reportMessageAction => '举报这条消息';

  @override
  String get reportNoteHint => '补充说明(可不填)';

  @override
  String get reportPickReason => '挑一条最贴近的。我们会看完再回你。';

  @override
  String get reportReasonHarassment => '骚扰或人身攻击';

  @override
  String get reportReasonHateSpeech => '仇恨或歧视言论';

  @override
  String get reportReasonIllegal => '违法或危险行为';

  @override
  String get reportReasonOther => '其他';

  @override
  String get reportReasonSexualContent => '色情或性暗示内容';

  @override
  String get reportReasonSpam => '垃圾信息或刷屏';

  @override
  String get reportReasonViolence => '暴力或血腥内容';

  @override
  String get reportSubmit => '提交举报';

  @override
  String get roomAloneHere => '就你一个在,等等看?';

  @override
  String get roomBackToRoom => '回到房间';

  @override
  String get roomBlockedSemantics => '已屏蔽';

  @override
  String get roomEmpty => '房间里还空着,坐一会儿?';

  @override
  String get roomErrorGeneric => '出错了';

  @override
  String get roomJoining => '正在进去…';

  @override
  String get roomPasscodeHint => '口令';

  @override
  String get roomPasscodeRetry => '再试一次';

  @override
  String get roomPasscodeSavedElsewhere =>
      '口令记下了。这台服务器当前用的是共享令牌,得去设置里改成按圈口令才会生效。';

  @override
  String get roomJoinLatencyTooltip => '本次进房耗时';

  @override
  String get roomKickBody => '对方会被移出房间(可以稍后再进来,不是封禁)';

  @override
  String get roomKickConfirm => '请出';

  @override
  String get roomKickMember => '请出房间';

  @override
  String get roomKickMemberHint => '对方可以稍后再进来,不是封禁';

  @override
  String roomKickTitle(String name) {
    return '把「$name」请出房间?';
  }

  @override
  String get roomKnockAllow => '让他进';

  @override
  String get roomKnockDeny => '先不';

  @override
  String get roomKnocking => '敲门中,等里面的人应门…';

  @override
  String roomKnockWants(String name) {
    return '$name 想进来';
  }

  @override
  String get roomLeave => '离开';

  @override
  String get roomLocationMap => '位置共享地图';

  @override
  String get roomMute => '静音';

  @override
  String roomPeopleHere(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个人在',
    );
    return '$_temp0';
  }

  @override
  String get roomStatusBusy => '在忙';

  @override
  String get roomStatusEars => '耳朵在';

  @override
  String get roomStatusFree => '随时聊';

  @override
  String get roomStatusPick => '我的状态';

  @override
  String get roomUnmute => '说话';

  @override
  String get settingsAuthModeCircle => '按圈口令';

  @override
  String get settingsAuthModeNone => '不需要口令';

  @override
  String get settingsAuthModeToken => '共享令牌';

  @override
  String get settingsBackground => '后台运行保障';

  @override
  String get settingsBackgroundDenied => '请在系统设置里允许忽略电池优化';

  @override
  String get settingsBackgroundGranted => '已允许后台运行(国产 ROM 建议再开「自启动」)';

  @override
  String get settingsBackgroundIos => '在房间里时 iOS 会自动以后台音频保活,无需设置';

  @override
  String get settingsBackgroundSub => '挂机不掉线:电池优化白名单 / 后台音频';

  @override
  String get settingsContentPolicy => '社区内容规范';

  @override
  String get settingsContentPolicySub => '看看我们对内容的要求';

  @override
  String get settingsDnd => '免打扰时段';

  @override
  String get settingsDndConfirm => '就这样';

  @override
  String get settingsDndFrom => '从';

  @override
  String get settingsDndOff => '未开启(敲门提示不受打扰)';

  @override
  String get settingsDndTo => '到';

  @override
  String get settingsDndTurnOff => '关闭';

  @override
  String get settingsGroupCircle => '这个圈子';

  @override
  String get settingsGroupMe => '我';

  @override
  String get settingsGroupSafety => '待得住';

  @override
  String get settingsGroupSound => '声音与打扰';

  @override
  String get settingsHomeWidget => '把圈子放到主屏幕';

  @override
  String get settingsHomeWidgetAndroidStep1 => '长按主屏幕空白处';

  @override
  String get settingsHomeWidgetAndroidStep2 => '点「小组件」';

  @override
  String get settingsHomeWidgetAndroidStep3 => '找到「炉灵」';

  @override
  String get settingsHomeWidgetAndroidStep4 => '拖到主屏幕上';

  @override
  String get settingsHomeWidgetGuideTitle => '怎么加到主屏幕';

  @override
  String get settingsHomeWidgetIosStep1 => '长按主屏幕空白处,等图标开始抖';

  @override
  String get settingsHomeWidgetIosStep2 => '点左上角的「+」';

  @override
  String get settingsHomeWidgetIosStep3 => '搜「炉灵」';

  @override
  String get settingsHomeWidgetIosStep4 => '选个尺寸,左右滑能换';

  @override
  String get settingsHomeWidgetIosStep5 => '点「添加小组件」,再点右上角「完成」';

  @override
  String get settingsHomeWidgetPhoneOnly => '主屏幕小组件是手机上的功能,这台设备上没有';

  @override
  String get settingsHomeWidgetSub => '主屏幕点一下,直接进主圈子';

  @override
  String get settingsIdentityExportBody =>
      '在那台设备上打开同一个地方,粘进下面的框里。里面只有你的身份和名字,没有任何圈子口令。';

  @override
  String get settingsIdentityExportTitle => '把这串给另一台设备';

  @override
  String get settingsIdentityImportAction => '用这个身份';

  @override
  String get settingsIdentityImportBad => '这串东西看着不像身份码,再复制一次试试';

  @override
  String get settingsIdentityImportHint => 'lares-id-v1:…';

  @override
  String get settingsIdentityImportRestart =>
      '身份存下了,但要重开一次 Lares 才算数 —— 现在这条连接还挂在旧身份上。';

  @override
  String get settingsIdentityImportTitle => '或者,粘一串过来';

  @override
  String get settingsLanguage => '语言';

  @override
  String get settingsLanguageSystem => '跟随系统';

  @override
  String get settingsMyName => '我的名字';

  @override
  String get settingsMyNameHint => '昵称';

  @override
  String get settingsMyNameTitle => '想让大家怎么称呼你?';

  @override
  String get settingsNoiseEnhanced => '增强';

  @override
  String get settingsNoiseOff => '关闭';

  @override
  String get settingsNoiseStandard => '标准';

  @override
  String get settingsNoiseSuppression => '降噪';

  @override
  String get settingsPickPrimaryCircle => '哪个是主圈子?';

  @override
  String get settingsPrimaryCircle => '主圈子';

  @override
  String get settingsPrimaryCircleNone => '还没有圈子';

  @override
  String settingsPrimaryCircleSub(String name) {
    return '$name\n小组件、快捷设置、托盘一键进的就是它';
  }

  @override
  String get settingsRecording => '录音与转写';

  @override
  String get settingsRecordingOff => '默认关闭;开启时所有人都会看到提示';

  @override
  String get settingsRecordingOn => '正在录音 —— 房间里所有人都看得到提示';

  @override
  String get settingsRecordingStart => '开始录音';

  @override
  String get settingsRecordingStartFailed => '录音未能开始';

  @override
  String get settingsRecordingStop => '停止录音';

  @override
  String get settingsSameIdentity => '另一台设备也用这个身份';

  @override
  String get settingsSameIdentitySub => '电脑和手机算同一个人,不会互相挤掉';

  @override
  String get settingsServer => '服务器与口令';

  @override
  String get settingsServerAdd => '添加服务器';

  @override
  String get settingsServerAuthLabel => '需要口令';

  @override
  String get settingsServerBiometricFailed => '没验证通过,没打开';

  @override
  String get settingsServerBiometricReason => '查看或修改服务器口令';

  @override
  String get settingsServerBuiltIn => '默认(打包内置)';

  @override
  String get settingsServerCircleId => '圈子 ID';

  @override
  String get settingsServerCirclePasscode => '圈口令';

  @override
  String settingsServerCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '共 $count 个服务器',
    );
    return '$_temp0';
  }

  @override
  String get settingsServerDefaultLabel => '我的服务器';

  @override
  String get settingsServerDelete => '删除';

  @override
  String get settingsServerEdit => '编辑';

  @override
  String get settingsServerEditTitle => '编辑服务器';

  @override
  String get settingsServerListTitle => '服务器';

  @override
  String get settingsServerName => '名字';

  @override
  String get settingsServerNameHint => '例:家里的 VPS';

  @override
  String get settingsServerPlaintextWarning =>
      '口令以明文保存在本机设置里,不是加密存储。别人拿到这台设备的文件就能读到 —— 共用设备请谨慎。';

  @override
  String get settingsServerSave => '保存';

  @override
  String get settingsServerSaved => '已保存,重启 App 生效';

  @override
  String get settingsServerTest => '测试连接';

  @override
  String get settingsServerTokenHint => '服务器的 LARES_AUTH_TOKEN';

  @override
  String get settingsServerUrl => '地址';

  @override
  String get settingsTitle => '设置';

  @override
  String get settingsWifiOnlyHq => '仅 WiFi 下高音质';

  @override
  String get settingsWifiOnlyHqSub => '移动网络自动降码率,省流量';

  @override
  String get updateAndroidInstallerOpened =>
      '系统安装器已打开。若提示「禁止安装未知应用」，请在弹出的设置里允许「炉灵」安装应用后重试。';

  @override
  String get updateAutoCheckSubtitle => '静默检查，发现新版本才提示；安装永远需要你点确认。';

  @override
  String get updateAutoCheckTitle => '启动时检查更新';

  @override
  String get updateCheckNow => '立即检查';

  @override
  String updateCurrentVersion(String version) {
    return '当前 v$version';
  }

  @override
  String get updateDownload => '下载更新';

  @override
  String get updateDownloading => '下载中…';

  @override
  String updateDownloadWithSize(String size) {
    return '下载更新（$size MB）';
  }

  @override
  String get updateErrAndroidInstallerNotOpened => '系统安装器未能打开。';

  @override
  String updateErrAndroidLaunchFailed(String detail) {
    return '拉起安装器失败：$detail';
  }

  @override
  String get updateErrChecksum => '文件校验和不匹配，可能已损坏或被篡改，已删除。';

  @override
  String updateErrDownloadFailed(String detail) {
    return '下载失败：$detail';
  }

  @override
  String updateErrDownloadHttp(int code) {
    return '下载失败（HTTP $code）。';
  }

  @override
  String get updateErrDownloadTimeout => '下载超时。';

  @override
  String updateErrGithubRefused(int code) {
    return 'GitHub 拒绝了这次请求（$code）。稍后再试。';
  }

  @override
  String updateErrHttp(int code) {
    return '检查失败（HTTP $code）。';
  }

  @override
  String get updateErrInstallFailed => '安装失败。';

  @override
  String get updateErrIosCannotInstall => 'iOS 无法在 App 内安装更新包。';

  @override
  String get updateErrIosNoSelfUpdate =>
      'iOS 无法在 App 内自我更新：请通过 TestFlight 更新，或用电脑重新侧载新版本 .ipa。';

  @override
  String get updateErrMalformed => '发布信息格式异常，无法解析。';

  @override
  String get updateErrNoAsset => '这个平台没有可下载的安装包。';

  @override
  String get updateErrNoReleases => '仓库还没有发布任何版本。';

  @override
  String get updateErrNotDownloaded => '还没有下载好的安装包。';

  @override
  String get updateErrOffline => '连不上网络，暂时查不了更新。';

  @override
  String get updateErrRateLimited => 'GitHub 接口调用次数用完了（未登录每小时 60 次）。稍后再试。';

  @override
  String updateErrRateLimitedUntil(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: 'GitHub 接口调用次数用完了（未登录每小时 60 次），约 $minutes 分钟后恢复。稍后再试。',
    );
    return '$_temp0';
  }

  @override
  String updateErrSizeMismatch(int expected, int actual) {
    return '下载的文件大小不对（期望 $expected 字节，实际 $actual），已删除。';
  }

  @override
  String get updateErrTimeout => '网络超时，暂时查不了更新。';

  @override
  String updateErrUnknownVersion(String version) {
    return '无法识别当前版本号（$version）';
  }

  @override
  String updateErrWinLaunchFailed(String detail) {
    return '安装启动失败：$detail';
  }

  @override
  String get updateErrWinNoInstallDir => '找不到安装目录，请手动下载新版本覆盖安装。';

  @override
  String get updateErrWinNotWritable =>
      '安装目录不可写（通常是装在 Program Files 且未以管理员身份运行）。请手动下载新版本，或把 Lares 移到用户目录后再试。';

  @override
  String updateErrWinPackageInvalid(String name) {
    return '更新包内容异常（未找到 $name），已中止，当前版本未被改动。';
  }

  @override
  String updateErrWinProbeFailed(String detail) {
    return '无法确认安装目录是否可写：$detail';
  }

  @override
  String updateErrWinUnzipFailed(String detail) {
    return '更新包解压失败：$detail';
  }

  @override
  String get updateGotIt => '知道了';

  @override
  String get updateInstallAndRestart => '安装并重启';

  @override
  String get updateInstallConfirmBody =>
      'Lares 会关闭，替换程序文件后自动重新启动。\n如果你正在圈子里说话，会先断开连接。';

  @override
  String get updateInstallConfirmTitle => '现在安装更新？';

  @override
  String get updateInstallNow => '立即安装';

  @override
  String get updateInstallStarted => '已开始安装。';

  @override
  String get updateIntegrityFull => '完整性：文件大小一致，且 SHA-256 与发布说明中公布的校验和匹配。';

  @override
  String get updateIntegrityNone => '完整性：未能校验（发布信息未提供大小）。';

  @override
  String get updateIntegritySizeOnly =>
      '完整性：仅核对了文件大小与 GitHub 声明一致（发布说明未提供校验和，无法验证内容真伪；传输安全依赖 HTTPS）。';

  @override
  String get updateLater => '稍后';

  @override
  String get updateMacosDragToApps =>
      '已在访达中为你打开新版本：\n1. 退出正在运行的 Lares；\n2. 把新的 lares_app.app 拖进「应用程序」，选择替换；\n3. 首次打开若提示「无法验证开发者」，右键点图标选「打开」。';

  @override
  String get updateNextStepsTitle => '接下来这样做';

  @override
  String get updateNoReleaseNotes => '（这个版本没有写更新说明）';

  @override
  String get updateNoticeIos =>
      'iOS 无法在 App 内更新。若用 TestFlight 安装，请到 TestFlight 更新；若是免费签名侧载，签名 7 天到期后需要用电脑重新侧载新版本 .ipa。';

  @override
  String get updateNoticeMacos => 'macOS 需要你手动把新版本拖进「应用程序」完成替换，下载后会自动打开访达。';

  @override
  String get updateNoticeNoAssetForPlatform =>
      '这个版本没有为当前平台提供可下载的安装包，请到 GitHub Releases 页面手动获取。';

  @override
  String get updateNoticeWeb => 'Web 版随服务端更新：强制刷新页面（Ctrl/Cmd + Shift + R）即可。';

  @override
  String get updateQuitting => '正在退出以完成更新…';

  @override
  String get updateRevealFolder => '打开所在文件夹';

  @override
  String updateStatusAvailable(String version) {
    return '发现新版本 v$version';
  }

  @override
  String get updateStatusCheckFailed => '检查失败。';

  @override
  String get updateStatusChecking => '正在检查…';

  @override
  String get updateStatusDownloading => '正在下载更新包…';

  @override
  String get updateStatusIdle => '还没检查过更新。';

  @override
  String get updateStatusReady => '下载完成，可以安装了。';

  @override
  String get updateStatusUpToDate => '已是最新版本。';

  @override
  String get updateTitle => '版本与更新';

  @override
  String get updateVersionUnknown => '当前版本未知';

  @override
  String get updateWinRestarting => '即将退出并完成更新，几秒后会自动重新启动。';

  @override
  String get widgetNoCircle => '还没有圈子';

  @override
  String get widgetNoCircleHint => '打开 App 建一个圈';

  @override
  String get widgetNobodyHere => '暂无人在,进去等等看?';

  @override
  String widgetPeopleHere(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个人在',
    );
    return '$_temp0';
  }

  @override
  String widgetPeopleHereWithNames(int count, String names) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个人在 · $names',
    );
    return '$_temp0';
  }

  @override
  String get settingsJoinWithMicOn => '进圈时打开麦克风';

  @override
  String get settingsJoinWithMicOnSub => '只在你自己点进圈时生效,断线重连不会替你开麦';

  @override
  String get settingsPushNotify => '有人进圈时通知我';

  @override
  String get settingsPushNotifySub => '点通知里的「加入」直接进圈。每个圈可以单独关掉';

  @override
  String get homeCirclePushOn => '这个圈的通知:开';

  @override
  String get homeCirclePushOff => '这个圈的通知:关';

  @override
  String get pushPermissionExplain => '朋友进圈时给你发个通知,点一下就能加入。';

  @override
  String get pushPermissionNotNow => '算了';

  @override
  String get pushPermissionTurnOn => '开启';

  @override
  String get roomMicPermissionDenied => '麦克风没打开:没有权限。去系统设置里允许炉灵使用麦克风';

  @override
  String get roomMicUnmuteFailed => '麦克风没打开,再点一下试试';

  @override
  String get roomMicMuteFailed => '没能静音,麦克风还开着';

  @override
  String get homeAddCircleNameLabel => '圈名';

  @override
  String get homeAddCirclePasscodeLabel => '口令';

  @override
  String get homeAddCirclePasscodeHelper => '已经帮你想好一个,也可以自己改。至少 8 个字符';

  @override
  String get homeAddCirclePasscodeTooShort => '口令至少要 8 个字符';

  @override
  String get homeAddCircleShuffle => '换一个';

  @override
  String get homeCircleCreatedShare => '圈子建好了,把链接发给要进来的人吧';

  @override
  String get homeOwnerKeyNote => '圈主钥匙只在这台设备上';

  @override
  String get homeOwnerKeyNoteDesc => '换手机或删掉 App,就没法再管这个圈子了';

  @override
  String get homeOwnerPending => '还在向服务器登记这个圈子';

  @override
  String get homeChangePasscode => '换口令';

  @override
  String get homeChangePasscodeDesc => '旧口令马上作废,除了你所有人都会被请出去';

  @override
  String get homeChangePasscodeConfirmTitle => '换成这个新口令?';

  @override
  String homeChangePasscodeConfirmBody(String passcode) {
    return '新口令:$passcode\n\n旧口令马上作废。除了你,圈里的人都会被请出去,拿到新链接的人才进得来。';
  }

  @override
  String get homeChangePasscodeConfirmYes => '就换它';

  @override
  String get homeChangePasscodeDone => '换好了。把新链接发给还要留下的人';

  @override
  String get homeDissolveCircle => '解散圈子';

  @override
  String get homeDissolveCircleDesc => '所有人都会被请出去,这个圈子从此没有了';

  @override
  String homeDissolveConfirmTitle(String name) {
    return '解散「$name」?';
  }

  @override
  String get homeDissolveConfirmBody =>
      '这一步撤不回来:所有人马上被请出去,以后谁也进不来,这个圈子也没法再建回来。\n\n确定的话,在下面输入圈名。';

  @override
  String get homeDissolveConfirmYes => '解散';

  @override
  String get homeCircleDissolved => '圈子已被圈主解散';

  @override
  String get homeOwnerErrNotOwner => '这台设备上的圈主钥匙对不上,没办成';

  @override
  String get homeOwnerErrTimeout => '服务器没回话,稍后再试';

  @override
  String get homeOwnerErrGeneric => '没办成,稍后再试';

  @override
  String get e2eeOwnerSwitchDesc => '给全圈一起开关:每个人进圈时自动跟着变,不会出现一半人听不见。';

  @override
  String get e2eeManagedOn => '圈主开了端到端加密';

  @override
  String get captionsToggle => '字幕';

  @override
  String get captionsToggleOn => '关闭字幕';

  @override
  String get captionsToggleOff => '打开字幕:把其他人说的话显示成文字';

  @override
  String captionsBanner(String names) {
    return '正在为 $names 生成字幕 · 语音经阿里云识别';
  }

  @override
  String get captionsBannerStop => '点此停止';

  @override
  String get captionsStoppedSnack => '这次不再为别人生成字幕,下次进圈恢复';

  @override
  String get captionsNameSeparator => '、';

  @override
  String get captionsPanelTitle => '字幕';

  @override
  String get captionsPanelEmpty => '有人说话时,文字会出现在这里';

  @override
  String captionsProviders(String names) {
    return '$names 正在提供字幕';
  }

  @override
  String captionsNotProviding(String names) {
    return '$names 未开启字幕';
  }

  @override
  String get captionsAlone => '房里还没有其他人';

  @override
  String get captionsYou => '我';

  @override
  String get captionsBannerSelf => '正在把你的话转成字幕 · 语音经阿里云识别';

  @override
  String get captionsArchiveBanner => '本圈已开启转写记录 · 语音经阿里云识别';

  @override
  String get captionsArchiveSelfOff => '你的话这次不转写';

  @override
  String get captionsArchiveStoppedSnack => '这次不再转写你的话,下次进圈恢复';

  @override
  String captionsNotTranscribed(String names) {
    return '$names 未转写';
  }

  @override
  String captionsBotName(String name) {
    return '$name(机器人)';
  }

  @override
  String get chatBotBadge => '机器人';

  @override
  String get settingsGroupCaptions => '实时字幕';

  @override
  String get settingsCaptionsProvide => '为需要字幕的人生成字幕';

  @override
  String get settingsCaptionsProvideSub =>
      '只在房里有人需要字幕(或圈主开了转写记录)、且你开着麦时,你的语音才会发往阿里云识别成文字;不录音。关掉后你的话也不进转写记录';

  @override
  String get settingsCaptionsE2eeCloud => '加密的圈子也允许';

  @override
  String get settingsCaptionsE2eeCloudSub =>
      '加密圈的语音本来不出你的手机。打开后,有人需要字幕时你的语音会发往阿里云识别;识别出的文字仍加密传给对方';

  @override
  String get transcriptTitle => '转写记录';

  @override
  String get transcriptEmpty => '还没有记录。圈主开启后,大家说的话会在这里留下文字';

  @override
  String get transcriptLoadError => '没能读到记录,稍后再试';

  @override
  String get transcriptRetry => '重试';

  @override
  String get transcriptLoadMore => '更早的记录';

  @override
  String get transcriptClear => '清空记录';

  @override
  String get transcriptClearConfirmTitle => '清空这个圈子的转写记录?';

  @override
  String get transcriptClearConfirmBody => '服务器上的全部记录会被删除,所有人都看不到了。这一步撤不回';

  @override
  String get transcriptClearConfirmBodyE2ee =>
      '每位成员设备上的记录都会被删除,还没送达的密文也会作废。这一步撤不回';

  @override
  String get transcriptClearConfirm => '清空';

  @override
  String get transcriptCleared => '已清空';

  @override
  String get transcriptClearFailed => '没清空成功,稍后再试';

  @override
  String get transcriptLocalOnlyNote => '加密圈:记录只存在这台设备上,服务器只转交看不懂的密文';

  @override
  String get transcriptEntryDesc => '看看大家说过的话';

  @override
  String get transcriptEntryDescE2ee => '只存在这台设备上';

  @override
  String get transcriptOwnerSwitchDesc =>
      '把大家说的话识别成文字并保存在服务器上,直到你清空或删除圈子。语音经阿里云识别;不想被记录的人可以在设置里关掉「为需要字幕的人生成字幕」';

  @override
  String get transcriptOwnerSwitchDescE2ee =>
      '把大家说的话识别成文字,加密后只存在各人设备上。语音会送到阿里云识别';

  @override
  String get transcriptE2eeWarnTitle => '在加密圈里开启转写记录?';

  @override
  String get transcriptE2eeWarnBody =>
      '开启后,大家的语音会送到阿里云识别成文字 —— 这一步语音离开了手机。识别出的文字会加密,服务器只转交它看不懂的密文;记录由每位成员各自存在自己的设备上';

  @override
  String get transcriptE2eeWarnConfirm => '开启';

  @override
  String get botTokensTitle => '机器人';

  @override
  String get botTokensEntryDesc => '让外部程序读写这个圈子的文字';

  @override
  String get botTokensDesc => '持有令牌的机器人可以读取转写记录,并以「机器人」身份发消息、发字幕、播放语音。随时可以吊销';

  @override
  String get botTokensDescE2ee => '这是加密圈:服务器看不懂内容,机器人读不到也发不了消息';

  @override
  String get botTokensEmpty => '还没有机器人';

  @override
  String get botTokenCreate => '新建';

  @override
  String get botTokenCreateTitle => '给机器人起个名字';

  @override
  String get botTokenNameHint => '比如:会议纪要';

  @override
  String get botTokenShownOnce => '令牌只显示这一次,关掉就再也看不到了。请现在复制并妥善保存';

  @override
  String get botTokenRevoke => '吊销';

  @override
  String get botTokenRevokeBody => '吊销后,用这个令牌的机器人立刻失去访问权限';

  @override
  String botTokenCreatedTitle(String name) {
    return '「$name」的令牌';
  }

  @override
  String botTokenRevokeTitle(String name) {
    return '吊销「$name」?';
  }

  @override
  String get pluginTitle => '插件';

  @override
  String get pluginEntryDesc => '给这个圈子装小工具';

  @override
  String get pluginAdd => '添加插件';

  @override
  String get pluginEmpty => '还没装插件';

  @override
  String get pluginInstall => '装上';

  @override
  String get pluginUninstall => '卸载';

  @override
  String get pluginDetails => '详情';

  @override
  String get pluginSettings => '设置';

  @override
  String pluginUninstallTitle(String name) {
    return '卸载「$name」?';
  }

  @override
  String get pluginUninstallBody => '插件的设置和共享状态会一起删掉';

  @override
  String pluginInstalled(String name) {
    return '「$name」装好了';
  }

  @override
  String get pluginAlreadyInstalled => '已经装了';

  @override
  String get pluginFocusName => '专注学习';

  @override
  String get pluginFocusDesc => '一起专注,番茄钟和排行榜';

  @override
  String get pluginAddFromUrl => '从网址安装';

  @override
  String get pluginAddPaste => '粘贴 manifest';

  @override
  String get pluginManifestUrlHint => 'https://…/manifest.json';

  @override
  String get pluginManifestJsonHint => '把 manifest.json 的内容粘贴到这里';

  @override
  String pluginMeta(String version, String author) {
    return '$version · $author';
  }

  @override
  String get pluginHasWebhook => '带服务端回调(webhook)';

  @override
  String get pluginSecretsOnce => '下面的内容只显示这一次,关掉就看不到了。先复制存好。';

  @override
  String get pluginToken => '插件 token';

  @override
  String get pluginWebhookSecret => 'Webhook 密钥';

  @override
  String pluginSettingsOf(String name) {
    return '$name 设置';
  }

  @override
  String get pluginErrAlreadyInstalled => '这个插件已经装过了';

  @override
  String get pluginErrTooMany => '一个圈子最多装 10 个插件';

  @override
  String get pluginErrBadManifest => 'manifest 不对';

  @override
  String get pluginErrFetch => '取不到这个 manifest';

  @override
  String get pluginErrTimeout => '服务器没回应,稍后再试';

  @override
  String get pluginErrNotOwner => '只有圈主能管插件';

  @override
  String pluginErrGeneric(String reason) {
    return '没成功:$reason';
  }

  @override
  String get pluginErrHttpsOnly => '网址要以 https:// 开头';

  @override
  String get pluginErrBadJson => '这不是一段有效的 JSON';

  @override
  String get pluginConsentTitle => '打开插件';

  @override
  String pluginConsentFrom(String origin) {
    return '来自 $origin';
  }

  @override
  String get pluginConsentPermsHeader => '它想要:';

  @override
  String get pluginConsentNoPerms => '它不需要任何权限';

  @override
  String get pluginConsentE2eeWarning => '注意:这个圈子是端到端加密的,但插件的共享状态和回调对服务器可见。';

  @override
  String get pluginConsentAllow => '允许';

  @override
  String get pluginPlatformUnsupported => '此平台暂不支持内嵌插件';

  @override
  String get pluginOpenInBrowser => '在浏览器打开';

  @override
  String get pluginPermCircleRead => '看圈子名字和设置';

  @override
  String get pluginPermMembersRead => '看房间里有谁、谁进出';

  @override
  String get pluginPermChatRead => '读聊天消息';

  @override
  String get pluginPermChatSend => '以你的名义发聊天消息';

  @override
  String get pluginPermCaptionsRead => '读实时字幕';

  @override
  String get pluginPermCaptionsSend => '发字幕';

  @override
  String get pluginPermTranscriptRead => '读转写记录';

  @override
  String get pluginPermStateRead => '读插件的共享状态';

  @override
  String get pluginPermStateWrite => '改插件的共享状态';

  @override
  String get pluginPermStorage => '在本机存数据';

  @override
  String get pluginPermFocusRead => '读专注状态';

  @override
  String get focusTitle => '专注学习';

  @override
  String get focusPhaseFocus => '专注中';

  @override
  String get focusPhaseBreak => '休息一下';

  @override
  String get focusPhaseIdle => '等待开始';

  @override
  String get focusPhaseIdleHint => '一起安静地做事 · 番茄钟可选';

  @override
  String focusRound(int round, int rounds) {
    return '第 $round/$rounds 轮';
  }

  @override
  String get focusStart => '开始专注';

  @override
  String get focusStop => '结束';

  @override
  String get focusBoard => '排行榜';

  @override
  String get focusLock => '锁定专注';

  @override
  String get focusLocked => '已锁定';

  @override
  String get focusUnlock => '解除锁定';

  @override
  String get focusLockTitle => '锁定专注?';

  @override
  String get focusLockBody =>
      '会把屏幕固定在 Lares 上,其他 App 和通知暂时打不开。想退出时,同时按住「返回」和「概览」键(或用系统提示的手势)。休息或结束时会自动解除。';

  @override
  String get focusLockConfirm => '锁定';

  @override
  String get focusLockCancel => '算了';

  @override
  String get focusLockFailed => '没能锁定,这台设备可能不支持屏幕固定';

  @override
  String get focusBadgeFocus => '专注中';

  @override
  String focusBadgeAway(String time) {
    return '离开 $time';
  }

  @override
  String get focusBadgeBreak => '休息';

  @override
  String focusNoticeAway(String name) {
    return '$name 离开了专注';
  }

  @override
  String focusNoticeBack(String name) {
    return '$name 回来了';
  }

  @override
  String focusNoticeBackAfter(String name, String time) {
    return '$name 回来了 · 离开 $time';
  }

  @override
  String focusNoticeLeftEarly(String name) {
    return '$name 提前离开了专注';
  }

  @override
  String focusNoticePhaseFocus(int round) {
    return '第 $round 轮专注开始';
  }

  @override
  String get focusNoticePhaseBreak => '休息一下,聊两句吧';

  @override
  String get focusNoticeStarted => '番茄钟开始了';

  @override
  String get focusNoticeStopped => '番茄钟结束了,辛苦了';

  @override
  String get focusNoticeEnded => '圈主结束了专注';

  @override
  String get focusErrorForbidden => '只有圈主能开始或结束番茄钟';

  @override
  String get focusErrorGeneric => '操作没成功,稍后再试';

  @override
  String get focusBoardToday => '今天';

  @override
  String get focusBoardWeek => '本周';

  @override
  String get focusBoardAll => '全部';

  @override
  String get focusBoardMe => '我';

  @override
  String get focusBoardEmpty => '还没有人上榜,开始专注吧';

  @override
  String focusMinutes(int minutes) {
    return '$minutes 分钟';
  }

  @override
  String focusHoursMinutes(int hours, int minutes) {
    return '$hours 小时 $minutes 分';
  }

  @override
  String get focusSettingsTitle => '专注设置';

  @override
  String get focusSettingsFocusMin => '专注时长';

  @override
  String get focusSettingsBreakMin => '休息时长';

  @override
  String get focusSettingsRounds => '轮数';

  @override
  String focusSettingsRoundsValue(int count) {
    return '$count 轮';
  }

  @override
  String get focusSettingsGrace => '离开宽限';

  @override
  String focusSettingsGraceValue(int seconds) {
    return '$seconds 秒';
  }

  @override
  String get focusSettingsGraceHint => '切出 App 超过这么久才算离开';

  @override
  String get focusSettingsMembersCanStart => '成员也能开始番茄钟';

  @override
  String get focusSettingsSave => '存下';

  @override
  String get focusSettingsPrivacy => '专注状态(谁在专注、离开多久、排行榜)服务器可见,加密圈也一样';

  @override
  String get featureCaptions => '实时字幕';

  @override
  String get featureTranscript => '转写记录';

  @override
  String get featureVoiceNotes => '语音便签';

  @override
  String get featureMap => '位置地图';

  @override
  String get featureRecording => '录音';

  @override
  String get featurePlugins => '插件';

  @override
  String get featureFocus => '专注学习';

  @override
  String get featureP2p => '点对点直连';

  @override
  String get featureDevTools => '开发者读数';

  @override
  String get roomMore => '更多';

  @override
  String get roomMoreOn => '开着';

  @override
  String get roomMoreOff => '关着';

  @override
  String get roomMoreVoiceNotesHint => '长按录一条';

  @override
  String roomMoreVoiceNotesPending(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 条待听 · 长按录',
    );
    return '$_temp0';
  }

  @override
  String get roomMoreVoiceNotesRecording => '松手发送';

  @override
  String get roomTranscriptNotice => '本圈开着转写记录';

  @override
  String get roomTranscriptNoticeOpen => '查看转写记录';

  @override
  String get ownerFeaturesTitle => '功能';

  @override
  String get ownerFeaturesEntryDesc => '这个圈里开哪些功能、做什么用';

  @override
  String get ownerFeaturesHint => '语音和文字聊天一直都在。下面这些按需打开,只对这个圈生效。';

  @override
  String get ownerFeatureCaptionsDesc => '说话实时转成字,语音片段会送云端识别';

  @override
  String get ownerFeatureTranscriptDesc => '把识别出的文字存档,圈里的人之后能翻看';

  @override
  String get ownerFeatureVoiceNotesDesc => '不在线时也能给圈里留一段话';

  @override
  String get ownerFeatureMapDesc => '愿意的人可以共享位置,在地图上看到彼此';

  @override
  String get ownerFeatureRecordingDesc => '经所有人同意后录下房间里的声音';

  @override
  String get ownerFeatureRecordingUnavailable => '这个版本还没有录音,先替以后定好';

  @override
  String get ownerFeaturePluginsDesc => '允许装第三方小程序';

  @override
  String get ownerFeatureFocusDesc => '番茄钟和一起专注的排行';

  @override
  String get ownerFeatureP2pDesc => '人少时绕过服务器直接连,延迟更低';

  @override
  String get ownerFeatureDevToolsDesc => '显示进房耗时等调试读数';

  @override
  String ownerFeatureToggleFailed(String feature, String reason) {
    return '「$feature」没改成:$reason';
  }

  @override
  String get purposeTitle => '用途';

  @override
  String get purposeNone => '还没选';

  @override
  String get purposePickerTitle => '这个圈用来做什么?';

  @override
  String get purposeChat => '闲聊';

  @override
  String get purposeChatDesc => '随便聊聊。留着语音便签,字幕和记录都关着';

  @override
  String get purposeStudy => '学习';

  @override
  String get purposeStudyDesc => '一起专注,打开番茄钟,少点打扰';

  @override
  String get purposeMeeting => '开会';

  @override
  String get purposeMeetingDesc => '打开实时字幕和转写记录,方便会后翻看';

  @override
  String get purposeCustom => '自定义';

  @override
  String get purposeCustomDesc => '自己挑功能和插件,也可以用别人的分享码';

  @override
  String get purposeCreateLabel => '用途';

  @override
  String get purposeCreateHint => '登记好之后自动设上,之后随时能改';

  @override
  String purposeApplied(String name) {
    return '已换成「$name」';
  }

  @override
  String purposeApplyFailed(String reason) {
    return '用途没换成:$reason';
  }

  @override
  String purposeReasonBad(String detail) {
    return '内容有问题($detail)';
  }

  @override
  String purposeReasonManifest(String detail) {
    return '插件描述有问题($detail)';
  }

  @override
  String get purposeReasonFetch => '插件地址拿不到';

  @override
  String get purposeReasonTooMany => '插件超过 10 个了';

  @override
  String get purposeReasonFeatureOff => '这个圈关了插件,要先打开';

  @override
  String get purposeReasonUnknownBuiltin => '服务器不认识这个内置插件';

  @override
  String get purposeReasonNotRegistered => '圈子还在登记,稍后再试';

  @override
  String get purposeExport => '导出分享码';

  @override
  String get purposeImport => '导入分享码';

  @override
  String get purposeExportFailed => '没导出来,稍后再试';

  @override
  String get purposeCodeTitle => '分享码';

  @override
  String get purposeCodeHint => '别人在「导入分享码」里粘贴它,就能用上同样的设置。里面不含口令和插件密钥。';

  @override
  String get purposeCodeCopied => '分享码复制好了';

  @override
  String get purposeCodeErrPrefix => '这不像分享码,应该以 lares-purpose: 开头';

  @override
  String get purposeCodeErrBroken => '分享码不完整,可能没复制全';

  @override
  String get purposeCodeErrTooLarge => '分享码太大了';

  @override
  String get purposeCodeErrJson => '分享码里的内容读不懂';

  @override
  String get purposeImportTitle => '导入分享码';

  @override
  String get purposeImportFieldHint => '把 lares-purpose:… 粘贴到这里';

  @override
  String get purposeImportApply => '应用';

  @override
  String get purposeImportFill => '填进去';

  @override
  String get purposePreviewNoChange => '功能开关不变';

  @override
  String purposePreviewTurnsOn(String list) {
    return '打开:$list';
  }

  @override
  String purposePreviewTurnsOff(String list) {
    return '关闭:$list';
  }

  @override
  String purposePreviewPlugins(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '涉及 $count 个插件',
    );
    return '$_temp0';
  }

  @override
  String purposePreviewSettings(String list) {
    return '圈设置:$list';
  }

  @override
  String get purposeEditorTitle => '自定义用途';

  @override
  String get purposeEditorFormat => '格式化';

  @override
  String get purposeEditorImport => '从分享码导入';

  @override
  String get purposeEditorCopyCode => '复制分享码';

  @override
  String get purposeEditorFormatFailed => '先把语法错误改好才能格式化';

  @override
  String get purposeEditorValid => '没问题,可以应用';

  @override
  String get purposeEditorChecking => '检查中…';

  @override
  String purposeEditorLine(int line) {
    return '第 $line 行';
  }

  @override
  String get purposeEditorApply => '应用';

  @override
  String purposeErrSyntax(int line, int column) {
    return 'JSON 写错了(第 $line 行第 $column 列)';
  }

  @override
  String get purposeErrNotObject => '最外层要是一个 JSON 对象';

  @override
  String get purposeErrTooLarge => '太大了,不能超过 32 KB';

  @override
  String get purposeErrUnknownKey => '不认识这个键';

  @override
  String get purposeErrVersion => 'v 只能是 1';

  @override
  String get purposeErrId => 'id 只能用小写字母、数字、- 和 _,最多 32 个';

  @override
  String get purposeErrName => '名字要有,最多 24 个字';

  @override
  String get purposeErrIcon => '图标放一个 emoji 就好';

  @override
  String get purposeErrDescription => '说明最多 200 个字';

  @override
  String get purposeErrNotBool => '要填 true 或 false';

  @override
  String get purposeErrNotObjectField => '这里要是一个 JSON 对象';

  @override
  String get purposeErrNotArray => '这里要是一个 JSON 列表';

  @override
  String get purposeErrTooManyPlugins => '插件最多 10 个';

  @override
  String get purposeErrPluginSource => 'id、manifest、manifestUrl 三选一,只能写一个';

  @override
  String get purposeErrPluginId => '插件 id 不对';

  @override
  String get purposeErrConfigTooLarge => '插件配置不能超过 4 KB';

  @override
  String get purposeErrManifestUrl => '要是一个 https:// 开头的地址';

  @override
  String purposeErrManifest(String field) {
    return '插件描述的「$field」不对';
  }

  @override
  String purposeErrConflict(String field) {
    return '和 $field 对不上';
  }

  @override
  String get purposeErrDuplicate => '同一个插件写了两次';

  @override
  String get privacySheetTitle => '本圈的隐私设置';

  @override
  String get privacySheetTranscript => '转写记录开(语音经阿里云识别,文字连同昵称存在服务器上,直到圈主清空)';

  @override
  String get privacySheetTranscriptE2ee => '转写记录开(语音经阿里云识别;服务器只转交密文,记录存在各人设备上)';

  @override
  String get privacySheetCaptions => '实时字幕可用(有人开字幕时,你说话的片段会送阿里云识别,本应用不保存)';

  @override
  String privacySheetPlugins(int count, String names) {
    return '插件 $count 个($names)';
  }

  @override
  String privacySheetPluginDetail(String name, String perms) {
    return '$name:$perms';
  }

  @override
  String get privacySheetPluginNoPerms => '不要任何权限';

  @override
  String get privacySheetPluginThirdParty => ' · 数据会发到插件作者的服务器(第三方)';

  @override
  String get privacySheetSeparator => '、';

  @override
  String get privacySheetFocus => '专注追踪开(圈里能看到谁在专注、离开了多久)';

  @override
  String get privacySheetMap => '位置共享可用(只在你自己打开时才共享)';

  @override
  String get privacySheetRecording => '录音功能开(录音时房里每个人都会看到提示)';

  @override
  String get privacySheetNothing => '本圈没开转写、插件这类会额外处理你数据的功能';

  @override
  String get privacySheetE2eeOn => '端到端加密:是';

  @override
  String get privacySheetE2eeOff => '端到端加密:否';

  @override
  String get privacySheetE2eeUnset => '端到端加密:圈子没有统一规定,看各人自己的设置';

  @override
  String get privacySheetAi => 'AI 助手开(房间里的语音会发到阿里云百炼 DashScope 识别并生成回答)';

  @override
  String get aiVoicePluginName => 'AI 助手';

  @override
  String get aiVoicePluginDesc => '房间里多一个会说话的助手,叫它就回答';

  @override
  String get aiVoiceSettingsTitle => 'AI 助手设置';

  @override
  String get aiVoicePrivacyNote =>
      '开了以后,房间里的语音会发到阿里云百炼 DashScope 识别,再由 AI 生成回答并念出来。它说的话是 AI 生成的,可能出错。端到端加密的圈子用不了。';

  @override
  String get aiVoiceE2eeBlocked => '这个圈开着端到端加密,服务器听不到语音,AI 助手没法工作';

  @override
  String get aiVoiceFieldName => '名字(也是唤醒词)';

  @override
  String get aiVoiceFieldNameEmpty => '给它起个名字';

  @override
  String get aiVoiceFieldWakeWords => '别的叫法';

  @override
  String get aiVoiceFieldWakeWordsHint => '可以不填,叫名字它就会应;多个用逗号或顿号隔开';

  @override
  String get aiVoiceFieldWakeWordsEmpty => '比如:小福、福仔';

  @override
  String get aiVoiceFieldPersona => '人设';

  @override
  String get aiVoicePersonaReset => '恢复默认';

  @override
  String get aiVoiceFieldTrigger => '什么时候回答';

  @override
  String get aiVoiceTriggerWake => '叫名字';

  @override
  String get aiVoiceTriggerAlways => '一直听';

  @override
  String get aiVoiceTriggerPtt => '只回 @它';

  @override
  String get aiVoiceTriggerWakeDesc => '有人叫它的名字或别的叫法,它才回答';

  @override
  String get aiVoiceTriggerAlwaysDesc => '有人说完一句话,它就回答 —— 适合一个人和它聊';

  @override
  String aiVoiceTriggerPttDesc(String name) {
    return '不听语音,只回答聊天里 @$name 开头的文字';
  }

  @override
  String get aiVoiceFieldVoice => '音色';

  @override
  String get aiVoiceFieldInterrupt => '有人插话就停下';

  @override
  String get aiVoiceAdvanced => '高级';

  @override
  String get aiVoiceFieldModel => '对话模型';

  @override
  String get aiVoiceFieldModelInvalid => '只能用字母、数字、点、横线和下划线';

  @override
  String get aiVoiceFieldMaxReplyChars => '一次最多说多少字';

  @override
  String get aiVoiceFieldMaxTurnsPerHour => '每小时最多回答几次';

  @override
  String get aiVoiceFieldMaxTurnsPerDay => '每天最多回答几次';

  @override
  String aiVoiceRangeHint(int min, int max) {
    return '$min–$max';
  }

  @override
  String aiVoiceRangeError(int min, int max) {
    return '要在 $min 到 $max 之间';
  }

  @override
  String get aiVoiceSaved => '存好了';

  @override
  String aiVoiceSaveFailed(String reason) {
    return '没存上:$reason';
  }

  @override
  String get aiVoiceSeatStatus => '等你叫它';

  @override
  String get aiVoiceSeatBadge => 'AI';

  @override
  String get aiVoiceModerationHint => '这是 AI 助手。圈主可以在「插件」里把它关掉';

  @override
  String get roomMoreAi => 'AI 助手';

  @override
  String roomMoreAiTitle(String name) {
    return 'AI 助手「$name」';
  }

  @override
  String roomMoreAiHowWake(String name) {
    return '叫「$name」再说问题';
  }

  @override
  String get roomMoreAiHowAlways => '说完它就会回答';

  @override
  String roomMoreAiHowPtt(String name) {
    return '在聊天里 @$name';
  }

  @override
  String get roomMoreAiPrivacy => '房间里的语音会发到阿里云百炼 DashScope 识别,回答由 AI 生成,可能出错。';

  @override
  String roomMoreAiMode(String mode) {
    return '$mode · 点开看怎么叫它';
  }

  @override
  String get purposeMeetingAiSwitch => '加上 AI 助手';

  @override
  String get purposeMeetingAiDesc => '开会时叫它名字就能提问;语音会发到阿里云百炼 DashScope';

  @override
  String get purposeMeetingAiE2ee => '这个圈开着端到端加密,用不了 AI 助手';

  @override
  String get purposeMeetingAiConfirm => '就用开会';

  @override
  String get privacySheetFullPolicy => '完整隐私说明';

  @override
  String get pushLevelTitle => '通知我';

  @override
  String get pushLevelAll => '全部';

  @override
  String get pushLevelAllDesc => '有人开始专注、房里人多了、圈主叫人,都提醒我';

  @override
  String get pushLevelCalled => '只要被叫';

  @override
  String get pushLevelCalledDesc => '只在圈主「叫大家来」时提醒我';

  @override
  String get pushLevelOff => '关';

  @override
  String get pushLevelOffDesc => '这个圈不给我发通知';

  @override
  String pushLevelTile(String level) {
    return '通知我:$level';
  }

  @override
  String get pushQuietTitle => '推送免打扰';

  @override
  String get pushQuietOffSub => '关 —— 任何时间都可能收到圈里的动静';

  @override
  String pushQuietOnSub(String range) {
    return '$range 不推送圈里的动静';
  }

  @override
  String get pushQuietSwitch => '免打扰时段';

  @override
  String get pushQuietHint => '按这台手机的时区算。圈主叫人、每周小结也会等到时段结束。';

  @override
  String get pushQuietDone => '好';

  @override
  String get pushTriggersTitle => '活动提醒';

  @override
  String get pushTriggersSub => '圈里有动静时,提醒不在房里的人';

  @override
  String get pushTriggerFocus => '有人开始专注';

  @override
  String get pushTriggerFocusDesc => '「阿蛮开始专注了,一起学?」';

  @override
  String get pushTriggerCrowd => '房里人多了';

  @override
  String pushTriggerCrowdDesc(int count) {
    return '「圈里已经有 $count 个人在聊」,每次开房只提醒一次';
  }

  @override
  String get pushTriggerCrowdN => '达到几个人时提醒';

  @override
  String pushTriggerCrowdNValue(int count) {
    return '$count 人';
  }

  @override
  String get pushTriggerArrive => '有人走进空房间';

  @override
  String get pushTriggerArriveDesc => '「小鹿来了」—— 默认关,容易吵';

  @override
  String get pushTriggersReset => '恢复用途默认';

  @override
  String get pushTriggersPurpose => '现在是按用途给的默认';

  @override
  String pushTriggersLimits(int cooldown, int cap) {
    return '每人每圈 $cooldown 分钟内最多收一条,一天最多 $cap 条;正在房里或刚离开的人不会收到。';
  }

  @override
  String get pushTriggersLoading => '正在读取…';

  @override
  String get pushTriggersFailed => '没改成,稍后再试';

  @override
  String get summonButton => '叫大家来';

  @override
  String summonCooldown(int minutes) {
    return '$minutes 分钟后可以再叫';
  }

  @override
  String summonCooldownShort(int minutes) {
    return '$minutes 分';
  }

  @override
  String summonSent(int count) {
    return '已经叫了 $count 个人';
  }

  @override
  String get summonNobody => '现在没有能叫到的人(有人关了通知或在免打扰)';

  @override
  String get summonFailed => '没叫成,稍后再试';

  @override
  String get summonConfirmTitle => '叫大家来?';

  @override
  String summonConfirmBody(String name, int minutes) {
    return '不在房里的人会收到一条「$name 叫你来圈里」。$minutes 分钟内只能叫一次。';
  }

  @override
  String focusRoundAllIn(int count) {
    return '本轮 $count 人全勤 🎉';
  }

  @override
  String get focusRoundSolo => '本轮全勤 🎉';

  @override
  String focusRoundPartial(int full, int total) {
    return '$full/$total 全勤';
  }

  @override
  String focusRoundAway(String name, int minutes) {
    return '$name离开 $minutes 分钟';
  }

  @override
  String focusRoundAwayBrief(String name) {
    return '$name离开了一会儿';
  }

  @override
  String focusRoundMore(int count) {
    return '等 $count 人';
  }

  @override
  String focusRoundTitle(int round) {
    return '第 $round 轮结束';
  }

  @override
  String get focusRoundDismiss => '收起';

  @override
  String focusStreakTooltip(int days) {
    return '连续 $days 天完成专注';
  }

  @override
  String get focusWeeklyTitle => '上周专注小结';

  @override
  String focusWeeklyTime(String time) {
    return '你专注了 $time';
  }

  @override
  String focusWeeklyRank(int rank, int of) {
    return '圈里第 $rank 名 · 共 $of 人';
  }

  @override
  String focusWeeklyStreak(int days) {
    return '连续 $days 天 🔥';
  }

  @override
  String focusWeeklyTotal(String time) {
    return '全圈一共 $time';
  }

  @override
  String get focusWeeklyDismiss => '知道了';

  @override
  String get aiStateListening => '在听';

  @override
  String get aiStateThinking => '在想…';

  @override
  String get aiStateSpeaking => '在说话';

  @override
  String aiOrbSemantics(String name, String state) {
    return '$name,AI 助手,$state';
  }

  @override
  String aiHintAskWake(String name) {
    return '叫它「$name」就能提问';
  }

  @override
  String get aiHintAskAlways => '直接说就行,它一直在听';

  @override
  String get aiHintAskPtt => '在聊天里 @AI 提问';

  @override
  String aiHintAlsoCall(String words) {
    return '也可以叫它:$words';
  }

  @override
  String aiHintAlsoAt(String names) {
    return '$names 也行';
  }

  @override
  String get aiHintListSep => '、';

  @override
  String get aiHintChatToo => '在聊天里 @AI 也能问';

  @override
  String aiHintMode(String mode, String desc) {
    return '现在是「$mode」:$desc';
  }

  @override
  String get aiHintPrivacy => '它会把语音发到阿里云处理,回答是 AI 生成的,可能出错';

  @override
  String get aiHintPrivacyPtt => '这个模式不听语音,只把 @它 的文字发到阿里云处理';

  @override
  String get chatAiInterrupted => '(被打断)';

  @override
  String get aiVoiceSectionCall => '叫它';

  @override
  String get aiVoiceSectionVoice => '它怎么说话';

  @override
  String get aiVoiceSectionUsage => '用量';

  @override
  String get aiVoiceFieldNameHelper => '大家喊这个名字,它就会应';

  @override
  String get aiVoiceFieldPersonaHelper => '告诉它用什么口气、说多长';

  @override
  String get aiVoiceFieldVoiceHelper => '它念回答时用的声音';

  @override
  String get aiVoiceFieldInterruptHelper => '它说着话时有人开口,它就先停下来听';

  @override
  String get aiVoiceUsageHelper => '限一下次数和字数,免得费用跑太多';

  @override
  String get aiVoiceFieldModelHelper => '不清楚就别改';

  @override
  String get profileOwnTitle => '我的资料';

  @override
  String get profileNameLabel => '名字';

  @override
  String get profileEmojiLabel => '头像';

  @override
  String get profileEmojiNone => '不用';

  @override
  String get profileBioLabel => '一句话';

  @override
  String get profileBioHint => '比如:在赶论文';

  @override
  String profileBioCounter(int count, int max) {
    return '$count/$max';
  }

  @override
  String get profileSaved => '存好了';

  @override
  String get profileErrorInvalid => '这份资料存不了,换个写法试试';

  @override
  String profileErrorRateLimited(int seconds) {
    return '改得有点勤,$seconds 秒后再试';
  }

  @override
  String get profileErrorNotAllowed => '现在改不了资料';

  @override
  String get profileErrorNotConnected => '还没连上,稍后再存';

  @override
  String get profileSpeaking => '在说话';

  @override
  String get profileStatusAway => '有事先走';

  @override
  String profileFocusToday(String time) {
    return '今天专注 $time';
  }

  @override
  String profileFocusWeek(String time) {
    return '本周 $time';
  }

  @override
  String profileStreak(int days) {
    return '🔥 连续 $days 天';
  }

  @override
  String get profileJoinedJustNow => '刚进来';

  @override
  String profileJoinedMinutes(int minutes) {
    return '$minutes 分钟前进来';
  }

  @override
  String profileJoinedAt(String time) {
    return '$time 进来的';
  }

  @override
  String get profileMention => '@Ta';

  @override
  String get profileMuteForMe => '听不到 Ta';

  @override
  String get profileMuteForMeHint => '只对你生效,对方不会知道';

  @override
  String get profileUnmuteForMe => '重新听到 Ta';

  @override
  String get profileKick => '移出圈子';
}
