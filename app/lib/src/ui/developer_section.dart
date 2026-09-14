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

import '../state/dev_mode_store.dart';
import '../state/models.dart';
import '../state/room_controller.dart';
import '../state/settings_store.dart';
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
  });

  final DevModeStore devMode;
  final SettingsStore settings;
  final RoomController controller;

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
        // ── 服务器与口令 ────────────────────────────────────────────
        // 自托管是本 App 的卖点,但「换服务器地址 + 填鉴权口令」本身
        // 是一次性的部署动作,不是日常设置;且口令是明文存储的敏感项。
        // 放在这里既保住了卖点(要用的人点得到),又不让默认用户误触。
        ServerSettingsSection(
          settings: settings,
          userId: controller.userId,
          defaultUrl: signalingUrl,
        ),
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
}
