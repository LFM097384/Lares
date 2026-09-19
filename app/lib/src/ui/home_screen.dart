import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/gen/app_localizations.dart';
import '../chat/chat_service.dart';
import '../e2ee/e2ee_controller.dart';
import '../e2ee/e2ee_status.dart';
import '../moderation/block_store.dart';
import '../moderation/consent_store.dart';
import '../recording/recording_consent.dart';
import '../p2p/ice_store.dart';
import '../state/circle_store.dart';
import '../state/dev_mode_store.dart';
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
import 'widgets/e2ee_badge.dart';

/// 首页:圈子列表(移动端整页 / 桌面端侧栏,§8.2-5 布局断点)。
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.circleStore,
    required this.settings,
    this.voiceNotes,
    this.locationShare,
    this.chat,
    this.recordingConsent,
    this.blocks,
    this.consent,
    this.e2ee,
    this.devMode,
    this.ice,
    this.onStartMesh,
  });

  final RoomController controller;
  final CircleStore circleStore;
  final SettingsStore settings;
  final VoiceNotesController? voiceNotes;
  final LocationShareService? locationShare;
  final ChatService? chat;
  final RecordingConsentController? recordingConsent;

  /// 本机屏蔽名单(指南 1.2);往下透传给房间页与设置
  final BlockStore? blocks;

  /// 内容规范同意状态;设置里「再看一遍」要用
  final ConsentStore? consent;

  /// 按圈端到端加密。为 null 时圈子菜单里不出现加密开关(可选协作者优雅降级)
  final E2EEController? e2ee;

  /// 开发者模式(连点版本号 7 次解锁)。为 null 时设置页里完全没有开发者区。
  final DevModeStore? devMode;
  final IceStore? ice;
  final VoidCallback? onStartMesh;

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
        final list = _CircleList(
          controller: controller,
          circleStore: circleStore,
          settings: settings,
          e2ee: e2ee,
        );
        return ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final t = AppLocalizations.of(context);
            final inRoom = controller.phase != RoomPhase.idle;
            // 被踢提示(弹出一次即清)
            if (controller.kickedBy != null) {
              final by = controller.kickedBy!;
              controller.kickedBy = null;
              // 名字为空时用「管理员」兜底。注意这里走的是占位符而不是拼接 ——
              // 「谁把你请出去」在英文里语序在前,拼接会把句子拆坏。
              final who = by.isEmpty ? t.homeKickedByAdmin : by;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(t.homeKickedBy(who))),
                );
              });
            }
            final roomScreen = RoomScreen(
              controller: controller,
              circleName: _circleName(controller.circleId),
              voiceNotes: voiceNotes,
              settings: settings,
              locationShare: locationShare,
              chat: chat,
              recordingConsent: recordingConsent,
              blocks: blocks,
              e2ee: e2ee,
            );
            if (!wide) {
              // 移动端:在房 -> 房间页整屏;未在房 -> 圈子列表
              return inRoom
                  ? roomScreen
                  : Scaffold(
                      appBar: AppBar(
                        // 应用名本身也要本地化:中文版叫「炉灵」。
                        title: Text(t.appTitle),
                        actions: [
                          _SettingsAction(
                            controller: controller,
                            settings: settings,
                            circleStore: circleStore,
                            recordingConsent: recordingConsent,
                            blocks: blocks,
                            consent: consent,
                            devMode: devMode,
                            ice: ice,
                            onStartMesh: onStartMesh,
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
                                Text(
                                  t.appTitle,
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const Spacer(),
                                _SettingsAction(
                                  controller: controller,
                                  settings: settings,
                                  circleStore: circleStore,
                                  recordingConsent: recordingConsent,
                                  blocks: blocks,
                                  consent: consent,
                                  devMode: devMode,
                                  ice: ice,
                                  onStartMesh: onStartMesh,
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
  const _CircleList({
    required this.controller,
    required this.circleStore,
    required this.settings,
    this.e2ee,
  });

  final RoomController controller;
  final CircleStore circleStore;

  /// 口令要存进它(走 SecretVault,不落明文 prefs)。
  final SettingsStore settings;
  final E2EEController? e2ee;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, circleStore, e2ee]),
      builder: (context, _) {
        final t = AppLocalizations.of(context);
        final joining = controller.phase == RoomPhase.joining;
        return ListView(
          padding: const EdgeInsets.all(LaresSpacing.md),
          children: [
            // 「我有空」:跨圈的,所以放在圈子列表之上而不是某个圈里。
            // 只在有两个以上圈子时才出现 —— 一个圈子的话直接进去就行,
            // 挂着等人反而多此一举。
            if (circleStore.circles.length > 1 &&
                controller.phase == RoomPhase.idle)
              AvailableToggle(
                controller: controller,
                circleStore: circleStore,
              ),
            for (final circle in circleStore.circles)
              _CircleTile(
                key: ValueKey(circle.id),
                circle: circle,
                controller: controller,
                circleStore: circleStore,
                joining: joining,
                e2ee: e2ee,
              ),
            const SizedBox(height: LaresSpacing.sm),
            // 加圈子(§2.2 多圈子)/ 粘贴邀请链接
            Center(
              child: TextButton.icon(
                onPressed: () => _showAddCircleDialog(context),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(t.homeAddCircle),
              ),
            ),
            Center(
              child: TextButton(
                onPressed: () => _showJoinByLinkDialog(context),
                child: Text(
                  t.homePasteInvite,
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
    final t = AppLocalizations.of(context);
    final field = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.homeAddCircle),
        content: TextField(
          controller: field,
          autofocus: true,
          maxLength: 16,
          decoration: InputDecoration(hintText: t.homeAddCircleHint),
          onSubmitted: (_) => Navigator.pop(ctx, field.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, field.text),
            child: Text(t.homeAddCircleConfirm),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final id = 'c_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    await circleStore.add(Circle(id: id, name: name.trim()));
  }

  /// 粘贴邀请链接进圈:`lares://circle/<id>?name=X`,或直接粘贴圈子 id。
  ///
  /// 口令是**可选**的第二个字段:邀请链接刻意不带口令(带上等于把 E2EE
  /// 密钥一起发出去,而链接会经微信/短信/剪贴板流转),朋友通常会另外发一份。
  /// 一次填完最顺;不填也能继续 —— 进不去时房内还能补。
  Future<void> _showJoinByLinkDialog(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final field = TextEditingController();
    final passField = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.homePasteInviteTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: field,
              autofocus: true,
              decoration: InputDecoration(
                hintText: t.homePasteInviteHint,
              ),
            ),
            const SizedBox(height: LaresSpacing.sm),
            TextField(
              controller: passField,
              // 口令不回显:旁边有人看着屏幕是最常见的泄露方式,
              // 而这个输入框的场景恰恰是「朋友刚把口令发给你」。
              obscureText: true,
              decoration: InputDecoration(
                labelText: t.homePasteInvitePasscode,
                hintText: t.homePasteInvitePasscodeHint,
              ),
              onSubmitted: (_) => Navigator.pop(ctx, true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.homeJoinCircle),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // 兜底圈名在这里取(UI 层),不把 context 递进 _parseInvite ——
    // 那是个纯函数,应当保持可单测。
    final circle = _parseInvite(field.text.trim(), t.homeInvitedCircleFallback);
    if (circle == null) return;
    await circleStore.add(circle);

    // 口令要在进房**之前**存好:进房路径上要拿它算鉴权证明,
    // 还要派生 E2EE 密钥(prepareEncryption 在 rtc.join 之前跑)。
    // 晚一步存就等于这次进房仍然没有口令。
    final pass = passField.text;
    if (pass.isNotEmpty) {
      await settings.setCirclePasscode(circle.id, pass);
    }

    // 直接进房
    if (controller.phase != RoomPhase.idle &&
        controller.circleId != circle.id) {
      await controller.leave();
    }
    // 刚填了口令:走 retryJoin —— 它会先把连接的「证明哪个圈子」摆正
    // 并带新凭据重新握手。普通 join 用的是上一次握手的身份,
    // 而那多半证明的是主圈子,不是刚加的这个。
    if (pass.isNotEmpty) {
      unawaited(controller.retryJoin(circle.id));
    } else {
      controller.join(circle.id);
    }
  }

  /// [fallbackName] 由调用方从本地化取好再传进来,保持本函数不依赖 context。
  Circle? _parseInvite(String input, String fallbackName) {
    if (input.isEmpty) return null;
    if (input.startsWith('lares://circle/')) {
      final uri = Uri.parse(input);
      final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
      if (id.isEmpty) return null;
      return Circle(id: id, name: uri.queryParameters['name'] ?? fallbackName);
    }
    // 纯 id
    return Circle(id: input, name: fallbackName);
  }
}

class _CircleTile extends StatelessWidget {
  const _CircleTile({
    super.key,
    required this.circle,
    required this.controller,
    required this.circleStore,
    required this.joining,
    this.e2ee,
  });

  final Circle circle;
  final RoomController controller;
  final CircleStore circleStore;
  final bool joining;
  final E2EEController? e2ee;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final isCurrentRoom =
        controller.circleId == circle.id && controller.phase != RoomPhase.idle;
    // 大厅摘要优先(未进房也可见);当前房间用房间快照兜底
    final summary = controller.circlePresence[circle.id];
    final online = isCurrentRoom
        ? controller.members.length
        : (summary?.count ?? 0);
    final names = summary?.names ?? const <String>[];
    // 挂着「有空」的人:还没进任何房间,但等着谁来找。
    // 和「几个人在」放同一行 —— 对用户来说这是同一类信息:
    // 「这个圈子现在有没有人可以说话」。
    final waiting = controller.availableIn(circle.id);
    // 人名连接符按语言走:中文顿号、英文逗号+空格。
    // 拼人名列表这件事没法交给 ICU,但分隔符本身必须本地化。
    final sep = t.commonListSeparator;
    final waitingNames = waiting.map((w) => w.name).join(sep);
    final subtitle = switch ((online, waiting.length)) {
      (0, 0) => t.homeCircleEmpty,
      (0, _) => t.homeCircleWaitingOnly(waitingNames),
      (_, 0) => names.isNotEmpty
          ? t.homeCircleOnlineWithNames(online, names.join(sep))
          : t.homeCircleOnline(online),
      _ => t.homeCircleOnlineAndWaiting(online, waitingNames),
    };

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
            // 加密状态:未开启时 E2EEBadge 自己渲染成空,不占位也不制造噪音。
            // 这里用 previewStatusFor(本设备的预测),因为圈子列表上大多数圈
            // 并不在通话中 —— 但它同样会如实报出「开了但平台不支持」。
            if (e2ee != null) ...[
              const SizedBox(width: LaresSpacing.sm),
              E2EEBadge(
                status: e2ee!.previewStatusFor(circle.id),
                compact: true,
              ),
            ],
            // 主圈子标记:一枚小余烬,不做响亮徽章(§8.2 安静的陪伴感)
            if (isPrimary) ...[
              const SizedBox(width: LaresSpacing.sm),
              Tooltip(
                message: t.homePrimaryCircleTooltip,
                child: Icon(
                  Icons.local_fire_department_rounded,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
        subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 邀请入口前置(用户反馈:找不到获取圈子链接的地方)
            IconButton(
              tooltip: t.homeInviteFriends,
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
                // 房里没人、但有人挂着「我有空」—— 那就去找 ta,
                // 而不是自己进一个空房间干等。
                // 服务端会把双方一起拉进这个圈子。
                if (online == 0 && waiting.isNotEmpty) {
                  controller.reach(waiting.first.userId, circleId: circle.id);
                  return;
                }
                controller.join(circle.id);
              },
        onLongPress: () => _showCircleMenu(context),
      ),
    );
  }

  /// 邀请对话框:展示 lares://circle 链接,一键复制
  Future<void> _showInviteDialog(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final link =
        'lares://circle/${circle.id}?name=${Uri.encodeComponent(circle.name)}';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.homeInviteTitle(circle.name)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.homeInviteBody),
            const SizedBox(height: LaresSpacing.md),
            SelectableText(
              link,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
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
            label: Text(t.commonCopy),
          ),
        ],
      ),
    );
  }

  /// 长按圈子:设为主圈 / 邀请 / 敲门模式开关 / 删除(默认圈仅不可删)
  void _showCircleMenu(BuildContext context) {
    final t = AppLocalizations.of(context);
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
                color: isPrimary ? Theme.of(context).colorScheme.primary : null,
              ),
              title: Text(
                isPrimary ? t.homePrimaryCircleAlready : t.homePrimaryCircleSet,
              ),
              subtitle: Text(
                isPrimary
                    ? t.homePrimaryCircleAlreadyDesc
                    : t.homePrimaryCircleSetDesc,
              ),
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
              title: Text(t.homeInviteFriends),
              subtitle: Text(t.homeInviteFriendsDesc),
              onTap: () async {
                Navigator.pop(ctx);
                await _showInviteDialog(context);
              },
            ),
            // 端到端加密:按圈可选,默认关。
            // 代价必须写在开关旁边(kE2EECostNotice),不能让人开完才困惑。
            if (e2ee != null) _E2EETile(circle: circle, e2ee: e2ee!),
            ListTile(
              leading: Icon(
                knockOn
                    ? Icons.door_front_door_rounded
                    : Icons.door_front_door_outlined,
              ),
              title: Text(knockOn ? t.homeKnockModeOn : t.homeKnockModeOff),
              subtitle: Text(t.homeKnockModeDesc),
              onTap: () {
                controller.setKnockMode(circle.id, !knockOn);
                Navigator.pop(ctx);
              },
            ),
            if (circle.id != CircleStore.defaultCircle.id)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: Text(t.homeDeleteCircle),
                onTap: () {
                  circleStore.remove(circle.id);
                  // 顺手清掉加密开关,不留悬空登记 ——
                  // 否则将来重建同名圈子会「莫名其妙已经开着加密」。
                  e2ee?.forget(circle.id);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// 圈子菜单里的端到端加密开关。
///
/// 三条纪律,缺一条这个功能就是安全负资产:
/// 1. **代价前置** —— 开关的副标题里直接写明「服务器无法转录、炉灵不可用」,
///    而不是藏进某个说明页;
/// 2. **诚实** —— 开了之后如果本平台/口令不支持,立刻在下面挂出红色说明,
///    绝不让开关的「已打开」状态独自代表「已加密」;
/// 3. **不可静默** —— 平台不支持时**开关照常可开**(用户换台设备就生效),
///    但当下这台设备的真实状态一个字都不隐瞒。
class _E2EETile extends StatefulWidget {
  const _E2EETile({required this.circle, required this.e2ee});

  final Circle circle;
  final E2EEController e2ee;

  @override
  State<_E2EETile> createState() => _E2EETileState();
}

class _E2EETileState extends State<_E2EETile> {
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final id = widget.circle.id;
    final bool on = widget.e2ee.isEnabled(id);
    final E2EEStatus status = widget.e2ee.previewStatusFor(id);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          secondary: Icon(
            on ? Icons.lock_rounded : Icons.lock_open_rounded,
            color: on && status.isEncrypted ? LaresColors.ember : null,
          ),
          title: Text(t.e2eeTitle),
          subtitle: Text(
            // 代价说明始终展示,开与不开都一样 —— 让人在按下去之前就知道。
            //
            // 注:原先直接内插 e2ee_status.dart 里的 kE2EECostNotice 常量。
            // 那个常量是顶层 const、拿不到 context,且 e2ee_degrade_test
            // 直接断言它的内容,故此处改为走本地化键 e2eeCostNotice
            // (文案与该常量逐字一致),常量本身保持原样不动。
            '${t.e2eeCostNotice}\n${t.e2eeKeyLocalNotice}',
            style: theme.textTheme.bodyMedium,
          ),
          isThreeLine: true,
          value: on,
          onChanged: (v) async {
            await widget.e2ee.setEnabled(id, v);
            if (mounted) setState(() {});
          },
        ),
        // 开了但这台设备做不到:必须说出来,而且要显眼。
        // E2EEWarningBanner 自带左右留白,与房间页的横幅视觉一致。
        if (status.isBrokenPromise) E2EEWarningBanner(status: status),
        if (status.isBrokenPromise) const SizedBox(height: LaresSpacing.md),
      ],
    );
  }
}

/// 设置入口
class _SettingsAction extends StatelessWidget {
  const _SettingsAction({
    required this.controller,
    required this.settings,
    required this.circleStore,
    this.recordingConsent,
    this.blocks,
    this.consent,
    this.devMode,
    this.ice,
    this.onStartMesh,
  });

  final RoomController controller;
  final SettingsStore settings;
  final CircleStore circleStore;
  final RecordingConsentController? recordingConsent;
  final BlockStore? blocks;
  final ConsentStore? consent;

  /// 开发者模式;为 null 时设置页既没有开发者区,版本号也点不出任何东西
  final DevModeStore? devMode;
  final IceStore? ice;
  final VoidCallback? onStartMesh;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: AppLocalizations.of(context).settingsTitle,
      icon: const Icon(Icons.tune_rounded, size: 20),
      onPressed: () => showSettingsSheet(
        context,
        settings: settings,
        controller: controller,
        circleStore: circleStore,
        signalingUrl: controller.signalingUrl,
        recordingConsent: recordingConsent,
        blocks: blocks,
        consent: consent,
        devMode: devMode,
        ice: ice,
        onStartMesh: onStartMesh,
      ),
    );
  }
}

/// 「我有空」开关:把自己挂出去,对选定的几个圈子可见。
///
/// 为什么放在圈子列表**之上**:它是跨圈的 —— 挂一次对多个圈子同时可见,
/// 塞进某个圈子的卡片里会让人以为只对那个圈生效。
///
/// 第一个来找的人把双方拉进**那个人所在的圈子**,此刻挂着态立即取消,
/// 其他圈子的人不再看到你可约。这条规则在副标题里说明白,
/// 不让用户按下去之后才发现。
/// 公开(而非 `_` 私有)是为了能被 widget 测试直接挂载 ——
/// 「选了哪几个圈子就挂哪几个」这条契约值得单独验,
/// 把整个首页拉起来测它既慢又脆。
class AvailableToggle extends StatelessWidget {
  const AvailableToggle({
    super.key,
    required this.controller,
    required this.circleStore,
  });

  final RoomController controller;
  final CircleStore circleStore;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final on = controller.iAmAvailable;
    final n = controller.myAvailableCircles.length;

    final total = circleStore.circles.length;
    // 挂着且只选了一部分圈子时,把「哪几个」说清楚 ——
    // 「2 个圈子看得到」比「已开启」有用得多。
    final picked = on && n < total;

    final tile = SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: LaresSpacing.lg,
        vertical: LaresSpacing.xs,
      ),
      secondary: Icon(
        on ? Icons.waving_hand_rounded : Icons.waving_hand_outlined,
        color: on ? theme.colorScheme.primary : null,
      ),
      title: Row(
        children: [
          Text(t.homeAvailable),
          if (picked) ...[
            const SizedBox(width: LaresSpacing.sm),
            Icon(
              Icons.filter_alt_rounded,
              size: 14,
              color: theme.colorScheme.primary,
            ),
          ],
        ],
      ),
      subtitle: Text(
        on
            ? t.homeAvailableOnDesc(n)
            // 没挂着时就把「可以挑」这件事说出来 ——
            // 长按是个藏起来的手势,不说没人会去试。
            : t.homeAvailableOffDesc,
        style: theme.textTheme.bodyMedium,
      ),
      value: on,
      onChanged: (v) {
        if (!v) return controller.clearAvailable();
        // 默认对所有圈子可见。想挑就长按 —— 先给最省事的默认值,
        // 而不是一上来就让人做选择题。
        controller.setAvailable([for (final c in circleStore.circles) c.id]);
      },
    );

    // SwitchListTile 自己没有 onLongPress,所以外面包一层。
    // behavior: opaque —— 让长按在整张卡片上都能触发,而不只是文字那一小块。
    return Card(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => _pickCircles(context),
        child: tile,
      ),
    );
  }

  /// 挑选对哪几个圈子可见。
  ///
  /// 入口是长按而不是常驻按钮:多数时候「对所有人可见」就是对的,
  /// 挑选是少数情况(比如今晚只想跟家里人聊)。
  Future<void> _pickCircles(BuildContext context) async {
    final t = AppLocalizations.of(context);
    // 起始值:已经挂着就沿用当前选择,没挂着则默认全选
    final selected = <String>{
      ...(controller.iAmAvailable
          ? controller.myAvailableCircles
          : circleStore.circles.map((c) => c.id)),
    };

    final result = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: Text(t.homeAvailablePickTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.homeAvailablePickBody,
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
              const SizedBox(height: LaresSpacing.md),
              // 圈子可能很多,给个上限高度,别把对话框撑破屏幕
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final c in circleStore.circles)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text(c.name, overflow: TextOverflow.ellipsis),
                          value: selected.contains(c.id),
                          onChanged: (v) => setInner(() {
                            if (v == true) {
                              selected.add(c.id);
                            } else {
                              selected.remove(c.id);
                            }
                          }),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(t.commonCancel),
            ),
            // 一个都没选就等于不挂着 —— 与其让用户提交一个空选择再困惑
            // 为什么没人看得到,不如直接把按钮禁掉。
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(ctx, selected),
              child: Text(t.homeAvailablePickConfirm),
            ),
          ],
        ),
      ),
    );

    if (result == null || result.isEmpty) return;
    controller.setAvailable(result.toList());
  }
}

/// 改名入口:点头像旁的编辑按钮改昵称,广播给圈内成员
class _RenameAction extends StatelessWidget {
  const _RenameAction({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return IconButton(
      tooltip: t.homeRename,
      icon: const Icon(Icons.edit_outlined, size: 20),
      onPressed: () async {
        final field = TextEditingController(text: controller.userName);
        final name = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(t.homeRenameTitle),
            content: TextField(
              controller: field,
              autofocus: true,
              maxLength: 12,
              decoration: InputDecoration(hintText: t.homeRenameHint),
              onSubmitted: (_) => Navigator.pop(ctx, field.text),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(t.commonCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, field.text),
                child: Text(t.homeRenameConfirm),
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
          Text(
            AppLocalizations.of(context).homeEmptyRoomHint,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}



