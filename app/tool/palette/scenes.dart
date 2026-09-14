// 渲染用的两个场景:房间界面 / 聊天面板。
//
// 忠实度说明(重要,别把这些图当成像素级真机截图):
//  · SpeakingRipple 是**直接复用**的真组件(lib/src/ui/widgets/speaking_ripple.dart),
//    它本来就接受 color 参数,所以能原样换色。
//  · AvatarOrb 与 ChatPanel 无法直接复用:前者从 Member.status.color 取色,
//    而 MemberStatus 的颜色是写死在枚举上的 LaresColors 编译期常量;
//    后者依赖 ChatService / BlockStore 等一整套运行时协作者。
//    因此这里按它们的真实布局(尺寸、圆角、间距、字阶、层级)重建,
//    数值全部引自 LaresRadii / LaresSpacing,不自创任何新尺寸。
//  · 目的是比较**配色**,不是验证布局 —— 五张图用的是同一套结构,
//    差异只来自 token,所以横向对比是成立的。

import 'package:flutter/material.dart';
import 'package:lares_app/src/theme/tokens.dart';
import 'package:lares_app/src/ui/widgets/speaking_ripple.dart';

import 'palettes.dart';

Color _c(int argb) => Color(argb);

/// 一位示例成员。
class DemoMember {
  const DemoMember(this.name, this.statusLabel, this.statusColor,
      {this.speaking = false, this.muted = false});
  final String name;
  final String statusLabel;
  final int statusColor;
  final bool speaking;
  final bool muted;
}

List<DemoMember> demoMembers(Palette p) => <DemoMember>[
      DemoMember('阿澈', '随时聊', p.statusFree, speaking: true),
      DemoMember('林一', '在忙', p.statusBusy),
      DemoMember('小满', '耳朵在', p.statusEars),
      DemoMember('周野', '有事先走', p.statusAway),
      DemoMember('文文', '随时聊', p.statusFree),
      DemoMember('我', '耳朵在', p.statusEars, muted: true),
    ];

// ══════════════════════════════════════════
// 场景一:房间界面
// ══════════════════════════════════════════

class RoomScene extends StatelessWidget {
  const RoomScene({super.key, required this.palette});

  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<DemoMember> members = demoMembers(palette);

    return Scaffold(
      body: Stack(
        children: <Widget>[
          // 真 RoomScreen 的「呼吸感」氛围背景:顶部一团极淡的品牌色光晕。
          // 这里取呼吸动画的中间相位(alpha 0.075),静态图上最接近平均观感。
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.7),
                radius: 1.2,
                colors: <Color>[
                  _c(palette.brand).withValues(alpha: 0.075),
                  theme.scaffoldBackgroundColor,
                ],
              ),
            ),
            child: const SizedBox.expand(),
          ),
          SafeArea(
            child: Column(
              children: <Widget>[
                _RoomHeader(palette: palette),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: LaresSpacing.md,
                    ),
                    // shrinkWrap + Center:六个头像自然占两行,
                    // 让它们在可用高度里居中,而不是顶在上面留一大片空
                    child: Center(
                      child: GridView.count(
                        crossAxisCount: 3,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        childAspectRatio: 0.82,
                        children: members
                            .map((DemoMember m) =>
                                _Orb(member: m, palette: palette))
                            .toList(),
                      ),
                    ),
                  ),
                ),
                _CollapsedComposer(palette: palette),
                _ControlBar(palette: palette),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 房间顶栏:圈子名 + 在房人数 + 一句状态。
class _RoomHeader extends StatelessWidget {
  const _RoomHeader({required this.palette});
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LaresSpacing.md,
        LaresSpacing.md,
        LaresSpacing.md,
        LaresSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('围炉', style: theme.textTheme.titleLarge),
                const SizedBox(height: 2),
                Text('6 人在 · 已经待了 2 小时 14 分',
                    style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: LaresSpacing.sm + 2,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: _c(palette.surfaceHigh),
              borderRadius: BorderRadius.circular(LaresRadii.sm),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.map_outlined,
                    size: 16, color: _c(palette.textSecondary)),
                const SizedBox(width: LaresSpacing.xs),
                Text('地图', style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 成员头像球:状态色环 + 说话波纹 + 静音标记。
/// 布局对照 lib/src/ui/widgets/avatar_orb.dart。
class _Orb extends StatelessWidget {
  const _Orb({required this.member, required this.palette});

  final DemoMember member;
  final Palette palette;

  static const double _size = 76;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        SizedBox(
          width: _size + 16,
          height: _size + 16,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              // 真组件复用:说话时三环扩散,颜色走品牌色
              SpeakingRipple(
                speaking: member.speaking,
                size: _size + 16,
                color: _c(palette.brand),
              ),
              Container(
                width: _size,
                height: _size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _c(member.statusColor),
                    width: 2.5,
                  ),
                  color: theme.colorScheme.surface,
                ),
                alignment: Alignment.center,
                child: Text(
                  member.name.characters.first,
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontSize: _size * 0.36),
                ),
              ),
              if (member.muted)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.colorScheme.surface,
                    ),
                    child: Icon(Icons.mic_off_rounded,
                        size: 15, color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: LaresSpacing.sm),
        Text(member.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge),
        Text(
          member.statusLabel,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: _c(member.statusColor), fontSize: 12),
        ),
      ],
    );
  }
}

/// 收起状态的聊天条 —— 房间界面里它就是一条窄条,带一颗未读圆点。
class _CollapsedComposer extends StatelessWidget {
  const _CollapsedComposer({required this.palette});
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(LaresRadii.lg),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LaresSpacing.sm,
          vertical: LaresSpacing.sm,
        ),
        child: Row(
          children: <Widget>[
            Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(LaresSpacing.sm),
                  child: Icon(Icons.chat_bubble_outline_rounded,
                      color: _c(palette.textSecondary)),
                ),
                // 未读:一颗余烬圆点,没有数字
                Positioned(
                  right: LaresSpacing.xs,
                  top: LaresSpacing.xs,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _c(palette.brand),
                      shape: BoxShape.circle,
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: _c(palette.brandSoft),
                          blurRadius: 6,
                          spreadRadius: 3,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: LaresSpacing.md,
                  vertical: LaresSpacing.sm + 2,
                ),
                decoration: BoxDecoration(
                  color: theme.scaffoldBackgroundColor,
                  borderRadius: BorderRadius.circular(LaresRadii.md),
                ),
                child: Text('说点什么,或者放张图',
                    style: theme.textTheme.bodyMedium),
              ),
            ),
            const SizedBox(width: LaresSpacing.xs),
            Icon(Icons.image_outlined, color: _c(palette.textSecondary)),
            const SizedBox(width: LaresSpacing.md),
            Icon(Icons.send_rounded, color: _c(palette.brand)),
            const SizedBox(width: LaresSpacing.xs),
          ],
        ),
      ),
    );
  }
}

/// 底部主操作条:静音 + 主麦克风(品牌色)+ 离开。
class _ControlBar extends StatelessWidget {
  const _ControlBar({required this.palette});
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LaresSpacing.md,
        LaresSpacing.md,
        LaresSpacing.md,
        LaresSpacing.lg,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          _RoundAction(
            icon: Icons.mic_off_rounded,
            label: '静音',
            bg: _c(palette.surfaceHigh),
            fg: _c(palette.textSecondary),
            palette: palette,
          ),
          // 主按钮:品牌色最重的一处落点
          Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 112,
                height: 56,
                decoration: BoxDecoration(
                  color: _c(palette.brand),
                  borderRadius: BorderRadius.circular(LaresRadii.md),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: _c(palette.brand).withValues(alpha: 0.28),
                      blurRadius: 20,
                      spreadRadius: -2,
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.mic_rounded,
                        size: 20, color: _c(palette.onBrand)),
                    const SizedBox(width: LaresSpacing.xs + 2),
                    Text(
                      '在说',
                      style: TextStyle(
                        color: _c(palette.onBrand),
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: LaresSpacing.xs + 2),
              Text('松开即静音', style: theme.textTheme.bodyMedium),
            ],
          ),
          _RoundAction(
            icon: Icons.logout_rounded,
            label: '离开',
            bg: _c(palette.surfaceHigh),
            fg: _c(palette.textSecondary),
            palette: palette,
          ),
        ],
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.label,
    required this.bg,
    required this.fg,
    required this.palette,
  });

  final IconData icon;
  final String label;
  final Color bg;
  final Color fg;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Icon(icon, color: fg, size: 22),
        ),
        const SizedBox(height: LaresSpacing.xs + 2),
        Text(label, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

// ══════════════════════════════════════════
// 场景二:聊天面板(展开态)
// ══════════════════════════════════════════

class ChatScene extends StatelessWidget {
  const ChatScene({super.key, required this.palette});

  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      body: Stack(
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.7),
                radius: 1.2,
                colors: <Color>[
                  _c(palette.brand).withValues(alpha: 0.075),
                  theme.scaffoldBackgroundColor,
                ],
              ),
            ),
            child: const SizedBox.expand(),
          ),
          SafeArea(
            child: Column(
              children: <Widget>[
                _RoomHeader(palette: palette),
                // 面板展开时,上方成员网格被压成一行
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LaresSpacing.md,
                    vertical: LaresSpacing.sm,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: demoMembers(palette)
                        .take(4)
                        .map((DemoMember m) =>
                            _MiniOrb(member: m, palette: palette))
                        .toList(),
                  ),
                ),
                const Spacer(),
                _ExpandedPanel(palette: palette),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 聊天展开时上方那一排小头像(仍带状态环)。
class _MiniOrb extends StatelessWidget {
  const _MiniOrb({required this.member, required this.palette});
  final DemoMember member;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: 60,
          height: 60,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              SpeakingRipple(
                speaking: member.speaking,
                size: 60,
                color: _c(palette.brand),
              ),
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border:
                      Border.all(color: _c(member.statusColor), width: 2.5),
                  color: theme.colorScheme.surface,
                ),
                alignment: Alignment.center,
                child: Text(
                  member.name.characters.first,
                  style: theme.textTheme.titleLarge?.copyWith(fontSize: 17),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: LaresSpacing.xs),
        Text(member.statusLabel,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: _c(member.statusColor), fontSize: 11)),
      ],
    );
  }
}

class _Msg {
  const _Msg(this.sender, this.time, this.text,
      {this.mine = false, this.showHeader = true, this.sending = false});
  final String sender;
  final String time;
  final String text;
  final bool mine;
  final bool showHeader;
  final bool sending;
}

const List<_Msg> _demoMessages = <_Msg>[
  _Msg('阿澈', '22:09', '今晚谁还在?我这边刚忙完'),
  _Msg('小满', '22:11', '在的,不过我戴着耳机写东西', showHeader: true),
  _Msg('阿澈', '22:14', '我把汤热上了,你们慢慢聊'),
  _Msg('小满', '22:16', '今天那首歌叫什么来着'),
  _Msg('小满', '22:16', '就是你上周放的那个', showHeader: false),
  _Msg('我', '22:18', '《夜航西飞》,我待会儿丢个链接', mine: true),
  // 刻意不放 emoji:headless 渲染环境下 Windows 字体没有彩色 emoji 字形,
  // Skia 回退查找会卡死整个测试进程(实测 b_emoji 探针必挂)。
  // 真机上不存在这个问题,但对比图里也不需要 emoji 来说明配色。
  _Msg('林一', '22:21', '别聊了,我这边还在改 bug'),
  _Msg('我', '22:22', '那你把耳朵开着就行', mine: true, sending: true),
];

/// 展开的聊天面板:消息列表 + 输入框。
class _ExpandedPanel extends StatelessWidget {
  const _ExpandedPanel({required this.palette});
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

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
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LaresSpacing.md,
              vertical: LaresSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _demoMessages
                  .map((_Msg m) => _MessageRow(msg: m, palette: palette))
                  .toList(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LaresSpacing.sm,
              0,
              LaresSpacing.sm,
              LaresSpacing.md,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(LaresSpacing.sm),
                  child: Icon(Icons.keyboard_arrow_down_rounded,
                      color: _c(palette.textSecondary)),
                ),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: LaresSpacing.md,
                      vertical: LaresSpacing.sm + 2,
                    ),
                    decoration: BoxDecoration(
                      color: theme.scaffoldBackgroundColor,
                      borderRadius: BorderRadius.circular(LaresRadii.md),
                    ),
                    child: Text('说点什么,或者放张图',
                        style: theme.textTheme.bodyMedium),
                  ),
                ),
                const SizedBox(width: LaresSpacing.xs),
                Icon(Icons.image_outlined, color: _c(palette.textSecondary)),
                const SizedBox(width: LaresSpacing.md),
                Icon(Icons.send_rounded, color: _c(palette.brand)),
                const SizedBox(width: LaresSpacing.xs),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 单条消息。自己发的只用一层极淡的品牌色底 + 右对齐,不做高对比气泡。
class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.msg, required this.palette});
  final _Msg msg;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: LaresSpacing.sm),
      child: Column(
        crossAxisAlignment:
            msg.mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: <Widget>[
          if (msg.showHeader)
            Padding(
              padding: const EdgeInsets.only(bottom: LaresSpacing.xs),
              child: Text('${msg.sender}  ${msg.time}',
                  style: theme.textTheme.bodyMedium),
            ),
          Opacity(
            opacity: msg.sending ? 0.55 : 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: msg.mine ? _c(palette.brandSoft) : null,
                borderRadius: BorderRadius.circular(LaresRadii.sm),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LaresSpacing.sm,
                  vertical: LaresSpacing.xs,
                ),
                child: Text(msg.text, style: theme.textTheme.bodyLarge),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
