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
}
