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
import 'settings_group.dart';
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: LaresSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── 声音与打扰 ────────────────────────────────────────
              // 日常最常调的:音质、降噪、什么时候别来烦我。放最上面。
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
                      final ok = await WidgetService.requestPin();
                      if (ctx.mounted && !ok) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(
                            content: Text(t.settingsHomeWidgetUnsupported),
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
        );
      },
    ),
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

