/// 圈子管理面板:首页长按圈子、房间里圈主的「管理圈子」共用这一份。
///
/// 内容就是原来首页长按菜单的全部:主圈子、邀请、转写记录、圈主工具
/// (用途 / 功能 / 加密 / 转写 / 插件 / 活动提醒 / 换口令 / 解散)、
/// 敲门模式、按圈通知、从本机删除。房间里打开时多一行标题,
/// 并去掉「从本机删除」(人还在这个圈里)。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/gen/app_localizations.dart';
import '../auth/circle_identity.dart';
import '../e2ee/e2ee_controller.dart';
import '../e2ee/e2ee_status.dart';
import '../focus/focus_widgets.dart' show FocusStudyScope;
import '../platform/platform_info.dart'
    if (dart.library.io) '../platform/platform_info_io.dart';
import '../plugins/plugin_owner_section.dart';
import '../plugins/plugin_scope.dart';
import '../purpose/features_screen.dart';
import '../state/circle_store.dart';
import '../state/invite_link.dart';
import '../state/models.dart';
import '../state/room_controller.dart';
import '../state/settings_store.dart';
import '../theme/tokens.dart';
import '../transcript/transcript_owner_section.dart';
import '../transcript/transcript_scope.dart';
import 'push_settings_widgets.dart';
import 'widgets/e2ee_badge.dart';

/// 本机是不是这个圈「已确认」的圈主(有钥匙,且登记已被服务器确认)。
///
/// 钥匙是登记**之前**就在本机生成的,所以「有钥匙」≠「已是圈主」。
bool canManageCircle(
  RoomController controller,
  SettingsStore? settings,
  String circleId,
) =>
    controller.isOwnerOf(circleId) &&
    !(settings?.isPendingRegistration(circleId) ?? false);

/// 打开圈子管理面板。[context] 是宿主页(首页圈子卡片 / 房间页)的 ——
/// 面板关掉后,后续的对话框与页面都从它继续。
///
/// [fromRoom]:从房间里打开。多一行标题,去掉「从本机删除」。
Future<void> showCircleManageSheet(
  BuildContext context, {
  required Circle circle,
  required RoomController controller,
  required CircleStore circleStore,
  required SettingsStore settings,
  E2EEController? e2ee,
  bool fromRoom = false,
}) {
  final m = _CircleManager(
    circle: circle,
    controller: controller,
    circleStore: circleStore,
    settings: settings,
    e2ee: e2ee,
  );
  return showModalBottomSheet<void>(
    context: context,
    // 圈主的条目多:可以长到屏幕的大半,超出就在面板里滚,不顶穿状态栏
    isScrollControlled: true,
    useSafeArea: true,
    // 房间里的面板(「更多」等)都带拖拽条:从房里打开时跟它们一个样;
    // 首页长按保持原样
    showDragHandle: fromRoom,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.85,
    ),
    builder: (ctx) =>
        _CircleManageSheet(manager: m, host: context, fromRoom: fromRoom),
  );
}

/// 邀请对话框(圈子菜单、新建圈子后、换口令后共用)。
Future<void> showCircleInviteDialog(
  BuildContext context, {
  required Circle circle,
  required SettingsStore settings,
  E2EEController? e2ee,
}) => _CircleManager.inviteDialog(
  context,
  circle: circle,
  settings: settings,
  e2ee: e2ee,
);

class _CircleManager {
  _CircleManager({
    required this.circle,
    required this.controller,
    required this.circleStore,
    required this.settings,
    this.e2ee,
  });

  final Circle circle;
  final RoomController controller;
  final CircleStore circleStore;
  final SettingsStore settings;
  final E2EEController? e2ee;

  Future<void> _showInviteDialog(BuildContext context) =>
      inviteDialog(context, circle: circle, settings: settings, e2ee: e2ee);

  /// 圈主身份:钥匙是登记**之前**就在本机生成好的,所以「有钥匙」≠「已是圈主」:
  /// 登记还没被服务器确认时,圈主菜单先不给,只显示「还在登记」。
  bool get _pending => settings.isPendingRegistration(circle.id);
  bool get _owner => controller.isOwnerOf(circle.id) && !_pending;
  bool get _ownerOfRegistered =>
      _owner && controller.isRegisteredCircle(circle.id);

  /// 「这个圈怎么用」组里圈主的条目:用途 + 功能、插件、活动提醒、转写开关。
  List<Widget> _ownerUseTiles(BuildContext context, BuildContext ctx) {
    if (!_ownerOfRegistered) return const [];
    final transcripts = TranscriptScope.maybeOf(context);
    return [
      // 用途 + 功能开关(features-purpose-contract §1–§3)
      FeaturesOwnerTiles(
        controller: controller,
        circleId: circle.id,
        hostContext: context,
        onBeforeOpen: () => Navigator.pop(ctx),
      ),
      // 插件管理(plugin-focus-contract §3)
      if (PluginScope.maybeOf(context) != null)
        PluginOwnerTile(
          service: PluginScope.maybeOf(context)!,
          circleId: circle.id,
          focusSettingsBuilder: PluginScope.maybeScopeOf(
            context,
          )?.focusSettingsBuilder,
          e2ee: controller.circleInfo[circle.id]?.e2ee == true,
          onBeforeOpen: () => Navigator.pop(ctx),
        ),
      // 活动提醒(plugin-focus-contract §9.5):推送只有 iOS 有,别的平台不给入口
      if (PlatformInfo.current == 'ios' &&
          FocusStudyScope.maybeOf(context) != null)
        OwnerPushTriggersTile(
          activity: FocusStudyScope.maybeOf(context)!.activity,
          circleId: circle.id,
          hostContext: context,
          onBeforeOpen: () => Navigator.pop(ctx),
        ),
      // 转写记录开关(transcript-bot-contract §3);完整说明在隐私说明里
      if (transcripts != null)
        TranscriptOwnerSwitch(
          on: controller.isTranscriptOn(circle.id),
          e2ee: transcripts.isE2EE(circle.id),
          onSet: (v) => transcripts.setTranscriptOn(circle.id, v),
        ),
    ];
  }

  /// 「进圈与安全」组里圈主的条目:换口令、全圈加密、机器人。
  List<Widget> _ownerSafetyTiles(BuildContext context, BuildContext ctx) {
    final t = AppLocalizations.of(context);
    if (!_owner) return const [];
    final registered = controller.isRegisteredCircle(circle.id);
    final transcripts = TranscriptScope.maybeOf(context);
    return [
      ListTile(
        leading: const Icon(Icons.key_rounded),
        title: Text(t.homeChangePasscode),
        subtitle: Text(t.homeChangePasscodeDesc),
        onTap: () async {
          Navigator.pop(ctx);
          await _changePasscode(context);
        },
      ),
      if (registered && e2ee != null)
        _OwnerE2EETile(circle: circle, controller: controller, e2ee: e2ee!),
      // 机器人 token(transcript-bot-contract §3)
      if (registered && transcripts != null)
        TranscriptBotTile(
          service: transcripts,
          circleId: circle.id,
          onBeforeOpen: () => Navigator.pop(ctx),
        ),
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
    messenger.showSnackBar(SnackBar(content: Text(t.homeChangePasscodeDone)));
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
  static Future<void> inviteDialog(
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
                  style: Theme.of(
                    ctx,
                  ).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
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

  /// 面板里的全部条目,分四组:常用 / 这个圈怎么用 / 进圈与安全 / 危险操作。
  /// 空组连小标题一起不出现(非圈主通常只剩「常用」和「进圈与安全」)。
  ///
  /// [context] 是宿主页的(面板关掉后继续用它弹对话框、推页面),
  /// [ctx] 是面板自己的(只用来关面板)。
  List<Widget> tiles(
    BuildContext context,
    BuildContext ctx, {
    required bool fromRoom,
  }) {
    final t = AppLocalizations.of(context);
    final knockOn = controller.circlePresence[circle.id]?.knockRequired == true;
    final isPrimary = circleStore.isPrimary(circle.id);
    final registered = controller.isRegisteredCircle(circle.id);
    final canModerate = controller.canModerate(circle.id);
    final transcripts = TranscriptScope.maybeOf(context);

    final common = <Widget>[
      ListTile(
        leading: const Icon(Icons.ios_share_rounded),
        title: Text(t.homeInviteFriends),
        subtitle: Text(t.homeInviteFriendsDesc),
        onTap: () async {
          Navigator.pop(ctx);
          await _showInviteDialog(context);
        },
      ),
      // 查看转写记录:圈主开了才有;所有成员都能看
      if (registered && controller.isTranscriptOn(circle.id) && transcripts != null)
        TranscriptHistoryTile(
          service: transcripts,
          circleId: circle.id,
          circleName: circle.name,
          isOwner: _owner,
          onBeforeOpen: () => Navigator.pop(ctx),
        ),
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
      // 按圈关通知:只在 iOS(推送只有它有)且总开关开着时出现 ——
      // 总开关关了,这里的开也不会有通知,显示出来就是误导。
      if (PlatformInfo.current == 'ios' && settings.pushEnabled)
        CirclePushLevelTile(settings: settings, circleId: circle.id),
      if (_pending)
        ListTile(
          leading: const Icon(Icons.hourglass_top_rounded),
          title: Text(t.homeOwnerPending),
        ),
    ];

    final use = _ownerUseTiles(context, ctx);

    final safety = <Widget>[
      if (canModerate)
        ListTile(
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
      ..._ownerSafetyTiles(context, ctx),
      // 注册圈:加密/敲门/踢人归圈主。非圈主**看不到**这些控件 ——
      // 服务器反正会拒,给一个按了没用的开关只会让人困惑。
      if (registered &&
          !canModerate &&
          controller.circleInfo[circle.id]?.e2ee == true)
        ListTile(
          leading: const Icon(Icons.lock_rounded, color: LaresColors.ember),
          title: Text(t.e2eeManagedOn),
        ),
      // 端到端加密(老圈 / env 圈):按圈可选,默认关,只动本机。
      // 代价必须写在开关旁边(kE2EECostNotice),不能让人开完才困惑。
      if (e2ee != null && !registered) _E2EETile(circle: circle, e2ee: e2ee!),
      if (_owner)
        ListTile(
          leading: const Icon(Icons.phone_android_rounded),
          title: Text(t.homeOwnerKeyNote),
          subtitle: Text(t.homeOwnerKeyNoteDesc),
        ),
    ];

    final danger = <Widget>[
      if (_owner)
        ListTile(
          leading: Icon(
            Icons.delete_forever_rounded,
            color: Theme.of(context).colorScheme.error,
          ),
          title: Text(t.homeDissolveCircle),
          subtitle: Text(t.homeDissolveCircleDesc),
          onTap: () async {
            Navigator.pop(ctx);
            await _dissolve(context);
          },
        ),
      // 「从本机删除」只在首页给:人正坐在这个圈的房间里,
      // 从列表里把它拿掉只会留下一个对不上号的房间。
      if (!fromRoom && circle.id != CircleStore.defaultCircle.id)
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
    ];

    return [
      ..._section('common', t.circleManageSectionCommon, common),
      ..._section('use', t.circleManageSectionUse, use),
      ..._section('safety', t.circleManageSectionSafety, safety),
      ..._section('danger', t.circleManageSectionDanger, danger, danger: true),
    ];
  }

  /// 一组条目前面一个小而淡的组名;空组整个不出现。
  List<Widget> _section(
    String id,
    String label,
    List<Widget> items, {
    bool danger = false,
  }) {
    if (items.isEmpty) return const [];
    return [_SectionHeader(id: id, label: label, danger: danger), ...items];
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

/// 面板本体。跟着 controller / 加密 / 圈子列表实时重建 ——
/// 圈主在房里改了功能、加密、用途,面板上的状态当场就对。
///
/// 圈子没了(被解散 / 从本机删掉),或者从房间打开而人已经不在这个房间里,
/// 面板自己收起:不能留一张管着一个不存在的圈的面板。
class _CircleManageSheet extends StatefulWidget {
  const _CircleManageSheet({
    required this.manager,
    required this.host,
    required this.fromRoom,
  });

  final _CircleManager manager;

  /// 宿主页的 context:面板关掉后,对话框与页面从它继续。
  final BuildContext host;
  final bool fromRoom;

  @override
  State<_CircleManageSheet> createState() => _CircleManageSheetState();
}

class _CircleManageSheetState extends State<_CircleManageSheet> {
  bool _closing = false;

  _CircleManager get _m => widget.manager;

  bool get _gone {
    final id = _m.circle.id;
    if (!_m.circleStore.circles.any((c) => c.id == id)) return true;
    if (widget.fromRoom) {
      final c = _m.controller;
      if (c.phase == RoomPhase.idle || c.circleId != id) return true;
    }
    return false;
  }

  void _closeIfGone() {
    if (_closing || !_gone) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 只收**自己这一层**:条目自己可能已经 pop 过面板(比如「从本机删除」),
      // 那时面板正在退场、已不是栈顶 —— 再盲 pop 一次就把宿主页也弹掉了。
      final route = ModalRoute.of(context);
      if (route == null || !route.isActive) return;
      if (route.isCurrent) {
        Navigator.of(context).pop();
      } else {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable?>[
        _m.controller,
        _m.circleStore,
        _m.e2ee,
      ]),
      builder: (ctx, _) {
        _closeIfGone();
        return SafeArea(
          child: SingleChildScrollView(
            key: const ValueKey('circle-manage-sheet'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 房间里打开:先说清楚管的是哪个圈(首页长按时,手指就按在圈名上)
                if (widget.fromRoom)
                  Padding(
                    // 上方已有拖拽条留的空,这里不再加顶距
                    padding: const EdgeInsets.fromLTRB(
                      LaresSpacing.lg,
                      0,
                      LaresSpacing.lg,
                      LaresSpacing.xs,
                    ),
                    child: Text(
                      t.roomManageCircleTitle(_m.circle.name),
                      key: const ValueKey('circle-manage-title'),
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ..._m.tiles(widget.host, ctx, fromRoom: widget.fromRoom),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 管理面板里的分组小标题:小、淡、贴着下面那组;「危险操作」用警示色。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.id,
    required this.label,
    this.danger = false,
  });

  final String id;
  final String label;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      key: ValueKey('manage-section-$id'),
      padding: const EdgeInsets.fromLTRB(
        LaresSpacing.lg,
        LaresSpacing.md,
        LaresSpacing.lg,
        LaresSpacing.xs,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: danger ? scheme.error : scheme.onSurfaceVariant,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

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
                  final err = await widget.controller.setCircleE2EEAsOwner(
                    id,
                    v,
                  );
                  if (!mounted) return;
                  setState(() => _busy = false);
                  if (err != null) {
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          err == 'not_owner'
                              ? t.homeOwnerErrNotOwner
                              : t.homeOwnerErrGeneric,
                        ),
                      ),
                    );
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
