/// 设置页的「开发者选项」区块 —— 连点版本号 7 次解锁之后才出现。
///
/// 收进来的原则:**普通用户永远不需要碰**的技术项。
/// 判断依据见各条目上方的注释;归类的完整理由写在交付报告里。
///
/// 单独成文件与 [ServerSettingsSection] / [BlockedUsersSection] 同理:
/// 不把多人在改的 settings_sheet.dart 继续撑大。
///
/// 设计纪律(设计.md §8.2):不硬编码颜色/圆角/间距,一律引用 tokens.dart。
library;

import 'package:flutter/material.dart';

import '../p2p/ice_store.dart';
import '../state/dev_mode_store.dart';
import '../state/models.dart';
import '../state/room_controller.dart';
import '../state/settings_store.dart';
import '../theme/tokens.dart';
import 'p2p_screen.dart';
import 'server_settings_section.dart';
import 'settings_group.dart';

/// 开发者选项区。**调用方必须自己判断 [DevModeStore.enabled]**
/// —— 本 widget 不做这道判断,以免「忘了判断」变成一个悄悄泄漏技术面的口子。
class DeveloperSection extends StatelessWidget {
  const DeveloperSection({
    super.key,
    required this.devMode,
    required this.settings,
    required this.controller,
    this.signalingUrl,
    this.ice,
    this.onStartMesh,
  });

  final DevModeStore devMode;
  final SettingsStore settings;
  final RoomController controller;

  /// 直连用的 ICE 配置。为空时不显示直连入口 ——
  /// 宁可没有入口,也不要一个点进去就崩的入口。
  final IceStore? ice;

  /// 启动多人直连。为空则直连界面只给 1 对 1。
  final VoidCallback? onStartMesh;

  /// 编译期内置的信令地址(「状态」里如实显示的就是它或它的覆盖值)
  final String? signalingUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SettingsGroup(
      title: '开发者选项',
      // 说清楚这里是什么、以及怎么回到干净的状态 —— 免得解锁之后
      // 用户面对一堆技术项不知所措,也不知道怎么关掉。
      caption: '这些是排查问题用的技术项,平时不需要动。',
      children: [
        // 「服务器与口令」**已移到常规设置**(settings_sheet.dart)。
        // 别再挪回来 —— 自托管是产品的核心主张,藏在彩蛋后面
        // 等于对普通用户不存在。
        //
        // ── 状态 ───────────────────────────────────────────────────
        // 纯诊断读数:信令地址 + 进房耗时。普通用户看不懂也不需要看懂。
        ListTile(
          leading: const Icon(Icons.speed_rounded),
          title: const Text('状态'),
          subtitle: Text(
            '信令 ${signalingUrl ?? '(未配置)'}\n'
            '上次进房 ${controller.lastJoinLatency?.inMilliseconds ?? '-'}ms'
            '${controller.phase == RoomPhase.inRoom ? ' · 当前在房间里' : ''}',
          ),
        ),
        // ── 直连(不经服务器)──────────────────────────────────────
        // 放这里而不是主流程:它是**兜底路径**,不该跟正常进圈竞争。
        // 而且它做不到的事很多(一对一、无文字图片、无 E2EE),
        // 摆在首页只会让人以为那是常规用法。
        if (ice != null) ...[
          ListTile(
            leading: const Icon(Icons.cable_rounded),
            title: const Text('直连对话'),
            subtitle: const Text('一台服务器都没有时,互传连接码也能说上话'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => P2PScreen(
                  ice: ice!,
                  onStartMesh: onStartMesh,
                ),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.alt_route_rounded),
            title: const Text('中继服务器(STUN / TURN)'),
            subtitle: Text(
              ice!.config.isEmpty
                  // 说明白空着的后果,而不是只显示「未配置」
                  ? '空着 —— 只能连同一个网络里的人'
                  : '${ice!.config.stunUrls.length} 个 STUN'
                      '${ice!.config.turn != null ? ' · 有中继' : ' · 无中继'}',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _editIce(context, ice!),
          ),
        ],
        const Divider(),
        // ── 关掉开发者模式 ──────────────────────────────────────────
        // 必须留一条出路:开发者模式是连点解锁的,如果关不掉,
        // 误触解锁的人就再也回不到干净的设置页了。
        SwitchListTile(
          secondary: const Icon(Icons.developer_mode_rounded),
          title: const Text('开发者模式'),
          subtitle: Text(
            '关掉之后这一整块都会收起来;想再打开,还是连点 7 次版本号。',
            style: theme.textTheme.bodyMedium,
          ),
          value: devMode.enabled,
          onChanged: (v) async {
            if (v) return; // 这里只负责关;开只能靠连点版本号
            final messenger = ScaffoldMessenger.of(context);
            await devMode.disable();
            messenger
              ..clearSnackBars()
              ..showSnackBar(const SnackBar(content: Text('开发者模式已关闭')));
          },
        ),
      ],
    );
  }

  /// 编辑 STUN / TURN。
  ///
  /// 刻意**不给默认值**(比如 Google 的公共 STUN):那是一个隐形的外部依赖,
  /// 与直连「不依赖任何人」的初衷相悖。填了才知道自己在依赖谁。
  Future<void> _editIce(BuildContext context, IceStore store) async {
    final cfg = store.config;
    final stun = TextEditingController(text: cfg.stunUrls.join('\n'));
    final turnUrl = TextEditingController(text: cfg.turn?.url ?? '');
    final turnUser = TextEditingController(text: cfg.turn?.username ?? '');
    final turnPass = TextEditingController(text: cfg.turn?.credential ?? '');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('中继服务器'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '直连需要先知道自己的公网地址(STUN)。\n'
                '双方网络都很严格时,还需要一台中继(TURN)帮忙转发。\n'
                '两者都留空也能用 —— 但只能连同一个网络里的人。',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
              const SizedBox(height: LaresSpacing.md),
              TextField(
                controller: stun,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(
                  labelText: 'STUN 地址(一行一个)',
                  hintText: 'stun:stun.example.com:3478',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: LaresSpacing.md),
              TextField(
                controller: turnUrl,
                decoration: const InputDecoration(
                  labelText: 'TURN 地址',
                  hintText: 'turn:turn.example.com:3478',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: LaresSpacing.sm),
              TextField(
                controller: turnUser,
                decoration: const InputDecoration(
                  labelText: 'TURN 用户名',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: LaresSpacing.sm),
              TextField(
                controller: turnPass,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'TURN 口令',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: LaresSpacing.sm),
              Text(
                'TURN 三项要么都填,要么都空 —— 只填一半会让连接挂在那儿等超时,'
                '比没填更糟。',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('算了'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (ok != true) return;
    await store.setStun(stun.text.split('\n'));
    await store.setTurn(
      url: turnUrl.text,
      username: turnUser.text,
      credential: turnPass.text,
    );
  }
}

