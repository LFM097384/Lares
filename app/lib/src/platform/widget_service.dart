import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';

import '../config.dart';
import '../state/circle_store.dart';
import '../state/models.dart';
import '../state/room_controller.dart';
import 'platform_info.dart'
    if (dart.library.io) 'platform_info_io.dart';

/// 主屏幕 Widget + 深链服务(Android/iOS):
/// - presence 推送到主屏 Widget(未开 App 也可见「X 人在」);
/// - `lares://join`(一键进房)与 `lares://circle/<id>?name=X`(邀请)深链,
///   Android 走 MainActivity,iOS 走 SceneDelegate,同一 MethodChannel 协议。
class WidgetService {
  static const _androidProvider = 'com.example.lares_app.LaresWidgetProvider';
  static const _iosWidgetName = 'LaresWidget';
  static const _iosAppGroup = 'group.com.example.lares_app';
  static const _deepLink = MethodChannel('lares/deeplink');
  static const _deepLinkEvents = EventChannel('lares/deeplink/events');

  RoomController? _controller;
  bool _pushPresence = false;

  Future<void> init(RoomController controller, {CircleStore? circleStore}) async {
    final platform = PlatformInfo.current;
    // 深链:Android/iOS/macOS;主屏 Widget:仅移动端(macOS 走托盘)
    const deepLinkPlatforms = {'android', 'ios', 'macos'};
    final hasHomeWidget = platform == 'android' || platform == 'ios';
    if (!deepLinkPlatforms.contains(platform)) return;
    _controller = controller;
    _pushPresence = hasHomeWidget;

    if (platform == 'ios') {
      await HomeWidget.setAppGroupId(_iosAppGroup);
    }

    void handleLink(String? link) {
      if (link == null) return;
      if (link == 'join') {
        if (controller.phase == RoomPhase.idle) {
          controller.join(LaresConfig.defaultCircleId);
        }
        return;
      }
      // 邀请链接:circle|<id>|<name> -> 登记圈子并进房
      final parts = link.split('|');
      if (parts.length == 3 && parts[0] == 'circle') {
        final circle = Circle(id: parts[1], name: parts[2]);
        circleStore?.add(circle);
        if (controller.phase != RoomPhase.idle &&
            controller.circleId != circle.id) {
          controller.leave().then((_) => controller.join(circle.id));
        } else if (controller.phase == RoomPhase.idle) {
          controller.join(circle.id);
        }
      }
    }

    // 冷启动:Widget/快捷方式/邀请链接拉起
    final cold = await _deepLink.invokeMethod<String>('consumeLink');
    handleLink(cold);

    // 运行中被深链唤起
    _deepLinkEvents.receiveBroadcastStream().listen((event) {
      if (event is String) handleLink(event);
    });

    // presence 变化 -> 推送 Widget
    controller.addListener(_syncPresence);
    _syncPresence();
  }

  Future<void> _syncPresence() async {
    final controller = _controller;
    if (controller == null || !_pushPresence) return;
    final summary = controller.circlePresence[LaresConfig.defaultCircleId];
    final count = summary?.count ?? controller.members.length;
    final names = summary?.names ?? const <String>[];
    final text = count > 0
        ? '$count 个人在${names.isNotEmpty ? ' · ${names.join('、')}' : ''}'
        : '暂无人在,进去等等看?';
    await HomeWidget.saveWidgetData<String>(
        'circle_name', LaresConfig.defaultCircleName);
    await HomeWidget.saveWidgetData<String>('presence_text', text);
    await HomeWidget.updateWidget(
      qualifiedAndroidName: _androidProvider,
      iOSName: _iosWidgetName,
    );
  }
}
