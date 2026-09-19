import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// 应用名。英文版用 Lares,中文版用炉灵。
  ///
  /// In zh, this message translates to:
  /// **'炉灵'**
  String get appTitle;

  /// 聊天面板折叠按钮的 tooltip
  ///
  /// In zh, this message translates to:
  /// **'收起消息'**
  String get chatCollapse;

  /// 聊天输入框的占位提示
  ///
  /// In zh, this message translates to:
  /// **'说点什么,或者放张图'**
  String get chatComposerHint;

  /// 聊天面板里一条消息都没有时的空状态文案
  ///
  /// In zh, this message translates to:
  /// **'这里很安静。想说的话、一张图,都可以放这儿。'**
  String get chatEmpty;

  /// 聊天面板展开按钮的 tooltip
  ///
  /// In zh, this message translates to:
  /// **'展开消息'**
  String get chatExpand;

  /// 图片占位块的读屏标签:对方发了图但本机没收到内容
  ///
  /// In zh, this message translates to:
  /// **'这张图没收到'**
  String get chatImageMissing;

  /// 聊天里图片缩略图的读屏标签,提示可以点开
  ///
  /// In zh, this message translates to:
  /// **'图片,点开看大图'**
  String get chatImageOpen;

  /// 系统选图器自身失败时,输入框上方的一行安静提示
  ///
  /// In zh, this message translates to:
  /// **'没能打开图片'**
  String get chatImagePickFailed;

  /// 选图按钮被禁用时的 tooltip:当前平台/版本还没有选图能力
  ///
  /// In zh, this message translates to:
  /// **'当前版本暂不支持选图'**
  String get chatImagePickUnsupported;

  /// 图片发送失败(通常是超限)时的一行安静提示
  ///
  /// In zh, this message translates to:
  /// **'这张图没发出去'**
  String get chatImageSendFailed;

  /// 图片大图对话框的读屏标签
  ///
  /// In zh, this message translates to:
  /// **'图片大图,点空白处关闭'**
  String get chatImageViewer;

  /// 图片大图对话框关闭按钮的 tooltip
  ///
  /// In zh, this message translates to:
  /// **'关闭大图'**
  String get chatImageViewerClose;

  /// 输入接近上限时显示的剩余可输入字数,只在最后 50 个字素簇内出现
  ///
  /// In zh, this message translates to:
  /// **'{left, plural, other{还能写 {left} 个字}}'**
  String chatRemaining(int left);

  /// 发送按钮的 tooltip
  ///
  /// In zh, this message translates to:
  /// **'发送'**
  String get chatSend;

  /// 文字消息没能发出去时的提示,也用在失败消息旁边的标记上
  ///
  /// In zh, this message translates to:
  /// **'没发出去'**
  String get chatSendFailed;

  /// 选图发送按钮的 tooltip
  ///
  /// In zh, this message translates to:
  /// **'发一张图'**
  String get chatSendImage;

  /// 未读红点的读屏标签,圆点本身不含文字
  ///
  /// In zh, this message translates to:
  /// **'有新消息'**
  String get chatUnread;

  /// 取消按钮。刻意不用「取消」—— 口语化一点,和产品语气一致。
  ///
  /// In zh, this message translates to:
  /// **'算了'**
  String get commonCancel;

  /// 确认按钮
  ///
  /// In zh, this message translates to:
  /// **'好'**
  String get commonConfirm;

  /// 复制按钮,用在复制邀请链接的地方
  ///
  /// In zh, this message translates to:
  /// **'复制'**
  String get commonCopy;

  /// 完成按钮
  ///
  /// In zh, this message translates to:
  /// **'完成'**
  String get commonDone;

  /// 只读提示对话框的确认按钮,读完点掉即可
  ///
  /// In zh, this message translates to:
  /// **'知道了'**
  String get commonGotIt;

  /// 把若干人名拼成一串时用的分隔符。中文用顿号,英文用逗号加空格。
  ///
  /// In zh, this message translates to:
  /// **'、'**
  String get commonListSeparator;

  /// 婉拒建议的按钮,比如系统建议顺手屏蔽某人时选择不做
  ///
  /// In zh, this message translates to:
  /// **'不用了'**
  String get commonNoThanks;

  /// 开启端到端加密的代价说明,开关旁常驻展示;文案与 e2ee_status.dart 里的 kE2EECostNotice 常量逐字一致
  ///
  /// In zh, this message translates to:
  /// **'开启后:服务器看不到任何内容,因此**无法转录**,「AI 炉灵」在这个圈子里也**不可用**(炉灵只在不开加密的圈子工作)。'**
  String get e2eeCostNotice;

  /// 端到端加密开关下方的第二句说明:密钥只存在本地
  ///
  /// In zh, this message translates to:
  /// **'密钥从你的圈口令派生,只在设备本地,绝不上传服务器。'**
  String get e2eeKeyLocalNotice;

  /// 端到端加密开关的标题
  ///
  /// In zh, this message translates to:
  /// **'端到端加密'**
  String get e2eeTitle;

  /// 主屏幕上新建圈子的按钮,也用作新建圈子对话框标题
  ///
  /// In zh, this message translates to:
  /// **'加个圈子'**
  String get homeAddCircle;

  /// 新建圈子对话框的确认按钮
  ///
  /// In zh, this message translates to:
  /// **'建一个'**
  String get homeAddCircleConfirm;

  /// 新建圈子时圈名输入框的提示文字
  ///
  /// In zh, this message translates to:
  /// **'比如:家人、死党群、考研搭子'**
  String get homeAddCircleHint;

  /// 「我有空」开关的标题
  ///
  /// In zh, this message translates to:
  /// **'我有空'**
  String get homeAvailable;

  /// 没挂着「有空」时开关下方的说明,顺带提示长按可以挑圈子
  ///
  /// In zh, this message translates to:
  /// **'挂出去,让圈友知道你现在能聊 · 长按可挑圈子'**
  String get homeAvailableOffDesc;

  /// 已挂着「有空」时开关下方的说明,n 是能看到你的圈子数
  ///
  /// In zh, this message translates to:
  /// **'{n, plural, other{{n} 个圈子看得到 · 谁先来就跟谁聊,进去之后其他圈子就看不到了}}'**
  String homeAvailableOnDesc(int n);

  /// 挑选可见圈子对话框的正文说明
  ///
  /// In zh, this message translates to:
  /// **'挂出去之后,这几个圈子的人会看到你有空。\n谁先来找你,就跟谁聊 —— 那一刻其他圈子就看不到你了。'**
  String get homeAvailablePickBody;

  /// 挑选可见圈子对话框的确认按钮
  ///
  /// In zh, this message translates to:
  /// **'就这几个'**
  String get homeAvailablePickConfirm;

  /// 挑选可见圈子对话框的标题
  ///
  /// In zh, this message translates to:
  /// **'对哪几个圈子可见'**
  String get homeAvailablePickTitle;

  /// 圈子列表项副标题:圈里既没人在线也没人挂着有空
  ///
  /// In zh, this message translates to:
  /// **'暂无人在,进去等等看?'**
  String get homeCircleEmpty;

  /// 圈子列表项副标题:只知道在线人数,不知道具体是谁
  ///
  /// In zh, this message translates to:
  /// **'{online, plural, other{{online} 个人在}}'**
  String homeCircleOnline(int online);

  /// 圈子列表项副标题:圈里有人在线,同时还有人挂着「有空」等人来找
  ///
  /// In zh, this message translates to:
  /// **'{online, plural, other{{online} 个人在 · {waitingNames} 有空}}'**
  String homeCircleOnlineAndWaiting(int online, String waitingNames);

  /// 圈子列表项副标题:有人在线并且知道名字,names 是已用本地化分隔符拼好的名字串
  ///
  /// In zh, this message translates to:
  /// **'{online, plural, other{{online} 个人在 · {names}}}'**
  String homeCircleOnlineWithNames(int online, String names);

  /// 圈子列表项副标题:没人在房间里,但有人挂着「有空」,waitingNames 是拼好的名字串
  ///
  /// In zh, this message translates to:
  /// **'{waitingNames} 有空,等人来找'**
  String homeCircleWaitingOnly(String waitingNames);

  /// 长按圈子菜单里的删除项
  ///
  /// In zh, this message translates to:
  /// **'删除这个圈子'**
  String get homeDeleteCircle;

  /// 宽屏布局下右侧还没进房间时的空状态提示
  ///
  /// In zh, this message translates to:
  /// **'点左边圈子,一键进圈'**
  String get homeEmptyRoomHint;

  /// 邀请对话框正文,说明这段链接怎么用
  ///
  /// In zh, this message translates to:
  /// **'把这段链接发给朋友,对方点一下就进圈(也可在 App 里粘贴):'**
  String get homeInviteBody;

  /// 邀请链接里没带圈名时的兜底圈子名
  ///
  /// In zh, this message translates to:
  /// **'朋友的圈'**
  String get homeInvitedCircleFallback;

  /// 圈子列表项上的邀请按钮 tooltip,也用作长按菜单项标题
  ///
  /// In zh, this message translates to:
  /// **'邀请朋友进圈'**
  String get homeInviteFriends;

  /// 长按菜单里邀请项的副标题
  ///
  /// In zh, this message translates to:
  /// **'复制邀请链接发给朋友'**
  String get homeInviteFriendsDesc;

  /// 邀请对话框标题,circleName 是圈子名
  ///
  /// In zh, this message translates to:
  /// **'邀请朋友进「{circleName}」'**
  String homeInviteTitle(String circleName);

  /// 粘贴邀请链接对话框的确认按钮
  ///
  /// In zh, this message translates to:
  /// **'进圈'**
  String get homeJoinCircle;

  /// 被踢出房间的提示,who 是踢人的人的名字
  ///
  /// In zh, this message translates to:
  /// **'你被{who}请出了房间'**
  String homeKickedBy(String who);

  /// 踢人者名字为空时的兜底称呼
  ///
  /// In zh, this message translates to:
  /// **'管理员'**
  String get homeKickedByAdmin;

  /// 长按菜单里敲门模式项的副标题
  ///
  /// In zh, this message translates to:
  /// **'开启后,圈外人进来需要里面的人放行'**
  String get homeKnockModeDesc;

  /// 长按菜单里敲门模式项的标题,当前是关闭状态
  ///
  /// In zh, this message translates to:
  /// **'敲门模式:关(点一下开启)'**
  String get homeKnockModeOff;

  /// 长按菜单里敲门模式项的标题,当前是开启状态
  ///
  /// In zh, this message translates to:
  /// **'敲门模式:开(点一下关闭)'**
  String get homeKnockModeOn;

  /// 主屏幕上打开粘贴邀请链接对话框的文字按钮
  ///
  /// In zh, this message translates to:
  /// **'有邀请链接?粘贴进圈'**
  String get homePasteInvite;

  /// 粘贴邀请链接输入框的提示文字
  ///
  /// In zh, this message translates to:
  /// **'lares://circle/… 或圈子 id'**
  String get homePasteInviteHint;

  /// 粘贴邀请链接对话框的标题
  ///
  /// In zh, this message translates to:
  /// **'粘贴邀请链接'**
  String get homePasteInviteTitle;

  /// 长按菜单:该圈子已经是主圈子
  ///
  /// In zh, this message translates to:
  /// **'已是主圈子'**
  String get homePrimaryCircleAlready;

  /// 长按菜单:已是主圈子时的副标题
  ///
  /// In zh, this message translates to:
  /// **'小组件、快捷设置、托盘点一下进的就是这个圈'**
  String get homePrimaryCircleAlreadyDesc;

  /// 长按菜单:把该圈子设为主圈子
  ///
  /// In zh, this message translates to:
  /// **'设为主圈子'**
  String get homePrimaryCircleSet;

  /// 长按菜单:设为主圈子时的副标题
  ///
  /// In zh, this message translates to:
  /// **'主屏小组件点一下,直接进这个圈'**
  String get homePrimaryCircleSetDesc;

  /// 圈子标题旁主圈子火苗图标的 tooltip
  ///
  /// In zh, this message translates to:
  /// **'主圈子 · 小组件一键加入'**
  String get homePrimaryCircleTooltip;

  /// 改昵称按钮的 tooltip
  ///
  /// In zh, this message translates to:
  /// **'改昵称'**
  String get homeRename;

  /// 改昵称对话框的确认按钮
  ///
  /// In zh, this message translates to:
  /// **'就叫这个'**
  String get homeRenameConfirm;

  /// 改昵称输入框的提示文字
  ///
  /// In zh, this message translates to:
  /// **'昵称'**
  String get homeRenameHint;

  /// 改昵称对话框的标题
  ///
  /// In zh, this message translates to:
  /// **'圈子里叫你什么?'**
  String get homeRenameTitle;

  /// 管理菜单里屏蔽某人的条目标题
  ///
  /// In zh, this message translates to:
  /// **'屏蔽这个人'**
  String get moderationBlock;

  /// 屏蔽条目的副标题,说明屏蔽后会发生什么
  ///
  /// In zh, this message translates to:
  /// **'听不到他的声音,也不再显示他的消息'**
  String get moderationBlockHint;

  /// 「顺手屏蔽」确认对话框上的确认按钮,短标签
  ///
  /// In zh, this message translates to:
  /// **'屏蔽'**
  String get moderationBlockShort;

  /// 管理菜单顶部,对方的用户 ID 为空时代替 ID 显示的兜底文案
  ///
  /// In zh, this message translates to:
  /// **'拿不到身份标识'**
  String get moderationNoUserId;

  /// 举报提交后建议顺手屏蔽的对话框正文
  ///
  /// In zh, this message translates to:
  /// **'屏蔽后你不会再听到他的声音,也不会看到他的消息。'**
  String get moderationSuggestBlockBody;

  /// 举报提交后建议顺手屏蔽的对话框标题
  ///
  /// In zh, this message translates to:
  /// **'顺手屏蔽他?'**
  String get moderationSuggestBlockTitle;

  /// 管理菜单里解除屏蔽的条目标题,已屏蔽时显示
  ///
  /// In zh, this message translates to:
  /// **'解除屏蔽'**
  String get moderationUnblock;

  /// 解除屏蔽条目的副标题,说明解除后会发生什么
  ///
  /// In zh, this message translates to:
  /// **'他的声音和消息会重新出现'**
  String get moderationUnblockHint;

  /// 有语音便签时按钮的悬浮提示,带条数
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{听 {count} 条留言(长按留一条)}}'**
  String noteListen(int count);

  /// 没有语音便签时按钮的悬浮提示
  ///
  /// In zh, this message translates to:
  /// **'长按留语音便签'**
  String get noteRecordHint;

  /// 直连限制说明第二句，已配置 TURN 中继服务器时显示
  ///
  /// In zh, this message translates to:
  /// **'另外约两三成的网络组合直连不了,会走你配的中继服务器。'**
  String get p2pCaveatHasTurn;

  /// 直连限制说明第二句，未配置 TURN 中继服务器时显示
  ///
  /// In zh, this message translates to:
  /// **'另外约两三成的网络组合直连不了,需要在设置里填一台中继服务器(TURN)。'**
  String get p2pCaveatNoTurn;

  /// 直连的限制说明第一句：只能一对一，且没有文字、图片、加密标记
  ///
  /// In zh, this message translates to:
  /// **'⚠️ 只能一对一,而且这里没有文字、图片和加密标记 —— 那些功能依赖服务器。'**
  String get p2pCaveats;

  /// 连接码的字符数，显示在复制按钮旁边
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{{count} 字符}}'**
  String p2pCharCount(int count);

  /// 连接码复制成功后的提示条
  ///
  /// In zh, this message translates to:
  /// **'连接码已复制,发给对方吧'**
  String get p2pCodeCopied;

  /// 应答方一侧本地连接码框的标签，第二步
  ///
  /// In zh, this message translates to:
  /// **'② 把这段回给对方'**
  String get p2pCodeSendBack;

  /// 发起方一侧本地连接码框的标签，第一步
  ///
  /// In zh, this message translates to:
  /// **'① 把这段发给对方'**
  String get p2pCodeSendToPeer;

  /// 贴完连接码后开始建立连接的按钮
  ///
  /// In zh, this message translates to:
  /// **'连接'**
  String get p2pConnect;

  /// 复制连接码的按钮
  ///
  /// In zh, this message translates to:
  /// **'复制'**
  String get p2pCopy;

  /// 连接码解析失败：内容残缺或解码出错
  ///
  /// In zh, this message translates to:
  /// **'连接码不完整,可能复制时少了一截'**
  String get p2pErrorCorrupted;

  /// 连接码解析失败：贴进来的文字根本不是 Lares 连接码
  ///
  /// In zh, this message translates to:
  /// **'这段文字不是 Lares 连接码,再确认一下?'**
  String get p2pErrorNotLaresCode;

  /// 连接码解析失败：连接码版本号与本机不一致
  ///
  /// In zh, this message translates to:
  /// **'对方的 Lares 版本和你差太多,更新一下再试'**
  String get p2pErrorVersionMismatch;

  /// 连接码解析失败：贴入的是发起码，但此处需要应答码
  ///
  /// In zh, this message translates to:
  /// **'贴反了 —— 这是发起码,该贴的是对方回给你的应答码'**
  String get p2pErrorWrongKind;

  /// 说明卡片正文：互传连接码即可直连，传递方式不限
  ///
  /// In zh, this message translates to:
  /// **'你和对方互传一段连接码,声音就在两台设备之间直接走。\n连接码怎么传都行 —— 微信、短信、当面念都可以。'**
  String get p2pNoServerBody;

  /// 说明卡片的标题：直连不经过服务器
  ///
  /// In zh, this message translates to:
  /// **'不经过任何服务器'**
  String get p2pNoServerTitle;

  /// 连接码输入框里粘贴按钮的悬浮提示
  ///
  /// In zh, this message translates to:
  /// **'从剪贴板粘贴'**
  String get p2pPasteFromClipboard;

  /// 应答方粘贴对方发起码的输入框标签，第一步
  ///
  /// In zh, this message translates to:
  /// **'① 贴入对方发来的码'**
  String get p2pPasteIncomingLabel;

  /// 发起方粘贴对方应答码的输入框标签，第二步
  ///
  /// In zh, this message translates to:
  /// **'② 贴入对方回给你的码'**
  String get p2pPasteReplyLabel;

  /// 正在收集 ICE 候选、准备连接码时的等待提示
  ///
  /// In zh, this message translates to:
  /// **'正在准备连接信息…'**
  String get p2pPreparing;

  /// 应答方角色卡片的说明文字
  ///
  /// In zh, this message translates to:
  /// **'把对方发来的连接码贴进来,生成一段回给他。'**
  String get p2pRoleAnswererBody;

  /// 角色选择卡片：已经收到对方的连接码（应答方）
  ///
  /// In zh, this message translates to:
  /// **'对方发我码了'**
  String get p2pRoleAnswererTitle;

  /// 多人通话角色卡片的说明文字，解释信令由服务器转交、以及自动挑选转发者的规则
  ///
  /// In zh, this message translates to:
  /// **'连接码由服务器转交,不用手动传。会自动挑一个人转发声音 —— 优先挑电脑,因为它插着电、网更稳。'**
  String get p2pRoleMeshBody;

  /// 角色选择卡片：多人网状通话，只在有服务器信令时出现
  ///
  /// In zh, this message translates to:
  /// **'圈里的人一起(最多 4 人)'**
  String get p2pRoleMeshTitle;

  /// 发起方角色卡片的说明文字
  ///
  /// In zh, this message translates to:
  /// **'生成一段连接码发给对方,等对方回一段给你。'**
  String get p2pRoleOffererBody;

  /// 角色选择卡片：由自己先生成连接码（发起方）
  ///
  /// In zh, this message translates to:
  /// **'我先开口'**
  String get p2pRoleOffererTitle;

  /// 连接状态：连接已断开
  ///
  /// In zh, this message translates to:
  /// **'已断开'**
  String get p2pStatusClosed;

  /// 连接状态：已连通
  ///
  /// In zh, this message translates to:
  /// **'连上了,可以说话'**
  String get p2pStatusConnected;

  /// 连接状态：正在连接
  ///
  /// In zh, this message translates to:
  /// **'正在连接…'**
  String get p2pStatusConnecting;

  /// 连接状态：连接失败，且没有更具体的失败原因
  ///
  /// In zh, this message translates to:
  /// **'没能连上'**
  String get p2pStatusFailed;

  /// 连接状态：等待对方贴码或回码
  ///
  /// In zh, this message translates to:
  /// **'等对方那边动作'**
  String get p2pStatusWaitingForPeer;

  /// 直连（点对点）对话界面的标题栏
  ///
  /// In zh, this message translates to:
  /// **'直连对话'**
  String get p2pTitle;

  /// 内容规范页的同意按钮。必须是明确的肯定动作,不能写成「知道了」这类含糊说法。
  ///
  /// In zh, this message translates to:
  /// **'我已阅读并同意'**
  String get policyAgree;

  /// 内容规范页的不同意按钮
  ///
  /// In zh, this message translates to:
  /// **'不同意'**
  String get policyDecline;

  /// 内容规范第二条正文:用户对自己发布的内容负责
  ///
  /// In zh, this message translates to:
  /// **'你说出口、发出去、分享出去的每一条内容,责任都在你自己身上。加入一个圈子,就是接受这条。'**
  String get policyOwnContentBody;

  /// 内容规范第二条小标题
  ///
  /// In zh, this message translates to:
  /// **'你对自己发布的内容负责'**
  String get policyOwnContentTitle;

  /// 内容规范第三条正文:违规者会被移除,以及举报的处理时限
  ///
  /// In zh, this message translates to:
  /// **'违规的人会被移出圈子;情节严重的会被永久禁止使用本服务。收到举报后,我们在 24 小时内处理完并给出结果。'**
  String get policyRemovalBody;

  /// 内容规范第三条小标题
  ///
  /// In zh, this message translates to:
  /// **'违规者会被移除'**
  String get policyRemovalTitle;

  /// 内容规范页顶部的一句话说明
  ///
  /// In zh, this message translates to:
  /// **'这是给熟人小圈子用的语音空间。想让它一直待得住,下面几条要守住。'**
  String get policySummary;

  /// 内容规范页的标题
  ///
  /// In zh, this message translates to:
  /// **'社区内容规范'**
  String get policyTitle;

  /// 内容规范第四条正文:用户手上有屏蔽和举报两件工具
  ///
  /// In zh, this message translates to:
  /// **'任何时候都可以在本机屏蔽某个人,屏蔽后不再收到对方的任何内容。要举报,可以在成员列表里选那个人,也可以长按具体那条消息。'**
  String get policyToolsBody;

  /// 内容规范第四条小标题
  ///
  /// In zh, this message translates to:
  /// **'你手上有工具'**
  String get policyToolsTitle;

  /// 内容规范第一条正文:对滥用行为零容忍,覆盖所有内容形式
  ///
  /// In zh, this message translates to:
  /// **'骚扰、人身攻击、仇恨或歧视言论、色情内容、暴力内容、违法信息,一律不允许出现在这里。语音、文字、图片、位置都算,没有例外。'**
  String get policyZeroToleranceBody;

  /// 内容规范第一条小标题
  ///
  /// In zh, this message translates to:
  /// **'对滥用行为零容忍'**
  String get policyZeroToleranceTitle;

  /// 我在录音时的补充行:房间里除我之外还有几个人也在录
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{房间里还有 {count} 人在录音}}'**
  String recordingAlsoRecording(int count);

  /// 录音确认对话框正文第一条:房间里所有人都会立刻知道是你在录
  ///
  /// In zh, this message translates to:
  /// **'房间里每个人都会立刻收到通知,知道是你在录。'**
  String get recordingConsentEveryoneNotified;

  /// 录音确认对话框正文第三条:音频转写为文字并只留在本机,不上传
  ///
  /// In zh, this message translates to:
  /// **'声音会被转写成文字,只保存在本地设备,不会上传。'**
  String get recordingConsentLocalOnly;

  /// 录音确认对话框正文第四条:当前房间里的人数
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{现在房间里有 {count} 个人。}}'**
  String recordingConsentMemberCount(int count);

  /// 录音确认对话框正文第二条:录音期间提示常驻且无法关闭
  ///
  /// In zh, this message translates to:
  /// **'录音期间,所有人的界面上都会一直显示录音提示,关不掉。'**
  String get recordingConsentPersistentNotice;

  /// 录音确认对话框的取消按钮
  ///
  /// In zh, this message translates to:
  /// **'再想想'**
  String get recordingConsentReconsider;

  /// 录音确认对话框的确认按钮
  ///
  /// In zh, this message translates to:
  /// **'开始录音'**
  String get recordingConsentStart;

  /// 开始录音前的确认对话框标题
  ///
  /// In zh, this message translates to:
  /// **'开始录音?'**
  String get recordingConsentTitle;

  /// 已录时长,满整点小时时省略分钟
  ///
  /// In zh, this message translates to:
  /// **'{hours, plural, other{已录 {hours} 小时}}'**
  String recordingElapsedHours(int hours);

  /// 已录时长,超过一小时且有零头分钟时显示小时加分钟
  ///
  /// In zh, this message translates to:
  /// **'已录 {hours, plural, other{{hours} 小时}} {minutes, plural, other{{minutes} 分钟}}'**
  String recordingElapsedHoursMinutes(int hours, int minutes);

  /// 已录时长,不足一小时时按分钟显示
  ///
  /// In zh, this message translates to:
  /// **'{minutes, plural, other{已录 {minutes} 分钟}}'**
  String recordingElapsedMinutes(int minutes);

  /// 已录时长,不足一分钟时按秒显示
  ///
  /// In zh, this message translates to:
  /// **'{seconds, plural, other{已录 {seconds} 秒}}'**
  String recordingElapsedSeconds(int seconds);

  /// 拼接录音提示各分句时用的分隔符。中文用逗号,英文用逗号加空格
  ///
  /// In zh, this message translates to:
  /// **','**
  String get recordingListSeparator;

  /// 录音指示器主语句:房间里没有任何人在录音
  ///
  /// In zh, this message translates to:
  /// **'房间里没有人在录音'**
  String get recordingNobodyRecording;

  /// 录音提示:已有录音流程占用中,要求先停止当前录音
  ///
  /// In zh, this message translates to:
  /// **'已有录音流程进行中,请先停止当前录音'**
  String get recordingNoticeAlreadyInProgress;

  /// 录音提示:等服务器回执超时,起录失败已取消。括号里是等待的秒数
  ///
  /// In zh, this message translates to:
  /// **'未能确认房间已被告知录音开始,已取消录音(等待服务器回执超过 {seconds, plural, other{{seconds} 秒}})'**
  String recordingNoticeArmingTimeout(int seconds);

  /// 录音提示:圈子 ID 为空,压根无从录起
  ///
  /// In zh, this message translates to:
  /// **'圈子 ID 为空,无法开始录音'**
  String get recordingNoticeCircleIdEmpty;

  /// 录音提示:信令断开,宽限期内尝试恢复中
  ///
  /// In zh, this message translates to:
  /// **'信令连接已断开,正在尝试恢复;若无法恢复将自动停止录音'**
  String get recordingNoticeDisconnected;

  /// 录音提示:宽限期耗尽仍未恢复,无法确认房间知情,已强制停止。数字是宽限期秒数
  ///
  /// In zh, this message translates to:
  /// **'信令中断超过 {seconds, plural, other{{seconds} 秒}}仍未恢复,无法确认房间知情,已自动停止录音'**
  String recordingNoticeGraceExpired(int seconds);

  /// 录音提示:本机已被移出房间,别人看不到我的录音指示,已强制停止
  ///
  /// In zh, this message translates to:
  /// **'本机已被移出房间,已自动停止录音以免房间不知情'**
  String get recordingNoticeRemovedFromRoom;

  /// 录音提示:服务器明确表示本机没在录,属正面矛盾,已强制停止
  ///
  /// In zh, this message translates to:
  /// **'服务器已将本机标记为未在录音,已自动停止录音以免房间不知情'**
  String get recordingNoticeServerMarkedInactive;

  /// 录音提示:久无入站信令消息(半开连接看门狗),正在重新确认
  ///
  /// In zh, this message translates to:
  /// **'长时间未收到信令消息,正在重新确认录音状态'**
  String get recordingNoticeSignalingSilent;

  /// 录音提示:服务器快照里没有我但本机自以为在录,正在重新确认
  ///
  /// In zh, this message translates to:
  /// **'信令状态不同步,正在重新确认录音状态'**
  String get recordingNoticeStateOutOfSync;

  /// 读屏用的整条录音提示。固定前缀放在最前面,听到第一个词就知道是怎么回事
  ///
  /// In zh, this message translates to:
  /// **'录音提示:{body}'**
  String recordingSemanticsLabel(String body);

  /// 录音指示器主语句:多人同时录音,显示最早开始的那位的名字和总人数
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{{name} 等 {count} 人正在录音}}'**
  String recordingSeveralRecording(String name, int count);

  /// 录音指示器主语句:只有一个人在录音,显示其名字。书名号用于把名字和句子切开
  ///
  /// In zh, this message translates to:
  /// **'「{name}」正在录音'**
  String recordingSomeoneRecording(String name);

  /// 宽限期标题:信令中断,无法确认房间是否还看得见录音指示
  ///
  /// In zh, this message translates to:
  /// **'录音状态未确认'**
  String get recordingStatusUnconfirmed;

  /// 录音指示条上的「停止录音」按钮
  ///
  /// In zh, this message translates to:
  /// **'停止录音'**
  String get recordingStop;

  /// 录音指示器主语句:录音的人是你自己,第一人称提醒责任在己
  ///
  /// In zh, this message translates to:
  /// **'你正在录音'**
  String get recordingYouAreRecording;

  /// 举报提交成功后的 SnackBar 回执。承诺 24 小时内处理,不要改动时限。
  ///
  /// In zh, this message translates to:
  /// **'已提交,我们会在 24 小时内处理'**
  String get reportAccepted;

  /// 成员管理菜单里「举报这个人」的条目标题
  ///
  /// In zh, this message translates to:
  /// **'举报'**
  String get reportAction;

  /// 举报条目的副标题,成员菜单和消息菜单共用
  ///
  /// In zh, this message translates to:
  /// **'把情况告诉我们,24 小时内处理'**
  String get reportActionHint;

  /// 送达说明对话框的正文:举报通过邮件送出,正文已写好并复制到剪贴板。这段话后面紧跟支持邮箱地址。
  ///
  /// In zh, this message translates to:
  /// **'我们已经帮你把举报写好并打开邮件。确认后点发送即可。\n要是邮件没有自动打开,内容也已经放进剪贴板了 —— 手动新建一封,粘贴后发到:'**
  String get reportDeliveryBody;

  /// 送达说明对话框里邮箱地址下方的补充说明,讲处理时限和回复方式
  ///
  /// In zh, this message translates to:
  /// **'收到后 24 小时内处理完,结果也回这个邮箱。'**
  String get reportDeliveryFollowUp;

  /// 举报送达说明对话框的标题
  ///
  /// In zh, this message translates to:
  /// **'最后一步:把邮件发出来'**
  String get reportDeliveryTitle;

  /// 举报对话框的标题,带被举报者的昵称
  ///
  /// In zh, this message translates to:
  /// **'举报「{targetName}」'**
  String reportDialogTitle(String targetName);

  /// 消息管理菜单里举报单条消息的条目标题
  ///
  /// In zh, this message translates to:
  /// **'举报这条消息'**
  String get reportMessageAction;

  /// 举报对话框里选填备注输入框的占位提示
  ///
  /// In zh, this message translates to:
  /// **'补充说明(可不填)'**
  String get reportNoteHint;

  /// 举报对话框里分类列表上方的说明文字
  ///
  /// In zh, this message translates to:
  /// **'挑一条最贴近的。我们会看完再回你。'**
  String get reportPickReason;

  /// 举报分类:骚扰。中性的分类标签,不是指控。
  ///
  /// In zh, this message translates to:
  /// **'骚扰或人身攻击'**
  String get reportReasonHarassment;

  /// 举报分类:仇恨言论。中性的分类标签,不是指控。
  ///
  /// In zh, this message translates to:
  /// **'仇恨或歧视言论'**
  String get reportReasonHateSpeech;

  /// 举报分类:违法内容。中性的分类标签,不是指控。
  ///
  /// In zh, this message translates to:
  /// **'违法或危险行为'**
  String get reportReasonIllegal;

  /// 举报分类:以上都不是,细节写在备注里
  ///
  /// In zh, this message translates to:
  /// **'其他'**
  String get reportReasonOther;

  /// 举报分类:色情内容。中性的分类标签,不要用委婉语盖住它指什么。
  ///
  /// In zh, this message translates to:
  /// **'色情或性暗示内容'**
  String get reportReasonSexualContent;

  /// 举报分类:垃圾信息。中性的分类标签,不是指控。
  ///
  /// In zh, this message translates to:
  /// **'垃圾信息或刷屏'**
  String get reportReasonSpam;

  /// 举报分类:暴力内容。中性的分类标签,不是指控。
  ///
  /// In zh, this message translates to:
  /// **'暴力或血腥内容'**
  String get reportReasonViolence;

  /// 举报对话框的提交按钮。没选分类前一直是禁用状态。
  ///
  /// In zh, this message translates to:
  /// **'提交举报'**
  String get reportSubmit;

  /// 房间里只有自己一个人时的状态行
  ///
  /// In zh, this message translates to:
  /// **'就你一个在,等等看?'**
  String get roomAloneHere;

  /// 地图视图下切回房间成员视图的图标按钮提示
  ///
  /// In zh, this message translates to:
  /// **'回到房间'**
  String get roomBackToRoom;

  /// 被屏蔽成员头像遮罩的无障碍标签,读屏会念出来
  ///
  /// In zh, this message translates to:
  /// **'已屏蔽'**
  String get roomBlockedSemantics;

  /// 房间成员列表为空时的占位文案
  ///
  /// In zh, this message translates to:
  /// **'房间里还空着,坐一会儿?'**
  String get roomEmpty;

  /// 进房失败且没有更具体说明时的兜底提示
  ///
  /// In zh, this message translates to:
  /// **'出错了'**
  String get roomErrorGeneric;

  /// 正在加入房间时的状态行
  ///
  /// In zh, this message translates to:
  /// **'正在进去…'**
  String get roomJoining;

  /// 房间头部延迟数字的悬浮提示
  ///
  /// In zh, this message translates to:
  /// **'本次进房耗时'**
  String get roomJoinLatencyTooltip;

  /// 请出成员确认对话框的正文说明
  ///
  /// In zh, this message translates to:
  /// **'对方会被移出房间(可以稍后再进来,不是封禁)'**
  String get roomKickBody;

  /// 请出成员确认对话框的确认按钮
  ///
  /// In zh, this message translates to:
  /// **'请出'**
  String get roomKickConfirm;

  /// 成员管理菜单里「请出房间」这一项的标题
  ///
  /// In zh, this message translates to:
  /// **'请出房间'**
  String get roomKickMember;

  /// 成员管理菜单里「请出房间」这一项的副标题
  ///
  /// In zh, this message translates to:
  /// **'对方可以稍后再进来,不是封禁'**
  String get roomKickMemberHint;

  /// 请出成员确认对话框的标题,带对方昵称
  ///
  /// In zh, this message translates to:
  /// **'把「{name}」请出房间?'**
  String roomKickTitle(String name);

  /// 敲门横幅上同意放人进来的按钮
  ///
  /// In zh, this message translates to:
  /// **'让他进'**
  String get roomKnockAllow;

  /// 敲门横幅上暂不放人进来的按钮
  ///
  /// In zh, this message translates to:
  /// **'先不'**
  String get roomKnockDeny;

  /// 自己在敲门等待放行时的状态行
  ///
  /// In zh, this message translates to:
  /// **'敲门中,等里面的人应门…'**
  String get roomKnocking;

  /// 有人敲门时横幅的标题,带敲门人昵称
  ///
  /// In zh, this message translates to:
  /// **'{name} 想进来'**
  String roomKnockWants(String name);

  /// 控制栏上离开房间按钮的提示
  ///
  /// In zh, this message translates to:
  /// **'离开'**
  String get roomLeave;

  /// 切到位置共享地图视图的图标按钮提示
  ///
  /// In zh, this message translates to:
  /// **'位置共享地图'**
  String get roomLocationMap;

  /// 把自己麦克风静音的按钮提示
  ///
  /// In zh, this message translates to:
  /// **'静音'**
  String get roomMute;

  /// 房间里的人数状态行
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{{count} 个人在}}'**
  String roomPeopleHere(int count);

  /// 轻状态选择:在忙
  ///
  /// In zh, this message translates to:
  /// **'在忙'**
  String get roomStatusBusy;

  /// 轻状态选择:只听不说
  ///
  /// In zh, this message translates to:
  /// **'耳朵在'**
  String get roomStatusEars;

  /// 轻状态选择:随时可以聊
  ///
  /// In zh, this message translates to:
  /// **'随时聊'**
  String get roomStatusFree;

  /// 解除静音开口说话的按钮提示
  ///
  /// In zh, this message translates to:
  /// **'说话'**
  String get roomUnmute;

  /// 认证方式:每个圈子各自一个口令
  ///
  /// In zh, this message translates to:
  /// **'按圈口令'**
  String get settingsAuthModeCircle;

  /// 认证方式:不需要口令
  ///
  /// In zh, this message translates to:
  /// **'不需要口令'**
  String get settingsAuthModeNone;

  /// 认证方式:共享令牌;同时也是令牌输入框的标签
  ///
  /// In zh, this message translates to:
  /// **'共享令牌'**
  String get settingsAuthModeToken;

  /// 后台运行设置项的标题
  ///
  /// In zh, this message translates to:
  /// **'后台运行保障'**
  String get settingsBackground;

  /// Android 上用户没有同意忽略电池优化时的提示
  ///
  /// In zh, this message translates to:
  /// **'请在系统设置里允许忽略电池优化'**
  String get settingsBackgroundDenied;

  /// Android 上用户同意忽略电池优化后的提示
  ///
  /// In zh, this message translates to:
  /// **'已允许后台运行(国产 ROM 建议再开「自启动」)'**
  String get settingsBackgroundGranted;

  /// iOS 上点击后台运行项时的说明,该平台不需要额外设置
  ///
  /// In zh, this message translates to:
  /// **'在房间里时 iOS 会自动以后台音频保活,无需设置'**
  String get settingsBackgroundIos;

  /// 后台运行设置项的副标题
  ///
  /// In zh, this message translates to:
  /// **'挂机不掉线:电池优化白名单 / 后台音频'**
  String get settingsBackgroundSub;

  /// 内容规范入口的标题
  ///
  /// In zh, this message translates to:
  /// **'社区内容规范'**
  String get settingsContentPolicy;

  /// 内容规范入口的副标题
  ///
  /// In zh, this message translates to:
  /// **'看看我们对内容的要求'**
  String get settingsContentPolicySub;

  /// 免打扰时段设置项标题,同时也是选择时段对话框的标题
  ///
  /// In zh, this message translates to:
  /// **'免打扰时段'**
  String get settingsDnd;

  /// 免打扰时段对话框的确认按钮
  ///
  /// In zh, this message translates to:
  /// **'就这样'**
  String get settingsDndConfirm;

  /// 免打扰时段对话框里起始小时选择器的标签
  ///
  /// In zh, this message translates to:
  /// **'从'**
  String get settingsDndFrom;

  /// 免打扰未开启时的副标题,说明敲门提示照常提醒
  ///
  /// In zh, this message translates to:
  /// **'未开启(敲门提示不受打扰)'**
  String get settingsDndOff;

  /// 免打扰时段对话框里结束小时选择器的标签
  ///
  /// In zh, this message translates to:
  /// **'到'**
  String get settingsDndTo;

  /// 关掉当前免打扰时段的按钮
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get settingsDndTurnOff;

  /// 设置页分组标题:主圈子、小组件、后台运行
  ///
  /// In zh, this message translates to:
  /// **'这个圈子'**
  String get settingsGroupCircle;

  /// 设置页分组标题:屏蔽名单与内容规范
  ///
  /// In zh, this message translates to:
  /// **'待得住'**
  String get settingsGroupSafety;

  /// 设置页分组标题:音质、降噪、免打扰
  ///
  /// In zh, this message translates to:
  /// **'声音与打扰'**
  String get settingsGroupSound;

  /// 添加主屏幕小组件的设置项标题
  ///
  /// In zh, this message translates to:
  /// **'把圈子放到主屏幕'**
  String get settingsHomeWidget;

  /// 主屏幕小组件设置项的副标题
  ///
  /// In zh, this message translates to:
  /// **'主屏幕点一下,直接进主圈子'**
  String get settingsHomeWidgetSub;

  /// 系统不支持一键固定小组件时的提示
  ///
  /// In zh, this message translates to:
  /// **'当前设备不支持,请长按桌面手动添加'**
  String get settingsHomeWidgetUnsupported;

  /// 降噪下拉选项:增强强度
  ///
  /// In zh, this message translates to:
  /// **'增强'**
  String get settingsNoiseEnhanced;

  /// 降噪下拉选项:关闭降噪
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get settingsNoiseOff;

  /// 降噪下拉选项:标准强度
  ///
  /// In zh, this message translates to:
  /// **'标准'**
  String get settingsNoiseStandard;

  /// 降噪设置项的标题
  ///
  /// In zh, this message translates to:
  /// **'降噪'**
  String get settingsNoiseSuppression;

  /// 选择主圈子的对话框标题
  ///
  /// In zh, this message translates to:
  /// **'哪个是主圈子?'**
  String get settingsPickPrimaryCircle;

  /// 主圈子设置项的标题
  ///
  /// In zh, this message translates to:
  /// **'主圈子'**
  String get settingsPrimaryCircle;

  /// 用户一个圈子都还没有时,主圈子项的副标题
  ///
  /// In zh, this message translates to:
  /// **'还没有圈子'**
  String get settingsPrimaryCircleNone;

  /// 主圈子项的副标题:第一行是圈子名,第二行说明它是各处快捷入口的目标
  ///
  /// In zh, this message translates to:
  /// **'{name}\n小组件、快捷设置、托盘一键进的就是它'**
  String settingsPrimaryCircleSub(String name);

  /// 录音与转写设置项的标题
  ///
  /// In zh, this message translates to:
  /// **'录音与转写'**
  String get settingsRecording;

  /// 录音未开启时的副标题
  ///
  /// In zh, this message translates to:
  /// **'默认关闭;开启时所有人都会看到提示'**
  String get settingsRecordingOff;

  /// 录音进行中的副标题,强调房间里所有人都会看到提示
  ///
  /// In zh, this message translates to:
  /// **'正在录音 —— 房间里所有人都看得到提示'**
  String get settingsRecordingOn;

  /// 开始录音的按钮
  ///
  /// In zh, this message translates to:
  /// **'开始录音'**
  String get settingsRecordingStart;

  /// 录音启动失败且服务端没给出具体原因时的兜底提示
  ///
  /// In zh, this message translates to:
  /// **'录音未能开始'**
  String get settingsRecordingStartFailed;

  /// 停止录音的按钮
  ///
  /// In zh, this message translates to:
  /// **'停止录音'**
  String get settingsRecordingStop;

  /// 设置页里进入服务器配置的入口标题
  ///
  /// In zh, this message translates to:
  /// **'服务器与口令'**
  String get settingsServer;

  /// 新增服务器的列表项,同时也是新增对话框的标题
  ///
  /// In zh, this message translates to:
  /// **'添加服务器'**
  String get settingsServerAdd;

  /// 认证方式下拉框左侧的标签
  ///
  /// In zh, this message translates to:
  /// **'需要口令'**
  String get settingsServerAuthLabel;

  /// 生物识别没通过、因此没有打开服务器配置的提示
  ///
  /// In zh, this message translates to:
  /// **'没验证通过,没打开'**
  String get settingsServerBiometricFailed;

  /// 打开含口令的服务器配置前,系统生物识别弹窗里显示的理由
  ///
  /// In zh, this message translates to:
  /// **'查看或修改服务器口令'**
  String get settingsServerBiometricReason;

  /// 没有自定义服务器时显示的默认服务器名称
  ///
  /// In zh, this message translates to:
  /// **'默认(打包内置)'**
  String get settingsServerBuiltIn;

  /// 圈口令模式下圈子 ID 输入框的标签
  ///
  /// In zh, this message translates to:
  /// **'圈子 ID'**
  String get settingsServerCircleId;

  /// 圈口令模式下口令输入框的标签
  ///
  /// In zh, this message translates to:
  /// **'圈口令'**
  String get settingsServerCirclePasscode;

  /// 配置了多个服务器时,在服务器入口副标题里显示的数量
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{共 {count} 个服务器}}'**
  String settingsServerCount(int count);

  /// 新建服务器时名字输入框的默认值,留空时也用它
  ///
  /// In zh, this message translates to:
  /// **'我的服务器'**
  String get settingsServerDefaultLabel;

  /// 删除这个服务器配置的按钮
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get settingsServerDelete;

  /// 服务器列表里编辑按钮的提示文字
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get settingsServerEdit;

  /// 编辑已有服务器的对话框标题
  ///
  /// In zh, this message translates to:
  /// **'编辑服务器'**
  String get settingsServerEditTitle;

  /// 服务器列表面板的标题
  ///
  /// In zh, this message translates to:
  /// **'服务器'**
  String get settingsServerListTitle;

  /// 服务器名字输入框的标签
  ///
  /// In zh, this message translates to:
  /// **'名字'**
  String get settingsServerName;

  /// 服务器名字输入框的示例提示
  ///
  /// In zh, this message translates to:
  /// **'例:家里的 VPS'**
  String get settingsServerNameHint;

  /// 服务器列表底部关于口令明文存储的说明
  ///
  /// In zh, this message translates to:
  /// **'口令以明文保存在本机设置里,不是加密存储。别人拿到这台设备的文件就能读到 —— 共用设备请谨慎。'**
  String get settingsServerPlaintextWarning;

  /// 保存服务器配置的按钮
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get settingsServerSave;

  /// 服务器配置保存成功后的提示
  ///
  /// In zh, this message translates to:
  /// **'已保存,重启 App 生效'**
  String get settingsServerSaved;

  /// 测试服务器连通性的按钮
  ///
  /// In zh, this message translates to:
  /// **'测试连接'**
  String get settingsServerTest;

  /// 共享令牌输入框的提示,说明该填服务端的哪个值
  ///
  /// In zh, this message translates to:
  /// **'服务器的 LARES_AUTH_TOKEN'**
  String get settingsServerTokenHint;

  /// 服务器地址输入框的标签
  ///
  /// In zh, this message translates to:
  /// **'地址'**
  String get settingsServerUrl;

  /// 主屏幕右上角打开设置面板的按钮提示
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get settingsTitle;

  /// 开关标题:只在 WiFi 下使用高音质
  ///
  /// In zh, this message translates to:
  /// **'仅 WiFi 下高音质'**
  String get settingsWifiOnlyHq;

  /// 「仅 WiFi 下高音质」开关的副标题
  ///
  /// In zh, this message translates to:
  /// **'移动网络自动降码率,省流量'**
  String get settingsWifiOnlyHqSub;

  /// Android 安装指引：系统安装器已打开，并说明未知来源权限
  ///
  /// In zh, this message translates to:
  /// **'系统安装器已打开。若提示「禁止安装未知应用」，请在弹出的设置里允许「炉灵」安装应用后重试。'**
  String get updateAndroidInstallerOpened;

  /// 自动检查更新开关的说明
  ///
  /// In zh, this message translates to:
  /// **'静默检查，发现新版本才提示；安装永远需要你点确认。'**
  String get updateAutoCheckSubtitle;

  /// 自动检查更新开关的标题
  ///
  /// In zh, this message translates to:
  /// **'启动时检查更新'**
  String get updateAutoCheckTitle;

  /// 手动检查更新的按钮
  ///
  /// In zh, this message translates to:
  /// **'立即检查'**
  String get updateCheckNow;

  /// 更新面板右上角显示的当前版本号
  ///
  /// In zh, this message translates to:
  /// **'当前 v{version}'**
  String updateCurrentVersion(String version);

  /// 下载更新按钮，安装包大小未知时
  ///
  /// In zh, this message translates to:
  /// **'下载更新'**
  String get updateDownload;

  /// 下载进度条下方的文字，服务端没给总大小、进度未知时显示
  ///
  /// In zh, this message translates to:
  /// **'下载中…'**
  String get updateDownloading;

  /// 下载更新按钮，带安装包大小
  ///
  /// In zh, this message translates to:
  /// **'下载更新（{size} MB）'**
  String updateDownloadWithSize(String size);

  /// Android 安装失败：系统安装器没打开
  ///
  /// In zh, this message translates to:
  /// **'系统安装器未能打开。'**
  String get updateErrAndroidInstallerNotOpened;

  /// Android 安装失败：调用系统安装器时抛了异常
  ///
  /// In zh, this message translates to:
  /// **'拉起安装器失败：{detail}'**
  String updateErrAndroidLaunchFailed(String detail);

  /// 下载失败：SHA-256 与发布说明公布的不一致
  ///
  /// In zh, this message translates to:
  /// **'文件校验和不匹配，可能已损坏或被篡改，已删除。'**
  String get updateErrChecksum;

  /// 下载失败：其他异常，附带异常详情
  ///
  /// In zh, this message translates to:
  /// **'下载失败：{detail}'**
  String updateErrDownloadFailed(String detail);

  /// 下载失败：服务器返回了非 200 状态码
  ///
  /// In zh, this message translates to:
  /// **'下载失败（HTTP {code}）。'**
  String updateErrDownloadHttp(int code);

  /// 下载失败：超时
  ///
  /// In zh, this message translates to:
  /// **'下载超时。'**
  String get updateErrDownloadTimeout;

  /// 检查失败：GitHub 返回 403/429 但不是配额耗尽
  ///
  /// In zh, this message translates to:
  /// **'GitHub 拒绝了这次请求（{code}）。稍后再试。'**
  String updateErrGithubRefused(int code);

  /// 检查失败：其他 HTTP 状态码
  ///
  /// In zh, this message translates to:
  /// **'检查失败（HTTP {code}）。'**
  String updateErrHttp(int code);

  /// 安装失败：安装器没有给出更具体的原因
  ///
  /// In zh, this message translates to:
  /// **'安装失败。'**
  String get updateErrInstallFailed;

  /// iOS 安装失败：App 内不能安装更新包
  ///
  /// In zh, this message translates to:
  /// **'iOS 无法在 App 内安装更新包。'**
  String get updateErrIosCannotInstall;

  /// iOS 安装前检查失败：App 内不能自我更新
  ///
  /// In zh, this message translates to:
  /// **'iOS 无法在 App 内自我更新：请通过 TestFlight 更新，或用电脑重新侧载新版本 .ipa。'**
  String get updateErrIosNoSelfUpdate;

  /// 检查失败：发布信息 JSON 解析不出来
  ///
  /// In zh, this message translates to:
  /// **'发布信息格式异常，无法解析。'**
  String get updateErrMalformed;

  /// 下载失败：当前平台没有对应的安装包
  ///
  /// In zh, this message translates to:
  /// **'这个平台没有可下载的安装包。'**
  String get updateErrNoAsset;

  /// 检查失败：仓库里没有任何 release
  ///
  /// In zh, this message translates to:
  /// **'仓库还没有发布任何版本。'**
  String get updateErrNoReleases;

  /// 安装失败：还没有下载过安装包
  ///
  /// In zh, this message translates to:
  /// **'还没有下载好的安装包。'**
  String get updateErrNotDownloaded;

  /// 检查失败：断网、DNS 或 TLS 问题
  ///
  /// In zh, this message translates to:
  /// **'连不上网络，暂时查不了更新。'**
  String get updateErrOffline;

  /// 检查失败：GitHub 限流，且不知道多久恢复
  ///
  /// In zh, this message translates to:
  /// **'GitHub 接口调用次数用完了（未登录每小时 60 次）。稍后再试。'**
  String get updateErrRateLimited;

  /// 检查失败：GitHub 限流，并给出还有多少分钟恢复
  ///
  /// In zh, this message translates to:
  /// **'{minutes, plural, other{GitHub 接口调用次数用完了（未登录每小时 60 次），约 {minutes} 分钟后恢复。稍后再试。}}'**
  String updateErrRateLimitedUntil(int minutes);

  /// 下载失败：收到的字节数与发布信息声明的不一致
  ///
  /// In zh, this message translates to:
  /// **'下载的文件大小不对（期望 {expected} 字节，实际 {actual}），已删除。'**
  String updateErrSizeMismatch(int expected, int actual);

  /// 检查失败：请求超时
  ///
  /// In zh, this message translates to:
  /// **'网络超时，暂时查不了更新。'**
  String get updateErrTimeout;

  /// 检查失败：当前版本号字符串解析不出来
  ///
  /// In zh, this message translates to:
  /// **'无法识别当前版本号（{version}）'**
  String updateErrUnknownVersion(String version);

  /// Windows 安装失败：拉起助手脚本时出错
  ///
  /// In zh, this message translates to:
  /// **'安装启动失败：{detail}'**
  String updateErrWinLaunchFailed(String detail);

  /// Windows 安装前检查失败：定位不到安装目录
  ///
  /// In zh, this message translates to:
  /// **'找不到安装目录，请手动下载新版本覆盖安装。'**
  String get updateErrWinNoInstallDir;

  /// Windows 安装前检查失败：安装目录没有写权限
  ///
  /// In zh, this message translates to:
  /// **'安装目录不可写（通常是装在 Program Files 且未以管理员身份运行）。请手动下载新版本，或把 Lares 移到用户目录后再试。'**
  String get updateErrWinNotWritable;

  /// Windows 安装失败：解压后找不到可执行文件
  ///
  /// In zh, this message translates to:
  /// **'更新包内容异常（未找到 {name}），已中止，当前版本未被改动。'**
  String updateErrWinPackageInvalid(String name);

  /// Windows 安装前检查失败：探测写权限时抛了异常
  ///
  /// In zh, this message translates to:
  /// **'无法确认安装目录是否可写：{detail}'**
  String updateErrWinProbeFailed(String detail);

  /// Windows 安装失败：解压更新包时出错，附带解压器输出
  ///
  /// In zh, this message translates to:
  /// **'更新包解压失败：{detail}'**
  String updateErrWinUnzipFailed(String detail);

  /// 关闭安装指引弹窗的按钮
  ///
  /// In zh, this message translates to:
  /// **'知道了'**
  String get updateGotIt;

  /// 安装确认弹窗里确认安装的按钮
  ///
  /// In zh, this message translates to:
  /// **'安装并重启'**
  String get updateInstallAndRestart;

  /// 安装前确认弹窗的正文，说明会重启并断开连接
  ///
  /// In zh, this message translates to:
  /// **'Lares 会关闭，替换程序文件后自动重新启动。\n如果你正在圈子里说话，会先断开连接。'**
  String get updateInstallConfirmBody;

  /// 安装前确认弹窗的标题
  ///
  /// In zh, this message translates to:
  /// **'现在安装更新？'**
  String get updateInstallConfirmTitle;

  /// 开始安装已下载更新包的按钮
  ///
  /// In zh, this message translates to:
  /// **'立即安装'**
  String get updateInstallNow;

  /// 安装已启动、但安装器没有给出更具体指引时的提示
  ///
  /// In zh, this message translates to:
  /// **'已开始安装。'**
  String get updateInstallStarted;

  /// 完整性级别：大小与已公布的 SHA-256 都核对通过
  ///
  /// In zh, this message translates to:
  /// **'完整性：文件大小一致，且 SHA-256 与发布说明中公布的校验和匹配。'**
  String get updateIntegrityFull;

  /// 完整性级别：什么都没能核对
  ///
  /// In zh, this message translates to:
  /// **'完整性：未能校验（发布信息未提供大小）。'**
  String get updateIntegrityNone;

  /// 完整性级别：只核对了文件大小
  ///
  /// In zh, this message translates to:
  /// **'完整性：仅核对了文件大小与 GitHub 声明一致（发布说明未提供校验和，无法验证内容真伪；传输安全依赖 HTTPS）。'**
  String get updateIntegritySizeOnly;

  /// 安装确认弹窗里推迟安装的按钮
  ///
  /// In zh, this message translates to:
  /// **'稍后'**
  String get updateLater;

  /// macOS 安装指引：手动把新版本拖进「应用程序」的分步说明
  ///
  /// In zh, this message translates to:
  /// **'已在访达中为你打开新版本：\n1. 退出正在运行的 Lares；\n2. 把新的 lares_app.app 拖进「应用程序」，选择替换；\n3. 首次打开若提示「无法验证开发者」，右键点图标选「打开」。'**
  String get updateMacosDragToApps;

  /// 承载多步安装指引的弹窗标题
  ///
  /// In zh, this message translates to:
  /// **'接下来这样做'**
  String get updateNextStepsTitle;

  /// 发布说明为空时的占位文字
  ///
  /// In zh, this message translates to:
  /// **'（这个版本没有写更新说明）'**
  String get updateNoReleaseNotes;

  /// iOS 平台无法自助更新的说明
  ///
  /// In zh, this message translates to:
  /// **'iOS 无法在 App 内更新。若用 TestFlight 安装，请到 TestFlight 更新；若是免费签名侧载，签名 7 天到期后需要用电脑重新侧载新版本 .ipa。'**
  String get updateNoticeIos;

  /// macOS 只能下载并引导、不能自动安装的说明
  ///
  /// In zh, this message translates to:
  /// **'macOS 需要你手动把新版本拖进「应用程序」完成替换，下载后会自动打开访达。'**
  String get updateNoticeMacos;

  /// 该发布版本没有当前平台安装包时的说明
  ///
  /// In zh, this message translates to:
  /// **'这个版本没有为当前平台提供可下载的安装包，请到 GitHub Releases 页面手动获取。'**
  String get updateNoticeNoAssetForPlatform;

  /// Web 平台无需自助更新的说明
  ///
  /// In zh, this message translates to:
  /// **'Web 版随服务端更新：强制刷新页面（Ctrl/Cmd + Shift + R）即可。'**
  String get updateNoticeWeb;

  /// 需要退出应用才能完成安装时的提示
  ///
  /// In zh, this message translates to:
  /// **'正在退出以完成更新…'**
  String get updateQuitting;

  /// 只能下载并引导的平台（macOS）上，替代「立即安装」的按钮
  ///
  /// In zh, this message translates to:
  /// **'打开所在文件夹'**
  String get updateRevealFolder;

  /// 更新状态：查到了更新的版本
  ///
  /// In zh, this message translates to:
  /// **'发现新版本 v{version}'**
  String updateStatusAvailable(String version);

  /// 更新状态：检查失败且没有更具体的原因
  ///
  /// In zh, this message translates to:
  /// **'检查失败。'**
  String get updateStatusCheckFailed;

  /// 更新状态：正在向 GitHub 查询新版本
  ///
  /// In zh, this message translates to:
  /// **'正在检查…'**
  String get updateStatusChecking;

  /// 更新状态：安装包下载中
  ///
  /// In zh, this message translates to:
  /// **'正在下载更新包…'**
  String get updateStatusDownloading;

  /// 更新状态：本次启动后还没检查过
  ///
  /// In zh, this message translates to:
  /// **'还没检查过更新。'**
  String get updateStatusIdle;

  /// 更新状态：安装包已下载完，等待用户确认安装
  ///
  /// In zh, this message translates to:
  /// **'下载完成，可以安装了。'**
  String get updateStatusReady;

  /// 更新状态：没有可用的新版本
  ///
  /// In zh, this message translates to:
  /// **'已是最新版本。'**
  String get updateStatusUpToDate;

  /// 更新面板的标题
  ///
  /// In zh, this message translates to:
  /// **'版本与更新'**
  String get updateTitle;

  /// 读取当前版本号失败时，更新面板右上角的替代文字
  ///
  /// In zh, this message translates to:
  /// **'当前版本未知'**
  String get updateVersionUnknown;

  /// Windows 安装已就绪：应用即将退出并自动重启
  ///
  /// In zh, this message translates to:
  /// **'即将退出并完成更新，几秒后会自动重新启动。'**
  String get updateWinRestarting;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
