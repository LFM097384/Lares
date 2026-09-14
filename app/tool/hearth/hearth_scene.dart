/// 炉火之灵 —— 场景组装(SPEC §1 的三层 Stack)。
///
/// ## 层序(刻意如此)
///
/// ```
/// 背景色 HearthColors.bg
///   └ A 层 GlowLayer   —— 呼吸的烬,在所有人**下面**
///   └ B 层 SeatRing    —— 围炉而坐的人
///   └ D 层 SparkLayer  —— 火星,在所有人**上面**
///   └ 控制面板 + 性能 HUD(**不在截图边界内**)
/// ```
///
/// 火星压在头像之上,是为了让它读作「从火里升起、从人前面飘过去」。
/// 如果把火星塞到头像下面,它会变成一层背景纹理,失去纵深。
/// 光晕反过来:它是环境光,压在人上面会把脸糊掉。
///
/// ## 坐标系(唯一一处容易出错的地方)
///
/// A / B / D 三层拿到的是**同一个** `Size`、**同一个** `flameCenter`,
/// 都是画布左上角为原点的绝对逻辑坐标。`HearthState.flameCenter` 也写同一个值 ——
/// `HearthState.memberLeaves` / `sendMessage` 用它 + `seatDirection * 180`
/// 算火星起点,一旦坐标系不一致,火星就会从屏幕外飞进来。
///
/// 所以这里的规矩是:**所有层都铺满同一个 `SizedBox`,谁也不加 padding**。
/// 座位需要的内缩在 [SeatLayout.compute] 内部做,不体现为 Widget 层级的偏移。
///
/// ## 时钟的归属
///
/// [HearthClock] 需要一个 `TickerProvider`,由本 State 提供并负责 dispose。
/// 整个原型**只有这一个**常驻 Ticker(B 层的隐式动画会临时起 Ticker,
/// 过渡结束即停)。这是 SPEC 性能模型的地基。
///
/// ## 自截图(为什么原型要自己截自己)
///
/// 外部截图工具(PrintWindow / BitBlt)对 Flutter 的 GPU 合成表面不可靠,
/// 经常抓到黑帧。所以场景把 A+B+D 包进一个带 [GlobalKey] 的 `RepaintBoundary`,
/// 用 `boundary.toImage()` 自己出图 —— 拿到的是 Flutter 自己的合成结果,
/// 不经过窗口系统,不可能黑帧。控制面板和 HUD **在边界之外**,
/// 因此截图里天然没有它们。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data' show ByteData;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'demo_controls.dart';
import 'hearth_state.dart';
import 'hearth_tokens.dart';
import 'layer_a_glow.dart';
import 'layer_b_seats.dart';
import 'layer_d_sparks.dart';

/// 截图输出目录(相对 `flutter run` 的工作目录,即 `app/`)。
const String kShotDir = 'tool/hearth/shots';

/// 炉边场景。
class HearthScene extends StatefulWidget {
  const HearthScene({
    super.key,
    this.onPerformanceOverlayToggle,
    this.showPerformanceOverlay = false,
  });

  /// 由 [MaterialApp] 持有 performance overlay 的开关,所以往上回调。
  final ValueChanged<bool>? onPerformanceOverlayToggle;
  final bool showPerformanceOverlay;

  @override
  State<HearthScene> createState() => HearthSceneState();
}

class HearthSceneState extends State<HearthScene>
    with SingleTickerProviderStateMixin {
  late final HearthClock _clock;
  late final HearthState _state;

  /// A+B+D 的截图边界。控制面板**不在**它里面。
  final GlobalKey _sceneKey = GlobalKey(debugLabel: 'hearth-scene-boundary');

  /// 截图期间把控制面板整体藏起来。
  ///
  /// 严格说没必要(控制面板本来就在边界外),但截图序列会连续跑十几秒,
  /// 期间面板上的数字在跳,藏掉更干净;也顺手挡住 SnackBar。
  bool _capturing = false;

  /// 「紧凑」模式:把可用环数压到 1,让溢出芯片在桌面尺寸下也能出现。
  /// 见 `layer_b_seats.dart` 文件头「澄清 3」。
  bool _compact = false;

  /// B 层每次布局的结果,给 HUD 显示环容量。
  /// **不用 ValueNotifier**:那会在 build 期间同步通知监听者,
  /// 等于 build 里 setState。这里只是个普通字段,HUD 按自己的 1s 节奏来读。
  final SeatLayoutProbe _layoutProbe = SeatLayoutProbe();

  @override
  void initState() {
    super.initState();
    _clock = HearthClock(vsync: this);
    _state = HearthState(clock: _clock);
  }

  @override
  void dispose() {
    // 顺序要紧:state 在构造里把 _advance 挂到了 clock.onAdvance 上,
    // 先摘钩子再拆表,避免拆表过程中回调到已 dispose 的 state。
    _clock.onAdvance = null;
    _state.sparksAliveProbe = null;
    _state.dispose();
    _clock.dispose();
    super.dispose();
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 截图
  // ───────────────────────────────────────────────────────────────────────────

  /// 把 A+B+D 这一块渲染成 PNG 存盘。
  ///
  /// [pixelRatio] 2.0:1280x720 的画布出 2560x1440,产品负责人放大看边缘
  /// 柔和度时不会先撞上分辨率不够。
  Future<String?> capture(String name, {double pixelRatio = 2.0}) async {
    final BuildContext? ctx = _sceneKey.currentContext;
    if (ctx == null) {
      debugPrint('[shot] 边界还没挂上,跳过 $name');
      return null;
    }
    final RenderObject? ro = ctx.findRenderObject();
    if (ro is! RenderRepaintBoundary) {
      debugPrint('[shot] 边界类型不对,跳过 $name');
      return null;
    }

    // debug 模式下 toImage 对「这一帧还没画」很敏感,先等一帧落地。
    await WidgetsBinding.instance.endOfFrame;
    // 极少数情况下(刚 setState 完)一帧不够,再给一帧。
    if (ro.debugNeedsPaint) {
      await WidgetsBinding.instance.endOfFrame;
    }

    final ui.Image image = await ro.toImage(pixelRatio: pixelRatio);
    try {
      final ByteData? bytes =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) {
        debugPrint('[shot] 编码失败:$name');
        return null;
      }
      final File file = File('$kShotDir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes.buffer.asUint8List());
      final String abs = file.absolute.path;
      debugPrint('[shot] $name -> $abs  (${image.width}x${image.height})');
      return abs;
    } finally {
      // ui.Image 是 native 资源,不 dispose 会在连拍时堆起来。
      image.dispose();
    }
  }

  /// 手动截一张,文件名带时间戳。
  Future<void> captureTimestamped() async {
    final DateTime n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final String stamp =
        '${n.year}${two(n.month)}${two(n.day)}-${two(n.hour)}${two(n.minute)}${two(n.second)}';
    setState(() => _capturing = true);
    try {
      await capture('shot-$stamp');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  /// 自动截图序列。
  ///
  /// 每一步都插了**真实**的 `Future.delayed` —— 因为这些画面要的就是
  /// 「动画正跑到某个位置」的那一瞬:光团要有时间偏过去,火星要正在半空。
  /// 直接连拍会得到七张一模一样的静息图。
  Future<void> runCaptureSequence() async {
    if (_capturing) return;
    setState(() => _capturing = true);
    final bool restoreCompact = _compact;
    try {
      _state.autoChatter = false;
      _state.silenceAll();

      // 01 静息 5 人
      _state.setMemberCount(5);
      await _settle(1600);
      await capture('01-idle-5p');

      // 02 有人说话:等 ~1.2s,让 A 层的弹簧(时间常数 450ms)偏到位并拉伸
      final List<HearthMember> five = _state.members;
      if (five.isNotEmpty) {
        _state.setSpeaking(five[1 % five.length].id, true);
      }
      await _settle(1200);
      await capture('02-speaking-5p');
      _state.silenceAll();
      await _settle(900);

      // 03 火星:进房迸发后 ~600ms,粒子正在半空散开
      _state.memberJoins();
      await _settle(600);
      await capture('03-sparks-join');

      // 04 20 人静息(双环)
      _state.silenceAll();
      _state.setMemberCount(20);
      await _settle(1600);
      await capture('04-crowd-20p');

      // 05 12 人 + 一人说话
      _state.setMemberCount(12);
      await _settle(900);
      final List<HearthMember> twelve = _state.members;
      if (twelve.isNotEmpty) {
        _state.setSpeaking(twelve[twelve.length ~/ 3].id, true);
      }
      await _settle(1200);
      await capture('05-crowd-12p');
      _state.silenceAll();

      // 06 28 人,全员在场(**不开紧凑**)。
      // 这是"人多时还能不能看"的验收图,主角是排布本身,不是芯片。
      _state.setMemberCount(28);
      await _settle(1600);
      await capture('06-crowd-28p');

      // 06b 同样 28 人,但开紧凑模式逼出 +N 芯片。
      // 桌面尺寸下正常容量 = 68,28 人根本溢不出去(见 layer_b_seats 「澄清 3」),
      // 芯片只能这样演示。单独一张,免得和上面那张的用途混在一起。
      setState(() => _compact = true);
      await _settle(1600);
      await capture('06b-overflow-chip');
      setState(() => _compact = restoreCompact);
      await _settle(700);

      // 07 两个人,一个在说
      _state.setMemberCount(2);
      await _settle(900);
      final List<HearthMember> duo = _state.members;
      if (duo.isNotEmpty) _state.setSpeaking(duo.first.id, true);
      await _settle(1200);
      await capture('07-duo-2p');
      _state.silenceAll();

      debugPrint('[shot] 序列完成,输出目录:'
          '${Directory(kShotDir).absolute.path}');
    } finally {
      if (mounted) {
        setState(() {
          _capturing = false;
          _compact = restoreCompact;
        });
      }
    }
  }

  /// 等待若干毫秒并确保至少走过一帧。
  ///
  /// 时钟在静息档会把重绘节流到 12fps,`endOfFrame` 仍然每个 vsync 都会完成
  /// (vsync 回调没被省掉,省掉的是 paint),所以这里是安全的。
  Future<void> _settle(int ms) async {
    _clock.requestFullRate();
    await Future<void>.delayed(Duration(milliseconds: ms));
    await WidgetsBinding.instance.endOfFrame;
  }

  // ───────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: HearthColors.bg,
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size canvas = Size(
            constraints.maxWidth,
            constraints.maxHeight,
          );
          final Offset center = Offset(canvas.width / 2, canvas.height / 2);

          // 三层共用的火焰中心。HearthState 用它算火星起点,必须先写。
          _state.flameCenter = center;

          // 座位区再让出底部控制条的高度。
          //
          // 环是**居中**的,所以必须对称地让 —— 只减底部会把火心顶上去,
          // 而 flameCenter 按 SPEC 固定在画布正中。这里上下各让
          // _controlBarReserve,净效果是最外环的下沿抬高同样的量,
          // 20 人布局的底边从 660 收到 ~630,干净地避开收起状态的控制条。
          final Size seatCanvas = Size(
            canvas.width,
            (canvas.height - 2 * _controlBarReserve).clamp(0.0, canvas.height),
          );

          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // ── 截图边界:只包 A+B+D ──
              RepaintBoundary(
                key: _sceneKey,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    const ColoredBox(color: HearthColors.bg),

                    // A 层:光在所有人下面。
                    RepaintBoundary(
                      child: GlowLayer(clock: _clock, state: _state),
                    ),

                    // B 层:人。
                    SeatRing(
                      clock: _clock,
                      state: _state,
                      size: seatCanvas,
                      flameCenter: center,
                      maxRings: _compact ? 1 : 3,
                      onLayout: _layoutProbe.set,
                    ),

                    // D 层:火星压在人上面,读作「从人前面飘过」。
                    RepaintBoundary(
                      child: SparkLayer(clock: _clock, state: _state),
                    ),
                  ],
                ),
              ),

              // ── 控制面板:在边界之外,截图里不会有 ──
              if (!_capturing)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: DemoControls(
                    clock: _clock,
                    state: _state,
                    layoutProbe: _layoutProbe,
                    compact: _compact,
                    onCompactChanged: (bool v) => setState(() => _compact = v),
                    showPerformanceOverlay: widget.showPerformanceOverlay,
                    onPerformanceOverlayChanged:
                        widget.onPerformanceOverlayToggle,
                    onCaptureOne: captureTimestamped,
                    onCaptureSequence: runCaptureSequence,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 收起状态的控制条高度的一半左右。见上面的对称让位说明。
  static const double _controlBarReserve = 34;
}

/// B 层布局结果的搬运工。
///
/// 它**不是** `ValueNotifier`:B 层在 `build` 里回写布局,若此时同步通知
/// 监听者,监听者的 `setState` 就发生在 build 期间 —— 直接报错。
/// 这里退化成一个裸字段,HUD 按自己的 1 秒节拍来读,天然错开。
class SeatLayoutProbe {
  SeatLayout? _last;
  SeatLayout? get last => _last;
  void set(SeatLayout l) => _last = l;
}
