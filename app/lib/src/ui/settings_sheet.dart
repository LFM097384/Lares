import 'package:flutter/material.dart';

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
