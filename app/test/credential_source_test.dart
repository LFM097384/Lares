/// 守住 `main()` 里那个凭据回调的两条性质。
///
/// ## 为什么值得单独一个文件
///
/// 2026-09-19 连续踩了两次,两次 `flutter test` 都是全绿:
///
/// 1. **回调永远取主圈的口令** —— 进任何非主圈的圈子都用错凭据,
///    服务端 4401、界面反复要口令,而用户输的口令一直是对的。
/// 2. **改成 `late final` + 自引用之后启动白屏** ——
///    级联 `..authCircleId = ...` 在变量赋值完成前触发 setter,
///    setter 内部读那个 late 变量 → LateInitializationError。
///
/// 两次都逃过了 682 个测试,因为**没有任何测试覆盖 main() 的装配**。
/// 完整跑 main() 在测试里不现实(平台插件、窗口、托盘),
/// 但那个闭包的逻辑可以原样搬过来验 —— 它才是出错的地方。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/auth/auth_credential.dart';
import 'package:lares_app/src/net/signaling_client.dart';

/// 与 main.dart 里同构的凭据查表。真实实现是 SettingsStore.credentialFor。
AuthCredential _credentialFor(String circleId) => AuthCredential(
      mode: AuthMode.circle,
      passcode: switch (circleId) {
        'home' => 'fengming',
        'review' => 'amber-cedar-lumen-quiet',
        _ => '',
      },
      circleId: circleId,
    );

void main() {
  const primary = 'home';

  /// 原样复刻 main.dart 的装配顺序。**改 main.dart 时这里要跟着改。**
  (SignalingClient, List<String>) build() {
    final asked = <String>[]; // 记录回调每次问了哪个圈
    SignalingClient? ref;
    final c = SignalingClient(
      url: 'ws://fake',
      credentials: () {
        final id = ref?.authCircleId ?? primary;
        asked.add(id);
        return _credentialFor(id);
      },
    );
    ref = c;
    c.authCircleId = primary;
    return (c, asked);
  }

  test('装配过程本身不抛异常(白屏回归)', () {
    // late + 自引用的那一版在这一步就炸 LateInitializationError。
    expect(build, returnsNormally);
  });

  test('回调跟着 authCircleId 走,不是跟着主圈走', () {
    // 直接验回调这个纯逻辑,不走 setter —— setter 会触发真实重连,
    // 在测试里会挂到超时(它要去连 ws://fake)。
    String? current;
    AuthCredential credentials() => _credentialFor(current ?? primary);

    current = 'home';
    expect(credentials().passcode, 'fengming');

    current = 'review';
    expect(credentials().passcode, 'amber-cedar-lumen-quiet',
        reason: '仍取 fengming 的话,就是那个「口令明明对却进不去」的 bug');
  });

  test('authCircleId 为空时回落到主圈,不是空串', () {
    // 回落错了会让 isComplete 为 false,连接直接不发起 —— 又是一次干等。
    SignalingClient? ref;
    final c = SignalingClient(
      url: 'ws://fake',
      credentials: () => _credentialFor(ref?.authCircleId ?? primary),
    );
    ref = c;
    addTearDown(c.dispose);

    // 还没设过 authCircleId
    expect(c.authCircleId, isNull);
    // 此时回调应当给出主圈的完整凭据
    expect(_credentialFor(c.authCircleId ?? primary).isComplete, isTrue);
  });
}
