import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../platform/platform_info.dart'
    if (dart.library.io) '../platform/platform_info_io.dart';
import '../platform/widget_service.dart';
import '../state/circle_store.dart';
import '../state/models.dart';
import '../recording/recording_consent.dart';
import '../recording/recording_indicator.dart';
import '../rtc/rtc_service.dart' show NoiseSuppressionMode;
import '../state/room_controller.dart';
import '../state/settings_store.dart';
import '../theme/tokens.dart';
import 'server_settings_section.dart';

/// 设置(§2.2 耗电与流量透明度、防打扰)
Future<void> showSettingsSheet(
  BuildContext context, {
  required SettingsStore settings,
  required RoomController controller,
  required String signalingUrl,
  CircleStore? circleStore,
  RecordingConsentController? recordingConsent,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => ListenableBuilder(
      listenable: Listenable.merge([
        settings,
        controller,
        ?circleStore,
        ?recordingConsent,
      ]),
      builder: (context, _) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: LaresSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.wifi_rounded),
                title: const Text('仅 WiFi 下高音质'),
                subtitle: const Text('移动网络自动降码率,省流量'),
                value: settings.wifiOnlyHq,
                onChanged: settings.setWifiOnlyHq,
              ),
              ListTile(
                leading: const Icon(Icons.noise_control_off_rounded),
                title: const Text('降噪'),
                // 如实显示本平台真正能做到的,不承诺做不到的事
                // (例如 Windows 不支持增强降噪,会诚实显示已回落)
                subtitle: Text(
                  controller.rtcPreview(settings.audioTuning).reason,
                ),
                trailing: DropdownButton<NoiseSuppressionMode>(
                  value: settings.noiseMode,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(
                        value: NoiseSuppressionMode.off, child: Text('关闭')),
                    DropdownMenuItem(
                        value: NoiseSuppressionMode.standard, child: Text('标准')),
                    DropdownMenuItem(
                        value: NoiseSuppressionMode.enhanced, child: Text('增强')),
                  ],
                  onChanged: (v) {
                    if (v != null) settings.setNoiseMode(v);
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.do_not_disturb_on_outlined),
                title: const Text('免打扰时段'),
                subtitle: Text(
                  settings.dndEnabled
                      ? '${settings.dndStartHour}:00 - ${settings.dndEndHour}:00'
                      : '未开启(敲门提示不受打扰)',
                ),
                trailing: settings.dndEnabled
                    ? TextButton(
                        onPressed: () => settings.setDnd(-1, -1),
                        child: const Text('关闭'),
                      )
                    : null,
                onTap: () => _pickDnd(context, settings),
              ),
              const Divider(),
              // ── 录音与转写(需求⑧)──────────────────────────────────
              // 默认关闭。打开前必过确认对话框 —— 录同伴的声音是有伦理与法律
              // 分量的事,不做成一个可以手滑打开的开关。
              if (recordingConsent != null)
                ListTile(
                  leading: Icon(
                    Icons.fiber_manual_record_rounded,
                    color: recordingConsent.captureAllowed
                        ? Theme.of(context).colorScheme.error
                        : null,
                  ),
                  title: const Text('录音与转写'),
                  subtitle: Text(
                    recordingConsent.captureAllowed
                        ? '正在录音 —— 房间里所有人都看得到提示'
                        : '默认关闭;开启时所有人都会看到提示',
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
                                    recordingConsent.message ?? '录音未能开始',
                                  ),
                                ),
                              );
                            }
                          },
                    child: Text(
                      recordingConsent.captureAllowed ? '停止录音' : '开始录音',
                    ),
                  ),
                ),
              // 后台运行保障(用户反馈):Android 请求忽略电池优化;iOS 说明机制
              ListTile(
                leading: const Icon(Icons.battery_saver_rounded),
                title: const Text('后台运行保障'),
                subtitle: const Text('挂机不掉线:电池优化白名单 / 后台音频'),
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(ctx);
                  if (PlatformInfo.current == 'android') {
                    final granted = await FlutterForegroundTask
                        .requestIgnoreBatteryOptimization();
                    messenger.showSnackBar(SnackBar(
                      content: Text(granted
                          ? '已允许后台运行(国产 ROM 建议再开「自启动」)'
                          : '请在系统设置里允许忽略电池优化'),
                    ));
                  } else {
                    messenger.showSnackBar(const SnackBar(
                      content: Text('在房间里时 iOS 会自动以后台音频保活,无需设置'),
                    ));
                  }
                },
              ),
              // §2.1-1 核心入口:主圈子 + 主屏幕点一下直达
              if (circleStore != null)
                ListTile(
                  leading: const Icon(Icons.local_fire_department_rounded),
                  title: const Text('主圈子'),
                  subtitle: Text(
                    circleStore.primaryCircle == null
                        ? '还没有圈子'
                        : '${circleStore.primaryCircle!.name}\n'
                            '小组件、快捷设置、托盘一键进的就是它',
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
                title: const Text('把圈子放到主屏幕'),
                subtitle: const Text('主屏幕点一下,直接进主圈子'),
                onTap: () async {
                  final ok = await WidgetService.requestPin();
                  if (ctx.mounted && !ok) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('当前设备不支持,请长按桌面手动添加')),
                    );
                  }
                },
              ),
              // 真机联调:局域网 IP 常变,免重打包改地址
              // 现在升级为「具名服务器档案 + 口令 + 测试连接」(两套部署来回切)
              ServerSettingsSection(
                settings: settings,
                userId: controller.userId,
                defaultUrl: signalingUrl,
              ),
              ListTile(
                leading: const Icon(Icons.speed_rounded),
                title: const Text('状态'),
                subtitle: Text(
                  '信令 $signalingUrl\n'
                  '上次进房 ${controller.lastJoinLatency?.inMilliseconds ?? '-'}ms'
                  '${controller.phase == RoomPhase.inRoom ? ' · 当前在房间里' : ''}',
                ),
              ),
            ],
          ),
        ),
      ),
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
      title: const Text('哪个是主圈子?'),
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
      builder: (ctx, setState) => AlertDialog(
        title: const Text('免打扰时段'),
        content: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _HourPicker(
              label: '从',
              value: start,
              onChanged: (v) => setState(() => start = v),
            ),
            _HourPicker(
              label: '到',
              value: end,
              onChanged: (v) => setState(() => end = v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('算了'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('就这样'),
          ),
        ],
      ),
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
