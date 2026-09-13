import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/circle_store.dart';
import '../state/identity.dart';
import '../state/location_share_stub.dart'
    if (dart.library.io) '../state/location_share.dart';
import '../state/models.dart';
import '../state/room_controller.dart';
import '../state/settings_store.dart';
import '../state/voice_notes.dart';
import '../theme/tokens.dart';
import 'room_screen.dart';
import 'settings_sheet.dart';

/// 首页:圈子列表(移动端整页 / 桌面端侧栏,§8.2-5 布局断点)。
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.circleStore,
    required this.settings,
    this.voiceNotes,
    this.locationShare,
  });

  final RoomController controller;
  final CircleStore circleStore;
  final SettingsStore settings;
  final VoiceNotesController? voiceNotes;
  final LocationShareService? locationShare;

  String _circleName(String? circleId) {
    if (circleId == null) return '';
    for (final c in circleStore.circles) {
      if (c.id == circleId) return c.name;
    }
    return circleId;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= LaresBreakpoints.desktop;
        final list = _CircleList(controller: controller, circleStore: circleStore);
        return ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final inRoom = controller.phase != RoomPhase.idle;
            // 被踢提示(弹出一次即清)
            if (controller.kickedBy != null) {
              final by = controller.kickedBy!;
              controller.kickedBy = null;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text('你被${by.isEmpty ? '管理员' : by}请出了房间')),
                );
              });
            }
            final roomScreen = RoomScreen(
              controller: controller,
              circleName: _circleName(controller.circleId),
              voiceNotes: voiceNotes,
              settings: settings,
              locationShare: locationShare,
            );
            if (!wide) {
              // 移动端:在房 -> 房间页整屏;未在房 -> 圈子列表
              return inRoom
                  ? roomScreen
                  : Scaffold(
                      appBar: AppBar(
                        title: const Text('Lares'),
                        actions: [
                          _SettingsAction(
                            controller: controller,
                            settings: settings,
                            circleStore: circleStore,
                          ),
                          _RenameAction(controller: controller),
                        ],
                      ),
                      body: list,
                    );
            }
            // 桌面端:侧栏 + 主区
            return Scaffold(
              body: Row(
                children: [
                  SizedBox(
                    width: 280,
                    child: ColoredBox(
                      color: Theme.of(context).colorScheme.surface,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(LaresSpacing.lg),
                            child: Row(
                              children: [
                                Text('Lares',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge),
                                const Spacer(),
                                _SettingsAction(
                                  controller: controller,
                                  settings: settings,
                                  circleStore: circleStore,
                                ),
                                _RenameAction(controller: controller),
                              ],
                            ),
                          ),
                          Expanded(child: list),
                        ],
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: inRoom ? roomScreen : const _EmptyRoomHint()),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _CircleList extends StatelessWidget {
  const _CircleList({required this.controller, required this.circleStore});

  final RoomController controller;
  final CircleStore circleStore;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, circleStore]),
      builder: (context, _) {
        final joining = controller.phase == RoomPhase.joining;
        return ListView(
          padding: const EdgeInsets.all(LaresSpacing.md),
          children: [
            for (final circle in circleStore.circles)
              _CircleTile(
                key: ValueKey(circle.id),
                circle: circle,
                controller: controller,
                circleStore: circleStore,
                joining: joining,
              ),
            const SizedBox(height: LaresSpacing.sm),
            // 加圈子(§2.2 多圈子)/ 粘贴邀请链接
            Center(
              child: TextButton.icon(
                onPressed: () => _showAddCircleDialog(context),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('加个圈子'),
              ),
            ),
            Center(
              child: TextButton(
                onPressed: () => _showJoinByLinkDialog(context),
                child: Text(
                  '有邀请链接?粘贴进圈',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showAddCircleDialog(BuildContext context) async {
    final field = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('加个圈子'),
        content: TextField(
          controller: field,
          autofocus: true,
          maxLength: 16,
          decoration: const InputDecoration(hintText: '比如:家人、死党群、考研搭子'),
          onSubmitted: (_) => Navigator.pop(ctx, field.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('算了'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, field.text),
            child: const Text('建一个'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final id = 'c_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    await circleStore.add(Circle(id: id, name: name.trim()));
  }

  /// 粘贴邀请链接进圈:`lares://circle/<id>?name=X`,或直接粘贴圈子 id
  Future<void> _showJoinByLinkDialog(BuildContext context) async {
    final field = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('粘贴邀请链接'),
        content: TextField(
          controller: field,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'lares://circle/… 或圈子 id',
          ),
          onSubmitted: (_) => Navigator.pop(ctx, field.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('算了'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, field.text),
            child: const Text('进圈'),
          ),
        ],
      ),
    );
    if (input == null) return;
    final circle = _parseInvite(input.trim());
    if (circle == null) return;
    await circleStore.add(circle);
    // 直接进房
    if (controller.phase != RoomPhase.idle &&
        controller.circleId != circle.id) {
      await controller.leave();
    }
    controller.join(circle.id);
  }

  Circle? _parseInvite(String input) {
    if (input.isEmpty) return null;
    if (input.startsWith('lares://circle/')) {
      final uri = Uri.parse(input);
      final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
      if (id.isEmpty) return null;
      return Circle(
        id: id,
        name: uri.queryParameters['name'] ?? '朋友的圈',
      );
    }
    // 纯 id
    return Circle(id: input, name: '朋友的圈');
  }
}

class _CircleTile extends StatelessWidget {
  const _CircleTile({
    super.key,
    required this.circle,
    required this.controller,
    required this.circleStore,
    required this.joining,
  });

  final Circle circle;
  final RoomController controller;
  final CircleStore circleStore;
  final bool joining;

  @override
  Widget build(BuildContext context) {
    final isCurrentRoom =
        controller.circleId == circle.id && controller.phase != RoomPhase.idle;
    // 大厅摘要优先(未进房也可见);当前房间用房间快照兜底
    final summary = controller.circlePresence[circle.id];
    final online = isCurrentRoom
        ? controller.members.length
        : (summary?.count ?? 0);
    final names = summary?.names ?? const <String>[];
    final subtitle = online > 0
        ? '$online 个人在${names.isNotEmpty ? ' · ${names.join('、')}' : ''}'
        : '暂无人在,进去等等看?';

    final isPrimary = circleStore.isPrimary(circle.id);

    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: LaresSpacing.lg,
          vertical: LaresSpacing.sm,
        ),
        title: Row(
          children: [
            Flexible(child: Text(circle.name, overflow: TextOverflow.ellipsis)),
            // 主圈子标记:一枚小余烬,不做响亮徽章(§8.2 安静的陪伴感)
            if (isPrimary) ...[
              const SizedBox(width: LaresSpacing.sm),
              Tooltip(
                message: '主圈子 · 小组件一键加入',
                child: Icon(
                  Icons.local_fire_department_rounded,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
        subtitle: Text(
          subtitle,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 邀请入口前置(用户反馈:找不到获取圈子链接的地方)
            IconButton(
              tooltip: '邀请朋友进圈',
              icon: const Icon(Icons.ios_share_rounded, size: 18),
              onPressed: () => _showInviteDialog(context),
            ),
            if (summary?.knockRequired == true)
              Padding(
                padding: const EdgeInsets.only(right: LaresSpacing.xs),
                child: Icon(
                  Icons.door_front_door_outlined,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            if (joining && controller.circleId == circle.id)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(Icons.chevron_right_rounded),
          ],
        ),
        onTap: joining
            ? null
            : () async {
                // 多圈子切换:已在别的房间先退(§2.2 互不干扰)
                if (controller.phase != RoomPhase.idle &&
                    controller.circleId != circle.id) {
                  await controller.leave();
                }
                controller.join(circle.id);
              },
        onLongPress: () => _showCircleMenu(context),
      ),
    );
  }

  /// 邀请对话框:展示 lares://circle 链接,一键复制
  Future<void> _showInviteDialog(BuildContext context) async {
    final link =
        'lares://circle/${circle.id}?name=${Uri.encodeComponent(circle.name)}';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('邀请朋友进「${circle.name}」'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('把这段链接发给朋友,对方点一下就进圈(也可在 App 里粘贴):'),
            const SizedBox(height: LaresSpacing.md),
            SelectableText(
              link,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                  ),
            ),
          ],
        ),
        actions: [
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: link));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('复制'),
          ),
        ],
      ),
    );
  }

  /// 长按圈子:设为主圈 / 邀请 / 敲门模式开关 / 删除(默认圈仅不可删)
  void _showCircleMenu(BuildContext context) {
    final knockOn = controller.circlePresence[circle.id]?.knockRequired == true;
    final isPrimary = circleStore.isPrimary(circle.id);
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 主圈子:主屏小组件 / 快捷设置 / 桌面托盘 一键进的就是它
            ListTile(
              leading: Icon(
                isPrimary
                    ? Icons.local_fire_department_rounded
                    : Icons.local_fire_department_outlined,
                color:
                    isPrimary ? Theme.of(context).colorScheme.primary : null,
              ),
              title: Text(isPrimary ? '已是主圈子' : '设为主圈子'),
              subtitle: Text(isPrimary
                  ? '小组件、快捷设置、托盘点一下进的就是这个圈'
                  : '主屏小组件点一下,直接进这个圈'),
              enabled: !isPrimary,
              onTap: isPrimary
                  ? null
                  : () async {
                      Navigator.pop(ctx);
                      await circleStore.setPrimaryCircle(circle.id);
                    },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share_rounded),
              title: const Text('邀请朋友进圈'),
              subtitle: const Text('复制邀请链接发给朋友'),
              onTap: () async {
                Navigator.pop(ctx);
                await _showInviteDialog(context);
              },
            ),
            ListTile(
              leading: Icon(knockOn
                  ? Icons.door_front_door_rounded
                  : Icons.door_front_door_outlined),
              title: Text(knockOn ? '敲门模式:开(点一下关闭)' : '敲门模式:关(点一下开启)'),
              subtitle: const Text('开启后,圈外人进来需要里面的人放行'),
              onTap: () {
                controller.setKnockMode(circle.id, !knockOn);
                Navigator.pop(ctx);
              },
            ),
            if (circle.id != CircleStore.defaultCircle.id)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('删除这个圈子'),
                onTap: () {
                  circleStore.remove(circle.id);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// 设置入口
class _SettingsAction extends StatelessWidget {
  const _SettingsAction({
    required this.controller,
    required this.settings,
    required this.circleStore,
  });

  final RoomController controller;
  final SettingsStore settings;
  final CircleStore circleStore;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '设置',
      icon: const Icon(Icons.tune_rounded, size: 20),
      onPressed: () => showSettingsSheet(
        context,
        settings: settings,
        controller: controller,
        circleStore: circleStore,
        signalingUrl: controller.signalingUrl,
      ),
    );
  }
}

/// 改名入口:点头像旁的编辑按钮改昵称,广播给圈内成员
class _RenameAction extends StatelessWidget {
  const _RenameAction({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '改昵称',
      icon: const Icon(Icons.edit_outlined, size: 20),
      onPressed: () async {
        final field = TextEditingController(text: controller.userName);
        final name = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('圈子里叫你什么?'),
            content: TextField(
              controller: field,
              autofocus: true,
              maxLength: 12,
              decoration: const InputDecoration(hintText: '昵称'),
              onSubmitted: (_) => Navigator.pop(ctx, field.text),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('算了'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, field.text),
                child: const Text('就叫这个'),
              ),
            ],
          ),
        );
        if (name != null && name.trim().isNotEmpty) {
          controller.rename(name);
          await Identity.saveName(name.trim());
        }
      },
    );
  }
}

class _EmptyRoomHint extends StatelessWidget {
  const _EmptyRoomHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.graphic_eq_rounded,
            size: 48,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
          ),
          const SizedBox(height: LaresSpacing.md),
          Text('点左边圈子,一键进圈',
              style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
