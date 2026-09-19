import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'platform_info_io.dart';

/// 桌面端窗口配置(§8.2:尊重平台窗口框架)。移动端调用为空操作。
Future<void> setupDesktopWindow() async {
  if (!PlatformInfo.isDesktop) return;
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(1100, 720),
    minimumSize: Size(860, 560),
    center: true,
    // 这里在 runApp 之前执行,拿不到 AppLocalizations,
    // 所以用语言中性的品牌名。窗口标题栏很快会被 MaterialApp 的
    // onGenerateTitle 接管(那个是本地化的)。
    title: 'Lares Circle',
    titleBarStyle: TitleBarStyle.normal,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

Future<void> showAndFocusWindow() async {
  if (!PlatformInfo.isDesktop) return;
  await windowManager.show();
  await windowManager.focus();
}
