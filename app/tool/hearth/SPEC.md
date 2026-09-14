# 炉火之灵 原型 — 实现契约 (SPEC)

独立原型，入口 `app/tool/hearth/main.dart`。**禁止修改 `app/lib/` 任何文件。禁止新增依赖。**
只用 Flutter SDK：`dart:ui`、`dart:math`、`CustomPainter`、`AnimationController`/`Ticker`、隐式动画。

包名 `lares_app`（pubspec）。原型内部一律用相对 import，不要 `package:lares_app/...` 引 `lib/`。
Token 值在 `hearth_tokens.dart` 里**复制**一份（不 import lib/），保持与 `app/lib/src/theme/tokens.dart` 一致。

---

## 0. 既有主 app 的三条硬事实（原型必须照顾）

1. 说话状态只有离散 `Set<String> speakingIds`，**没有音量幅度**。原型自行合成"说话包络"（onset 上升 / 尾音衰减），并在报告里注明这是合成的。
2. **没有 per-member 最后说话时间戳**。原型自己维护 `lastSpokeAt`。
3. 主 app 全库无 `RepaintBoundary`，`ChangeNotifier` 一 notify 整层重建。原型必须做对，作为合入示范。

---

## 1. 文件划分（各自负责，不要越界）

| 文件 | 负责人 | 内容 |
|---|---|---|
| `hearth_tokens.dart` | 共享（已给定，见 §2） | 颜色/间距常量 + 调参常量 |
| `hearth_state.dart` | 共享（已给定，见 §3） | `HearthMember` / `HearthState` / `HearthClock` |
| `layer_a_glow.dart` | **Agent V** | 呼吸的烬：`GlowPainter` |
| `layer_d_sparks.dart` | **Agent V** | 火星：`SparkField` + `SparkPainter` |
| `layer_b_seats.dart` | **Agent L** | 围炉布局：`SeatLayout` + `SeatRing` + `MemberOrb` |
| `hearth_scene.dart` | **Agent L** | 三层 Stack 组装 |
| `demo_controls.dart` | **Agent L** | 演示控制面板 + 性能 HUD |
| `main.dart` | **Agent L** | 入口 |

---

## 2. `hearth_tokens.dart`（Agent V 创建，两边都用）

```dart
import 'dart:ui';

abstract final class HearthColors {
  static const Color bg          = Color(0xFF121016);
  static const Color surface     = Color(0xFF1C1922);
  static const Color surfaceHigh = Color(0xFF26222E);
  static const Color ember       = Color(0xFFFF8A5C); // 品牌余烬橙
  static const Color emberDeep   = Color(0xFFFF5A2A); // 火心
  static const Color emberAsh    = Color(0xFF8C3A1E); // 将熄的炭
  static const Color textPrimary   = Color(0xFFF2EEE9);
  static const Color textSecondary = Color(0xFF9A93A3);
  static const Color statusFree = Color(0xFF6FD08C);
  static const Color statusBusy = Color(0xFFE8B45A);
  static const Color statusEars = Color(0xFF6FA8D0);
  static const Color statusAway = Color(0xFF6E6878);
}

abstract final class HearthSpacing {
  static const double xs = 4, sm = 8, md = 16, lg = 24, xl = 40;
}
```
调参常量（`HearthTuning`）由各自 layer 文件自行定义，但必须集中在文件顶部、带注释，方便产品负责人改。

---

## 3. `hearth_state.dart`（Agent V 创建，Agent L 消费）

这是三层共用的唯一数据源。**必须严格按此接口实现**，Agent L 只读不改。

```dart
enum HearthStatus { free, busy, ears, away }

class HearthMember {
  final String id;
  final String name;
  HearthStatus status;
  /// 合成的说话包络 0..1：onset 快速升到 1，停说后按 ~900ms 衰减到 0
  double speech = 0;
  /// 是否在 activeSpeakers 集合里（离散信号）
  bool speaking = false;
  /// 最后一次说话时刻（毫秒，HearthClock.nowMs）
  int lastSpokeMs = 0;
  /// 座位序（稳定，入房时分配，说话不改变）
  int seat = 0;
}

/// 三层共用的心跳。**关键性能对象**。
/// 它是 Listenable：A 层 painter 用 `super(repaint: clock)` 订阅，不做 widget rebuild。
class HearthClock extends ChangeNotifier {
  int get nowMs;               // 单调毫秒
  double get t;                // 秒，double
  ActivityLevel get level;     // 当前档位
  void requestFullRate();      // 有事件/说话时调用，回到 60fps 并重置 idle 计时
}

enum ActivityLevel { active, calm, deepIdle }
```

### 3.1 `HearthClock` 三档降级策略（**本原型的性能核心，必须实现**）

单个 `Ticker`。每次 tick 判断是否"放行"一次 `notifyListeners()`：

| 档位 | 进入条件 | 重绘节流 | 呼吸周期 |
|---|---|---|---|
| `active` | 有人说话，或粒子存活，或 3s 内有事件 | 不节流（跟 vsync，≈60fps） | 4.5s |
| `calm` | 静息 ≥ 3s | ≥ 80ms 才放行（≈12fps） | 4.5s |
| `deepIdle` | 静息 ≥ 90s | ≥ 160ms 才放行（≈6fps） | 6.5s（拉长，更"睡着"） |

**额外**：`HearthClock` 必须支持 `freezeWhenDeepIdle` 开关（默认 false）。为 true 时 deepIdle 直接 `ticker.stop()` 并保持最后一帧 —— 这是用来**实测真实零开销地板**的对照组，报告里要给出这一档的数字。

**重要说明写进代码注释**：ticker 运行时即使不 markNeedsPaint，引擎仍会走 vsync 回调，只是跳过 build/layout/paint。节流省的是 raster+paint，不是 vsync。完全停 ticker 才是真零。这一点报告里要如实讲。

### 3.2 `HearthState`

```dart
class HearthState extends ChangeNotifier {
  final HearthClock clock;
  List<HearthMember> get members;
  /// 归一化的"灵"朝向：所有说话者座位方向按 speech 加权求和，长度 0..1
  Offset get spiritPull;
  /// 所有说话者 speech 的最大值 0..1，驱动 A 层整体亮度
  double get arousal;

  void setMemberCount(int n);        // 演示用：重建成员列表
  void toggleSpeaking(String id);
  void memberJoins();                // 触发 D 层 spark burst
  void memberLeaves();
  void sendMessage(String id);       // 触发 D 层 spark burst
  void tickEnvelopes(double dtSec);  // 由 clock 每帧调用，推进 speech 包络
}
```
`spiritPull` 的座位方向由 Agent L 的 `SeatLayout` 算出并回写给 `HearthState`（`setSeatDirections(Map<String, Offset>)`），避免 A 层依赖 B 层布局代码。

---

## 4. Layer A — 呼吸的烬（Agent V）

### 4.1 渲染技术（**已定，不要换方案**）

- **不用** `MaskFilter.blur`（大 sigma 在 Skia/Impeller 上昂贵）。
- **不用** FragmentProgram（需要改 pubspec 的 shaders 段）。
- **用**：`Path` + `ui.Gradient.radial`。

具体：把火焰画成 **3~4 层叠加的"有机光斑"**，每层：

1. 用极坐标半径函数生成不规则闭合 `Path`：
   `r(θ) = R * (1 + Σᵢ aᵢ·sin(kᵢ·θ + ωᵢ·t + φᵢ))`，取 i=3 个谐波，k = 2/3/5，a ≈ 0.06/0.04/0.025，ω 各不相同且互质感（如 0.31/0.47/0.73 rad/s）。采样 72 个点，`Path.lineTo` 连成（72 段在这个尺度下肉眼即为平滑，不要用 cubicTo，省 CPU）。
2. 用 `ui.Gradient.radial` 填充，**alpha 必须在 stop ≈ 0.82 之前就衰减到 0**，这样 Path 的硬边缘完全看不见 —— 这是不用 blur 也能得到柔和发光的关键。
   色标示例（由内到外）：`emberDeep@0.0` → `ember@0.28` → `ember α0.35@0.55` → `透明@0.82`。
3. 各层 R、相位、透明度、中心偏移都不同，产生流动感。最内层小而亮（火心），最外层大而淡（光晕）。

### 4.2 呼吸

- 静息：亮度在 **0.82 ↔ 1.0** 之间做 4.5s `sin` 循环 —— **幅度必须克制**。这是长时间注视的界面，不要做成脉冲灯。用 `sin` 不要用 `easeInOut` 反复（后者在端点停留太久，像喘气）。
- 半径同步微呼吸：**±3%**，不要更多。

### 4.3 说话态

- `arousal` 0→1 时：整体亮度乘 `1.0 → 1.45`，火心半径 `1.0 → 1.18`，最外光晕 `1.0 → 1.3`。
- **朝向**：整团光沿 `spiritPull` 方向偏移 `spiritPull * R * 0.22`，并沿该方向**拉伸** —— 用 `canvas.save(); canvas.translate(c); canvas.rotate(angle); canvas.scale(1 + 0.18*|pull|, 1 - 0.07*|pull|); canvas.rotate(-angle); canvas.translate(-c);` 或等价 `Matrix4`。偏移/拉伸要用弹簧式插值平滑（时间常数 ~450ms），不能瞬间跳。
- 多人同时说话：`spiritPull` 是加权和，会自然变短（互相抵消），光团回到居中但更亮 —— 这是正确的行为，不要特判。

### 4.4 性能纪律

- `GlowPainter extends CustomPainter` 必须 `super(repaint: clock)`。
- `shouldRepaint` 只比较**非动画**的配置项，**不比较时间**。
- `ui.Gradient.radial` 每帧新建是可以接受的（几个对象），但 `Paint` 实例要复用（字段持有，不要每帧 `Paint()`）。
- Path 点数组用**复用的 `Float32List`/预分配 list**，不要每帧 `List.generate`。
- 外层包 `RepaintBoundary`。

---

## 5. Layer D — 火星（Agent V）

### 5.1 生命周期（**关键：真的会熄**）

```dart
class SparkField {
  static const int capacity = 180;      // 固定池，绝不动态扩容
  int _alive = 0;
  void burst({required Offset origin, required int count, required SparkKind kind});
  /// 返回是否还有存活粒子；由 clock 每帧调用
  bool advance(double dtSec);
}
```
- 固定容量对象池，粒子用**就地复用**的 `_Spark` 对象（字段 mutable），**每帧零分配**。
- 池满时丢弃新粒子（不扩容，不覆盖最老的 —— 丢弃更省）。
- `_alive == 0` 时，`SparkPainter` 直接 `return`，且 `HearthClock` 不因粒子而保持 active。
- **绝不持续发射**。只有 `memberJoins` / `sendMessage` / 成员离开 才 burst。

### 5.2 事件与数量

| 事件 | 粒子数 | 起点 | 风味 |
|---|---|---|---|
| 有人进房 | 28 | 火焰中心 | 向上扩散，暖亮 |
| 发消息 | 14 | 该成员座位 → 略偏向火焰 | 小而快，向火焰方向斜飘 |
| 有人离开 | 18 | 该成员座位 | 偏暗，飘散后快速熄灭 |

### 5.3 运动模型（1080p 桌面下的数值）

```
初速 vy  = -(55 .. 130) px/s      (向上为负)
初速 vx  = (-18 .. 18) px/s
浮力 ay  = -14 px/s²              (真实火星会先加速再被阻力拉住)
阻力      v *= exp(-1.15 * dt)     (每秒衰减，不要用 v -= k*v*dt)
横向扰动  x += A * sin(ω*t + φ) * dt,  A = 20..46 px/s, ω = 1.6..4.2 rad/s
寿命      1.5 .. 3.0 s
半径      1.1 .. 3.0 px (核)，外圈 halo = 核 * 2.6
```
- alpha 包络：`0..0.10` 生命期内从 0 升到 1（快速点燃），之后 `pow(1-u, 1.6)` 衰减。
- 颜色：生命初期 `emberDeep` → 中期 `ember` → 末期 `emberAsh`，用两段 `Color.lerp`。
- 绘制：每粒子 2 次 `drawCircle`（halo 低 alpha + 核）。180 粒子 = 360 drawCircle，桌面上无压力。**不要用 `drawAtlas`**（需要图集，本原型无图片）。不要给粒子加 blur。

### 5.4 性能纪律
- `SparkPainter` 用 `super(repaint: clock)`；`_alive == 0` 时 `paint` 首行 return。
- 独立 `RepaintBoundary`（与 A 层分开，因为 D 层是爆发式重绘，A 层是慢速）。
- `Paint` 复用。

---

## 6. Layer B — 围炉而坐（Agent L）

### 6.1 座位环算法（**已定**）

给定 n 人、可用区域 `Size s`、火焰中心 `c`：

```
base = min(s.width, s.height)
// 头像直径随人数收缩，44px 是触摸下限，留余量取 52
d = clamp(96 - (n - 2) * 2.6, 52.0, 96.0)
R1 = base * 0.30
R2 = base * 0.44
R3 = base * 0.575
// 一个环能放几个（1.22 是相邻间隙系数）
cap(R) = max(3, floor(2 * pi * R / (d * 1.22)))
```

分环规则：
- `n <= cap(R1)` → 单环
- `n <= cap(R1) + cap(R2)` → 双环，**内环放 `ceil(n * 0.38)`，外环放余下**（内环少一点，视觉上不挤火）
- `n <= cap(R1)+cap(R2)+cap(R3)` → 三环，按 0.22 / 0.34 / 0.44 分配
- 超出 → 前 `cap-1` 个正常显示，最后一位换成 **`+N` 聚合芯片**（可点击，展开成滚动列表；原型里点击弹 `showModalBottomSheet` 列表即可）

每环起始角错开（`ring i` 起始角 `= -pi/2 + i * pi / ringCount`），避免内外环径向对齐显得死板。

### 6.2 稳定性（**已定，不要改**）

- 座位序 `seat` 在成员加入时分配，**说话不重排**。长期挂机的界面，位置恒定才有"熟悉感"。
- 说话者只做**径向内移**，不换角度。
- 人数变化时环重算，位置变动用 400ms `Curves.easeOutCubic` 过渡。

### 6.3 状态表现

| 状态 | 半径 | 透明度 | 其他 |
|---|---|---|---|
| 说话中 | `R * (1 - 0.10 * speech)` | 1.0 | 状态环增亮，加一圈 ember 描边；轻微 scale 1.0→1.06 |
| 正常在场 | `R` | 0.88 | — |
| 静默 >2min | `R * 1.02`（略退） | 0.55 | — |
| 静默 >10min（退入阴影） | `R * 1.04` | **0.34（硬下限，不得更低）** | 名字文字 0.5 |

透明度不影响命中测试，**所有成员始终可点**。原型里点头像弹一个 SnackBar 证明可点。

### 6.4 性能纪律（**这是 B 层的重点**）

- **每个头像用隐式动画**（`AnimatedPositioned` / `AnimatedOpacity` / `AnimatedScale`）。隐式动画只在过渡期间跑 ticker，稳态**零开销** —— 这是 B 层能做到静息零成本的原因。
- **不要**把头像挂到 `HearthClock` 上逐帧重绘。
- 每个头像外包 `RepaintBoundary`。
- 说话时头像上的呼吸/波纹效果：**不要**再各自开 `AnimationController`（20 个 ticker 是灾难）。说话者的光感交给 A 层和状态环颜色，头像自身只做一次性过渡。
- 布局计算（`SeatLayout.compute`）结果要缓存，只在 `(n, size)` 变化时重算。

---

## 7. 演示外壳（Agent L）

`main.dart` 起一个 `MaterialApp`（暗色，`HearthColors.bg`），单页 `HearthScene`，加一个可折叠控制面板：

- 人数滑杆/快捷按钮：**2 / 5 / 12 / 20 / 28**（28 用来验证溢出芯片）
- 「让某人说话」：点击成员头像切换其说话态；另有"随机说话"开关（模拟真实对话节奏，每 1.5~4s 换人）
- 「有人进房」「发消息」「有人离开」按钮 → 触发 D 层
- 档位指示：当前 `ActivityLevel`（active / calm / deepIdle），以及距离下一档还有多久
- `freezeWhenDeepIdle` 开关
- **性能 HUD**：自己实现，用 `SchedulerBinding.instance.addTimingsCallback` 读 `FrameTiming`，显示最近 120 帧的
  - 平均/p90 `buildDuration + rasterDuration`（ms）
  - **实际帧提交速率**（每秒 FrameTiming 回调数）——这个数字比"FPS"更诚实，因为静息降级时就是要低
  - 存活粒子数
  HUD 必须可隐藏（截图时关掉），且 HUD 自身不能每帧 setState（用 1s 定时刷新）。
- 快捷键/按钮：切换 performance overlay（`MaterialApp.showPerformanceOverlay`）

控制面板要好看，别做成调试面板的样子 —— 产品负责人会看截图。建议半透明毛玻璃感的底部收纳条（用 `surfaceHigh` + 低 alpha，不要 BackdropFilter，贵）。

---

## 8. 视觉验收标准（产品负责人会看的）

1. 静息截图：中心一团**有机的、非正圆的**暖光，边缘完全柔和无硬边，成员环绕，整体像深夜的炉边，不像"一个橙色圆点"。
2. 说话截图：光团明显朝说话者偏移+拉伸，说话者略微靠近火且更亮。
3. 火星截图：粒子在上升途中，有明显的散开和明暗层次。
4. 20 人截图：双环排列合理，不重叠、不拥挤、不出屏。
5. 整体**低饱和、暖调、克制**。宁可暗一点，不要糊一片橙。

## 9. 交付前自检

- `flutter analyze` 对 `tool/hearth/` 零错误（warning 尽量清零）。
- `flutter run -d windows -t tool/hearth/main.dart` 能跑。
- 不改 `app/lib/` 下任何文件（`git status` 验证）。
- 无新增依赖（`pubspec.yaml` 未改）。
