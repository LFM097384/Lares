import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../platform/platform_info.dart'
    if (dart.library.io) '../platform/platform_info_io.dart';
import '../../l10n/gen/app_localizations.dart';
import '../config.dart';
import '../moderation/block_store.dart';
import '../moderation/consent_store.dart';
import '../platform/widget_service.dart';
import '../state/circle_store.dart';
import '../state/dev_mode_store.dart';
import '../recording/recording_consent.dart';
import '../recording/recording_indicator.dart';
import '../rtc/rtc_service.dart' show NoiseSuppressionMode;
import '../state/room_controller.dart';
import '../state/settings_store.dart';
import '../theme/tokens.dart';
import '../p2p/ice_store.dart';
import 'blocked_users_section.dart';
import 'content_policy_screen.dart';
import 'developer_section.dart';
import 'identity_section.dart';
import 'nickname.dart';
import 'settings_group.dart';
import 'server_settings_section.dart';
import 'update_panel.dart';
import 'version_footer.dart';

/// 设置(§2.2 耗电与流量透明度、防打扰)
///
/// 结构:按「用得上的」分三组,技术项收进开发者模式(连点版本号 7 次解锁)。
/// 分组只是结构性整理 —— 视觉语言仍沿用现有 token 与 ThemeData,没有另起一套。
Future<void> showSettingsSheet(
  BuildContext context, {
  required SettingsStore settings,
  required RoomController controller,
  required String signalingUrl,
  CircleStore? circleStore,
  RecordingConsentController? recordingConsent,
  BlockStore? blocks,
  ConsentStore? consent,
  DevModeStore? devMode,
  IceStore? ice,
  VoidCallback? onStartMesh,
  VersionReader? versionReader,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    // 这一屏的行数会随功能增长,矮屏(横屏手机)上放不下 ——
    // 交给 SingleChildScrollView 滚,不让它溢出。
    isScrollControlled: true,
    // ⚠️ 必须给一个上界。`isScrollControlled: true` 允许弹层长到整屏高,
    // 而一旦长到整屏,可点的遮罩就只剩顶上那几个像素 ——
    // iOS 没有系统返回键,拖拽下滑又会被里面的 SingleChildScrollView
    // 吃掉(滚动区先拿到手势),于是这一屏**关不掉**。
    // 留出一成高度,遮罩才重新是个能点中的东西。
    // 这只是第二道保险:真正可靠的出口是下面那个常驻的关闭按钮。
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.9,
    ),
    builder: (ctx) => ListenableBuilder(
      listenable: Listenable.merge([
        settings,
        controller,
        ?circleStore,
        ?recordingConsent,
        ?blocks,
        ?consent,
        ?devMode,
        ?ice,
      ]),
      builder: (context, _) {
        final t = AppLocalizations.of(context);
        return SafeArea(
        // 固定头 + 可滚身体。
        //
        // 从前整屏是一个 SingleChildScrollView,没有任何常驻的关闭控件,
        // 于是 iOS 上这一屏事实上关不掉(没有返回键;遮罩被撑到几乎为零;
        // 下滑手势被内层滚动区吃掉)。现在标题栏是 Column 的固定子项,
        // 滚动只发生在它**下面** —— 一个滚到底部的人和刚打开的人,
        // 看到的出口是同一个。
        //
        // ⚠️ `mainAxisSize: MainAxisSize.min` 与 `Expanded` 不能共存
        // (Expanded 要求父级在主轴上有确定尺寸,min 恰恰意味着没有),
        // 会直接抛 "RenderFlex ... unbounded"。所以这里用
        // `Flexible(fit: FlexFit.loose)`:内容少时按内容高度收起来
        // (弹层不会凭空变成整屏),内容多时才顶到上面那个 maxHeight。
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SheetHeader(title: t.settingsTitle),
            Flexible(
              fit: FlexFit.loose,
              child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: LaresSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── 我 ────────────────────────────────────────────────
              // 名字、身份、语言都是「关于我 / 关于这个 App」,既不属于声音,
              // 也不属于某个圈子。它们也是新用户最先想确认的两件事
              // (我叫什么、界面说什么话),所以排在最前面。
              //
              // ⚠️ 这里曾经有**两个**同名分组(settingsGroupMe 与
              // settingsGroupIdentity,两边中文都叫「我」),各带一行改昵称。
              // 两行、两套上限、两条保存路径 —— 已合并成现在这一组:
              // 昵称 → 跨设备身份 → 语言。别再拆回去。
              SettingsGroup(
                title: t.settingsGroupMe,
                children: [
                  ListTile(
                    leading: const Icon(Icons.badge_outlined),
                    title: Text(t.settingsMyName),
                    // 直接把当前昵称摆出来:改名这件事最需要的信息
                    // 就是「我现在叫什么」,不该逼人点进去才看得到。
                    subtitle: Text(controller.userName),
                    onTap: () => _editMyName(context, controller),
                  ),
                  // 跨设备身份:导出 / 导入身份码。身份三要素从 controller
                  // 现取,所以不必再把 main.dart 里的 Identity 穿进来。
                  IdentityCodeTile(controller: controller),
                  ListTile(
                    leading: const Icon(Icons.translate_rounded),
                    title: Text(t.settingsLanguage),
                    trailing: DropdownButton<AppLanguage>(
                      value: settings.appLanguage,
                      underline: const SizedBox.shrink(),
                      items: [
                        DropdownMenuItem(
                          value: AppLanguage.system,
                          child: Text(t.settingsLanguageSystem),
                        ),
                        // ⚠️ 「中文」和「English」是**故意**写死的字面量,
                        // 不是漏进 ARB 的疏忽 —— 别「顺手修好」它。
                        //
                        // 这两个是语言的自称(endonym),必须在**任何**界面
                        // 语言下都长一个样。理由很实际:一个人之所以会点开这一行,
                        // 多半正是因为当前界面他读不懂 —— 这时若把选项也按界面语言
                        // 翻译掉(英文界面下把中文写成 "Chinese"),等于让他
                        // 在一个读不懂的列表里猜哪个是自己的母语。
                        // 自称永远认得出,这也是各家系统设置页的通行做法。
                        const DropdownMenuItem(
                          value: AppLanguage.zh,
                          child: Text('中文'),
                        ),
                        const DropdownMenuItem(
                          value: AppLanguage.en,
                          child: Text('English'),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) settings.setAppLanguage(v);
                      },
                    ),
                  ),
                ],
              ),
              // ── 声音与打扰 ────────────────────────────────────────
              // 日常最常调的:音质、降噪、什么时候别来烦我。
              SettingsGroup(
                title: t.settingsGroupSound,
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.wifi_rounded),
                    title: Text(t.settingsWifiOnlyHq),
                    subtitle: Text(t.settingsWifiOnlyHqSub),
                    value: settings.wifiOnlyHq,
                    onChanged: settings.setWifiOnlyHq,
                  ),
                  // 只管用户亲手点的「进圈」;掉线恢复、自动进圈一律不开麦。
                  // 副标题把这条边界说出来 —— 用户关心的正是「会不会被偷偷听见」。
                  SwitchListTile(
                    secondary: const Icon(Icons.mic_rounded),
                    title: Text(t.settingsJoinWithMicOn),
                    subtitle: Text(t.settingsJoinWithMicOnSub),
                    value: settings.joinWithMicOn,
                    onChanged: settings.setJoinWithMicOn,
                  ),
                  ListTile(
                    leading: const Icon(Icons.noise_control_off_rounded),
                    title: Text(t.settingsNoiseSuppression),
                    // 如实显示本平台真正能做到的,不承诺做不到的事
                    // (例如 Windows 不支持增强降噪,会诚实显示已回落)
                    subtitle: Text(
                      controller.rtcPreview(settings.audioTuning).reason,
                    ),
                    trailing: DropdownButton<NoiseSuppressionMode>(
                      value: settings.noiseMode,
                      underline: const SizedBox.shrink(),
                      items: [
                        DropdownMenuItem(
                          value: NoiseSuppressionMode.off,
                          child: Text(t.settingsNoiseOff),
                        ),
                        DropdownMenuItem(
                          value: NoiseSuppressionMode.standard,
                          child: Text(t.settingsNoiseStandard),
                        ),
                        DropdownMenuItem(
                          value: NoiseSuppressionMode.enhanced,
                          child: Text(t.settingsNoiseEnhanced),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) settings.setNoiseMode(v);
                      },
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.do_not_disturb_on_outlined),
                    title: Text(t.settingsDnd),
                    subtitle: Text(
                      settings.dndEnabled
                          // 纯数字时段,不含词汇,两种语言一致 —— 不进 ARB
                          ? '${settings.dndStartHour}:00 - ${settings.dndEndHour}:00'
                          : t.settingsDndOff,
                    ),
                    trailing: settings.dndEnabled
                        ? TextButton(
                            onPressed: () => settings.setDnd(-1, -1),
                            child: Text(t.settingsDndTurnOff),
                          )
                        : null,
                    onTap: () => _pickDnd(context, settings),
                  ),
                  // ── 录音与转写(需求⑧)──────────────────────────────
                  // **默认不开放**(LaresConfig.recordingEnabled 默认 false):
                  // 功能已完成且有 218 项测试,但 VAD 门限从未见过真实麦克风,
                  // 且录音的伦理面尚未定稿 —— 故入口整体隐藏,而非留一个半成品开关。
                  //
                  // 开启后:默认关闭状态,打开前必过确认对话框 —— 录同伴的声音是
                  // 有伦理与法律分量的事,不做成一个可以手滑打开的开关。
                  // 它跟「声音」是一回事,所以留在这一组,不进开发者模式。
                  if (LaresConfig.recordingEnabled && recordingConsent != null)
                    ListTile(
                      leading: Icon(
                        Icons.fiber_manual_record_rounded,
                        color: recordingConsent.captureAllowed
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                      title: Text(t.settingsRecording),
                      subtitle: Text(
                        recordingConsent.captureAllowed
                            ? t.settingsRecordingOn
                            : t.settingsRecordingOff,
                      ),
                      trailing: FilledButton.tonal(
                        onPressed: controller.circleId == null
                            ? null // 不在房间里无从录起
                            : () async {
                                final messenger = ScaffoldMessenger.of(ctx);
                                if (recordingConsent.captureAllowed) {
                                  recordingConsent.stop(); // 停止永远同步、立即
                                  return;
                                }
                                final ok = await showRecordingConsentDialog(
                                  context,
                                  memberCount: controller.members.length,
                                );
                                if (!ok) return;
                                final started = await recordingConsent
                                    .requestStart(controller.circleId!);
                                // 没等到服务器回显就**不采集** —— 硬失败很烦人,
                                // 静默失败是伦理事故,选烦人。
                                if (!started) {
                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        recordingConsent.message ??
                                            t.settingsRecordingStartFailed,
                                      ),
                                    ),
                                  );
                                }
                              },
                        child: Text(
                          recordingConsent.captureAllowed
                              ? t.settingsRecordingStop
                              : t.settingsRecordingStart,
                        ),
                      ),
                    ),
                ],
              ),
              // ── 这个圈子 ──────────────────────────────────────────
              // 「我平时从哪儿进来」:主圈子 + 主屏幕入口 + 挂机保活。
              // 后台运行保障留在普通设置:它治的是「挂机会掉线」这个
              // 普通用户**真的会遇到**的毛病,而且点一下就是系统对话框,
              // 不需要任何技术理解 —— 藏进开发者模式等于让人求助无门。
              SettingsGroup(
                title: t.settingsGroupCircle,
                children: [
                  // §2.1-1 核心入口:主圈子 + 主屏幕点一下直达
                  if (circleStore != null)
                    ListTile(
                      leading: const Icon(Icons.local_fire_department_rounded),
                      title: Text(t.settingsPrimaryCircle),
                      subtitle: Text(
                        circleStore.primaryCircle == null
                            ? t.settingsPrimaryCircleNone
                            : t.settingsPrimaryCircleSub(
                                circleStore.primaryCircle!.name,
                              ),
                      ),
                      trailing: circleStore.circles.length > 1
                          ? const Icon(Icons.chevron_right_rounded)
                          : null,
                      onTap: circleStore.circles.length > 1
                          ? () => _pickPrimaryCircle(ctx, circleStore)
                          : null,
                    ),
                  ListTile(
                    leading: const Icon(Icons.widgets_outlined),
                    title: Text(t.settingsHomeWidget),
                    subtitle: Text(t.settingsHomeWidgetSub),
                    onTap: () async {
                      final outcome = await WidgetService.requestPin();
                      if (!ctx.mounted) return;
                      switch (outcome) {
                        // 系统确认弹窗已经在用户眼前了,再叠一层是打扰
                        case PinWidgetOutcome.pinned:
                          break;
                        case PinWidgetOutcome.iosManual:
                          await _showHomeWidgetGuide(ctx, [
                            t.settingsHomeWidgetIosStep1,
                            t.settingsHomeWidgetIosStep2,
                            t.settingsHomeWidgetIosStep3,
                            t.settingsHomeWidgetIosStep4,
                            t.settingsHomeWidgetIosStep5,
                          ]);
                        case PinWidgetOutcome.androidManual:
                          await _showHomeWidgetGuide(ctx, [
                            t.settingsHomeWidgetAndroidStep1,
                            t.settingsHomeWidgetAndroidStep2,
                            t.settingsHomeWidgetAndroidStep3,
                            t.settingsHomeWidgetAndroidStep4,
                          ]);
                        // 桌面/Web 没有主屏小组件这回事,没有可照做的步骤,
                        // 一条 SnackBar 说清楚就够,别摆一个空对话框
                        case PinWidgetOutcome.unavailable:
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(
                              content: Text(t.settingsHomeWidgetPhoneOnly),
                            ),
                          );
                      }
                    },
                  ),
                  // 后台运行保障(用户反馈):Android 请求忽略电池优化;iOS 说明机制
                  ListTile(
                    leading: const Icon(Icons.battery_saver_rounded),
                    title: Text(t.settingsBackground),
                    subtitle: Text(t.settingsBackgroundSub),
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(ctx);
                      if (PlatformInfo.current == 'android') {
                        final granted = await FlutterForegroundTask
                            .requestIgnoreBatteryOptimization();
                        messenger.showSnackBar(SnackBar(
                          content: Text(granted
                              ? t.settingsBackgroundGranted
                              : t.settingsBackgroundDenied),
                        ));
                      } else {
                        messenger.showSnackBar(SnackBar(
                          content: Text(t.settingsBackgroundIos),
                        ));
                      }
                    },
                  ),
                ],
              ),
              // ── 待得住 ────────────────────────────────────────────
              // 内容与安全(App Store 审核指南 1.2)。
              // **绝不进开发者模式**:1.2 要求屏蔽与内容规范是随时可达的,
              // 藏在「连点 7 次才出现」的地方等于不可达,是明确的审核风险。
              SettingsGroup(
                title: t.settingsGroupSafety,
                children: [
                  if (blocks != null) BlockedUsersSection(blocks: blocks),
                  ListTile(
                    leading: const Icon(Icons.rule_rounded),
                    title: Text(t.settingsContentPolicy),
                    subtitle: Text(t.settingsContentPolicySub),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    // 同意过之后仍然随时可查 ——
                    // 1.2 审核员会找「同意之后还能不能看到条款」
                    onTap: () => Navigator.of(ctx).push(
                      MaterialPageRoute<void>(
                        builder: (pageCtx) => ContentPolicyScreen(
                          // 已经同意过了,这里只是重读:点「同意」就是关掉这一页
                          onAccept: () async {
                            await consent?.accept();
                            if (pageCtx.mounted) Navigator.of(pageCtx).pop();
                          },
                          showDecline: false,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              // ── 版本与更新 ────────────────────────────────────────
              // 更新面板留在普通设置:五端里有三端(Win/macOS/Android)
              // 靠它自助更新,而「装新版本」是普通用户必须做得到的事。
              // 它自己已经是一张自包含的 Card,不再额外加小标题。
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: LaresSpacing.md),
                child: UpdatePanel(),
              ),
              // ── 服务器与口令 ──────────────────────────────────────
              //
              // ⚠️ 这一块**属于常规设置**,不要再挪回开发者选项。
              //
              // 自托管是本 App 的核心主张 —— 隐私政策、官网、商店描述
              // 里都写着「你可以跑在自己的机器上」。把切换服务器藏在
              // 「连点版本号 7 次」后面,等于让这个承诺对普通用户不成立。
              //
              // 2026-09-22 之前它确实埋在 DeveloperSection 里,理由写的是
              // 「不让默认用户误触」。那个判断是错的:误触的代价是改回来,
              // 找不到的代价是这个功能等于不存在。
              ServerSettingsSection(
                settings: settings,
                userId: controller.userId,
                defaultUrl: signalingUrl,
              ),
              // ── 开发者选项 ────────────────────────────────────────
              // 未解锁时**整块不渲染**:不是灰掉、不是折叠,是根本不存在。
              if (devMode != null && devMode.enabled)
                DeveloperSection(
                  devMode: devMode,
                  settings: settings,
                  controller: controller,
                  signalingUrl: signalingUrl,
                  ice: ice,
                  onStartMesh: onStartMesh,
                ),
              // 底部版本号 —— 连点 7 次解锁开发者模式
              VersionFooter(devMode: devMode, versionReader: versionReader),
            ],
          ),
              ),
            ),
          ],
        ),
        );
      },
    ),
  );
}

/// 设置页顶部的常驻标题栏:左边标题,右边一个关闭按钮。
///
/// 它**不跟着滚**。一个滚到最底下的人,和刚打开的人一样需要这个出口 ——
/// 把出口放进滚动区,等于让「能不能退出去」取决于当前滚到了哪里。
///
/// 用 `maybePop()` 而不是 `pop()`:弹层内部若还压着一个对话框/子路由,
/// maybePop 会先让那一层处理,不会一下把整栈掀掉。
class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        left: LaresSpacing.md,
        right: LaresSpacing.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            tooltip: t.commonClose,
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}

/// 手动添加主屏小组件的分步说明。
///
/// 用对话框而不是 SnackBar:照着做要离开 App 去主屏幕,SnackBar 几秒就没了,
/// 人还没走到第二步就忘了第三步是什么。对话框关掉后再点这一行还能再看一遍。
/// iOS 与 Android 步骤不同但版式一样,共用这一份实现。
Future<void> _showHomeWidgetGuide(
  BuildContext context,
  List<String> steps,
) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final t = AppLocalizations.of(ctx);
      return AlertDialog(
        title: Text(t.settingsHomeWidgetGuideTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, step) in steps.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: LaresSpacing.xs),
                // 序号写死成阿拉伯数字:这是「第几步」的顺序标记,
                // 两种语言的列表都这么编号
                child: Text('${i + 1}. $step'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.commonGotIt),
          ),
        ],
      );
    },
  );
}

/// 选主圈子:圈子多于一个时才有意义(只有一个圈时它天然就是主圈)
Future<void> _pickPrimaryCircle(
  BuildContext context,
  CircleStore circleStore,
) async {
  final chosen = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(AppLocalizations.of(ctx).settingsPickPrimaryCircle),
      children: [
        for (final c in circleStore.circles)
          ListTile(
            leading: Icon(
              circleStore.isPrimary(c.id)
                  ? Icons.local_fire_department_rounded
                  : Icons.local_fire_department_outlined,
              color: circleStore.isPrimary(c.id)
                  ? Theme.of(ctx).colorScheme.primary
                  : null,
            ),
            title: Text(c.name),
            onTap: () => Navigator.pop(ctx, c.id),
          ),
      ],
    ),
  );
  if (chosen != null) await circleStore.setPrimaryCircle(chosen);
}

/// 改昵称对话框。保存走 [saveMyNickname] —— 与主屏那个入口是同一条路。
Future<void> _editMyName(
  BuildContext context,
  RoomController controller,
) async {
  final field = TextEditingController(text: controller.userName);
  final name = await showDialog<String>(
    context: context,
    // StatefulBuilder:确认按钮要随输入实时亮灭,而这个对话框本身
    // 没有 State 可用。与本文件里 _pickDnd 用的是同一套写法。
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final t = AppLocalizations.of(ctx);
        // 空名字不许提交 —— 一个没有名字的人在成员列表里就是一行空白,
        // 别人无从称呼。拦在按钮上(而不是提交后弹错)是因为
        // 「按钮是灰的」本身就说明了原因,不必再写一句话去解释。
        final canSave = field.text.trim().isNotEmpty;
        return AlertDialog(
          title: Text(t.settingsMyNameTitle),
          // ⚠️ 不用 maxLength:它按 UTF-16 code unit 数,
          // 一个 emoji 会被算成 2 个,还可能在代理对中间截断,
          // 渲染成乱码方块。上限由 saveMyNickname() 按**字素簇**执行。
          content: TextField(
            controller: field,
            autofocus: true,
            decoration: InputDecoration(hintText: t.settingsMyNameHint),
            onChanged: (_) => setState(() {}),
            onSubmitted: (v) {
              if (v.trim().isNotEmpty) Navigator.pop(ctx, v);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(t.commonCancel),
            ),
            FilledButton(
              onPressed: canSave ? () => Navigator.pop(ctx, field.text) : null,
              child: Text(t.homeRenameConfirm),
            ),
          ],
        );
      },
    ),
  );
  // 再兜一次空:回车路径和将来可能新增的关闭方式都从这里过。
  if (name != null) await saveMyNickname(controller, name);
}

Future<void> _pickDnd(BuildContext context, SettingsStore settings) async {
  var start = settings.dndEnabled ? settings.dndStartHour : 22;
  var end = settings.dndEnabled ? settings.dndEndHour : 7;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final t = AppLocalizations.of(ctx);
        return AlertDialog(
          title: Text(t.settingsDnd),
          content: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _HourPicker(
                label: t.settingsDndFrom,
                value: start,
                onChanged: (v) => setState(() => start = v),
              ),
              _HourPicker(
                label: t.settingsDndTo,
                value: end,
                onChanged: (v) => setState(() => end = v),
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
              child: Text(t.settingsDndConfirm),
            ),
          ],
        );
      },
    ),
  );
  if (ok == true) await settings.setDnd(start, end);
}

class _HourPicker extends StatelessWidget {
  const _HourPicker({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        DropdownButton<int>(
          value: value,
          items: [
            for (var h = 0; h < 24; h++)
              DropdownMenuItem(value: h, child: Text('$h:00')),
          ],
          onChanged: (v) => onChanged(v ?? value),
        ),
      ],
    );
  }
}

