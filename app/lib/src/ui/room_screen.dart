import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../captions/caption_controller.dart';
import '../chat/chat_service.dart';
import '../config.dart';
import '../e2ee/e2ee_controller.dart';
import '../e2ee/e2ee_status.dart';
import '../moderation/block_store.dart';
import '../recording/recording_consent.dart';
import '../recording/recording_indicator.dart';
import '../state/location_share_stub.dart'
    if (dart.library.io) '../state/location_share.dart';
import '../state/mic_notice.dart';
import '../state/models.dart';
import '../state/room_controller.dart';
import '../state/settings_store.dart';
import '../state/voice_notes.dart';
import '../theme/tokens.dart';
import 'caption_panel.dart';
import 'chat_panel.dart';
import 'map_panel.dart';
import '../transcript/transcript_scope.dart';
import 'moderation_menus.dart';
import 'widgets/avatar_orb.dart';
import 'widgets/e2ee_badge.dart';

// ── 就地常量 ──
// tokens.dart 没有「图标尺寸」这一档,被屏蔽标记的两个尺寸就地定义。

/// 被屏蔽成员的头像压到多暗。压到四成是「一眼看出不一样」又「还认得出是谁」
/// 的平衡点 —— 全糊掉反而让人不知道自己屏蔽了谁。
const double _blockedAvatarOpacity = 0.4;

/// 被屏蔽角标的图标尺寸,与 AvatarOrb 里的静音标记同量级。
const double _blockedBadgeIconSize = 16;

/// 房间内界面(设计.md §3.2-2):极简 —— 头像网格 + 波纹 + 底部两个主按钮。
/// 文字/图片是安静的副通道(§2.3 已由 owner 显式放开):默认折叠,
/// 不抢成员网格与主麦克风按钮的位置,语音仍是一等公民。
/// 地图视图:位置共享(Snapchat 式)。
class RoomScreen extends StatefulWidget {
  const RoomScreen({
    super.key,
    required this.controller,
    required this.circleName,
    this.voiceNotes,
    this.settings,
    this.locationShare,
    this.chat,
    this.recordingConsent,
    this.blocks,
    this.e2ee,
    this.captions,
  });

  final RoomController controller;
  final String circleName;
  final VoiceNotesController? voiceNotes;
  final SettingsStore? settings;
  final LocationShareService? locationShare;

  /// 文字/图片副通道。为 null 时整块不渲染(与 _KnockBanner 同样的降级方式)
  final ChatService? chat;

  /// 录音同意控制器。为 null 时不渲染指示器(同上的降级方式)
  final RecordingConsentController? recordingConsent;

  /// 屏蔽名单(App Store 审核指南 1.2)。为 null 时长按头像退回「直接踢人」的
  /// 老行为,既不崩也不少任何既有功能 —— 可选协作者一律优雅降级(同上)。
  final BlockStore? blocks;

  /// 按圈端到端加密。为 null 时不显示任何加密字样 ——
  /// 宁可什么都不说,也不能显示一个可能说错的状态。
  final E2EEController? e2ee;

  /// 实时字幕。为 null 时没有「字幕」按钮,也不会替别人转写。
  final CaptionController? captions;

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  bool _showMap = false;

  /// 聊天消息区此刻是否展开(由 ChatPanel 回报)。展开 = 语音区收成一条。
  bool _chatExpanded = false;

  /// ChatPanel 在「窄屏底座」与「宽屏侧栏」之间换位置时,草稿、滚动、
  /// 展开态都不能丢 —— GlobalKey 让同一个 State 跟着搬家。
  final GlobalKey<ChatPanelState> _chatKey = GlobalKey<ChatPanelState>();

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    // 在 Scaffold **之上**读键盘:Scaffold 会把 body 的 viewInsets 吃掉
    final bool keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    // 键盘弹起时它已盖住 Home 条区域,底座不必再垫安全区
    final double bottomSafe = keyboardOpen
        ? 0
        : MediaQuery.paddingOf(context).bottom;
    final bool mapOn = _showMap && widget.locationShare != null;
    return Scaffold(
      body: Stack(
        children: [
          // 地图铺满时这层完全被盖住 —— 停掉,别白烧 60fps。
          _BreathingBackground(visible: !mapOn),
          // 麦克风开关失败的提示:与控制条是否可见无关(键盘弹起时控制条会收起)
          _MicNoticeListener(controller: controller),
          SafeArea(
            // 底部安全区交给底座自己垫:底座的底色要一直铺到屏幕最下沿,
            // 而不是在 Home 条上方断开、露出一截背景。
            bottom: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final bool wide =
                    widget.chat != null &&
                    constraints.maxWidth >= _wideRoomWidth;
                // 宽屏里消息区常驻,不存在「展开」;回到窄屏时从收起态开始
                if (wide) _chatExpanded = false;
                final bool compact =
                    !wide && !mapOn && (_chatExpanded || keyboardOpen);
                return Column(
                  children: [
                    _RoomHeader(
                      controller: controller,
                      circleName: widget.circleName,
                      showMap: _showMap,
                      onToggleMap: widget.locationShare == null
                          ? null
                          : () => setState(() => _showMap = !_showMap),
                      e2ee: widget.e2ee,
                    ),
                    // 本机的语音正在出本机(云端识别):常驻,可一键停
                    if (widget.captions != null)
                      CaptionProvidingBanner(captions: widget.captions!),
                    // 「你以为加密了但其实没有」值得一整条横幅,不是一个小角标。
                    if (widget.e2ee != null)
                      _E2EERoomBanner(
                        controller: controller,
                        e2ee: widget.e2ee!,
                      ),
                    // 「这个圈子要口令」—— 当场补填,不必跑去设置页。
                    // 放在敲门横幅之前:它是一条**挡路**的错误,
                    // 而敲门是别人的请求,此刻还轮不到。
                    _PasscodeRetryBanner(
                      controller: controller,
                      settings: widget.settings,
                    ),
                    _KnockBanner(
                      controller: controller,
                      settings: widget.settings,
                    ),
                    // 录音指示器:房间里有人在录音时对**所有人**常驻显示。
                    // 这是本 App 唯一刻意「吵」的组件 —— 安静的设计 ≠ 藏起来。
                    // 没人录音时它自己退化成 SizedBox.shrink(),不占位。
                    //
                    // 注:录音功能当前整体未开放(LaresConfig.recordingEnabled),
                    // 故指示器一并隐藏。二者必须同开同关 —— 只要功能可用,
                    // 指示器就必须在,否则就成了「偷录」。
                    if (LaresConfig.recordingEnabled &&
                        widget.recordingConsent != null)
                      RecordingIndicatorBanner(
                        controller: widget.recordingConsent!,
                      ),
                    if (wide)
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: _stage(
                                controller,
                                mapOn: mapOn,
                                bottomInset: bottomSafe,
                                withControls: true,
                              ),
                            ),
                            SizedBox(
                              width: _sidePanelWidth,
                              child: _Dock(
                                floating: true,
                                bottomInset: bottomSafe,
                                child: _chatPanel(
                                  controller,
                                  collapsible: false,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    else ...[
                      // 语音区:有空间时是舞台,聊天展开 / 键盘弹起时收成一条 ——
                      // 但**永远不消失**。谁在说话,任何时候都看得见。
                      if (compact)
                        _VoiceStrip(
                          controller: controller,
                          blocks: widget.blocks,
                          showMute: keyboardOpen,
                          showNames: !keyboardOpen,
                        )
                      else
                        Expanded(
                          child: _stage(
                            controller,
                            mapOn: mapOn,
                            bottomInset: 0,
                            withControls: false,
                          ),
                        ),
                      // 底座:聊天、字幕带、输入框、主控件同在一块面上
                      _maybeExpanded(
                        expand: compact && _chatExpanded,
                        spacer: compact && !_chatExpanded,
                        child: _Dock(
                          bottomInset: bottomSafe,
                          child: Column(
                            mainAxisSize: compact && _chatExpanded
                                ? MainAxisSize.max
                                : MainAxisSize.min,
                            children: [
                              if (widget.chat != null)
                                _maybeExpanded(
                                  expand: compact && _chatExpanded,
                                  child: _chatPanel(
                                    controller,
                                    collapsible: true,
                                    // 键盘弹起时主控件排让位,展开/收起键回到输入栏
                                    showToggle: keyboardOpen,
                                  ),
                                )
                              else if (widget.captions != null)
                                CaptionPanel(
                                  captions: widget.captions!,
                                  band: true,
                                ),
                              // 键盘弹起时主控件让位给输入框;静音键已挪到语音条上
                              if (!keyboardOpen)
                                _ControlBar(
                                  controller: controller,
                                  voiceNotes: widget.voiceNotes,
                                  captions: widget.captions,
                                  // 聊天展开/收起键从输入栏挪到这里:与离开/字幕
                                  // 左右对称,输入框也因此多出一截宽度
                                  trailing: widget.chat == null
                                      ? null
                                      : ChatToggleButton(
                                          chat: widget.chat!,
                                          expanded: _chatExpanded,
                                          tonal: true,
                                          onToggle: () => _chatKey.currentState
                                              ?.toggleExpanded(),
                                        ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// expand=true 时包进 Expanded;spacer=true 时前面垫一个 Spacer 把它压到底部。
  Widget _maybeExpanded({
    required bool expand,
    bool spacer = false,
    required Widget child,
  }) {
    if (expand) return Expanded(child: child);
    if (spacer) {
      return Expanded(
        child: Align(alignment: Alignment.bottomCenter, child: child),
      );
    }
    return child;
  }

  /// 语音舞台:座位(或地图)+ 我的状态;宽屏时主控件也在这里。
  Widget _stage(
    RoomController controller, {
    required bool mapOn,
    required double bottomInset,
    required bool withControls,
  }) {
    return Column(
      children: [
        Expanded(
          child: mapOn
              ? MapPanel(
                  controller: controller,
                  locationShare: widget.locationShare!,
                )
              : _MemberGrid(controller: controller, blocks: widget.blocks),
        ),
        _StatusSelector(controller: controller),
        if (withControls)
          Padding(
            padding: EdgeInsets.only(bottom: bottomInset),
            child: _ControlBar(
              controller: controller,
              voiceNotes: widget.voiceNotes,
              captions: widget.captions,
            ),
          )
        else
          const SizedBox(height: LaresSpacing.sm),
      ],
    );
  }

  Widget _chatPanel(
    RoomController controller, {
    required bool collapsible,
    bool showToggle = true,
  }) {
    return ChatPanel(
      key: _chatKey,
      chat: widget.chat!,
      blocks: widget.blocks,
      embedded: true,
      collapsible: collapsible,
      showToggle: showToggle,
      onExpandedChanged: (v) => setState(() => _chatExpanded = v),
      // 字幕带嵌在消息与输入框之间:「此刻正在说的」紧挨「我要写的」
      aboveComposer: widget.captions == null
          ? null
          : CaptionPanel(captions: widget.captions!, band: true),
      senderAvatar: (context, m) => _SeatMiniAvatar(
        controller: controller,
        userId: m.senderId,
        name: m.senderName,
      ),
    );
  }
}

/// 房间底座:聊天、字幕带、输入框、主控件共用的一整块面。
///
/// 统一的底色、圆角与一层很淡的上投影 —— 不用描边。
/// 窄屏贴底(只圆上角,底色铺进 Home 条);宽屏是右侧一张浮起的侧栏。
class _Dock extends StatelessWidget {
  const _Dock({
    required this.child,
    required this.bottomInset,
    this.floating = false,
  });

  final Widget child;
  final double bottomInset;
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool dark = theme.brightness == Brightness.dark;
    final radius = floating
        ? BorderRadius.circular(LaresRadii.lg)
        : const BorderRadius.vertical(top: Radius.circular(LaresRadii.lg));
    final Widget body = Padding(
      padding: EdgeInsets.only(
        top: LaresSpacing.xs,
        bottom: floating ? 0 : bottomInset,
      ),
      child: child,
    );
    return Padding(
      padding: floating
          ? EdgeInsets.fromLTRB(
              0,
              LaresSpacing.sm,
              LaresSpacing.md,
              LaresSpacing.md + bottomInset,
            )
          : EdgeInsets.zero,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: dark ? _dockShadowDark : _dockShadowLight,
              ),
              blurRadius: _dockShadowBlur,
              offset: Offset(0, floating ? 2 : -2),
            ),
          ],
        ),
        child: ClipRRect(borderRadius: radius, child: body),
      ),
    );
  }
}

/// 麦克风开关失败:弹一次即清。独立成一个不占位的监听件,
/// 这样键盘弹起、控制条让位时提示也不会丢。
class _MicNoticeListener extends StatelessWidget {
  const _MicNoticeListener({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        // 权限被拒要说清「去系统设置」,App 里再按多少次都没用。
        final notice = controller.micNotice;
        if (notice != null) {
          controller.micNotice = null;
          final text = switch (notice) {
            MicNotice.permissionDenied => t.roomMicPermissionDenied,
            MicNotice.unmuteFailed => t.roomMicUnmuteFailed,
            MicNotice.muteFailed => t.roomMicMuteFailed,
          };
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(text)));
          });
        }
        return const SizedBox.shrink();
      },
    );
  }
}

/// 聊天消息旁的发送者小头像:与语音座位同形同色(首字 + 状态色环),
/// 正在说话时换成余烬色环并微微发光 —— 「这句话是谁说的」与
/// 「那个在发光的人」一眼对上。人已离开房间时退成中性灰环。
class _SeatMiniAvatar extends StatelessWidget {
  const _SeatMiniAvatar({
    required this.controller,
    required this.userId,
    required this.name,
  });

  final RoomController controller;
  final String userId;
  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExcludeSemantics(
      // 名字已经在消息头里读过一遍,头像不再重复
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          Member? member;
          for (final m in controller.members) {
            if (m.userId == userId) {
              member = m;
              break;
            }
          }
          final bool speaking = controller.speakingIds.contains(userId);
          final Color ring = speaking
              ? LaresColors.ember
              : member?.status.color ?? LaresColors.statusAway;
          return Container(
            width: _miniAvatarSize,
            height: _miniAvatarSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.colorScheme.surfaceContainerHighest,
              border: Border.all(color: ring, width: 2),
              boxShadow: speaking
                  ? [
                      BoxShadow(
                        color: LaresColors.ember.withValues(alpha: 0.4),
                        blurRadius: 8,
                      ),
                    ]
                  : null,
            ),
            child: Text(
              name.isEmpty ? '?' : name.characters.first,
              style: theme.textTheme.labelLarge?.copyWith(fontSize: 13),
            ),
          );
        },
      ),
    );
  }
}

/// 收起后的语音条:一排小头像(说话波纹照常)+ 我的状态 +(键盘弹起时)静音键。
class _VoiceStrip extends StatelessWidget {
  const _VoiceStrip({
    required this.controller,
    this.blocks,
    required this.showMute,
    required this.showNames,
  });

  final RoomController controller;
  final BlockStore? blocks;
  final bool showMute;
  final bool showNames;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable?>[controller, blocks]),
      builder: (context, _) {
        final members = controller.members;
        return SizedBox(
          height: showNames ? _stripHeight : _stripHeightNoNames,
          child: Row(
            children: [
              Expanded(
                child: members.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: LaresSpacing.lg,
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            t.roomEmpty,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      )
                    : ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: LaresSpacing.md,
                        ),
                        itemCount: members.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(width: LaresSpacing.xs),
                        itemBuilder: (context, i) => Center(
                          child: _seat(
                            context,
                            controller,
                            blocks,
                            members[i],
                            compact: true,
                            showName: showNames,
                          ),
                        ),
                      ),
              ),
              // 键盘弹起时只留头像与静音键:状态可以等会儿再改,座位不能被挤掉
              if (!showMute) _StatusChip(controller: controller),
              if (showMute)
                Padding(
                  padding: const EdgeInsets.only(left: LaresSpacing.xs),
                  child: IconButton.filled(
                    tooltip: controller.muted ? t.roomUnmute : t.roomMute,
                    style: IconButton.styleFrom(
                      backgroundColor: controller.muted
                          ? theme.colorScheme.surfaceContainerHighest
                          : LaresColors.ember,
                      foregroundColor: controller.muted
                          ? theme.colorScheme.onSurface
                          : const Color(0xFF1A120C),
                    ),
                    onPressed: controller.toggleMute,
                    icon: Icon(
                      controller.muted
                          ? Icons.mic_off_rounded
                          : Icons.mic_rounded,
                    ),
                  ),
                ),
              const SizedBox(width: LaresSpacing.md),
            ],
          ),
        );
      },
    );
  }
}

/// 语音条上的「我的状态」:一个小药丸,点开选三种状态之一。
/// 与舞台上的分段按钮是同一件事的紧凑形态。
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    String label(MemberStatus s) => switch (s) {
      MemberStatus.free => t.roomStatusFree,
      MemberStatus.busy => t.roomStatusBusy,
      MemberStatus.ears => t.roomStatusEars,
      MemberStatus.away => s.label,
    };
    final MemberStatus mine = controller.myStatus;
    return PopupMenuButton<MemberStatus>(
      tooltip: t.roomStatusPick,
      initialValue: mine,
      onSelected: controller.setStatus,
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        for (final s in const [
          MemberStatus.free,
          MemberStatus.busy,
          MemberStatus.ears,
        ])
          PopupMenuItem(
            value: s,
            child: Row(
              children: [
                _StatusDot(color: s.color),
                const SizedBox(width: LaresSpacing.sm),
                Text(label(s)),
              ],
            ),
          ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _minTapTarget),
        child: Center(
          widthFactor: 1,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: LaresSpacing.md - LaresSpacing.xs,
              vertical: LaresSpacing.xs + 2,
            ),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(LaresRadii.lg),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StatusDot(color: mine.color),
                const SizedBox(width: LaresSpacing.xs + 2),
                Text(label(mine), style: theme.textTheme.labelLarge),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: _statusDotSize,
    height: _statusDotSize,
    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
  );
}

/// 舞台上的「我的状态」分段按钮(§2.2:降低「现在方不方便进」的顾虑)。
class _StatusSelector extends StatelessWidget {
  const _StatusSelector({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: LaresSpacing.md),
        child: SegmentedButton<MemberStatus>(
          showSelectedIcon: false,
          // ⚠️ const 必须去掉:本地化字符串不是编译期常量。
          segments: [
            ButtonSegment(
              value: MemberStatus.free,
              label: Text(t.roomStatusFree),
            ),
            ButtonSegment(
              value: MemberStatus.busy,
              label: Text(t.roomStatusBusy),
            ),
            ButtonSegment(
              value: MemberStatus.ears,
              label: Text(t.roomStatusEars),
            ),
          ],
          selected: {controller.myStatus},
          onSelectionChanged: (s) => controller.setStatus(s.first),
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            textStyle: WidgetStatePropertyAll(theme.textTheme.bodyMedium),
          ),
        ),
      ),
    );
  }
}

/// 房间「呼吸感」氛围背景:极慢明灭的暖色光晕,让「有人在」可感知。
///
/// ## 省电:App 退到后台就**停表**,不是降频
///
/// 这是常驻挂机类应用的准入条件,不是优化项 —— 核心场景是一天挂十几小时。
///
/// 原型实测(见 `app/tool/hearth/REPORT.md`)给出过一条反直觉的数据:
/// **节流重绘救不了耗电**。把重绘从 60fps 降到 12fps 之后,
/// 提交帧率仍是 60fps、CPU 仍占 27% —— 因为只要 Ticker 还在跑,
/// 引擎每个 vsync 都要走完整的帧调度,节流只省掉 paint 里画渐变那一点。
///
/// 只有彻底 `stop()` 才是真的零:**27.2% → 0.31%,降到 1/88**。
class _BreathingBackground extends StatefulWidget {
  const _BreathingBackground({this.visible = true});

  /// 这层背景此刻是否真的看得见。
  ///
  /// 地图页打开时,背景仍在 `Stack` 底层、只是被盖住 —— 那种情况下
  /// 继续烧 60fps 是纯浪费,用户一帧都看不到。
  final bool visible;

  @override
  State<_BreathingBackground> createState() => _BreathingBackgroundState();
}

class _BreathingBackgroundState extends State<_BreathingBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath;
  AppLifecycleListener? _lifecycle;

  /// App 是否在前台。与 [_BreathingBackground.visible] 是**两个独立条件**,
  /// 必须都成立才转表。
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 7),
    );
    // 用 onStateChange 而不是 onHide/onShow:后者在部分平台上不触发,
    // 而 paused/inactive 是所有平台都会报的。
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    _sync();
  }

  @override
  void didUpdateWidget(_BreathingBackground old) {
    super.didUpdateWidget(old);
    if (old.visible != widget.visible) _sync();
  }

  void _onLifecycle(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  /// 把「该不该转」这件事收在一个地方算,避免两个条件各改各的而打架。
  void _sync() {
    final shouldRun = _foreground && widget.visible;
    if (shouldRun) {
      // 只在真的停了的时候才重启 —— 重复调 repeat() 会把动画拽回起点,
      // 表现为光晕突然一跳。
      if (!_breath.isAnimating) _breath.repeat(reverse: true);
    } else {
      // stop() 保留当前值,下次恢复从原处继续,视觉上不跳。
      _breath.stop();
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).scaffoldBackgroundColor;
    return AnimatedBuilder(
      animation: _breath,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_breath.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0, -0.7),
              radius: 1.2,
              colors: [
                LaresColors.ember.withValues(alpha: 0.05 + 0.05 * t),
                base,
              ],
            ),
          ),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

/// 进房被拒于「差一个口令」时,当场补填的横幅。
///
/// ## 为什么值得一个常驻输入框,而不是一句「去设置里填」
///
/// 邀请链接**刻意不带口令** —— 口令经 Argon2id 派生出 E2EE 密钥,写进链接
/// 等于把密钥一起发出去,而链接会经微信/短信/剪贴板流转。代价是:通过链接
/// 加进来的圈子,本地必然没有口令,第一次进房必然被 4401 拒。
///
/// 那是新用户遇到的**第一个**障碍。让他去翻设置页、找到服务器档案、
/// 看懂「按圈口令」是什么意思,才能填一个朋友刚发给他的四位数 —— 太远了。
///
/// ## 只在「确实是口令问题」时出现
///
/// 判据是 [RoomController.needsPasscode],它读的是结构化的错误种类,
/// 不是去匹配错误文案的文字。网络不好、服务器没配 LiveKit 的时候弹口令框
/// 是误导 —— 用户会反复输入一个本来就没错的口令。
class _PasscodeRetryBanner extends StatefulWidget {
  const _PasscodeRetryBanner({required this.controller, this.settings});

  final RoomController controller;
  final SettingsStore? settings;

  @override
  State<_PasscodeRetryBanner> createState() => _PasscodeRetryBannerState();
}

class _PasscodeRetryBannerState extends State<_PasscodeRetryBanner> {
  final _field = TextEditingController();

  /// 正在保存/重连中:按钮置灰,防止连点。
  /// 连点的代价是实打实的:服务端 5 分钟 10 次失败就封 IP(4429)。
  bool _busy = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final settings = widget.settings;
    final circleId = widget.controller.circleId;
    final pass = _field.text;
    if (settings == null || circleId == null || pass.isEmpty || _busy) return;

    setState(() => _busy = true);
    // 存口令。返回 false 表示「存下了,但这台服务器当前用的是共享令牌,
    // 不会立刻生效」—— 那种情况必须如实说,不能假装重试会成功。
    final effective = await settings.setCirclePasscode(circleId, pass);
    if (!mounted) return;

    if (!effective) {
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).roomPasscodeSavedElsewhere,
          ),
        ),
      );
      return;
    }

    // 输入框在重试之前就清空:口令已经存进 SecretVault 了,
    // 没有任何理由让它继续留在一个 widget 的内存里。
    _field.clear();
    await widget.controller.retryJoin(circleId);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        // settings 为 null 时不渲染:没有它就无处存口令,
        // 给一个按了没反应的按钮比不给更糟(可选协作者一律优雅降级)。
        if (!widget.controller.needsPasscode || widget.settings == null) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            LaresSpacing.lg,
            LaresSpacing.sm,
            LaresSpacing.lg,
            0,
          ),
          child: Card(
            color: Theme.of(context).colorScheme.surface,
            child: Padding(
              padding: const EdgeInsets.all(LaresSpacing.md),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _field,
                      // 不回显:这个场景就是「旁边可能有人」。
                      obscureText: true,
                      enabled: !_busy,
                      decoration: InputDecoration(
                        labelText: t.roomPasscodeHint,
                        isDense: true,
                      ),
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                  const SizedBox(width: LaresSpacing.sm),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(t.roomPasscodeRetry),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 敲门横幅:有人想进来时,轻提示 + 放行按钮(§2.2「轻敲门」非强提醒)
class _KnockBanner extends StatelessWidget {
  const _KnockBanner({required this.controller, this.settings});

  final RoomController controller;
  final SettingsStore? settings;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.knockRequests.isEmpty) {
          return const SizedBox.shrink();
        }
        // 免打扰时段:不弹敲门横幅(§2.2 防打扰)
        if (settings?.inDndNow == true) {
          return const SizedBox.shrink();
        }
        final knock = controller.knockRequests.first;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            LaresSpacing.lg,
            LaresSpacing.sm,
            LaresSpacing.lg,
            0,
          ),
          child: Card(
            color: Theme.of(context).colorScheme.surface,
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.door_front_door_outlined),
              title: Text(t.roomKnockWants(knock.name)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () => controller.dismissKnock(knock.userId),
                    child: Text(t.roomKnockDeny),
                  ),
                  FilledButton.tonal(
                    onPressed: () => controller.allowKnock(knock.userId),
                    child: Text(t.roomKnockAllow),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RoomHeader extends StatelessWidget {
  const _RoomHeader({
    required this.controller,
    required this.circleName,
    this.showMap = false,
    this.onToggleMap,
    this.e2ee,
  });

  final RoomController controller;
  final String circleName;
  final bool showMap;
  final VoidCallback? onToggleMap;
  final E2EEController? e2ee;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([controller, e2ee]),
      builder: (context, _) {
        final count = controller.members.length;
        // 只认「本次通话」的权威结论,且必须与当前圈子匹配 ——
        // 圈子对不上一律返回 null,绝不把上一个圈的状态显示给这一个圈。
        // 注册圈的加密由圈主统一定:进房后照样以本次通话的权威结论为准;
        // 还没连上媒体时(joining)用预测值,让人一进门就看到这把锁的真实情况。
        final cid = controller.circleId;
        final E2EEStatus? status =
            e2ee?.statusForActiveCircle(cid) ??
            (cid != null && e2ee != null && e2ee!.isCircleManaged(cid)
                ? e2ee!.previewStatusFor(cid)
                : null);
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            LaresSpacing.lg,
            LaresSpacing.md,
            LaresSpacing.lg,
            0,
          ),
          child: Row(
            children: [
              // ⚠️ 必须 Expanded/Flexible。Row 对非 flex 子节点给的是**无界**横向约束,
              // 而下面那行副标题在 error 态是异常文本 —— 长度不可控。
              // 漏掉它的后果实测过:单行铺开到 2000+ px,
              // 屏幕右上角出现黄黑警示条「RIGHT OVERFLOWED BY 2014 PIXELS」。
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            circleName,
                            style: theme.textTheme.titleLarge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (status != null &&
                            status != E2EEStatus.disabled) ...[
                          const SizedBox(width: LaresSpacing.sm),
                          E2EEBadge(status: status, compact: true),
                        ],
                      ],
                    ),
                    Text(
                      switch (controller.phase) {
                        RoomPhase.joining =>
                          controller.knocking ? t.roomKnocking : t.roomJoining,
                        RoomPhase.inRoom =>
                          count <= 1
                              ? t.roomAloneHere
                              : t.roomPeopleHere(count),
                        // 只显示人话。原始异常留给日志,不甩给用户。
                        // 注:errorMessage 本身由 room_controller.dart 产出,
                        // 仍是中文硬编码 —— 那个文件不在本批范围内,待后续批次。
                        RoomPhase.error =>
                          controller.errorMessage ?? t.roomErrorGeneric,
                        RoomPhase.idle => '',
                      },
                      style: theme.textTheme.bodyMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              // 转写记录入口:圈主开了才有(transcript-bot-contract)
              if (cid != null &&
                  controller.isTranscriptOn(cid) &&
                  TranscriptScope.maybeOf(context) != null)
                IconButton(
                  key: const ValueKey('room-transcript-history'),
                  tooltip: t.transcriptTitle,
                  icon: const Icon(Icons.subject_rounded),
                  onPressed: () => openTranscriptHistory(
                    context,
                    service: TranscriptScope.maybeOf(context)!,
                    circleId: cid,
                    circleName: circleName,
                    isOwner: controller.isOwnerOf(cid),
                  ),
                ),
              if (onToggleMap != null)
                IconButton(
                  tooltip: showMap ? t.roomBackToRoom : t.roomLocationMap,
                  onPressed: onToggleMap,
                  icon: Icon(
                    showMap ? Icons.groups_rounded : Icons.map_outlined,
                    color: showMap ? LaresColors.ember : null,
                  ),
                ),
              if (controller.lastJoinLatency != null)
                Tooltip(
                  message: t.roomJoinLatencyTooltip,
                  child: Text(
                    '${controller.lastJoinLatency!.inMilliseconds}ms',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 「开了加密但这次通话其实没加密」的房内横幅。
///
/// 只在 [E2EEStatus.isBrokenPromise] 时出现 —— 真加密了不喊(头部那把锁足够),
/// 没开加密也不喊(那是用户的选择,天天提醒只会变成背景噪音)。
/// 唯一要打断用户的,是「你以为加密了」这一种情况。
class _E2EERoomBanner extends StatelessWidget {
  const _E2EERoomBanner({required this.controller, required this.e2ee});

  final RoomController controller;
  final E2EEController e2ee;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, e2ee]),
      builder: (context, _) {
        final status = e2ee.statusForActiveCircle(controller.circleId);
        if (status == null || !status.isBrokenPromise) {
          return const SizedBox.shrink();
        }
        return E2EEWarningBanner(status: status);
      },
    );
  }
}

/// 语音便签按钮:红点=有待听;长按录音时变色提示
class _VoiceNoteButton extends StatelessWidget {
  const _VoiceNoteButton({this.voiceNotes});

  final VoiceNotesController? voiceNotes;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final vn = voiceNotes;
    if (vn == null) {
      return const IconButton.filledTonal(
        onPressed: null,
        icon: Icon(Icons.voicemail_rounded),
      );
    }
    return ListenableBuilder(
      listenable: vn,
      builder: (context, _) {
        final count = vn.pendingCount;
        return GestureDetector(
          onLongPressStart: (_) => vn.startRecording(),
          onLongPressEnd: (_) => vn.stopAndSend(),
          child: Badge(
            isLabelVisible: count > 0,
            label: Text('$count'),
            child: IconButton.filledTonal(
              tooltip: count > 0 ? t.noteListen(count) : t.noteRecordHint,
              style: vn.recording
                  ? IconButton.styleFrom(
                      backgroundColor: LaresColors.ember,
                      foregroundColor: const Color(0xFF1A120C),
                    )
                  : null,
              onPressed: count > 0 ? vn.playAll : null,
              icon: Icon(
                vn.recording
                    ? Icons.mic_rounded
                    : vn.playing
                    ? Icons.volume_up_rounded
                    : Icons.voicemail_rounded,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 踢人确认
Future<void> _confirmKick(
  BuildContext context,
  RoomController controller,
  Member m,
) async {
  final t = AppLocalizations.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.roomKickTitle(m.name)),
      content: Text(t.roomKickBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(t.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(t.roomKickConfirm),
        ),
      ],
    ),
  );
  if (ok == true) controller.kick(m.userId);
}

class _MemberGrid extends StatelessWidget {
  const _MemberGrid({required this.controller, this.blocks});

  final RoomController controller;

  /// 为 null 时整块退回「长按=踢人」的老行为,且不画屏蔽标记
  final BlockStore? blocks;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final BlockStore? blocks = this.blocks;
    return ListenableBuilder(
      // 必须把 blocks 一起并进来:屏蔽是在 BlockStore 上发生的,
      // controller 根本不会为此 notify,不合并就「屏蔽了但画面没变」。
      listenable: Listenable.merge(<Listenable?>[controller, blocks]),
      builder: (context, _) {
        final members = controller.members;
        if (members.isEmpty) {
          return Center(
            child: Text(
              t.roomEmpty,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(LaresSpacing.lg),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 140,
            mainAxisSpacing: LaresSpacing.md,
            crossAxisSpacing: LaresSpacing.sm,
            // 头像球 + 名字 + 状态字的真实高度约 160;0.72 会挤出 3px 溢出
            childAspectRatio: _gridChildAspect,
          ),
          itemCount: members.length,
          itemBuilder: (context, i) =>
              Center(child: _seat(context, controller, blocks, members[i])),
        );
      },
    );
  }
}

/// 一个座位:头像球 + 处置手势 + 屏蔽标记。舞台网格与收起后的语音条共用,
/// 两种形态下「点人 = 处置菜单」的行为完全一致。
Widget _seat(
  BuildContext context,
  RoomController controller,
  BlockStore? blocks,
  Member m, {
  bool compact = false,
  bool showName = true,
}) {
  final isMe = m.userId == controller.userId;
  final bool blocked = blocks?.isBlocked(m.userId) ?? false;
  // 注册圈里只有圈主能踢:非圈主连这一行都看不到(服务器反正会拒)。
  // env 圈维持老行为,人人可踢。屏蔽是个人行为,不受影响。
  final cid = controller.circleId;
  final canKick = cid == null || controller.canModerate(cid);

  // 接了屏蔽名单就走处置菜单(踢人作为其中一行保留);
  // 没接就还是老样子:长按直接踢。
  VoidCallback? openMenu;
  if (!isMe && blocks != null) {
    openMenu = () => showMemberModerationSheet(
      context,
      controller: controller,
      blocks: blocks,
      member: m,
      onKick: canKick ? () => _confirmKick(context, controller, m) : null,
    );
  }

  final Widget orb = AvatarOrb(
    member: m,
    speaking: controller.speakingIds.contains(m.userId),
    muted: isMe && controller.muted,
    size: compact ? _stripOrbSize : 88,
    compact: compact,
    showName: showName,
  );

  return GestureDetector(
    // 点一下也能打开处置菜单。只留长按太隐蔽了 ——
    // AvatarOrb 自己 excludeSemantics: true,读屏用户更摸不到,
    // 而「能屏蔽」这件事必须让人找得到(审核指南 1.2)。
    onTap: openMenu,
    onLongPress:
        openMenu ??
        (isMe || !canKick ? null : () => _confirmKick(context, controller, m)),
    child: blocked ? _BlockedOverlay(child: orb) : orb,
  );
}

/// 被屏蔽成员的视觉标记:头像压暗 + 右上角一枚禁止图标。
///
/// 为什么一定要有:屏蔽的效果(听不到、看不到消息)全都发生在别处,
/// 网格里若毫无变化,用户点完那一下根本不知道生效了没有 ——
/// 审核员也是。名字已经在 AvatarOrb 里了,这里只加「暗」和「角标」两件事。
class _BlockedOverlay extends StatelessWidget {
  const _BlockedOverlay({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      // 无障碍标签同样要翻译 —— 读屏用户也是用户,而且这是审核指南 1.2
      // 「屏蔽能力必须找得到」的一部分。
      label: AppLocalizations.of(context).roomBlockedSemantics,
      // container: true 是必须的:AvatarOrb 自己已经建了一个语义节点
      // (还带 excludeSemantics),外层若不独立成节点,这个标签就会被吞掉,
      // 读屏用户根本听不到「已屏蔽」三个字。
      container: true,
      child: Stack(
        children: <Widget>[
          Opacity(opacity: _blockedAvatarOpacity, child: child),
          Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(LaresSpacing.xs),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.surface,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(LaresSpacing.xs),
                  child: Icon(
                    Icons.block_rounded,
                    size: _blockedBadgeIconSize,
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 底座最下一排主控件:离开 · 字幕 · 静音(主角) · 语音便签。
///
/// 从前字幕开关在顶栏、控件在另一块面板里;现在「和声音有关的开关」
/// 都在拇指够得着的这一排,与输入框同在一块底座上。
class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.controller,
    this.voiceNotes,
    this.captions,
    this.trailing,
  });

  final RoomController controller;
  final VoiceNotesController? voiceNotes;
  final CaptionController? captions;

  /// 静音键右侧的第二颗键(窄屏 = 聊天展开/收起)。有它时左右各两颗。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final bool captionsOn =
            captions != null && controller.captionsAvailable;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            LaresSpacing.md,
            LaresSpacing.xs,
            LaresSpacing.md,
            LaresSpacing.md,
          ),
          child: _balancedRow(
            left: [
              // 离开:低调,无仪式感
              IconButton.filledTonal(
                tooltip: t.roomLeave,
                onPressed: controller.leave,
                icon: const Icon(Icons.call_end_rounded),
              ),
              // 字幕:与离开同级的次要键;服务器没配字幕就不出现
              if (captionsOn) _CaptionsControl(captions: captions!),
            ],
            // 静音/说话:绝对主角
            center: SizedBox(
              width: _micSize,
              height: _micSize,
              child: IconButton.filled(
                tooltip: controller.muted ? t.roomUnmute : t.roomMute,
                style: IconButton.styleFrom(
                  backgroundColor: controller.muted
                      ? theme.colorScheme.surfaceContainerHighest
                      : LaresColors.ember,
                  foregroundColor: controller.muted
                      ? theme.colorScheme.onSurface
                      : const Color(0xFF1A120C),
                ),
                onPressed: controller.toggleMute,
                icon: Icon(
                  controller.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                  size: 30,
                ),
              ),
            ),
            right: [
              // 语音便签:点=听留言,长按=留一条(≤15s)
              _VoiceNoteButton(voiceNotes: voiceNotes),
              ?trailing,
            ],
          ),
        );
      },
    );
  }
}

/// 主键居中、次要键分列两侧。
///
/// 两侧数量相等时用等宽的两半夹住主键 —— 主键落在**正中**;
/// 不等时(某项功能没配)退成整组居中、等间距,绝不留一个空槽。
Widget _balancedRow({
  required List<Widget> left,
  required Widget center,
  required List<Widget> right,
}) {
  List<Widget> spaced(List<Widget> xs) => [
    for (var i = 0; i < xs.length; i++) ...[
      if (i > 0) const SizedBox(width: LaresSpacing.md),
      xs[i],
    ],
  ];
  if (left.length == right.length) {
    return Row(
      children: [
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: spaced(left),
          ),
        ),
        const SizedBox(width: LaresSpacing.lg),
        center,
        const SizedBox(width: LaresSpacing.lg),
        Expanded(child: Row(children: spaced(right))),
      ],
    );
  }
  return Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: spaced([...left, center, ...right]),
  );
}

/// 控件排里的字幕开关:外观与离开/便签同为 tonal 圆键,开着时余烬色。
class _CaptionsControl extends StatelessWidget {
  const _CaptionsControl({required this.captions});

  final CaptionController captions;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: captions,
      builder: (context, _) {
        final bool on = captions.wantCaptions;
        return IconButtonTheme(
          data: IconButtonThemeData(
            style: IconButton.styleFrom(
              backgroundColor: on
                  ? LaresColors.emberSoft
                  : Theme.of(context).colorScheme.secondaryContainer,
            ),
          ),
          child: CaptionToggleButton(captions: captions, available: true),
        );
      },
    );
  }
}

// ── 房间布局常量 ──

/// 窗口宽到这个值起,聊天改成右侧常驻侧栏(语音舞台在左)。
/// 比 LaresBreakpoints.desktop(840)略低:平板横屏 / 小窗桌面也值得并排。
const double _wideRoomWidth = 760;

/// 宽屏侧栏宽度:够放下 16~18 字一行的消息,又不抢舞台。
const double _sidePanelWidth = 380;

/// 网格座位宽高比。
const double _gridChildAspect = 0.64;

/// 收起后的语音条:头像直径、整条高度(带名字 / 键盘弹起不带名字)。
const double _stripOrbSize = 40;
const double _stripHeight = 84;
const double _stripHeightNoNames = 64;

/// 主麦克风键直径。
const double _micSize = 64;

/// 最小可点区域(Material / HIG 44~48)。
const double _minTapTarget = 48;

/// 聊天旁 mini 座位头像直径(= ChatPanel 预留的槽宽)。
const double _miniAvatarSize = 28;

/// 状态小圆点直径。
const double _statusDotSize = 8;

/// 底座投影:极淡,只为让它「浮」在呼吸背景上,不要描边。
const double _dockShadowDark = 0.35;
const double _dockShadowLight = 0.08;
const double _dockShadowBlur = 16;
