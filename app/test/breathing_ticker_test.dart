import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 呼吸背景的「停表」行为测试。
///
/// 为什么这件事值得单独测:原型实测发现**节流重绘救不了耗电** ——
/// 重绘降到 12fps 后 CPU 仍占 27%,因为只要 Ticker 在跑,
/// 引擎每个 vsync 都走完整帧调度。只有真的 `stop()` 才降到 0.31%(1/88)。
///
/// 所以「有没有停表」是一个**行为事实**,不是观感问题,必须能被断言。
///
/// 这里不直接测私有的 `_BreathingBackground`,而是用一个同构的最小组件
/// 复现同一套状态机(前台 && 可见 -> 转;否则停),把逻辑本身钉住。
class _Breather extends StatefulWidget {
  const _Breather({required this.visible});
  final bool visible;

  @override
  State<_Breather> createState() => _BreatherState();
}

class _BreatherState extends State<_Breather>
    with SingleTickerProviderStateMixin {
  late final AnimationController c;
  AppLifecycleListener? _lifecycle;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    c = AnimationController(vsync: this, duration: const Duration(seconds: 7));
    _lifecycle = AppLifecycleListener(onStateChange: (s) {
      _foreground = s == AppLifecycleState.resumed;
      _sync();
    });
    _sync();
  }

  @override
  void didUpdateWidget(_Breather old) {
    super.didUpdateWidget(old);
    if (old.visible != widget.visible) _sync();
  }

  void _sync() {
    if (_foreground && widget.visible) {
      if (!c.isAnimating) c.repeat(reverse: true);
    } else {
      c.stop();
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  _BreatherState stateOf(WidgetTester t) =>
      t.state<_BreatherState>(find.byType(_Breather));

  testWidgets('默认(前台+可见)时转表', (t) async {
    await t.pumpWidget(const MaterialApp(home: _Breather(visible: true)));
    expect(stateOf(t).c.isAnimating, isTrue);
    // 收尾:让 controller 停下来,否则 pumpWidget 的 teardown 会抱怨
    stateOf(t).c.stop();
  });

  testWidgets('不可见(地图盖住)时停表', (t) async {
    await t.pumpWidget(const MaterialApp(home: _Breather(visible: true)));
    expect(stateOf(t).c.isAnimating, isTrue);

    await t.pumpWidget(const MaterialApp(home: _Breather(visible: false)));
    expect(stateOf(t).c.isAnimating, isFalse, reason: '被盖住就该停');
  });

  testWidgets('重新可见时续上,且不跳回起点', (t) async {
    await t.pumpWidget(const MaterialApp(home: _Breather(visible: true)));
    await t.pump(const Duration(seconds: 2));
    final before = stateOf(t).c.value;
    expect(before, greaterThan(0.0));

    await t.pumpWidget(const MaterialApp(home: _Breather(visible: false)));
    expect(stateOf(t).c.isAnimating, isFalse);
    // stop() 必须保留当前值 —— 归零会让光晕在恢复时突然一跳
    expect(stateOf(t).c.value, before);

    await t.pumpWidget(const MaterialApp(home: _Breather(visible: true)));
    expect(stateOf(t).c.isAnimating, isTrue, reason: '回来要续上');
    stateOf(t).c.stop();
  });

  testWidgets('已经在转的时候再次 sync,不会把动画拽回起点', (t) async {
    await t.pumpWidget(const MaterialApp(home: _Breather(visible: true)));
    await t.pump(const Duration(seconds: 2));
    final before = stateOf(t).c.value;

    // 同样的 visible 再来一次:didUpdateWidget 不该做任何事
    await t.pumpWidget(const MaterialApp(home: _Breather(visible: true)));
    expect(stateOf(t).c.value, before, reason: '重复 repeat() 会归零,那是 bug');
    stateOf(t).c.stop();
  });
}
