import 'package:flutter/material.dart';

import '../chat/chat_service.dart';
import '../config.dart';
import '../moderation/block_store.dart';
import '../recording/recording_consent.dart';
import '../recording/recording_indicator.dart';
import '../state/location_share_stub.dart'
    if (dart.library.io) '../state/location_share.dart';
import '../state/models.dart';
import '../state/room_controller.dart';
import '../state/settings_store.dart';
import '../state/voice_notes.dart';
import '../theme/tokens.dart';
import 'chat_panel.dart';
import 'map_panel.dart';
import 'moderation_menus.dart';
import 'widgets/avatar_orb.dart';

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

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  bool _showMap = false;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      body: Stack(
        children: [
          const _BreathingBackground(),
          SafeArea(
            child: Column(
              children: [
                _RoomHeader(
                  controller: controller,
                  circleName: widget.circleName,
                  showMap: _showMap,
                  onToggleMap: widget.locationShare == null
                      ? null
                      : () => setState(() => _showMap = !_showMap),
                ),
                _KnockBanner(controller: controller, settings: widget.settings),
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
                Expanded(
                  child: _showMap && widget.locationShare != null
                      ? MapPanel(
                          controller: controller,
                          locationShare: widget.locationShare!,
                        )
                      : _MemberGrid(
                          controller: controller,
                          blocks: widget.blocks,
                        ),
                ),
                // 副通道置于主按钮之上:默认折叠成一条细条,不挤压上方网格
                if (widget.chat != null)
                  ChatPanel(chat: widget.chat!, blocks: widget.blocks)
                else
                  const SizedBox.shrink(),
                _ControlBar(
                    controller: controller, voiceNotes: widget.voiceNotes),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 房间「呼吸感」氛围背景:极慢明灭的暖色光晕,让「有人在」可感知。
class _BreathingBackground extends StatefulWidget {
  const _BreathingBackground();

  @override
  State<_BreathingBackground> createState() => _BreathingBackgroundState();
}

class _BreathingBackgroundState extends State<_BreathingBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath;

  @override
  void initState() {
    super.initState();
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 7),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
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

/// 敲门横幅:有人想进来时,轻提示 + 放行按钮(§2.2「轻敲门」非强提醒)
class _KnockBanner extends StatelessWidget {
  const _KnockBanner({required this.controller, this.settings});

  final RoomController controller;
  final SettingsStore? settings;

  @override
  Widget build(BuildContext context) {
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
              title: Text('${knock.name} 想进来'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () => controller.dismissKnock(knock.userId),
                    child: const Text('先不'),
                  ),
                  FilledButton.tonal(
                    onPressed: () => controller.allowKnock(knock.userId),
                    child: const Text('让他进'),
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
  });

  final RoomController controller;
  final String circleName;
  final bool showMap;
  final VoidCallback? onToggleMap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final count = controller.members.length;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            LaresSpacing.lg,
            LaresSpacing.md,
            LaresSpacing.lg,
            0,
          ),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(circleName, style: theme.textTheme.titleLarge),
                  Text(
                    switch (controller.phase) {
                      RoomPhase.joining =>
                        controller.knocking ? '敲门中,等里面的人应门…' : '正在进去…',
                      RoomPhase.inRoom => count <= 1 ? '就你一个在,等等看?' : '$count 个人在',
                      RoomPhase.error => controller.errorMessage ?? '出错了',
                      RoomPhase.idle => '',
                    },
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
              const Spacer(),
              if (onToggleMap != null)
                IconButton(
                  tooltip: showMap ? '回到房间' : '位置共享地图',
                  onPressed: onToggleMap,
                  icon: Icon(
                    showMap ? Icons.groups_rounded : Icons.map_outlined,
                    color: showMap ? LaresColors.ember : null,
                  ),
                ),
              if (controller.lastJoinLatency != null)
                Tooltip(
                  message: '本次进房耗时',
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

/// 语音便签按钮:红点=有待听;长按录音时变色提示
class _VoiceNoteButton extends StatelessWidget {
  const _VoiceNoteButton({this.voiceNotes});

  final VoiceNotesController? voiceNotes;

  @override
  Widget build(BuildContext context) {
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
              tooltip: count > 0 ? '听 $count 条留言(长按留一条)' : '长按留语音便签',
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
    BuildContext context, RoomController controller, Member m) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('把「${m.name}」请出房间?'),
      content: const Text('对方会被移出房间(可以稍后再进来,不是封禁)'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('算了'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('请出'),
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
    final BlockStore? blocks = this.blocks;
    return ListenableBuilder(
      // 必须把 blocks 一起并进来:屏蔽是在 BlockStore 上发生的,
      // controller 根本不会为此 notify,不合并就「屏蔽了但画面没变」。
      listenable: Listenable.merge(<Listenable?>[controller, blocks]),
      builder: (context, _) {
        final members = controller.members;
        if (members.isEmpty) {
          return Center(
            child: Text('房间里还空着,坐一会儿?',
                style: Theme.of(context).textTheme.bodyMedium),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(LaresSpacing.lg),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 140,
            mainAxisSpacing: LaresSpacing.lg,
            crossAxisSpacing: LaresSpacing.sm,
            childAspectRatio: 0.72,
          ),
          itemCount: members.length,
          itemBuilder: (context, i) {
            final m = members[i];
            final isMe = m.userId == controller.userId;
            final bool blocked = blocks?.isBlocked(m.userId) ?? false;

            // 接了屏蔽名单就走处置菜单(踢人作为其中一行保留);
            // 没接就还是老样子:长按直接踢。
            VoidCallback? openMenu;
            if (!isMe && blocks != null) {
              openMenu = () => showMemberModerationSheet(
                    context,
                    controller: controller,
                    blocks: blocks,
                    member: m,
                    onKick: () => _confirmKick(context, controller, m),
                  );
            }

            final Widget orb = AvatarOrb(
              member: m,
              speaking: controller.speakingIds.contains(m.userId),
              muted: isMe && controller.muted,
            );

            return GestureDetector(
              // 点一下也能打开处置菜单。只留长按太隐蔽了 ——
              // AvatarOrb 自己 excludeSemantics: true,读屏用户更摸不到,
              // 而「能屏蔽」这件事必须让人找得到(审核指南 1.2)。
              onTap: openMenu,
              onLongPress: openMenu ??
                  (isMe ? null : () => _confirmKick(context, controller, m)),
              child: blocked ? _BlockedOverlay(child: orb) : orb,
            );
          },
        );
      },
    );
  }
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
      label: '已屏蔽',
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

class _ControlBar extends StatelessWidget {
  const _ControlBar({required this.controller, this.voiceNotes});

  final RoomController controller;
  final VoiceNotesController? voiceNotes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.all(LaresSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 轻状态选择(§2.2:降低「现在方不方便进」的顾虑)
              SegmentedButton<MemberStatus>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: MemberStatus.free, label: Text('随时聊')),
                  ButtonSegment(value: MemberStatus.busy, label: Text('在忙')),
                  ButtonSegment(value: MemberStatus.ears, label: Text('耳朵在')),
                ],
                selected: {controller.myStatus},
                onSelectionChanged: (s) => controller.setStatus(s.first),
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStatePropertyAll(
                    theme.textTheme.bodyMedium,
                  ),
                ),
              ),
              const SizedBox(height: LaresSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 离开:低调,无仪式感
                  IconButton.filledTonal(
                    tooltip: '离开',
                    onPressed: controller.leave,
                    icon: const Icon(Icons.call_end_rounded),
                  ),
                  const SizedBox(width: LaresSpacing.lg),
                  // 静音/说话:绝对主角
                  SizedBox(
                    width: 76,
                    height: 76,
                    child: IconButton.filled(
                      tooltip: controller.muted ? '说话' : '静音',
                      style: IconButton.styleFrom(
                        backgroundColor: controller.muted
                            ? theme.colorScheme.surface
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
                        size: 34,
                      ),
                    ),
                  ),
                  const SizedBox(width: LaresSpacing.lg),
                  // 语音便签:点=听留言,长按=留一条(≤15s)
                  _VoiceNoteButton(voiceNotes: voiceNotes),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
