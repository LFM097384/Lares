import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'platform_info.dart'
    if (dart.library.io) 'platform_info_io.dart';

/// Android 前台服务保活(§8.3-P1 精细化):
/// 仅在「真正进房且媒体在线」期间持有前台服务,出房/闲时降级立即释放。
/// 浸泡测试抓到的真实问题:后台被系统杀 -> presence 掉线。
class ForegroundRoomService {
  bool _started = false;

  void init() {
    if (PlatformInfo.current != 'android') return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'lares_room',
        channelName: '在圈子里',
        channelDescription: '进房期间保持连接',
        channelImportance: NotificationChannelImportance.LOW, // 轻提示,不打扰
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions:
          const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true, // 挂机时 WiFi 休眠会断长连接
      ),
    );
  }

  /// 进房(媒体在线)时调用
  Future<void> start() async {
    if (PlatformInfo.current != 'android' || _started) return;
    _started = true;
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceId: 42,
      notificationTitle: 'Lares · 在圈子里',
      notificationText: '点一下回到房间',
      callback: _noopEntry,
    );
  }

  /// 出房/闲时媒体降级时调用
  Future<void> stop() async {
    if (PlatformInfo.current != 'android' || !_started) return;
    _started = false;
    await FlutterForegroundTask.stopService();
  }
}

@pragma('vm:entry-point')
void _noopEntry() {
  // 仅保活,无周期任务;连接保持在主 isolate
  FlutterForegroundTask.setTaskHandler(_NoopHandler());
}

class _NoopHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
