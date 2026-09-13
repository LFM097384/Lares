import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:home_widget/home_widget.dart';

import '../state/circle_store.dart';
import '../state/models.dart';
import '../state/room_controller.dart';
import 'platform_info.dart'
    if (dart.library.io) 'platform_info_io.dart';

/// 主屏幕 Widget + 深链服务(Android/iOS):
/// - 主圈子的 presence 推送到主屏 Widget(未开 App 也可见「X 人在」);
/// - `lares://join`(一键进主圈)与 `lares://circle/<id>?name=X`(邀请)深链,
///   Android 走 MainActivity,iOS 走 SceneDelegate,同一 MethodChannel 协议。
///
/// 「一键加入主圈」的目标圈子**在 App 内解析**(读 [CircleStore.primaryCircle]),
/// 深链本身不带圈子 id。好处:Widget 侧共享存储哪怕过期、丢失、或在 iOS 免费
/// 签名下根本读不到,也只会让**显示**退化,绝不会把人送进错误的房间。
class WidgetService {
  static const _androidProvider = 'com.example.lares_app.LaresWidgetProvider';
  static const _iosWidgetName = 'LaresWidget';
  static const _iosAppGroup = 'group.com.example.lares_app';
  static const _deepLink = MethodChannel('lares/deeplink');
  static const _deepLinkEvents = EventChannel('lares/deeplink/events');

  RoomController? _controller;
  CircleStore? _circleStore;
  bool _pushPresence = false;
  AppLifecycleListener? _lifecycle;

  /// 去重:presence/圈子变化很频繁,只在真正要显示的内容变了才落盘 + 刷 Widget
  String? _lastPushedName;
  String? _lastPushedPresence;
  String? _lastPushedId;

  /// 请求把 Widget 固定到主屏幕(Android 部分 Launcher 支持,API 26+)
  static Future<bool> requestPin() async {
    if (PlatformInfo.current != 'android') return false;
    final supported =
        await HomeWidget.isRequestPinWidgetSupported() ?? false;
    if (!supported) return false;
    await HomeWidget.requestPinWidget(qualifiedAndroidName: _androidProvider);
    return true;
  }

  Future<void> init(RoomController controller,
      {CircleStore? circleStore}) async {
    final platform = PlatformInfo.current;
    // 深链:Android/iOS/macOS;主屏 Widget:仅移动端(macOS 走托盘)
    const deepLinkPlatforms = {'android', 'ios', 'macos'};
    final hasHomeWidget = platform == 'android' || platform == 'ios';
    if (!deepLinkPlatforms.contains(platform)) return;
    _controller = controller;
    _circleStore = circleStore;
    _pushPresence = hasHomeWidget;

    if (platform == 'ios') {
      await HomeWidget.setAppGroupId(_iosAppGroup);
    }

    // 冷启动:Widget/快捷方式/邀请链接拉起
    final cold = await _deepLink.invokeMethod<String>('consumeLink');
    _handleLink(cold);

    // 运行中被深链唤起
    _deepLinkEvents.receiveBroadcastStream().listen((event) {
      if (event is String) _handleLink(event);
    });

    // presence 变化 / 主圈子变化 -> 推送 Widget
    controller.addListener(_onStateChanged);
    circleStore?.addListener(_onStateChanged);
    // 回到前台:系统可能已清掉 Widget 进程缓存,补推一次
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(_syncPrimaryCircle(force: true)),
    );
    await _syncPrimaryCircle();
  }

  void _onStateChanged() => unawaited(_syncPrimaryCircle());

  /// 深链处理。`join` = 一键进主圈(圈子在此解析,见类注释)。
  void _handleLink(String? link) {
    final controller = _controller;
    if (link == null || controller == null) return;
    if (link == 'join') {
      joinPrimaryCircle();
      return;
    }
    // 邀请链接:circle|<id>|<name> -> 登记圈子并进房
    final parts = link.split('|');
    if (parts.length == 3 && parts[0] == 'circle') {
      final circle = Circle(id: parts[1], name: parts[2]);
      _circleStore?.add(circle);
      _switchTo(circle.id);
    }
  }

  /// 一键进主圈:供深链与其它常驻入口复用。
  /// 圈子列表为空时什么都不做(Widget 这时显示的也是空状态)。
  void joinPrimaryCircle() {
    final target = _circleStore?.primaryCircleId;
    if (target == null) return;
    _switchTo(target);
  }

  /// 进目标圈;已在别的房间则先退(§2.2 多圈子互不干扰)
  void _switchTo(String circleId) {
    final controller = _controller;
    if (controller == null) return;
    if (controller.phase == RoomPhase.idle) {
      controller.join(circleId);
    } else if (controller.circleId != circleId) {
      controller.leave().then((_) => controller.join(circleId));
    }
  }

  /// 把**主圈子**的名字与在线状态推到 Widget 共享存储。
  /// 圈子列表为空 -> 推空状态文案,而不是留着上一个圈的陈旧名字。
  Future<void> _syncPrimaryCircle({bool force = false}) async {
    final controller = _controller;
    if (controller == null || !_pushPresence) return;
    final primary = _circleStore?.primaryCircle;

    final String id;
    final String name;
    final String text;
    if (primary == null) {
      id = '';
      name = '还没有圈子';
      text = '打开 App 建一个圈';
    } else {
      id = primary.id;
      name = primary.name;
      final summary = controller.circlePresence[primary.id];
      // 当前就在这个房间时用房间快照兜底(大厅摘要可能还没到)
      final inThisRoom =
          controller.circleId == primary.id && controller.phase != RoomPhase.idle;
      final count =
          summary?.count ?? (inThisRoom ? controller.members.length : 0);
      final names = summary?.names ?? const <String>[];
      text = count > 0
          ? '$count 个人在${names.isNotEmpty ? ' · ${names.join('、')}' : ''}'
          : '暂无人在,进去等等看?';
    }

    if (!force &&
        id == _lastPushedId &&
        name == _lastPushedName &&
        text == _lastPushedPresence) {
      return;
    }
    _lastPushedId = id;
    _lastPushedName = name;
    _lastPushedPresence = text;

    await HomeWidget.saveWidgetData<String>('circle_name', name);
    await HomeWidget.saveWidgetData<String>('presence_text', text);
    // 仅供 Widget 侧显示/诊断;点按仍走 lares://join,不依赖这个值
    await HomeWidget.saveWidgetData<String>('primary_circle_id', id);
    await HomeWidget.saveWidgetData<bool>('has_primary', primary != null);
    await HomeWidget.updateWidget(
      qualifiedAndroidName: _androidProvider,
      iOSName: _iosWidgetName,
    );
  }

  void dispose() {
    _controller?.removeListener(_onStateChanged);
    _circleStore?.removeListener(_onStateChanged);
    _lifecycle?.dispose();
    _lifecycle = null;
  }
}
