import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import 'src/config.dart';
import 'src/net/signaling_client.dart';
import 'src/platform/foreground_service.dart';
import 'src/platform/widget_service.dart';
import 'src/platform/tray_service_stub.dart'
    if (dart.library.io) 'src/platform/tray_service.dart';
import 'src/platform/window_setup.dart'
    if (dart.library.io) 'src/platform/window_setup_io.dart';
import 'src/rtc/livekit_rtc_service.dart';
import 'src/state/circle_store.dart';
import 'src/state/identity.dart';
import 'src/state/location_share_stub.dart'
    if (dart.library.io) 'src/state/location_share.dart';
import 'src/state/models.dart';
import 'src/state/room_controller.dart';
import 'src/state/settings_store.dart';
import 'src/state/voice_notes.dart';
import 'src/theme/theme.dart';
import 'src/ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面端窗口配置(Web/移动为空操作)
  await setupDesktopWindow();

  final identity = await Identity.load();
  // 主圈子未显式指定时,优先用打包期配置的圈(常驻挂机机器靠它钉住一键入口)
  final circleStore = await CircleStore.load(
    preferredPrimaryId: LaresConfig.defaultCircleId,
  );
  final settings = await SettingsStore.load();

  // 所有「一键进圈」入口(托盘/自动挂机/主屏 Widget)的统一目标:主圈子。
  // 圈子列表为空时回落到打包期默认圈。
  String primaryCircleId() =>
      circleStore.primaryCircleId ?? LaresConfig.defaultCircleId;

  // 信令地址:当前服务器档案优先,其次老的单条覆盖,最后才是打包内置
  // (真机联调局域网 IP 常变,免重打包)
  final signalingUrl =
      settings.effectiveSignalingUrl ?? LaresConfig.signalingUrl;
  // 凭据现取现用:每条 challenge 到达时回调一次,用户改完口令下次重连自然生效
  final signaling = SignalingClient(
    url: signalingUrl,
    userId: identity.userId,
    credentials: () => settings.credentialFor(primaryCircleId()),
  )..authCircleId = primaryCircleId();
  final controller = RoomController(
    signaling: signaling,
    rtc: LiveKitRtcService(hostOnlyIce: LaresConfig.hostOnlyIce),
    userId: identity.userId,
    deviceId: identity.deviceId,
    userName: identity.name,
    settings: settings,
    isOnWifi: () async {
      final results = await Connectivity().checkConnectivity();
      return results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet);
    },
  );

  // P0 预连接:App 启动即建立信令长连接并上报身份
  controller.preconnect();
  signaling.hello(
    userId: identity.userId,
    deviceId: identity.deviceId,
    name: identity.name,
    platform: LaresConfig.platformName,
  );
  // P0 预热:提前为主圈子备 RTC token,进房时信令与媒体并行
  controller.prefetchToken(primaryCircleId());
  // 主圈子被改掉:为新的主圈子重新预热,保住一键进圈的 ≤1.5s 目标
  var lastPrimary = primaryCircleId();
  circleStore.addListener(() {
    final now = primaryCircleId();
    if (now == lastPrimary) return;
    lastPrimary = now;
    // circle 模式下换主圈 = 换密钥,要带新圈口令重新握手(其它模式无影响)
    signaling.authCircleId = now;
    controller.prefetchToken(now);
  });

  // 改了服务器/口令:带新凭据干净重连,不必重启 App 才生效
  var lastCred = settings.credentialFor(primaryCircleId());
  settings.addListener(() {
    final now = settings.credentialFor(primaryCircleId());
    if (now == lastCred) return;
    lastCred = now;
    signaling.reconnectWithNewCredential();
  });

  // 常驻挂机模式:启动即自动进主圈(信令连接建立后)
  if (LaresConfig.autoJoin) {
    Timer(const Duration(milliseconds: 1500), () {
      if (controller.phase == RoomPhase.idle) {
        controller.join(primaryCircleId());
      }
    });
  }

  // 桌面托盘:常驻入口,点图标即一键进主圈(Web 为空操作)
  final tray = TrayService(
    onEnterRoom: () {
      if (controller.phase == RoomPhase.idle) {
        controller.join(primaryCircleId());
      } else {
        controller.leave();
      }
    },
    onShowWindow: showAndFocusWindow,
  );
  await tray.init();

  // 主屏幕 Widget + 深链(主圈 presence 推送、一键进主圈、邀请链接;Android/iOS)
  await WidgetService().init(controller, circleStore: circleStore);

  // 房间状态同步到托盘菜单
  var lastPhase = controller.phase;
  controller.addListener(() {
    final inRoom = controller.phase != RoomPhase.idle;
    final wasInRoom = lastPhase != RoomPhase.idle;
    if (inRoom != wasInRoom) tray.setInRoom(inRoom);
    lastPhase = controller.phase;
  });

  // Android 前台服务:进房且媒体在线时保活,出房/闲时降级释放(§8.3-P1)
  final foreground = ForegroundRoomService()..init();
  controller.addListener(() {
    final mediaOnline =
        controller.phase == RoomPhase.inRoom && !controller.mediaDowngraded;
    if (mediaOnline) {
      foreground.start();
    } else {
      foreground.stop();
    }
  });

  // 语音便签(§2.2):没人时留一条 15s 语音
  final voiceNotes = VoiceNotesController(
    httpBase: httpBaseFromWs(signalingUrl),
    room: controller,
  );

  // 位置共享(Snapchat 式,产品反馈):显式开启,出房即停
  final locationShare = LocationShareService(room: controller);

  runApp(LaresApp(
    controller: controller,
    voiceNotes: voiceNotes,
    circleStore: circleStore,
    settings: settings,
    locationShare: locationShare,
  ));
}

class LaresApp extends StatelessWidget {
  const LaresApp({
    super.key,
    required this.controller,
    required this.circleStore,
    required this.settings,
    this.voiceNotes,
    this.locationShare,
  });

  final RoomController controller;
  final CircleStore circleStore;
  final SettingsStore settings;
  final VoiceNotesController? voiceNotes;
  final LocationShareService? locationShare;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lares 炉灵',
      debugShowCheckedModeBanner: false,
      // 暗色优先(§8.2-2):默认暗色,跟随系统切亮色
      theme: LaresTheme.light(),
      darkTheme: LaresTheme.dark(),
      themeMode: ThemeMode.dark,
      home: HomeScreen(
        controller: controller,
        circleStore: circleStore,
        settings: settings,
        voiceNotes: voiceNotes,
        locationShare: locationShare,
      ),
    );
  }
}
