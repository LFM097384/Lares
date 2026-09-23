import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
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
    // ── 在房状态(小组件的麦克风按钮) ──
    // 在房时小组件显示麦克风按钮,点一下不开 App 就能静音/开麦。
    // 开麦状态是隐私相关的显示,所以这几个键只写**真实**状态:
    // 由 RoomController 的 phase/muted 推导,而 muted 只在 RTC 层回报之后才变。
    'in_room',
    'muted',
    // 当前所在圈子。原生侧发起切换时把它带回来,Dart 核对一致才执行 ——
    // 小组件显示的是 A 圈,人却已经在 B 圈时,不许替 B 圈开麦。
    'room_circle_id',
    // 心跳时间戳(毫秒,存成字符串:home_widget 在 Android 上 int/long
    // 各走各的存储,跨版本读错类型会直接崩;字符串两端都不含糊)。
    // App 被杀后没有人会来写 in_room=false —— 原生侧看它过期就自己当成「不在房」。
    'state_updated_at',
  ];

  /// 心跳多久写一次。
  static const Duration heartbeatEvery = Duration(seconds: 60);

  /// 多久没心跳就当成「不在房」。原生两侧用同一个数(见契约测试)。
  /// 取两个心跳周期多一点:一次心跳因为调度抖动晚到,不该让按钮闪没。
  static const int staleAfterSeconds = 150;

  /// 小组件 -> App 的切换请求通道(原生调 Dart)。
  ///
  /// 与深链通道分开:深链是「打开 App 并去某处」,这条是「App 不必出现,
  /// 做完把真实结果交回来」,需要一个返回值,EventChannel 给不了。
  static const String widgetActionChannel = 'lares/widget_action';
  static const _widgetAction = MethodChannel(widgetActionChannel);

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

  /// [platformOverride] / [backgroundMicReady] / [now] 仅供测试注入。
  ///
  /// [backgroundMicReady]:App 不在前台时此刻能不能开麦。
  /// Android 14+ 上后台采集麦克风必须有一个**在前台时就已启动**的
  /// microphone 类型前台服务;它没在跑时开麦要么失败、要么被系统静默掐掉,
  /// 所以直接拒绝,不假装成功。默认实现见 [_defaultBackgroundMicReady]。
  WidgetService({
    @visibleForTesting String? platformOverride,
    @visibleForTesting Future<bool> Function()? backgroundMicReady,
    @visibleForTesting DateTime Function()? now,
  })  : _platformOverride = platformOverride,
        _backgroundMicReady = backgroundMicReady ?? _defaultBackgroundMicReady,
        _now = now ?? DateTime.now;

  final String? _platformOverride;
  final Future<bool> Function() _backgroundMicReady;
  final DateTime Function() _now;

  RoomController? _controller;
  CircleStore? _circleStore;
  bool _pushPresence = false;
  AppLifecycleListener? _lifecycle;
  Timer? _heartbeat;

  /// 去重:presence/圈子变化很频繁,只在真正要显示的内容变了才落盘 + 刷 Widget
  String? _lastPushedName;
  String? _lastPushedPresence;
  String? _lastPushedId;
  bool? _lastPushedInRoom;
  bool? _lastPushedMuted;
  String? _lastPushedRoomCircle;

  String get _platform => _platformOverride ?? PlatformInfo.current;

  static Future<bool> _defaultBackgroundMicReady() async {
    switch (PlatformInfo.current) {
      case 'android':
        // 这个服务由 main.dart 在「进房且媒体在线」时启动;没在跑就说明
        // 媒体已闲时挂起,或服务根本没起来 —— 两种情况下从后台开麦都不可靠。
        return FlutterForegroundTask.isRunningService;
      case 'ios':
        // iOS 没有等价的可查询开关:后台能否恢复采集要真机验证
        // (见 LaresWidget/ToggleMuteIntent.swift 顶部的风险说明)。
        // 这里放行,真实结果由 RTC 层回报 —— 开不成就是开不成,不会显示成开着。
        return true;
      default:
        return false;
    }
  }

  /// 小组件该显示的在房状态,只从控制器的**真实**状态推导。
  ///
  /// joining(包括掉线恢复中)不算在房:那时麦克风确实没在发布,
  /// 显示一个能按的麦克风按钮就是在承诺做不到的事。
  ///
  /// 只认**主圈子**:小组件标题显示的是主圈子的名字,人若在别的圈里,
  /// 在它旁边放一个麦克风按钮就是在暗示「这是主圈子的麦」—— 不是。
  /// [primaryCircleId] 为 null(没有圈子仓库,如测试)时不做这层限制。
  @visibleForTesting
  static ({bool inRoom, bool muted, String circleId}) roomSnapshot(
      RoomController c,
      {String? primaryCircleId}) {
    final id = c.circleId;
    final inRoom = c.phase == RoomPhase.inRoom &&
        id != null &&
        (primaryCircleId == null || id == primaryCircleId);
    return (
      inRoom: inRoom,
      // 不在房时一律写 true:原生侧就算读到了也只会画成静音,不会画成开着。
      muted: inRoom ? c.muted : true,
      circleId: inRoom ? id : '',
    );
  }

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
    final platform = _platform;
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

    // 小组件的麦克风按钮:原生侧把切换请求送进来,Dart 做完把真实结果交回去。
    // 注册在同意门之后(本方法整个被 main.dart 推迟到同意之后才调用)——
    // 同意之前连进圈都不许,更谈不上开麦。
    if (hasHomeWidget) {
      _widgetAction.setMethodCallHandler(_onWidgetAction);
    }

    // presence 变化 / 主圈子变化 -> 推送 Widget
    controller.addListener(_onStateChanged);
    circleStore?.addListener(_onStateChanged);
    // 回到前台:系统可能已清掉 Widget 进程缓存,补推一次
    _lifecycle = AppLifecycleListener(
      onResume: () {
        unawaited(_syncPrimaryCircle(force: true));
        unawaited(syncRoomState(force: true));
      },
    );
    await _syncPrimaryCircle();
    // 启动时强制写一次在房状态:上一次进程可能是被杀的,
    // 共享存储里还留着 in_room=true。新进程一定不在房,先把它纠正过来。
    await syncRoomState(force: true);
  }

  void _onStateChanged() {
    unawaited(_syncPrimaryCircle());
    unawaited(syncRoomState());
  }

  /// 原生侧的请求入口。只认一个方法:toggleMute。
  Future<Object?> _onWidgetAction(MethodCall call) async {
    if (call.method != 'toggleMute') {
      throw MissingPluginException('lares/widget_action: ${call.method}');
    }
    final args = call.arguments;
    final circleId = args is Map ? args['circleId'] as String? : null;
    return handleToggleRequest(circleId: circleId);
  }

  /// 处理一次来自小组件的开麦/静音请求,返回**切换之后的真实状态**。
  ///
  /// 返回的 map 就是原生侧要写回小组件的内容:`inRoom` / `muted` / `circleId`。
  /// 任何一步不满足都**不切换**,如实返回当前状态 —— 小组件拿到后按它重画,
  /// 用户看到按钮没变,就知道没成;绝不能出现「按钮说开了,麦其实关着」。
  @visibleForTesting
  Future<Map<String, Object?>> handleToggleRequest({String? circleId}) async {
    final controller = _controller;
    if (controller == null) {
      return const {'inRoom': false, 'muted': true, 'circleId': ''};
    }
    final before = roomSnapshot(controller, primaryCircleId: _primaryId());
    // 不在房(包括正在进、正在掉线恢复):没有麦克风可开。
    // 小组件可能显示得比真实状态旧(心跳还没过期),以这里为准。
    if (!before.inRoom) return await _replyAndSync(controller);
    // 小组件显示的圈子与此刻所在的不是同一个:它是旧的,别替另一个圈开麦。
    if (circleId != null && circleId.isNotEmpty && circleId != before.circleId) {
      return await _replyAndSync(controller);
    }
    // 静音方向永远放行(让人更安静不需要任何前提);
    // 开麦方向要先确认此刻从后台开麦是可靠的。
    final wantsUnmute = before.muted;
    if (wantsUnmute && !await _backgroundMicReady()) {
      return await _replyAndSync(controller);
    }
    await controller.toggleMute();
    return await _replyAndSync(controller);
  }

  Future<Map<String, Object?>> _replyAndSync(RoomController c) async {
    // 强制写一次:原生侧可能正显示着一个已经不对的状态(比如过期前的在房)。
    await syncRoomState(force: true);
    final s = roomSnapshot(c, primaryCircleId: _primaryId());
    return {'inRoom': s.inRoom, 'muted': s.muted, 'circleId': s.circleId};
  }

  /// 把在房状态写进共享存储并刷新小组件。
  ///
  /// 触发点:控制器每次通知(开麦/静音、进房/出房、媒体挂起/唤醒、掉线)
  /// 与在房期间的心跳。变化才写;[force] 用于心跳与回包。
  @visibleForTesting
  Future<void> syncRoomState({bool force = false}) async {
    final controller = _controller;
    if (controller == null || !_pushPresence) return;
    final s = roomSnapshot(controller, primaryCircleId: _primaryId());
    _armHeartbeat(s.inRoom);
    if (!force &&
        s.inRoom == _lastPushedInRoom &&
        s.muted == _lastPushedMuted &&
        s.circleId == _lastPushedRoomCircle) {
      return;
    }
    _lastPushedInRoom = s.inRoom;
    _lastPushedMuted = s.muted;
    _lastPushedRoomCircle = s.circleId;
    // 先写时间戳再写状态:原生侧若恰好在两次写之间读,读到的是
    // 「新时间 + 旧状态」—— 最多旧一瞬;反过来则可能把新状态判成过期。
    final stamp = '${_now().millisecondsSinceEpoch}';
    await HomeWidget.saveWidgetData<String>('state_updated_at', stamp);
    await HomeWidget.saveWidgetData<bool>('in_room', s.inRoom);
    await HomeWidget.saveWidgetData<bool>('muted', s.muted);
    await HomeWidget.saveWidgetData<String>('room_circle_id', s.circleId);
    await HomeWidget.updateWidget(
      qualifiedAndroidName: _androidProvider,
      iOSName: _iosWidgetName,
    );
  }

  /// 在房期间每 [heartbeatEvery] 刷一次时间戳;不在房就停。
  ///
  /// App 被杀时这个计时器跟着死,时间戳停止前进,原生侧在
  /// [staleAfterSeconds] 之后自行回落到「不在房」—— 这正是想要的:
  /// 没有 App 进程,就没有人能执行开麦,按钮不该还在。
  void _armHeartbeat(bool inRoom) {
    if (!inRoom) {
      _heartbeat?.cancel();
      _heartbeat = null;
      return;
    }
    _heartbeat ??= Timer.periodic(heartbeatEvery, (_) {
      unawaited(syncRoomState(force: true));
    });
  }

  /// 主圈子 id;没挂圈子仓库时为 null(= 不限制)。
  /// 圈子仓库在但一个圈子都没有时返回空串 —— 此时谁都不是主圈子。
  String? _primaryId() {
    final store = _circleStore;
    if (store == null) return null;
    return store.primaryCircleId ?? '';
  }

  /// 测试入口:只挂控制器,不碰深链与平台通道。
  @visibleForTesting
  void attachForTest(RoomController controller, {CircleStore? circleStore}) {
    _controller = controller;
    _circleStore = circleStore;
    _pushPresence = true;
  }

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
    _heartbeat?.cancel();
    _heartbeat = null;
    _controller?.removeListener(_onStateChanged);
    _circleStore?.removeListener(_onStateChanged);
    _lifecycle?.dispose();
    _lifecycle = null;
  }
}
