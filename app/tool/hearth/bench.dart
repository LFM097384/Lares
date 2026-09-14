/// 炉火之灵 —— 性能实测入口。
///
/// 这是一个**不带控制面板、不带 HUD** 的裸场景,专门用来测数字。
/// 为什么不复用 `main.dart`:控制面板里有 `Timer.periodic(1s)` 刷新 HUD,
/// 那本身就会每秒唤醒一次 UI 线程,把「静息态接近零开销」这个结论污染掉。
/// 要测地板,就得把地板上的东西搬空。
///
/// 用法(每次只测一个场景,由 dart-define 选):
/// ```
/// flutter run -d windows --profile -t tool/hearth/bench.dart \
///     --dart-define=SCENE=idle      --dart-define=MEMBERS=12
/// flutter run -d windows --profile -t tool/hearth/bench.dart \
///     --dart-define=SCENE=active    --dart-define=MEMBERS=12
/// flutter run -d windows --profile -t tool/hearth/bench.dart \
///     --dart-define=SCENE=frozen    --dart-define=MEMBERS=12
/// ```
///
/// 场景含义:
///   idle   —— 无人说话,时钟自然降到 calm(3s 后)。测「挂机」的常态。
///   active —— 随机对话 + 周期性发消息,粒子不断被点燃。测最坏情况。
///   frozen —— 打开 freezeWhenDeepIdle 并把 deepIdle 阈值压到 3s,
///             用来测「彻底停表」的零开销地板(对照组)。
///
/// 进程跑起来后用 `measure_cpu.ps1` 采样 CPU;帧时间由本文件自己
/// 通过 `addTimingsCallback` 统计,每 10 秒打印一行到 stdout。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'hearth_state.dart';
import 'hearth_tokens.dart';
import 'layer_a_glow.dart';
import 'layer_b_seats.dart';
import 'layer_d_sparks.dart';

const String kScene = String.fromEnvironment('SCENE', defaultValue: 'idle');
const int kMembers = int.fromEnvironment('MEMBERS', defaultValue: 12);

/// 统计窗口:每多少秒打印一次。
const int kReportEverySec = 10;

void main() {
  runApp(const _BenchApp());
}

class _BenchApp extends StatelessWidget {
  const _BenchApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: HearthColors.bg,
      ),
      home: const _BenchScene(),
    );
  }
}

class _BenchScene extends StatefulWidget {
  const _BenchScene();

  @override
  State<_BenchScene> createState() => _BenchSceneState();
}

class _BenchSceneState extends State<_BenchScene>
    with SingleTickerProviderStateMixin {
  late final HearthClock _clock;
  late final HearthState _state;
  Timer? _msgTimer;
  Timer? _reportTimer;

  // ── 帧统计 ──
  int _frames = 0;
  double _sumMs = 0;
  double _maxMs = 0;
  final List<double> _samples = <double>[];
  late final DateTime _windowStart = DateTime.now();
  DateTime _lastReport = DateTime.now();
  int _lastEmitted = 0;
  int _lastTicked = 0;

  @override
  void initState() {
    super.initState();
    _clock = HearthClock(vsync: this);
    _state = HearthState(clock: _clock);
    _state.setMemberCount(kMembers);

    switch (kScene) {
      case 'active':
        // 最坏情况:一直有人在说,并且每 1.2 秒丢一次火星。
        _state.autoChatter = true;
        _msgTimer = Timer.periodic(
          const Duration(milliseconds: 1200),
          (_) => _state.sendRandomMessage(),
        );
      case 'frozen':
        // 把沉睡阈值压到 3 秒,这样不用等 90 秒就能测到停表后的地板。
        _clock.freezeWhenDeepIdle = true;
      case 'idle':
      default:
        break;
    }

    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _reportTimer = Timer.periodic(
      const Duration(seconds: kReportEverySec),
      (_) => _report(),
    );

    debugPrint('BENCH scene=$kScene members=$kMembers '
        'freeze=${_clock.freezeWhenDeepIdle}');
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      // build + raster,单位毫秒。这是 UI 线程 + 光栅线程的实际工作量。
      final ms = (t.buildDuration.inMicroseconds +
              t.rasterDuration.inMicroseconds) /
          1000.0;
      _frames++;
      _sumMs += ms;
      if (ms > _maxMs) _maxMs = ms;
      _samples.add(ms);
    }
  }

  void _report() {
    final now = DateTime.now();
    final winSec = now.difference(_lastReport).inMilliseconds / 1000.0;
    final totalSec = now.difference(_windowStart).inMilliseconds / 1000.0;

    final emitted = _clock.emittedFrames - _lastEmitted;
    final ticked = _clock.tickedFrames - _lastTicked;
    _lastEmitted = _clock.emittedFrames;
    _lastTicked = _clock.tickedFrames;

    final sorted = List<double>.of(_samples)..sort();
    final p50 = sorted.isEmpty ? 0.0 : sorted[sorted.length ~/ 2];
    final p90 =
        sorted.isEmpty ? 0.0 : sorted[(sorted.length * 0.9).floor().clamp(0, sorted.length - 1)];
    final mean = _frames == 0 ? 0.0 : _sumMs / _frames;

    // 「提交帧率」= 引擎实际光栅化了多少帧 / 秒。降频时它就该低,
    // 这比报一个假的 60fps 诚实。
    final submitFps = _samples.length / winSec;

    debugPrint(
      'BENCH t=${totalSec.toStringAsFixed(0)}s scene=$kScene '
      'level=${_clock.level.name} frozen=${_clock.isFrozen} '
      'submitFps=${submitFps.toStringAsFixed(1)} '
      'tickFps=${(ticked / winSec).toStringAsFixed(1)} '
      'emitFps=${(emitted / winSec).toStringAsFixed(1)} '
      'frameMs(mean/p50/p90/max)=${mean.toStringAsFixed(2)}/'
      '${p50.toStringAsFixed(2)}/${p90.toStringAsFixed(2)}/'
      '${_maxMs.toStringAsFixed(2)} '
      'sparks=${_state.sparksAliveProbe?.call() ?? 0}',
    );

    _samples.clear();
    _lastReport = now;
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _msgTimer?.cancel();
    _reportTimer?.cancel();
    _state.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: HearthColors.bg,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final center = size.center(Offset.zero);
          _state.flameCenter = center;
          return SizedBox(
            width: size.width,
            height: size.height,
            child: Stack(
              children: <Widget>[
                GlowLayer(clock: _clock, state: _state),
                SeatRing(
                  clock: _clock,
                  state: _state,
                  size: size,
                  flameCenter: center,
                ),
                SparkLayer(clock: _clock, state: _state),
              ],
            ),
          );
        },
      ),
    );
  }
}
