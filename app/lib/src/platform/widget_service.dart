import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:home_widget/home_widget.dart';

import '../../l10n/gen/app_localizations.dart';
import '../state/circle_store.dart';
import '../state/models.dart';
import '../state/room_controller.dart';
import 'platform_info.dart'
    if (dart.library.io) 'platform_info_io.dart';

/// `requestPin` 的结果。返回 bool 的时候三种失败被压成了一种,
/// UI 只能一律说「当前设备不支持」—— 在 iOS 上那是假话。
enum PinWidgetOutcome {
  /// Android 且 Launcher 支持:系统确认弹窗已弹出,不必再打扰用户
  pinned,

  /// Android,但 Launcher 不支持一键固定 -> 给手动添加步骤
  androidManual,

  /// iOS:系统根本不开放程序化添加(home_widget 的 iOS 实现硬编码返回 false),
  /// 所以**不去尝试**,直接给手动步骤
  iosManual,

  /// 桌面 / Web:没有主屏幕小组件这回事
  unavailable,
}

/// 主屏幕 Widget + 深链服务(Android/iOS):
/// - 主圈子的 presence 推送到主屏 Widget(未开 App 也可见「X 人在」);
/// - `lares://join`(一键进主圈)与 `lares://circle/<id>?name=X`(邀请)深链,
///   Android 走 MainActivity,iOS 走 SceneDelegate,同一 MethodChannel 协议。
///
/// 「一键加入主圈」的目标圈子**在 App 内解析**(读 [CircleStore.primaryCircle]),
/// 深链本身不带圈子 id。好处:Widget 侧共享存储哪怕过期、丢失、或在 iOS 免费
/// 签名下根本读不到,也只会让**显示**退化,绝不会把人送进错误的房间。
class WidgetService {
  // ── 跨语言桥接的规范常量 ──────────────────────────────────────────
  //
  // 下面这几个字面量是 Dart / Swift / Kotlin 三侧唯一的共同约定:
  // 共享存储的键名、App Group、Widget kind、Provider 类名、深链。
  // 三者之间没有任何编译期联系 —— 改了一侧而忘了另一侧,不会报错、
  // 不会抛异常、日志里也什么都看不到,只会表现为「小组件永远不更新」
  // 这种最难查的症状。所以把它们**公开**出来,让
  // `test/widget_bridge_contract_test.dart` 能直接读原生源码比对,
  // 让漂移在 CI 上就炸掉,而不是等用户装到手机上才发现。

  /// 推给 Widget 共享存储的全部键名。顺序稳定,契约测试按这份清单去比对。
  static const List<String> dataKeys = <String>[
    'circle_name',
    'presence_text',
    'primary_circle_id',
    'has_primary',
  ];

  /// iOS App Group:Runner 与 LaresWidget 靠它共享 UserDefaults。
  /// 必须与两个 .entitlements 及 add_widget_target.rb 逐字一致。
  static const String iosAppGroup = 'group.com.lfm097384.lares';

  /// iOS Widget 的 kind。必须与 Swift 侧 `StaticConfiguration(kind:)` 一致,
  /// 否则 `reloadTimelines` 静默失效(找不到这个 kind 就什么也不做)。
  static const String iosWidgetName = 'LaresWidget';

  /// Android AppWidgetProvider 的全限定类名,固定/刷新 Widget 都要用它。
  static const String androidProviderClass =
      'com.example.lares_app.LaresWidgetProvider';

  /// 主屏小组件点按后打开的深链。原生侧(Swift `.widgetURL` /
  /// Kotlin `Uri.parse`)与 Info.plist 的 `lares` scheme 都得对得上。
  /// 注意:到了 Dart 侧 [_handleLink] 拿到的是被平台通道剥掉 scheme 的
  /// 裸字符串 `'join'`,不是这里的完整 URL。
  static const String joinDeepLink = 'lares://join';

  // 私有别名:保留原有调用点的可读性,值以上面的公开常量为准
  static const _androidProvider = androidProviderClass;
  static const _iosWidgetName = iosWidgetName;
  static const _iosAppGroup = iosAppGroup;
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

  /// 请求把 Widget 固定到主屏幕(Android 部分 Launcher 支持,API 26+)。
  /// 三种「没弹窗」的原因天差地别,所以返回 [PinWidgetOutcome] 而不是 bool:
  /// 只有 Android 能程序化固定,iOS 得手动去小组件库加,桌面压根没这回事。
  static Future<PinWidgetOutcome> requestPin() async {
    switch (PlatformInfo.current) {
      case 'android':
        final supported =
            await HomeWidget.isRequestPinWidgetSupported() ?? false;
        if (!supported) return PinWidgetOutcome.androidManual;
        await HomeWidget.requestPinWidget(
          qualifiedAndroidName: _androidProvider,
        );
        return PinWidgetOutcome.pinned;
      case 'ios':
        // 不调 home_widget 的固定接口:它的 iOS 实现是硬编码返回 false 的,
        // 调了只是白等一个注定失败的异步,还可能在 Widget 未装时抛。
        return PinWidgetOutcome.iosManual;
      default:
        return PinWidgetOutcome.unavailable;
    }
  }

  /// 拿不到 `BuildContext` 时(本类是纯逻辑层)按系统语言取一份文案。
  ///
  /// [lookupAppLocalizations] 对不支持的 locale 会抛 FlutterError,所以先拿
  /// languageCode 去 supportedLocales 里比对,比不上就回落英文 —— 与
  /// `main.dart` 的 localeResolutionCallback 是同一套规则:App Store 主语言
  /// 是 English,系统语言不认识时给英文而不是中文,否则一个西班牙语用户
  /// 会在主屏上看到中文,那比看到英文更莫名其妙。
  static AppLocalizations _l10n() {
    final system = WidgetsBinding.instance.platformDispatcher.locale;
    for (final supported in AppLocalizations.supportedLocales) {
      if (supported.languageCode == system.languageCode) {
        return lookupAppLocalizations(supported);
      }
    }
    return lookupAppLocalizations(const Locale('en'));
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
    // 这些字都会出现在主屏幕上,必须跟着系统语言走:写死中文会把原生侧
    // 已经本地化好的默认文案覆盖掉,英文用户主屏上就凭空多出一块中文。
    final t = _l10n();

    final String id;
    final String name;
    final String text;
    if (primary == null) {
      id = '';
      name = t.widgetNoCircle;
      text = t.widgetNoCircleHint;
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
      if (count <= 0) {
        text = t.widgetNobodyHere;
      } else if (names.isEmpty) {
        text = t.widgetPeopleHere(count);
      } else {
        // 分隔符本身也是语言相关的:中文顿号、英文逗号加空格
        text = t.widgetPeopleHereWithNames(
          count,
          names.join(t.commonListSeparator),
        );
      }
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
