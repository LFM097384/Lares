/// 炉火之灵 原型 —— 入口(SPEC §7)。
///
/// 运行:
/// ```
/// cd app
/// flutter run -d windows -t tool/hearth/main.dart
/// ```
///
/// 自动截图序列(无需点击,跑完自动退出):
/// ```
/// flutter run -d windows -t tool/hearth/main.dart --dart-define=HEARTH_AUTOSHOT=true
/// ```
/// 输出到 `app/tool/hearth/shots/`,每张的绝对路径会打到 stdout。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'hearth_scene.dart';
import 'hearth_tokens.dart';

/// `--dart-define=HEARTH_AUTOSHOT=true` 时,首帧后自动跑截图序列并退出。
///
/// 用 `const bool.fromEnvironment` 而不是读 `Platform.environment`:
/// 前者在编译期折叠,release 构建里这段代码会被整个摇掉。
const bool kAutoShot = bool.fromEnvironment('HEARTH_AUTOSHOT');

/// 自动截图前的等待时间。留足窗口创建 + 首次布局 + 光晕呼吸起步。
const Duration kAutoShotDelay = Duration(seconds: 2);

void main() {
  runApp(const HearthApp());
}

class HearthApp extends StatefulWidget {
  const HearthApp({super.key});

  @override
  State<HearthApp> createState() => _HearthAppState();
}

class _HearthAppState extends State<HearthApp> {
  /// performance overlay 由 [MaterialApp] 持有,控制面板通过回调翻转它。
  bool _perfOverlay = false;

  final GlobalKey<HearthSceneState> _sceneKey = GlobalKey<HearthSceneState>();

  @override
  void initState() {
    super.initState();
    if (kAutoShot) {
      // 首帧回调里再挂延时:此时 Scene 的 State 已经存在,GlobalKey 可用。
      SchedulerBinding.instance.addPostFrameCallback((_) {
        Timer(kAutoShotDelay, _runAutoShot);
      });
    }
  }

  Future<void> _runAutoShot() async {
    final HearthSceneState? scene = _sceneKey.currentState;
    if (scene == null) {
      debugPrint('[shot] 场景未就绪,放弃自动截图');
      exit(1);
    }
    debugPrint('[shot] 开始自动截图序列…');
    try {
      await scene.runCaptureSequence();
    } catch (e, st) {
      debugPrint('[shot] 序列失败:$e\n$st');
      exit(1);
    }
    // 给文件系统一点时间把最后一张刷盘。
    await Future<void>.delayed(const Duration(milliseconds: 400));
    debugPrint('[shot] 全部完成,退出。');
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '炉火之灵',
      debugShowCheckedModeBanner: false,
      showPerformanceOverlay: _perfOverlay,
      theme: _theme(),
      home: HearthScene(
        key: _sceneKey,
        showPerformanceOverlay: _perfOverlay,
        onPerformanceOverlayToggle: (bool v) =>
            setState(() => _perfOverlay = v),
      ),
    );
  }

  /// 暗色主题,全部从 [HearthColors] 派生 —— 不引 `lib/src/theme/tokens.dart`,
  /// 原型与主 app 解耦(SPEC 开头的硬约束)。
  static ThemeData _theme() {
    const ColorScheme scheme = ColorScheme.dark(
      primary: HearthColors.ember,
      onPrimary: HearthColors.bg,
      secondary: HearthColors.emberDeep,
      onSecondary: HearthColors.bg,
      surface: HearthColors.surface,
      onSurface: HearthColors.textPrimary,
      surfaceContainerHighest: HearthColors.surfaceHigh,
      error: HearthColors.emberDeep,
      onError: HearthColors.textPrimary,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: HearthColors.bg,
      canvasColor: HearthColors.bg,
      splashFactory: InkSparkle.splashFactory,
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: HearthColors.textPrimary),
        bodyMedium: TextStyle(color: HearthColors.textSecondary),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: HearthColors.surfaceHigh,
        contentTextStyle: TextStyle(color: HearthColors.textPrimary),
        behavior: SnackBarBehavior.floating,
      ),
      // 减弱动态效果时,Flutter 自己会把隐式动画的时长压成 0;
      // 原型里 B 层还额外显式处理了一道(见 layer_b_seats 的 reduceMotion),
      // 保证的是「定格在最亮的目标态」,而不是淡出消失。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}
