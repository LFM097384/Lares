import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../platform/platform_info.dart'
    if (dart.library.io) '../platform/platform_info_io.dart';
import '../platform/widget_service.dart';
import '../state/models.dart';
import '../state/room_controller.dart';
import '../state/settings_store.dart';
import '../theme/tokens.dart';

/// 设置(§2.2 耗电与流量透明度、防打扰)
Future<void> showSettingsSheet(
  BuildContext context, {
  required SettingsStore settings,
  required RoomController controller,
  required String signalingUrl,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => ListenableBuilder(
      listenable: Listenable.merge([settings, controller]),
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
              // §2.1-1 核心入口:主屏幕点一下直达
              ListTile(
                leading: const Icon(Icons.widgets_outlined),
                title: const Text('把圈子放到主屏幕'),
                subtitle: const Text('主屏幕点一下,直接进圈'),
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
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('服务器地址'),
                subtitle: Text(
                  settings.signalingOverride ?? '默认(打包内置)\n改完重启 App 生效',
                ),
                onTap: () async {
                  final field = TextEditingController(
                      text: settings.signalingOverride ?? '');
                  final input = await showDialog<String>(
                    context: ctx,
                    builder: (d) => AlertDialog(
                      title: const Text('服务器地址'),
                      content: TextField(
                        controller: field,
                        autofocus: true,
                        decoration: const InputDecoration(
                          hintText: 'ws://192.168.x.x:8787(留空恢复默认)',
                        ),
                        onSubmitted: (_) => Navigator.pop(d, field.text),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(d),
                          child: const Text('算了'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(d, field.text),
                          child: const Text('保存'),
                        ),
                      ],
                    ),
                  );
                  if (input != null) {
                    await settings.setSignalingOverride(input);
                  }
                },
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
