import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

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
import 'src/state/models.dart';
import 'src/state/room_controller.dart';
import 'src/state/settings_store.dart';
import 'src/state/voice_notes.dart';
import 'src/theme/theme.dart';
import 'src/ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized(); // 语音便签播放

  // 桌面端窗口配置(Web/移动为空操作)
  await setupDesktopWindow();

  final identity = await Identity.load();
  final circleStore = await CircleStore.load();
  final settings = await SettingsStore.load();

  final signaling = SignalingClient(url: LaresConfig.signalingUrl);
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
  // P0 预热:提前为默认圈子备 RTC token,进房时信令与媒体并行
  controller.prefetchToken(LaresConfig.defaultCircleId);

  // 常驻挂机模式:启动即自动进默认圈(信令连接建立后)
  if (LaresConfig.autoJoin) {
    Timer(const Duration(milliseconds: 1500), () {
      if (controller.phase == RoomPhase.idle) {
        controller.join(LaresConfig.defaultCircleId);
      }
    });
  }

  // 桌面托盘:常驻入口,点图标即一键进房(Web 为空操作)
  final tray = TrayService(
    onEnterRoom: () {
      if (controller.phase == RoomPhase.idle) {
        controller.join(LaresConfig.defaultCircleId);
      } else {
        controller.leave();
      }
    },
    onShowWindow: showAndFocusWindow,
  );
  await tray.init();

  // 主屏幕 Widget + 深链(presence 推送、一键进房、邀请链接;Android/iOS)
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
    httpBase: httpBaseFromWs(LaresConfig.signalingUrl),
    room: controller,
  );

  runApp(LaresApp(
    controller: controller,
    voiceNotes: voiceNotes,
    circleStore: circleStore,
    settings: settings,
  ));
}

class LaresApp extends StatelessWidget {
  const LaresApp({
    super.key,
    required this.controller,
    required this.circleStore,
    required this.settings,
    this.voiceNotes,
  });

  final RoomController controller;
  final CircleStore circleStore;
  final SettingsStore settings;
  final VoiceNotesController? voiceNotes;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lares · 一键进圈',
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
      ),
    );
  }
}
