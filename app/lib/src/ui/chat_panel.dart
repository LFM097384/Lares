import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/gen/app_localizations.dart';
import '../chat/chat_limits.dart';
import '../chat/chat_message.dart';
import '../chat/chat_service.dart';
import '../chat/chat_text.dart';
import '../chat/image_source.dart'
    if (dart.library.io) '../chat/image_source_io.dart';
import '../config.dart';
import '../moderation/block_store.dart';
import '../theme/tokens.dart';
import 'moderation_menus.dart';

// ── 就地常量 ──
// tokens.dart 只收录颜色/圆角/间距/断点,没有时长 token,也没有字阶 token,
// 所以本文件用到的时长/尺寸一律在此就地定义,而不是散落在 build 里。
// 将来若补了全局时长 token,只需改这几行。

/// 展开/收起动画时长。180~220ms 是「看得见但不打断」的区间,
/// 配合 easeOutCubic 收尾很轻 —— 面板是侧信道,不该抢语音的注意力(设计.md §2.3)。
const Duration _expandDuration = Duration(milliseconds: 200);

/// 新消息到达时列表滚到底的时长。比展开更短:这是跟随动作,不是状态切换。
const Duration _scrollDuration = Duration(milliseconds: 160);

/// 未读圆点直径。只有「有没有」两种语义,所以小到不打扰即可。
const double _unreadDotSize = 8;

/// 发送中的整体透明度。压到半透明表示「还没落定」,不用转圈不用进度条。
const double _sendingOpacity = 0.55;

/// 失败标记的图标尺寸,与 bodyMedium 字号同量级,不喧宾夺主。
const double _failedIconSize = 14;

/// 缩略图逻辑宽度。侧信道里的图只需「看得出是什么」,点开才看全图。
const double _thumbWidth = 160;

/// 拿不到原图尺寸时的占位宽高比(4:3),仅用于避免图片到达时列表跳动。
const double _fallbackAspect = 4 / 3;

/// 大图查看器的最大缩放倍数。
const double _viewerMaxScale = 5;

/// 大图查看器占屏高比例。留白让「点空白关闭」有地方可点。
const double _viewerHeightFactor = 0.72;

/// 输入框单行行高基准 = bodyLarge 的 fontSize(16) × height(1.5)。
/// 与主题里的实际值对齐,改主题时记得同步。
const double _composerLineHeight = 24;

/// 输入框最多长到几行,再多就内部滚动。
/// 三行足够写完一句话,更多会把成员网格挤走 —— 语音仍是第一优先级(设计.md §3.2)。
const int _composerMaxLines = 3;

/// 剩余字数提示的触发阈值:只在最后 50 个字素簇内出现。
/// 常驻计数器会把「随手说一句」变成「完成一项任务」,与低唤醒基调相悖。
const int _remainingHintThreshold = 50;

/// 面板占屏高预算上限。列表 + 输入框 + 边饰全部塞进这个额度内,
/// 保证 RoomScreen 里那个 Expanded 兄弟节点永远还剩得下空间。
const double _panelHeightBudget = 0.6;

/// 消息列表的目标占屏高比例(约四成),再按预算和绝对上下限收敛。
const double _listHeightFactor = 0.4;

/// 消息列表绝对高度上下限。上限 320 是「一屏能扫完的对话」;
/// 下限 0 是刻意的:窗口极矮时宁可把列表压没,也不许溢出。
const double _listHeightMin = 0;
const double _listHeightMax = 320;

/// 面板自身的固定边饰高度(上下内边距 + 分隔线),参与高度预算的算术。
const double _panelChromeHeight = 24;

/// 面板能冒出的三种安静提示。
///
/// 刻意存标识而不存译好的字符串:本地化文案不是编译期常量,更重要的是
/// State 里攥着一句中文/英文,用户中途切语言它就留在旧语言上了。
/// 存 enum、在 UI 层查表(见 [_noticeText]),与 l10n 规范里
/// 「模型只存语义 key,翻译放 UI 层」同构 —— 这里的「模型」就是面板自己的 State。
enum _Notice {
  /// 文字消息没能发出去(意料之外的错;传输失败由 ChatService 自己标 failed)。
  sendFailed,

  /// 系统选图器自身失败(筛选器配错、权限被拒、文件读不出来)。
  pickFailed,

  /// 图片没能发出去(通常是超限,一个包都没发)。
  imageSendFailed,
}

/// [_Notice] 到文案的查表。放 UI 层,拿得到 context。
String _noticeText(BuildContext context, _Notice notice) {
  final AppLocalizations t = AppLocalizations.of(context);
  return switch (notice) {
    _Notice.sendFailed => t.chatSendFailed,
    _Notice.pickFailed => t.chatImagePickFailed,
    _Notice.imageSendFailed => t.chatImageSendFailed,
  };
}

/// 文字+图片侧信道面板(设计.md §2.3 的定向翻案)。
///
/// 设计.md §2.3 原写「不做打字聊天区(保持语音优先)」,现由 owner 明确翻案:
/// 加文字与图片,但**语音仍是第一优先级**,本面板只是安静的侧信道 ——
/// 「说不了话的时候,丢个链接、一张图、一句话的地方」,不是微信。
///
/// 因此贯穿全文件的三条纪律:
///  1. 默认收起,绝不挤占成员网格与主麦克风按钮;
///  2. 未读只用一颗余烬圆点表示,**没有数字、没有红色角标、没有提示音**;
///  3. 失败、超限、空消息一律安静处理,不弹横幅不弹 SnackBar(设计.md §2.2)。
///
/// 仓库不使用 Provider / InheritedWidget:协作者一律构造函数注入,
/// 再用 [ListenableBuilder] 在叶子节点就地重建(与 room_screen.dart 一致)。
class ChatPanel extends StatefulWidget {
  const ChatPanel({
    super.key,
    required this.chat,
    this.onPickImage, // 可选:外部注入选图实现(依赖到位后接上)
    this.enterToSend, // null = 按平台推断
    this.initiallyExpanded = false,
    this.blocks,
  });

  /// 消息源与发送入口。面板自身不持有任何消息状态。
  final ChatService chat;

  /// 屏蔽名单(App Store 审核指南 1.2)。非空时:
  /// 列表改渲染 [ChatService.visibleMessages](已过滤屏蔽者),
  /// 且长按别人的消息能开处置菜单。为 null 时整套退回原行为,不崩不变
  /// (既有测试就是 `ChatPanel(chat: chat)` 这么构造的)。
  final BlockStore? blocks;

  /// 外部注入的选图实现。非空时优先于 [pickImage]。
  ///
  /// 存在的理由很实际:[isImagePickSupported] 现在各平台都是 true,走的是
  /// file_selector 的系统对话框——而系统对话框在 widget 测试里没法弹,
  /// 宿主也可能想换自己的选图入口(相册、拖拽、粘贴)。这个口子让二者
  /// 都能把真实字节直接喂进来,从而让「选图 → 发送 → 渲染」整条链路可端到端跑通。
  final Future<PickedImage?> Function()? onPickImage;

  /// 回车是否直接发送。null 表示按平台推断([LaresConfig.isDesktop])。
  ///
  /// 留这个覆盖位有两个用途:一是测试要能分别验证桌面与触摸两条分支
  /// (测试 VM 上 `dart.library.io` 为真,推断结果恒为 true,不覆盖就测不到另一半);
  /// 二是将来做「回车发送」用户偏好开关时,这里就是现成的接线点。
  final bool? enterToSend;

  /// 初始是否展开。默认收起 —— 这是产品纪律,不是实现细节。
  final bool initiallyExpanded;

  @override
  ChatPanelState createState() => ChatPanelState();
}

/// 刻意公开(而非 `_ChatPanelState`):测试需要用
/// `tester.state<ChatPanelState>(...)` 拿到 [ChatPanelState.debugIngestImage]。
/// 与 Flutter 自身 `ScaffoldState` 的做法一致。
class ChatPanelState extends State<ChatPanel> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode(debugLabel: 'ChatPanel composer');

  late bool _expanded = widget.initiallyExpanded;

  /// 上一次见到的消息条数,用来判断「是新增」还是「只是状态变了」。
  late int _lastMessageCount = widget.chat.messages.length;

  /// 派生自输入内容的三个值,缓存下来只为避免每次按键都无谓 setState。
  bool _canSend = false;
  bool _showRemaining = false;
  int _remaining = maxTextGraphemes;

  /// 一句平静的失败提示。null 表示无事发生。
  /// 刻意不是 SnackBar:SnackBar 会浮起来抢注意力,这里只要一行小字。
  /// 只存标识,译文在渲染时查表 —— 见 [_Notice]。
  _Notice? _notice;

  @override
  void initState() {
    super.initState();
    widget.chat.addListener(_onChatChanged);
    _controller.addListener(_onTextChanged);
    if (_expanded) {
      // 初始就展开时也要清未读,但必须等第一帧画完 —— 见 _afterFrame 的说明。
      _afterFrame(_markReadAndFollow);
    }
  }

  @override
  void didUpdateWidget(covariant ChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.chat, widget.chat)) {
      oldWidget.chat.removeListener(_onChatChanged);
      widget.chat.addListener(_onChatChanged);
      _lastMessageCount = widget.chat.messages.length;
    }
  }

  @override
  void dispose() {
    widget.chat.removeListener(_onChatChanged);
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 把回调推迟到当前帧画完之后再执行,并统一做 mounted 检查。
  ///
  /// 为什么非这样不可:[ChatService.markRead] 内部会 `notifyListeners()`,
  /// 而本组件正通过 [ListenableBuilder] 监听同一个 notifier ——
  /// 在 build 期间同步调用会直接撞上「setState() called during build」。
  void _afterFrame(VoidCallback action) {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      action();
    });
  }

  void _markReadAndFollow() {
    widget.chat.markRead();
    _scrollToNewest();
  }

  /// 消息源有任何变化时触发(新消息 / 发送态翻转 / 未读清零)。
  void _onChatChanged() {
    final int count = widget.chat.messages.length;
    final bool grew = count > _lastMessageCount;
    _lastMessageCount = count;

    // 收起状态下**不**清未读:那颗圆点正是「有话没看」的唯一提示,
    // 面板没打开就把它抹掉,等于没提示过。
    if (!_expanded) return;

    // markRead() 自己也会回调到这里。没新消息又没未读时直接返回,掐断空转。
    if (!grew && widget.chat.unreadCount == 0) return;

    _afterFrame(() {
      widget.chat.markRead();
      if (grew) _scrollToNewest();
    });
  }

  void _onTextChanged() {
    final String raw = _controller.text;
    final bool canSend = normalizeOutgoing(raw) != null;

    // String.length(UTF-16 码元数)恒 >= 字素簇数,所以长度离阈值还远时
    // 根本不必遍历整串。粘进一万字后每次按键都全串数字素簇,白白卡手。
    final int remaining;
    if (raw.length <= maxTextGraphemes - _remainingHintThreshold) {
      remaining = _remainingHintThreshold + 1; // 只需知道「还早着呢」
    } else {
      // 用 chat_text.dart 的 graphemeCount,与 capGraphemes 的截断口径严格一致
      remaining = maxTextGraphemes - graphemeCount(raw);
    }
    final bool showRemaining = remaining <= _remainingHintThreshold;

    if (canSend == _canSend &&
        showRemaining == _showRemaining &&
        remaining == _remaining) {
      return;
    }
    setState(() {
      _canSend = canSend;
      _showRemaining = showRemaining;
      _remaining = remaining;
    });
  }

  void _toggleExpanded() {
    setState(() {
      _expanded = !_expanded;
      _notice = null; // 换个状态就把旧提示收掉,不让它赖着
    });
    if (_expanded) _afterFrame(_markReadAndFollow);
  }

  void _scrollToNewest() {
    if (!_scroll.hasClients) return;
    // 轻轻滑过去,不是「咣」地跳到底
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: _scrollDuration,
      curve: Curves.easeOutCubic,
    );
  }

  void _setNotice(_Notice? notice) {
    if (!mounted || _notice == notice) return;
    setState(() => _notice = notice);
  }

  Future<void> _send() async {
    // 空/纯空白一律静默拒发:不报错、不抖动、不置灰闪烁(设计.md §2.3 低唤醒)
    final String? body = normalizeOutgoing(_controller.text);
    if (body == null) return;

    // 按字素簇截断,绝不把 👨‍👩‍👧‍👦 这类 ZWJ 序列拦腰劈开
    final String text = capGraphemes(body, maxTextGraphemes);

    // 只在确认可发之后才清空:被拒的输入永远原样留在框里。
    // 清空放在 await 之前,是因为 ChatService 已经做了乐观回显 ——
    // 消息此刻已经在列表里了,输入框再攥着同一份文字只会让人以为没发出去。
    _controller.clear();
    _setNotice(null);

    try {
      await widget.chat.sendText(text);
    } catch (_) {
      // 传输失败由 ChatService 自己标成 failed,并不抛异常;
      // 能走到这儿的是意料之外的错。把原文还给用户,别让人白打一遍。
      if (!mounted) return;
      _controller.text = text;
      _setNotice(_Notice.sendFailed);
    }
  }

  Future<void> _handlePickImage() async {
    final Future<PickedImage?> Function() picker = widget.onPickImage ?? pickImage;
    PickedImage? picked;
    try {
      picked = await picker();
    } catch (_) {
      // pickImage() 只对「用户取消」返回 null,真失败(筛选器配错、权限被拒、
      // 文件读不出来)一律上抛,由这里兜住。这行小字就是用户唯一能看见的痕迹——
      // 曾经它被下层吞掉,结果 iOS 上按钮点了毫无反应,谁也不知道出了事。
      _setNotice(_Notice.pickFailed);
      return;
    }
    // null = 用户取消(或选了个空文件)。不是错误,什么都不做。
    if (picked == null) return;
    await _sendImage(picked.bytes, width: picked.width, height: picked.height);
  }

  Future<void> _sendImage(Uint8List bytes, {int? width, int? height}) async {
    _setNotice(null);
    try {
      await widget.chat.sendImage(bytes, width: width, height: height);
    } catch (_) {
      // 宽 catch 是刻意的:图片超限会被同步抛出(一个包都没发),
      // 但这里**不** import 那个具体异常类型 —— 面板不该和 chat_service
      // 的实现细节耦合,它今天叫什么、明天改不改名都不该影响 UI 编译。
      // 宽 catch 不等于吞掉:下面这行小字就是用户能看见的痕迹。
      _setNotice(_Notice.imageSendFailed);
    }
  }

  /// 直接把图片字节喂进发送链路,绕开系统选图器。
  ///
  /// 存在的理由:[isImagePickSupported] 虽然各平台都是 true,但它背后是
  /// file_selector 的**系统文件对话框**——widget 测试里弹不出来、也点不了。
  /// 没有这个口子,「图片消息」这条链路就一行都测不到。
  /// 有了它,测试可以喂一张真 PNG 进来,把发送 → 回显 → 缩略图 → 点开大图
  /// 整条路径跑穿。生产代码请走 [ChatPanel.onPickImage]。
  @visibleForTesting
  Future<void> debugIngestImage(Uint8List bytes, {int? width, int? height}) =>
      _sendImage(bytes, width: width, height: height);

  /// 长按一条别人的消息:开处置菜单(屏蔽 / 举报)。
  ///
  /// 菜单是个 modal,不违反本面板「不弹横幅、不弹 SnackBar」的纪律 ——
  /// 那三条禁令针对的是**面板自己主动**冒出来的提示,
  /// 用户按住一条消息后主动召来的菜单是另一回事。
  Future<void> _moderate(BlockStore blocks, ChatMessage message) {
    return showMessageModerationSheet(
      context,
      blocks: blocks,
      message: message,
      reporterUserId: widget.chat.userId,
      circleId: message.circleId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 高度必须自己算,不能指望父级约束:RoomScreen 把本面板放在 Column 里,
    // 旁边还有个 Expanded 兄弟 —— Column 给非 flex 子节点的主轴约束是**无限**,
    // 所以 LayoutBuilder 拿到的 maxHeight 会是 infinity,只能回到屏幕尺寸来算。
    final double screenHeight = MediaQuery.sizeOf(context).height;

    // 输入框上限按当前字体缩放算,而不是钉死像素:大字号下硬上限会把文字压扁。
    final double scaledLine =
        MediaQuery.textScalerOf(context).scale(_composerLineHeight);
    final double idealComposer = scaledLine * _composerMaxLines + LaresSpacing.md;

    // 但「按字号放大」不能没有上限。超大字号(3×)下仅输入框自己就要 232px,
    // 而列表已经能缩到 0 —— 再没有可让的空间,于是溢出的是整个面板。
    // 所以输入框也必须夹在同一份预算里,超出部分改为框内滚动
    // (maxLines: null + 有界 ConstrainedBox 本来就支持)。
    // 下限保一行:宁可只剩一行,也不能夹成 0 让人没法打字。
    final double composerBudget = screenHeight * _panelHeightBudget -
        _panelChromeHeight -
        // 提示行可能出现,先把它的位置留出来再谈输入框能长多高
        ((_showRemaining || _notice != null)
            ? MediaQuery.textScalerOf(context).scale(_composerLineHeight) +
                LaresSpacing.xs
            : 0);
    final double oneLineFloor = scaledLine + LaresSpacing.md;
    final double composerMaxHeight = idealComposer.clamp(
      oneLineFloor,
      // 预算比一行还窄时(极端矮窗),clamp 的上下限会倒挂,取下限保底
      composerBudget < oneLineFloor ? oneLineFloor : composerBudget,
    );

    // 提示行(剩余字数 / 发送失败)也要占预算。它们平时不出现,一旦出现
    // 又恰逢超大字号,一行「还能写 N 个字」会折成好几行 —— 实测 3× 下高达 189px,
    // 比输入框还高。所以两件事一起做:这里按最多两行预留,
    // 渲染侧再把它们各自限死一行(见 _Composer 里的 maxLines)。
    final double hintReserve = _showRemaining || _notice != null
        ? scaledLine + LaresSpacing.xs
        : 0;

    // 列表高度 = min(四成屏高, 预算里刨掉输入框、提示行和边饰之后还剩的),再夹到绝对上下限。
    // 先扣输入框再分给列表,保证窄窗口 + 大字号时被牺牲的是列表而不是布局完整性。
    // 注意这里用的是**夹过之后**的输入框高度,让下面的列表算术保持不变。
    final double budgetLeft = screenHeight * _panelHeightBudget -
        composerMaxHeight -
        hintReserve -
        _panelChromeHeight;
    final double wanted = screenHeight * _listHeightFactor;
    final double listMaxHeight = (wanted < budgetLeft ? wanted : budgetLeft)
        .clamp(_listHeightMin, _listHeightMax);

    final bool imagePickEnabled =
        widget.onPickImage != null || isImagePickSupported;
    final bool enterToSend = widget.enterToSend ?? LaresConfig.isDesktop;

    // 提到局部变量,好让下面的空判定能提升类型(widget.blocks 是字段,提升不了)
    final BlockStore? blocks = widget.blocks;
    // 没接屏蔽名单就传 null,_MessageRow 那边收到 null 便完全不挂手势 ——
    // 与本面板一贯的降级方式一致。
    final ValueChanged<ChatMessage>? onModerate =
        blocks == null ? null : (ChatMessage m) => _moderate(blocks, m);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(LaresRadii.lg),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 只有消息区订阅 chat:输入框的可用态只取决于本地文字,
          // 让它跟着每条新消息一起重建纯属浪费(与 room_screen.dart 的叶子重建同构)。
          ListenableBuilder(
            // blocks 必须并进来:屏蔽发生在 BlockStore 上,chat 不会为此 notify,
            // 不合并就会「屏蔽了但那条消息还挂在列表里」。
            listenable: Listenable.merge(<Listenable?>[widget.chat, blocks]),
            builder: (BuildContext context, Widget? child) {
              return AnimatedSize(
                duration: _expandDuration,
                curve: Curves.easeOutCubic,
                alignment: Alignment.bottomCenter,
                child: _expanded
                    ? _MessageList(
                        // 接了屏蔽名单就渲染已过滤的那份;没接则保持原样。
                        // visibleMessages 是读取时过滤,解除屏蔽后历史原样回来。
                        messages: blocks == null
                            ? widget.chat.messages
                            : widget.chat.visibleMessages,
                        scrollController: _scroll,
                        maxHeight: listMaxHeight,
                        onModerate: onModerate,
                      )
                    // 收起时高度归零,宽度撑满,避免动画过程中横向也跟着抖
                    : const SizedBox(width: double.infinity),
              );
            },
          ),
          _Composer(
            chat: widget.chat,
            controller: _controller,
            focusNode: _focus,
            expanded: _expanded,
            enterToSend: enterToSend,
            canSend: _canSend,
            remaining: _showRemaining ? _remaining : null,
            notice: _notice,
            imagePickEnabled: imagePickEnabled,
            maxHeight: composerMaxHeight,
            onToggle: _toggleExpanded,
            onSend: _send,
            onPickImage: _handlePickImage,
          ),
        ],
      ),
    );
  }
}

/// 消息列表。新的在**后**,所以正序渲染、滚到底就是最新。
class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.messages,
    required this.scrollController,
    required this.maxHeight,
    this.onModerate,
  });

  final List<ChatMessage> messages;
  final ScrollController scrollController;
  final double maxHeight;

  /// 长按一条消息时的处置回调。null = 没接屏蔽名单,不挂任何手势。
  /// 仓库风格是「要什么就从构造函数传进来」(参见 _Composer 的 `final ChatService chat;`),
  /// 不搞 Provider / InheritedWidget。
  final ValueChanged<ChatMessage>? onModerate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (messages.isEmpty) {
      // 空态要暖,不能像报错。这里刻意不用图标、不用边框、不占满高度。
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LaresSpacing.md,
          vertical: LaresSpacing.lg,
        ),
        child: Text(
          AppLocalizations.of(context).chatEmpty,
          style: theme.textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      );
    }

    // 定高 + ListView:高度由外部算好,列表在盒子里自己滚。
    // 有界的 ListView 不需要 shrinkWrap(那会强制整表布局,长列表直接卡死)。
    return SizedBox(
      height: maxHeight,
      child: ListView.builder(
        controller: scrollController,
        padding: const EdgeInsets.symmetric(
          horizontal: LaresSpacing.md,
          vertical: LaresSpacing.sm,
        ),
        itemCount: messages.length,
        itemBuilder: (BuildContext context, int index) {
          final ChatMessage message = messages[index];
          final ChatMessage? previous = index == 0 ? null : messages[index - 1];
          // 同一个人连着说话时不再重复顶名字,读起来安静得多
          final bool showHeader =
              previous == null || previous.senderId != message.senderId;
          return _MessageRow(
            message: message,
            showHeader: showHeader,
            onModerate: onModerate,
          );
        },
      ),
    );
  }
}

/// 单条消息。自己发的只用一层极淡的余烬底色 + 右对齐来区分,
/// 刻意不做高对比气泡 —— 那是聊天软件的语言,不是炉灵的(设计.md §2.3)。
class _MessageRow extends StatelessWidget {
  const _MessageRow({
    required this.message,
    required this.showHeader,
    this.onModerate,
  });

  final ChatMessage message;
  final bool showHeader;

  /// 长按处置回调。null 或自己发的消息一律不挂手势(屏蔽/举报自己没有意义)。
  final ValueChanged<ChatMessage>? onModerate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool mine = message.isMine;

    final Widget body = message.kind == ChatMessageKind.image
        ? _ImageThumb(message: message)
        : Text(message.text ?? '', style: theme.textTheme.bodyLarge);

    final ValueChanged<ChatMessage>? moderate = onModerate;

    return Padding(
      padding: const EdgeInsets.only(bottom: LaresSpacing.sm),
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: <Widget>[
          if (showHeader)
            Padding(
              padding: const EdgeInsets.only(bottom: LaresSpacing.xs),
              // bodyMedium 本身已是次要色,时间戳直接用它,不再 copyWith 调色
              child: Text(
                '${message.senderName}  ${_formatHm(message.timestamp)}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          GestureDetector(
            // 长按别人的消息 = 处置菜单(屏蔽/举报)。自己的消息不挂,
            // 没接屏蔽名单也不挂 —— onLongPress 为 null 时 GestureDetector
            // 根本不参与命中测试,原来点缩略图看大图的手势一点不受影响。
            onLongPress: (moderate == null || mine)
                ? null
                : () => moderate(message),
            child: Opacity(
              // 发送中压暗,表示「还没落定」。不转圈、不进度条。
              opacity: message.state == ChatDeliveryState.sending
                  ? _sendingOpacity
                  : 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: mine ? LaresColors.emberSoft : null,
                  borderRadius: BorderRadius.circular(LaresRadii.sm),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LaresSpacing.sm,
                    vertical: LaresSpacing.xs,
                  ),
                  child: body,
                ),
              ),
            ),
          ),
          if (message.state == ChatDeliveryState.failed) const _FailedMark(),
        ],
      ),
    );
  }
}

/// 发送失败的行内小标记。一个小图标 + 四个字,用 error 色但只染这一处。
/// 不是横幅、不是 SnackBar:失败是个事实,不是个事件。
class _FailedMark extends StatelessWidget {
  const _FailedMark();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: LaresSpacing.xs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.error_outline_rounded,
            size: _failedIconSize,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: LaresSpacing.xs),
          Text(
            AppLocalizations.of(context).chatSendFailed,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ],
      ),
    );
  }
}

/// 行内缩略图。点一下进大图。
class _ImageThumb extends StatelessWidget {
  const _ImageThumb({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final Uint8List? bytes = message.imageBytes;
    // kind 是 image 但字节为空 = 接收端重组失败留下的占位,不是 bug,别崩
    if (bytes == null) return const _ImagePlaceholder();

    // cacheWidth 让解码阶段就降采样:缩略图只有 _thumbWidth 逻辑像素宽,
    // 按原分辨率解一张 256 KiB 的图纯属拿内存换空气。乘 dpr 才不会糊。
    final int cacheWidth =
        (_thumbWidth * MediaQuery.devicePixelRatioOf(context)).round();

    // 先用发送方带来的宽高占好位,图片解码完成时列表就不会往下一跳
    final int? width = message.imageWidth;
    final int? height = message.imageHeight;
    final double aspect = (width != null && height != null && height > 0)
        ? width / height
        : _fallbackAspect;

    return Semantics(
      label: AppLocalizations.of(context).chatImageOpen,
      button: true,
      child: InkWell(
        onTap: () => _openImageViewer(context, bytes),
        borderRadius: BorderRadius.circular(LaresRadii.sm),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(LaresRadii.sm),
          child: SizedBox(
            width: _thumbWidth,
            child: AspectRatio(
              aspectRatio: aspect,
              child: Image.memory(
                bytes,
                cacheWidth: cacheWidth,
                fit: BoxFit.cover,
                // 坏字节要安静地退化成占位,而不是甩一块红底报错出来
                errorBuilder: (
                  BuildContext context,
                  Object error,
                  StackTrace? stackTrace,
                ) =>
                    const _ImagePlaceholder(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 图片缺席时的安静占位:一个灰图标,不带任何错误色。
class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: AppLocalizations.of(context).chatImageMissing,
      child: SizedBox(
        width: _thumbWidth,
        child: AspectRatio(
          aspectRatio: _fallbackAspect,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: LaresColors.emberSoft,
              borderRadius: BorderRadius.circular(LaresRadii.sm),
            ),
            child: Icon(
              Icons.image_not_supported_outlined,
              color: theme.textTheme.bodyMedium?.color,
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _openImageViewer(BuildContext context, Uint8List bytes) {
  return showDialog<void>(
    context: context,
    // 点空白即关。再配一个带 tooltip 的关闭键,两条退路都留着。
    barrierDismissible: true,
    builder: (BuildContext context) => _ImageViewerDialog(bytes: bytes),
  );
}

/// 全屏大图。可缩放、可拖动、点空白或点关闭键都能退出。
class _ImageViewerDialog extends StatelessWidget {
  const _ImageViewerDialog({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Size screen = MediaQuery.sizeOf(context);

    return Dialog(
      backgroundColor: theme.colorScheme.surface,
      insetPadding: const EdgeInsets.all(LaresSpacing.md),
      shape: RoundedRectangleBorder(borderRadius: LaresRadii.cardRadius),
      child: Semantics(
        label: AppLocalizations.of(context).chatImageViewer,
        child: SizedBox(
          // 给个确定尺寸:否则 Dialog 会缩到图片的固有尺寸,
          // 一张 1×1 的图会变成一个看不见的对话框。
          width: screen.width,
          height: screen.height * _viewerHeightFactor,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: InteractiveViewer(
                  maxScale: _viewerMaxScale,
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    errorBuilder: (
                      BuildContext context,
                      Object error,
                      StackTrace? stackTrace,
                    ) =>
                        const Center(child: _ImagePlaceholder()),
                  ),
                ),
              ),
              Positioned(
                top: LaresSpacing.xs,
                right: LaresSpacing.xs,
                child: IconButton(
                  tooltip: AppLocalizations.of(context).chatImageViewerClose,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 未读提示:一颗余烬圆点。**没有数字**,也刻意不用 Material 的 Badge ——
/// 数字会把「有人说了话」变成「有 7 条待办」,那正是设计.md §2.2 要避开的唤醒感。
class _UnreadDot extends StatelessWidget {
  const _UnreadDot();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // 圆点自身不含文字,读屏用户全靠这句
      label: AppLocalizations.of(context).chatUnread,
      child: Container(
        width: _unreadDotSize,
        height: _unreadDotSize,
        decoration: const BoxDecoration(
          color: LaresColors.ember,
          shape: BoxShape.circle,
          // 一圈极淡的光晕,让它像「余烬」而不是「红点」
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: LaresColors.emberSoft,
              blurRadius: 6,
              spreadRadius: 3,
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部常驻栏:展开键(带未读圆点)+ 输入框 + 选图键 + 发送键。
/// 收起时它就是面板的全部 —— 一条窄条,不挡成员网格。
class _Composer extends StatelessWidget {
  const _Composer({
    required this.chat,
    required this.controller,
    required this.focusNode,
    required this.expanded,
    required this.enterToSend,
    required this.canSend,
    required this.remaining,
    required this.notice,
    required this.imagePickEnabled,
    required this.maxHeight,
    required this.onToggle,
    required this.onSend,
    required this.onPickImage,
  });

  final ChatService chat;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool expanded;
  final bool enterToSend;
  final bool canSend;

  /// 剩余可输入字素簇数;null 表示离上限还远,**不显示**计数器。
  final int? remaining;

  /// 一行平静的失败提示;null 表示无事发生。译文在 build 里查表。
  final _Notice? notice;

  final bool imagePickEnabled;
  final double maxHeight;
  final VoidCallback onToggle;
  final VoidCallback onSend;
  final VoidCallback onPickImage;

  /// 回车键处理。三条规矩,缺一不可:
  ///  1. 只认 [KeyDownEvent] —— 放过 KeyRepeatEvent 才不会「按住回车狂发」;
  ///  2. Shift+Enter 返回 ignored,把事件让回输入框去插入换行;
  ///  3. 只有真的吃掉一个裸回车拿去发送时才返回 handled,其余一律 ignored。
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // 触摸端:回车永远是换行,发送只有按钮一条路
    if (!enterToSend) return KeyEventResult.ignored;

    final LogicalKeyboardKey key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    // 查实时修饰键状态,而不是记自己的 shift 按下标志 —— 后者会漏掉焦点切换等情况
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;

    onSend();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final int? left = remaining;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LaresSpacing.sm,
        vertical: LaresSpacing.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (notice != null)
            Padding(
              padding: const EdgeInsets.only(
                left: LaresSpacing.sm,
                bottom: LaresSpacing.xs,
              ),
              // 限一行:超大字号下这句会折成好几行,把面板顶穿。
              // 它只是一句安静的附注,折行反而显得像报错。
              child: Text(
                _noticeText(context, notice!),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          if (left != null)
            Padding(
              padding: const EdgeInsets.only(
                right: LaresSpacing.sm,
                bottom: LaresSpacing.xs,
              ),
              // 只在最后 50 个字素簇内露面。常驻计数器会让人紧张。
              // 同样限一行:3× 字号下它能折到 189px,比输入框还高。
              child: Text(
                AppLocalizations.of(context).chatRemaining(left),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.end,
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              _ToggleButton(chat: chat, expanded: expanded, onToggle: onToggle),
              Expanded(
                child: Focus(
                  onKeyEvent: _onKeyEvent,
                  child: ConstrainedBox(
                    // 粘进一万字也不许把布局撑破:到顶就在输入框内部滚
                    constraints: BoxConstraints(maxHeight: maxHeight),
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      minLines: 1,
                      maxLines: null,
                      keyboardType: TextInputType.multiline,
                      // 桌面端软键盘动作给「发送」,触摸端给「换行」,与回车语义对齐
                      textInputAction: enterToSend
                          ? TextInputAction.send
                          : TextInputAction.newline,
                      onSubmitted:
                          enterToSend ? (String _) => onSend() : null,
                      style: theme.textTheme.bodyLarge,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: AppLocalizations.of(context).chatComposerHint,
                        hintStyle: theme.textTheme.bodyMedium,
                        filled: true,
                        fillColor: theme.scaffoldBackgroundColor,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: LaresSpacing.md,
                          vertical: LaresSpacing.sm,
                        ),
                        border: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(LaresRadii.md),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                // 禁用也要留着入口,不藏 —— 依赖一落地用户就知道该点哪儿
                tooltip: imagePickEnabled
                    ? AppLocalizations.of(context).chatSendImage
                    : AppLocalizations.of(context).chatImagePickUnsupported,
                icon: const Icon(Icons.image_outlined),
                onPressed: imagePickEnabled ? onPickImage : null,
              ),
              IconButton(
                tooltip: AppLocalizations.of(context).chatSend,
                icon: const Icon(Icons.send_rounded),
                color: theme.colorScheme.primary,
                onPressed: canSend ? onSend : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 展开/收起键,未读圆点叠在它右上角。
/// 单独抽出来是为了让那颗圆点自己订阅 chat,而不是拖着整条输入栏一起重建。
class _ToggleButton extends StatelessWidget {
  const _ToggleButton({
    required this.chat,
    required this.expanded,
    required this.onToggle,
  });

  final ChatService chat;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: chat,
      builder: (BuildContext context, Widget? child) {
        final bool hasUnread = chat.unreadCount > 0;
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: <Widget>[
            // IconButton 自带 >=48 的点击区,不额外加 SizedBox
            IconButton(
              tooltip: expanded
                  ? AppLocalizations.of(context).chatCollapse
                  : AppLocalizations.of(context).chatExpand,
              icon: Icon(
                expanded
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.chat_bubble_outline_rounded,
              ),
              onPressed: onToggle,
            ),
            if (hasUnread)
              const Positioned(
                right: LaresSpacing.sm,
                top: LaresSpacing.sm,
                // _UnreadDot 内部读 AppLocalizations,但它自身无字段,
                // 构造仍是 const —— 本地化发生在它的 build 里,不影响这里。
                child: _UnreadDot(),
              ),
          ],
        );
      },
    );
  }
}

/// 时间戳格式化成 `HH:mm`。
/// 项目不引 intl(不新增依赖),而聊天时间戳只需要这一种格式,
/// 手写一行远比为它拉进一整个本地化库划算。
String _formatHm(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}';
