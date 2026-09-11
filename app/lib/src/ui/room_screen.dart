import 'package:flutter/material.dart';

import '../state/models.dart';
import '../state/room_controller.dart';
import '../state/settings_store.dart';
import '../state/voice_notes.dart';
import '../theme/tokens.dart';
import 'widgets/avatar_orb.dart';

/// 房间内界面(设计.md §3.2-2):极简 —— 头像网格 + 波纹 + 底部两个主按钮。
/// 不做打字聊天区,陪伴而非会议。
class RoomScreen extends StatelessWidget {
  const RoomScreen({
    super.key,
    required this.controller,
    required this.circleName,
    this.voiceNotes,
    this.settings,
  });

  final RoomController controller;
  final String circleName;
  final VoiceNotesController? voiceNotes;
  final SettingsStore? settings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const _BreathingBackground(),
          SafeArea(
            child: Column(
              children: [
                _RoomHeader(controller: controller, circleName: circleName),
                _KnockBanner(controller: controller, settings: settings),
                Expanded(child: _MemberGrid(controller: controller)),
                _ControlBar(controller: controller, voiceNotes: voiceNotes),
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
  const _RoomHeader({required this.controller, required this.circleName});

  final RoomController controller;
  final String circleName;

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

class _MemberGrid extends StatelessWidget {
  const _MemberGrid({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
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
            return AvatarOrb(
              member: m,
              speaking: controller.speakingIds.contains(m.userId),
              muted: isMe && controller.muted,
            );
          },
        );
      },
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
