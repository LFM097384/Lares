import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/gen/app_localizations.dart';
import '../auth/circle_identity.dart';
import '../chat/chat_service.dart';
import '../e2ee/e2ee_controller.dart';
import '../e2ee/e2ee_status.dart';
import '../moderation/block_store.dart';
import '../moderation/consent_store.dart';
import '../platform/platform_info.dart'
    if (dart.library.io) '../platform/platform_info_io.dart';
import '../recording/recording_consent.dart';
import '../p2p/ice_store.dart';
import '../state/circle_store.dart';
import '../state/dev_mode_store.dart';
import '../state/location_share_stub.dart'
    if (dart.library.io) '../state/location_share.dart';
import '../state/invite_link.dart';
import '../state/models.dart';
import '../state/room_controller.dart';
import '../state/settings_store.dart';
import '../state/voice_notes.dart';
import '../theme/tokens.dart';
import 'nickname.dart';
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
            // 圈子被圈主解散(弹出一次即清;本地清理在 main.dart)
            if (controller.dissolvedCircleId != null) {
              controller.dissolvedCircleId = null;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(t.homeCircleDissolved)),
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
                settings: settings,
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

  /// 新建圈子:圈名 + 口令(预填 4 个随机英文词,可改,至少 8 字符)。
  ///
  /// 以前 id 用毫秒时间戳 —— 可猜,而服务器上「谁先登记谁是圈主」,
  /// 可猜的 id 等于把圈主位置让给抢注的人。现在是 128 bit 随机数。
  ///
  /// 建好只在本机挂「待登记」,真正登记发生在下一次握手(hello 带 register),
  /// 服务器回 welcome 时下发圈主钥匙。这里不做隐式建圈之外的任何网络操作。
  Future<void> _showAddCircleDialog(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final field = TextEditingController();
    final passField = TextEditingController(text: generateCirclePasscode());
    final result = await showDialog<({String name, String passcode})>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
        final passOk = isAcceptableCirclePasscode(passField.text);
        void submit() {
          if (field.text.trim().isEmpty || !passOk) return;
          Navigator.pop(ctx, (name: field.text.trim(), passcode: passField.text));
        }

        return AlertDialog(
          title: Text(t.homeAddCircle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: field,
                autofocus: true,
                maxLength: 16,
                decoration: InputDecoration(
                  labelText: t.homeAddCircleNameLabel,
                  hintText: t.homeAddCircleHint,
                ),
                onChanged: (_) => setState(() {}),
              ),
              TextField(
                key: const ValueKey('add-circle-passcode'),
                controller: passField,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => submit(),
                decoration: InputDecoration(
                  labelText: t.homeAddCirclePasscodeLabel,
                  helperText: t.homeAddCirclePasscodeHelper,
                  helperMaxLines: 3,
                  errorText: passOk ? null : t.homeAddCirclePasscodeTooShort,
                  suffixIcon: IconButton(
                    tooltip: t.homeAddCircleShuffle,
                    icon: const Icon(Icons.casino_outlined),
                    onPressed: () => setState(
                        () => passField.text = generateCirclePasscode()),
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
            FilledButton(
              onPressed:
                  field.text.trim().isNotEmpty && passOk ? submit : null,
              child: Text(t.homeAddCircleConfirm),
            ),
          ],
        );
      }),
    );
    if (result == null) return;
    final circle = Circle(id: generateCircleId(), name: result.name);
    // 顺序:口令(vault)→ 圈主钥匙(本机生成,vault 读回确认)→ 待登记标记
    // → 列表。钥匙存不进去就不建:否则登记上去就是一个本机不持钥匙的无主圈。
    await settings.setCirclePasscode(circle.id, result.passcode);
    try {
      await settings.saveOwnerKey(circle.id, generateOwnerKey());
    } catch (e) {
      debugPrint('[lares] 圈主钥匙存不进安全存储,放弃建圈: $e');
      await settings.forgetCircleSecrets(circle.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.homeOwnerErrGeneric)));
      }
      return;
    }
    await settings.markPendingRegistration(circle.id);
    await circleStore.add(circle);
    // 空闲时立刻去登记,好尽快拿到圈主钥匙(在别的房间里就等第一次进圈)
    controller.ensureRegistered(circle.id);
    if (!context.mounted) return;
    // 建完就提示分享:一个人的圈子没有意义。复用邀请对话框。
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t.homeCircleCreatedShare)));
    await showCircleInviteDialog(
      context,
      circle: circle,
      settings: settings,
      e2ee: e2ee,
    );
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

    final invite = parseInviteLink(field.text);
    if (invite == null) return;
    final circle = Circle(
      id: invite.circleId,
      name: invite.name ?? t.homeInvitedCircleFallback,
    );
    await circleStore.add(circle);

    // 链接带了服务器地址就先切过去 —— 必须在存口令与进房**之前**。
    //
    // 朋友的圈子多半在朋友的服务器上。不切的话:口令会被存到当前
    // 服务器的档案下(错的地方),而进房又会连当前服务器(那里没有
    // 这个圈)。两者都错,表现却只是「进不去」,没人能看出为什么。
    if (invite.hasServer) {
      await settings.switchToServer(invite.serverUrl!);
    }

    // 口令要在进房**之前**存好:进房路径上要拿它算鉴权证明,
    // 还要派生 E2EE 密钥(prepareEncryption 在 rtc.join 之前跑)。
    // 晚一步存就等于这次进房仍然没有口令。
    //
    // 链接里带的口令优先级低于用户手填 —— 手填是更明确的意图,
    // 而且链接可能是转发来的旧版本。
    final pass =
        passField.text.isNotEmpty ? passField.text : (invite.passcode ?? '');
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

  // 解析已移到 `lib/src/state/invite_link.dart` —— 它现在还要读
  // server / pass 两个字段,值得单独成文件并测透(见 invite_link_test.dart)。
}

class _CircleTile extends StatelessWidget {
  const _CircleTile({
    super.key,
    required this.circle,
    required this.controller,
    required this.circleStore,
    required this.joining,
    required this.settings,
    this.e2ee,
  });

  final Circle circle;
  final RoomController controller;
  final CircleStore circleStore;
  final bool joining;

  /// 生成邀请链接要用:带上当前服务器地址,以及(用户勾选时)圈口令。
  final SettingsStore settings;
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

  /// 邀请对话框:展示 lares://circle 链接,一键复制。
  ///
  /// 链接**总是带上当前服务器地址** —— 朋友的圈子多半在朋友的服务器上,
  /// 不带的话对方要先自己去设置里换服务器,而他根本不知道要做这一步。
  /// 地址不是秘密(域名本来就公开),带上没有代价。
  ///
  /// 口令**默认不带**,由分享者勾选。理由见 `invite_link.dart` 的文件头:
  /// 口令经 Argon2id 派生出该圈的 E2EE 密钥,写进链接等于把密钥
  /// 一起发出去,而链接会经微信/截图流转。
  Future<void> _showInviteDialog(BuildContext context) => _inviteDialog(
        context,
        circle: circle,
        settings: settings,
        e2ee: e2ee,
      );

  /// 圈主菜单项(只给本机持有圈主钥匙的注册圈)。
  List<Widget> _ownerTiles(BuildContext context, BuildContext ctx) {
    final t = AppLocalizations.of(context);
    final registered = controller.isRegisteredCircle(circle.id);
    // 钥匙是登记**之前**就在本机生成好的,所以「有钥匙」≠「已是圈主」:
    // 登记还没被服务器确认时,圈主菜单先不给,只显示「还在登记」。
    final pending = settings.isPendingRegistration(circle.id);
    final owner = controller.isOwnerOf(circle.id) && !pending;
    return [
      if (pending)
        ListTile(
          leading: const Icon(Icons.hourglass_top_rounded),
          title: Text(t.homeOwnerPending),
        ),
      if (owner) ...[
        if (registered && e2ee != null)
          _OwnerE2EETile(circle: circle, controller: controller, e2ee: e2ee!),
        ListTile(
          leading: const Icon(Icons.key_rounded),
          title: Text(t.homeChangePasscode),
          subtitle: Text(t.homeChangePasscodeDesc),
          onTap: () async {
            Navigator.pop(ctx);
            await _changePasscode(context);
          },
        ),
        ListTile(
          leading: Icon(Icons.delete_forever_rounded,
              color: Theme.of(context).colorScheme.error),
          title: Text(t.homeDissolveCircle),
          subtitle: Text(t.homeDissolveCircleDesc),
          onTap: () async {
            Navigator.pop(ctx);
            await _dissolve(context);
          },
        ),
        ListTile(
          leading: const Icon(Icons.phone_android_rounded),
          title: Text(t.homeOwnerKeyNote),
          subtitle: Text(t.homeOwnerKeyNoteDesc),
        ),
      ],
    ];
  }

  String _ownerErrorText(AppLocalizations t, String reason) => switch (reason) {
        'not_owner' => t.homeOwnerErrNotOwner,
        'timeout' => t.homeOwnerErrTimeout,
        _ => t.homeOwnerErrGeneric,
      };

  /// 换口令 = 真正的「请人离开」(服务器断开除圈主外的所有连接)。
  ///
  /// 顺序是要点:先在后台算好新 verifier → 发给服务器 → **等 owner_ok**
  /// 才改本地口令。本地先改而服务器没换成,本机会拿新口令去证明,
  /// 把圈主自己锁在门外。
  Future<void> _changePasscode(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final next = generateCirclePasscode();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(t.homeChangePasscodeConfirmTitle),
        content: SelectableText(t.homeChangePasscodeConfirmBody(next)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(t.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(t.homeChangePasscodeConfirmYes),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final verifier = await settings.verifiers.get(circle.id, next);
    final err = await controller.setCirclePasscodeAsOwner(circle.id, verifier);
    if (err != null) {
      messenger.showSnackBar(SnackBar(content: Text(_ownerErrorText(t, err))));
      return;
    }
    await settings.setCirclePasscode(circle.id, next);
    messenger
        .showSnackBar(SnackBar(content: Text(t.homeChangePasscodeDone)));
    if (context.mounted) await _showInviteDialog(context);
  }

  /// 解散:强确认 —— 要亲手输入圈名,按钮才亮。
  Future<void> _dissolve(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final typed = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setState) => AlertDialog(
          title: Text(t.homeDissolveConfirmTitle(circle.name)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t.homeDissolveConfirmBody),
              TextField(
                key: const ValueKey('dissolve-confirm-name'),
                controller: typed,
                decoration: InputDecoration(hintText: circle.name),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text(t.commonCancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dctx).colorScheme.error,
              ),
              onPressed: typed.text.trim() == circle.name.trim()
                  ? () => Navigator.pop(dctx, true)
                  : null,
              child: Text(t.homeDissolveConfirmYes),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final err = await controller.deleteCircleAsOwner(circle.id);
    if (err != null) {
      messenger.showSnackBar(SnackBar(content: Text(_ownerErrorText(t, err))));
      return;
    }
    // 服务器会紧接着推 circle_deleted,main.dart 统一清理本地;这里只把列表先收掉
    await circleStore.remove(circle.id);
    e2ee?.forget(circle.id);
    await settings.forgetCircleSecrets(circle.id);
  }

  /// 邀请对话框本体(静态:新建圈子时还没有 tile 实例,见 [showCircleInviteDialog])。
  static Future<void> _inviteDialog(
    BuildContext context, {
    required Circle circle,
    required SettingsStore settings,
    E2EEController? e2ee,
  }) async {
    final t = AppLocalizations.of(context);
    final serverUrl = settings.effectiveSignalingUrl;
    final passcode = settings.passcodeFor(circle.id);
    final e2eeOn = e2ee?.isEnabled(circle.id) ?? false;
    var includePass = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final link = buildInviteLink(
            circleId: circle.id,
            name: circle.name,
            serverUrl: serverUrl,
            passcode: includePass ? passcode : null,
          );
          return AlertDialog(
            title: Text(t.homeInviteTitle(circle.name)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.homeInviteBody),
                const SizedBox(height: LaresSpacing.md),
                SelectableText(
                  link,
                  style: Theme.of(ctx)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontFamily: 'monospace'),
                ),
                // 没存过口令就不给这个选项 —— 勾了也带不出东西,
                // 只会让人以为自己带上了。
                if (passcode.isNotEmpty) ...[
                  const SizedBox(height: LaresSpacing.sm),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: includePass,
                    onChanged: (v) => setState(() => includePass = v ?? false),
                    title: Text(t.homeInviteIncludePasscode),
                    // 开了 E2EE 时把代价说清楚:那把口令就是解密密钥。
                    subtitle: Text(
                      e2eeOn
                          ? t.homeInviteIncludePasscodeE2ee
                          : t.homeInviteIncludePasscodeHint,
                    ),
                  ),
                ],
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
          );
        },
      ),
    );
  }

  /// 长按圈子:设为主圈 / 邀请 / 敲门模式开关 / 删除(默认圈仅不可删)
  void _showCircleMenu(BuildContext context) {
    final t = AppLocalizations.of(context);
    final knockOn = controller.circlePresence[circle.id]?.knockRequired == true;
    final isPrimary = circleStore.isPrimary(circle.id);
    final registered = controller.isRegisteredCircle(circle.id);
    final canModerate = controller.canModerate(circle.id);
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
            // 注册圈:加密/敲门/踢人归圈主。非圈主**看不到**这些控件 ——
            // 服务器反正会拒,给一个按了没用的开关只会让人困惑。
            // 圈主的全圈加密开关在 _ownerTiles 里。
            if (registered && !canModerate &&
                controller.circleInfo[circle.id]?.e2ee == true)
              ListTile(
                leading: const Icon(Icons.lock_rounded, color: LaresColors.ember),
                title: Text(t.e2eeManagedOn),
              ),
            ..._ownerTiles(context, ctx),
            // 端到端加密(老圈 / env 圈):按圈可选,默认关,只动本机。
            // 代价必须写在开关旁边(kE2EECostNotice),不能让人开完才困惑。
            if (e2ee != null && !registered)
              _E2EETile(circle: circle, e2ee: e2ee!),
            if (canModerate) ListTile(
              leading: Icon(
                knockOn
                    ? Icons.door_front_door_rounded
                    : Icons.door_front_door_outlined,
              ),
              title: Text(knockOn ? t.homeKnockModeOn : t.homeKnockModeOff),
              // 第二句是要紧的那句:这不是个人偏好,是全圈共享的一个值。
              subtitle: Text(
                '${t.homeKnockModeDesc}\n${t.homeKnockModeEveryoneNotice}',
              ),
              isThreeLine: true,
              onTap: () async {
                // 确认在**两个方向上都要**,与 E2EE 不同 ——
                // 那个开关只影响自己,这个开关两个方向都改的是所有人的设置。
                // 注册圈的圈主例外:这本来就是圈主的职责,不必再问「你确定替大家改?」
                if (!registered && !await _confirmKnockMode(context)) return;
                controller.setKnockMode(circle.id, !knockOn);
                if (ctx.mounted) Navigator.pop(ctx);
              },
            ),
            // 按圈关通知:只在 iOS(推送只有它有)且总开关开着时出现 ——
            // 总开关关了,这里的开也不会有通知,显示出来就是误导。
            if (PlatformInfo.current == 'ios' && settings.pushEnabled)
              _pushMuteTile(ctx, t),
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

  Widget _pushMuteTile(BuildContext ctx, AppLocalizations t) {
    final muted = settings.isCirclePushMuted(circle.id);
    return ListTile(
      leading: Icon(
        muted ? Icons.notifications_off_outlined : Icons.notifications_rounded,
      ),
      title: Text(muted ? t.homeCirclePushOff : t.homeCirclePushOn),
      onTap: () {
        // 只改本机设置;PushService 监听到变化会把新名单发给服务器
        unawaited(settings.setCirclePushMuted(circle.id, !muted));
        Navigator.pop(ctx);
      },
    );
  }

  /// 改敲门模式前的确认。
  ///
  /// ## 服务端到底校验了什么(2026-09 实测,别再凭印象猜)
  ///
  /// `server/src/index.js` 的 `case 'knock_mode_set'` 有三道检查:
  /// 1. `session.userId` 必须存在 —— 没握过手的连接直接 `say_hello_first`;
  /// 2. `circleAllowed(session, msg.circleId)` —— 不在授权范围内回 `auth_scope`;
  /// 3. 圈子非空时,设置者必须是**在场成员**,且该 deviceId 确实在他的
  ///    `devices` 里,否则静默丢弃。
  ///
  /// 所以**不存在未授权写入** —— 这一点上早先的怀疑是错的。
  ///
  /// ## 但也确实没有权限控制
  ///
  /// 在服务端全量 grep `owner|role|admin|isOwner`:**零命中**。
  /// 根本没有 owner / 角色这个概念。因此结论是:
  /// **圈里任何一个已握手的在场成员都能替所有人改掉这个设置**,
  /// 而且谁都能再改回去。
  ///
  /// 「只让圈主改」今天做不到,而且不该在客户端假造一个 ——
  /// 客户端拦一下只是装饰,绕过它的人照样能发出那一帧。
  /// 这件事要等身份与角色那一摊做完。
  /// 在此之前,唯一诚实的做法就是把「你改的是所有人的」说出来,
  /// 并在动手之前问一句。
  Future<bool> _confirmKnockMode(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(t.homeKnockModeConfirmTitle),
        content: Text(t.homeKnockModeConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(t.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(t.homeKnockModeConfirmYes),
          ),
        ],
      ),
    );
    return ok == true;
  }
}

/// 邀请对话框(圈子长按菜单、新建圈子后、换口令后共用)。
Future<void> showCircleInviteDialog(
  BuildContext context, {
  required Circle circle,
  required SettingsStore settings,
  E2EEController? e2ee,
}) =>
    _CircleTile._inviteDialog(context,
        circle: circle, settings: settings, e2ee: e2ee);

/// 圈主的全圈加密开关(注册圈)。
///
/// 与 [_E2EETile] 的根本区别:那个只动本机登记表,一个人开了别人听不见;
/// 这个由服务器记在圈上、推给每个成员,在任何人建 Room 之前生效 ——
/// 所以不需要「全圈都要开」那道确认,只说清楚「给全圈一起开关」。
class _OwnerE2EETile extends StatefulWidget {
  const _OwnerE2EETile({
    required this.circle,
    required this.controller,
    required this.e2ee,
  });

  final Circle circle;
  final RoomController controller;
  final E2EEController e2ee;

  @override
  State<_OwnerE2EETile> createState() => _OwnerE2EETileState();
}

class _OwnerE2EETileState extends State<_OwnerE2EETile> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final id = widget.circle.id;
    final on = widget.controller.circleInfo[id]?.e2ee ?? false;
    final status = widget.e2ee.previewStatusFor(id);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          key: const ValueKey('owner-e2ee-switch'),
          secondary: Icon(
            on ? Icons.lock_rounded : Icons.lock_open_rounded,
            color: on && status.isEncrypted ? LaresColors.ember : null,
          ),
          title: Text(t.e2eeTitle),
          subtitle: Text('${t.e2eeOwnerSwitchDesc}\n${t.e2eeCostNotice}'),
          isThreeLine: true,
          value: on,
          onChanged: _busy
              ? null
              : (v) async {
                  final messenger = ScaffoldMessenger.of(context);
                  setState(() => _busy = true);
                  final err =
                      await widget.controller.setCircleE2EEAsOwner(id, v);
                  if (!mounted) return;
                  setState(() => _busy = false);
                  if (err != null) {
                    messenger.showSnackBar(SnackBar(
                      content: Text(err == 'not_owner'
                          ? t.homeOwnerErrNotOwner
                          : t.homeOwnerErrGeneric),
                    ));
                  }
                },
        ),
        if (status.isBrokenPromise) E2EEWarningBanner(status: status),
      ],
    );
  }
}

/// 圈子菜单里的端到端加密开关。
///
/// 四条纪律,缺一条这个功能就是安全负资产:
/// 1. **代价前置** —— 开关的副标题里直接写明「服务器无法转录、炉灵不可用」,
///    而不是藏进某个说明页;
/// 2. **诚实** —— 开了之后如果本平台/口令不支持,立刻在下面挂出红色说明,
///    绝不让开关的「已打开」状态独自代表「已加密」;
/// 3. **不可静默** —— 平台不支持时**开关照常可开**(用户换台设备就生效),
///    但当下这台设备的真实状态一个字都不隐瞒。
/// 4. **全圈一致是前提** —— 见下面 [_E2EETileState._confirmTurnOn]。
///
/// ## 为什么这个开关留在圈子菜单里,而不是收进开发者选项
///
/// 端到端加密是本 App 的卖点之一。把卖点藏进「连点版本号 7 次」后面,
/// 等于让它对普通用户不存在。所以它留在原处 —— 代价是必须把
/// 「一个人开了没用」这件事说到无法忽视的程度,这正是下面那句
/// e2eeEveryoneNotice 和开启前那道确认在做的事。
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
            //
            // e2eeEveryoneNotice 排在**最前面**,因为它是三句里唯一
            // 会让人「听不到别人说话」的那一句 —— 后果最硬,位置最先。
            '${t.e2eeEveryoneNotice}\n'
            '${t.e2eeCostNotice}\n'
            '${t.e2eeKeyLocalNotice}',
            style: theme.textTheme.bodyMedium,
          ),
          isThreeLine: true,
          value: on,
          onChanged: (v) async {
            // 只在**开**的方向上确认。
            //
            // 关是永远安全的:它把互通性还回来,最坏的结果是「本来加密的
            // 现在不加密了」,而副标题已经说明了加密意味着什么。
            // 开则相反 —— 只有你开,你和圈里其他人就互相听不见,
            // 而这个后果从开关的外观上完全看不出来,所以必须拦一道。
            if (v && !await _confirmTurnOn()) return;
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

  /// 开启加密前的确认。
  ///
  /// ## 为什么非要拦这一下
  ///
  /// `E2EEStore` 是纯本地的 —— 一个 `shared_preferences` 里的圈子 id 集合
  /// (`lares.e2eeCircles`),`setEnabled` 只动这个本地集合。
  /// 密钥由圈口令经 Argon2id 派生,**从不离开设备**,
  /// 也**从不告诉服务器或其他成员**。
  ///
  /// 所以单方面打开的后果是:你的声音被加密发出去,而没开的人手里
  /// 没有同一把锁 —— 他们听不见你,你也听不见他们。
  /// 这不是「安全性提高了一点」,这是**通话直接断了**,
  /// 而开关看上去只是变成了「开」。
  ///
  /// 对话框只解释后果、不代替用户做判断:圈子小到什么程度、
  /// 能不能一个个说到,只有用户知道。
  Future<bool> _confirmTurnOn() async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.e2eeConfirmTitle),
        content: Text(t.e2eeConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.e2eeConfirmYes),
          ),
        ],
      ),
    );
    // 点遮罩关掉 = 没答应。null 一律当否 —— 这个方向上「不确定」就是「不开」。
    return ok == true;
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
            // 不用 maxLength:它按 UTF-16 code unit 数,会把一个 emoji
            // 算成 2 个、还可能在代理对中间截断,留下乱码方块。
            // 上限改由 saveMyNickname() 按字素簇执行 ——
            // 那也是设置页那个入口走的同一条路,两边不会再各有一套上限。
            content: TextField(
              controller: field,
              autofocus: true,
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
        // 截断、广播、落盘全在 saveMyNickname 里;空名字它自己会拒。
        if (name != null) await saveMyNickname(controller, name);
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



