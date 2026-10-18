// ② 隐名之约的房间、③ 圈内 AI、⑦ 守则时段的房间(AI 离席)。
import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'chatham_data.dart';
import 'chatham_kit.dart';

/// 房间页骨架:顶栏 + 约带 + 座位 + 下半区(字幕或 AI 对话)+ 控制条。
class _RoomFrame extends StatelessWidget {
  const _RoomFrame({
    required this.lower,
    this.compactSeats = false,
    this.speaking = 2,
    this.strict = false,
    this.seats,
  });
  final Widget lower;
  final bool strict;
  final Widget? seats;
  final bool compactSeats;
  final int speaking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: HearthBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              PreviewTopBar(
                title: '周四夜谈',
                subtitle: strict ? '5 人在 · 名单只在屋内显示' : '6 人在 · 名字只在圈内可见',
                leading: null,
                trailing: strict
                    ? const Pill(label: '截屏防护', icon: Icons.screenshot_monitor_outlined, dense: true)
                    : const GateIndicator(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(LaresSpacing.lg, 14, LaresSpacing.lg, 0),
                child: strict ? const RuleBand(latin: 'CHATHAM HOUSE', zh: '守则时段') : const RuleBand(),
              ),
              SizedBox(height: compactSeats ? LaresSpacing.md : LaresSpacing.lg),
              seats ?? _Seats(compact: compactSeats, speaking: speaking),
              if (!strict && !compactSeats) ...[
                const SizedBox(height: LaresSpacing.sm + 2),
                const _VerifiedLine(),
                const SizedBox(height: LaresSpacing.md),
              ] else
                SizedBox(height: compactSeats ? LaresSpacing.md : LaresSpacing.lg),
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withValues(alpha: theme.isDark ? 0.92 : 1),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(LaresRadii.lg)),
                  ),
                  child: Column(
                    children: [
                      Expanded(child: lower),
                      _Controls(strict: strict),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Seats extends StatelessWidget {
  const _Seats({required this.compact, required this.speaking});
  final bool compact;
  final int speaking;

  @override
  Widget build(BuildContext context) {
    final double size = compact ? 44 : 58;
    final List<Widget> orbs = <Widget>[
      for (int i = 0; i < kSeats.length; i++)
        VeiledOrb(
          glyph: kSeats[i].glyph,
          name: kSeats[i].name,
          size: size,
          speaking: i == speaking,
          verified: kSeats[i].verified,
          badge: kSeats[i].officer ? const OrbBadge(icon: Icons.shield_outlined) : null,
        ),
    ];
    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: LaresSpacing.md),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: orbs,
        ),
      );
    }
    return Column(
      children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: orbs.sublist(0, 3)),
        const SizedBox(height: LaresSpacing.md),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: orbs.sublist(3)),
      ],
    );
  }
}

/// 「5/6 已核验身份 · 放行只计已核验成员」。
class _VerifiedLine extends StatelessWidget {
  const _VerifiedLine();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final int n = kSeats.where((Seat s) => s.verified).length;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.verified_user_rounded, size: 12, color: const Color(0xFF6FD08C).withValues(alpha: 0.85)),
        const SizedBox(width: 5),
        Text(
          '$n/${kSeats.length} 已核验身份 · 放行只计已核验成员',
          style: TextStyle(fontSize: 11.5, color: theme.faint),
        ),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({this.strict = false});
  final bool strict;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget round(IconData i, {Color? fg}) => Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(shape: BoxShape.circle, color: theme.colorScheme.surfaceContainerHighest),
      child: Icon(i, size: 22, color: fg ?? theme.colorScheme.onSurfaceVariant),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        LaresSpacing.lg,
        LaresSpacing.sm,
        LaresSpacing.lg,
        MediaQuery.paddingOf(context).bottom + LaresSpacing.md,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          round(Icons.call_end_rounded, fg: theme.colorScheme.error),
          if (!strict) round(Icons.blur_on_rounded),
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: LaresColors.ember),
            child: const Icon(Icons.mic_rounded, size: 28, color: Color(0xFF1A120C)),
          ),
          if (!strict) round(Icons.door_front_door_outlined),
          round(Icons.more_horiz_rounded),
        ],
      ),
    );
  }
}

/// 字幕条的页眉:左侧火漆点 + 「仅在本机内存 · 散会即焚」。
class _EphemeralHeader extends StatelessWidget {
  const _EphemeralHeader({required this.left});
  final String left;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(Icons.closed_caption_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(left, style: TextStyle(fontSize: 12.5, color: theme.colorScheme.onSurfaceVariant)),
        const Spacer(),
        const Pill(
          label: '仅在本机内存 · 散会即焚',
          icon: Icons.local_fire_department_outlined,
          color: LaresColors.ember,
          filled: true,
          dense: true,
        ),
      ],
    );
  }
}

class RoomUnderRulePreview extends StatelessWidget {
  const RoomUnderRulePreview({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return _RoomFrame(
      lower: Padding(
        padding: const EdgeInsets.fromLTRB(LaresSpacing.lg, 18, LaresSpacing.lg, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _EphemeralHeader(left: '实时字幕'),
            const SizedBox(height: 14),
            Expanded(
              child: ShaderMask(
                // 最早的行往上渐隐:字幕是流过去的,不是存下来的
                shaderCallback: (Rect r) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0xFF000000), Color(0xFF000000)],
                  stops: [0, 0.32, 1],
                ).createShader(r),
                blendMode: BlendMode.dstIn,
                child: ListView(
                  physics: const NeverScrollableScrollPhysics(),
                  reverse: true,
                  padding: EdgeInsets.zero,
                  children: [
                    for (int i = kCaptions.length - 1; i >= 0; i--)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '${kCaptions[i].who}  ',
                                style: TextStyle(
                                  color: i == kCaptions.length - 1 ? LaresColors.ember : cs.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                              TextSpan(
                                text: kCaptions[i].text,
                                style: TextStyle(
                                  color: cs.onSurface.withValues(alpha: i == kCaptions.length - 1 ? 0.95 : 0.78),
                                ),
                              ),
                            ],
                          ),
                          style: const TextStyle(fontSize: 15.5, height: 1.55),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(Icons.memory_rounded, size: 13, color: theme.faint),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      '端到端加密，经中转服务器转发 · 不落盘',
                      style: TextStyle(fontSize: 11.5, color: theme.faint),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class InRoomAiPreview extends StatelessWidget {
  const InRoomAiPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return _RoomFrame(
      compactSeats: true,
      speaking: -1,
      lower: Padding(
        padding: const EdgeInsets.fromLTRB(LaresSpacing.lg, 18, LaresSpacing.lg, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const StillAiOrb(size: 18),
                const SizedBox(width: 8),
                Text('圈内 AI', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                const Spacer(),
                const Pill(
                  label: '我们不存，也读不到',
                  icon: Icons.visibility_off_outlined,
                  color: LaresColors.aiGlow,
                  filled: true,
                  dense: true,
                ),
              ],
            ),
            const SizedBox(height: LaresSpacing.md),
            // 提问:右侧气泡
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 280),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: LaresColors.emberSoft,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(18),
                    topRight: Radius.circular(18),
                    bottomLeft: Radius.circular(18),
                    bottomRight: Radius.circular(6),
                  ),
                ),
                child: Text('刚才大家对预算的分歧是什么？', style: TextStyle(fontSize: 15, color: cs.onSurface, height: 1.45)),
              ),
            ),
            const SizedBox(height: LaresSpacing.md),
            Expanded(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(LaresRadii.md + 2),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      LaresColors.aiGlow.withValues(alpha: theme.isDark ? 0.08 : 0.16),
                      LaresColors.aiPlum.withValues(alpha: theme.isDark ? 0.06 : 0.06),
                    ],
                  ),
                  border: Border.all(color: LaresColors.aiGlow.withValues(alpha: 0.18)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '分歧主要在两处：',
                      style: TextStyle(fontSize: 15, height: 1.5, color: cs.onSurface),
                    ),
                    const SizedBox(height: 8),
                    const _Point(n: '1', head: '一次花多少', body: '大橘主张别一次全买新书；青禾提议先拿一千试三个月。'),
                    const SizedBox(height: 8),
                    const _Point(n: '2', head: '余钱去哪', body: '老周想留给读书会，还没人明确反对或附和。'),
                    const SizedBox(height: 8),
                    const _Point(n: '·', head: '已有共识', body: '书架可报销一半（小鹿转述）。'),
                    const Spacer(),
                    Divider(height: 1, color: theme.hairline),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(Icons.timelapse_rounded, size: 13, color: theme.faint),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            '只读本场内存字幕 · 答完即忘 · 不进训练',
                            style: TextStyle(fontSize: 11.5, color: theme.faint),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: const [
                _Chip('我们定了什么？'),
                _Chip('译成英文'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.n, required this.head, required this.body});
  final String n;
  final String head;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 18,
          child: Text(
            n,
            style: const TextStyle(
              fontFamily: ChathamType.serifLatin,
              fontSize: 14,
              height: 1.6,
              color: LaresColors.ember,
            ),
          ),
        ),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: '$head　', style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w600)),
                TextSpan(text: body, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.78))),
              ],
            ),
            style: const TextStyle(fontSize: 14, height: 1.6),
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.hairline),
      ),
      child: Text(label, style: TextStyle(fontSize: 12.5, color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

// ─────────────────────────── ⑦ 守则时段 ───────────────────────────

/// 守则时段:按 Chatham House 规则公开文本只有声音。AI 光球从座位圈里退到门边,写着「已离席」。
class StrictRoomPreview extends StatelessWidget {
  const StrictRoomPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final List<Seat> people = kVoters;
    return _RoomFrame(
      strict: true,
      seats: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (int i = 0; i < 3; i++)
                VeiledOrb(glyph: people[i].glyph, name: people[i].name, size: 58, speaking: i == 1),
            ],
          ),
          const SizedBox(height: LaresSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (int i = 3; i < 5; i++)
                VeiledOrb(glyph: people[i].glyph, name: people[i].name, size: 58),
              const _DepartedAi(),
            ],
          ),
        ],
      ),
      lower: Padding(
        padding: const EdgeInsets.fromLTRB(LaresSpacing.lg, 22, LaresSpacing.lg, 0),
        child: Column(
          children: [
            Text(
              'AI 已离席',
              style: TextStyle(
                fontFamily: ChathamType.serifCjk,
                fontSize: 22,
                letterSpacing: 2,
                color: cs.onSurface,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '按 Chatham House 规则公开文本进行：只有人声。\nAI 不听、不记、不转写，散会后才回到屋里。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, height: 1.65, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: LaresSpacing.lg - 4),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(LaresRadii.md),
                border: Border.all(color: theme.hairline),
              ),
              child: Column(
                children: [
                  for (final (int i, (IconData, String, String) r) in const <(IconData, String, String)>[
                    (Icons.closed_caption_disabled_outlined, '字幕 · 转写', '关'),
                    (Icons.fiber_manual_record_outlined, '录音 · 录像', '关'),
                    (Icons.screenshot_monitor_outlined, '截屏 · 录屏', '尽力防护'),
                  ].indexed) ...[
                    if (i > 0) Divider(height: 1, color: theme.hairline, indent: 44),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                      child: Row(
                        children: [
                          Icon(r.$1, size: 17, color: theme.faint),
                          const SizedBox(width: 13),
                          Expanded(
                            child: Text(r.$2, style: TextStyle(fontSize: 13.5, color: cs.onSurface.withValues(alpha: 0.85))),
                          ),
                          Text(r.$3, style: TextStyle(fontSize: 12.5, color: theme.faint)),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.info_outline_rounded, size: 13, color: theme.faint),
                const SizedBox(width: 5),
                Text(
                  '无法阻止外接录音（另一台设备或系统内录）',
                  style: TextStyle(fontSize: 11.5, color: theme.faint),
                ),
              ],
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_clock_outlined, size: 13, color: theme.faint),
                  const SizedBox(width: 5),
                  Text(
                    '守则时段 · 已 18 分钟 · 整场适用 · 开始后不可切换',
                    style: TextStyle(fontSize: 11.5, color: theme.faint),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 离席的 AI:光球褪成虚线空座,一道残光往右飘出,下面写「已离席」。
class _DepartedAi extends StatelessWidget {
  const _DepartedAi();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const double size = 58;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size + 10,
          height: size + 10,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              CustomPaint(
                size: const Size(size, size),
                painter: _DashedCircle(theme.faint),
              ),
              // 残光:三颗越来越淡的小光球,沿右上方离开
              for (final (double dx, double dy, double s, double a) in const <(double, double, double, double)>[
                (6, -4, 22, 0.55),
                (24, -14, 13, 0.3),
                (36, -22, 7, 0.15),
              ])
                Transform.translate(
                  offset: Offset(dx, dy),
                  child: Opacity(opacity: a, child: StillAiOrb(size: s)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text('已离席', style: TextStyle(fontSize: 12.5, color: theme.faint)),
      ],
    );
  }
}

class _DashedCircle extends CustomPainter {
  _DashedCircle(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color;
    final Rect rect = Offset.zero & size;
    const int n = 28;
    const double sweep = 2 * 3.141592653589793 / n;
    for (int i = 0; i < n; i++) {
      canvas.drawArc(rect.deflate(0.6), i * sweep, sweep * 0.5, false, p);
    }
  }

  @override
  bool shouldRepaint(_DashedCircle old) => old.color != color;
}