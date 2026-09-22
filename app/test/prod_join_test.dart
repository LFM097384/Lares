/// 打**真实生产服务器**的进房联调。
///
/// ## 为什么必须有这个测试
///
/// 2026-09-12 到 09-22,整整十天、十几个构建、三轮状态机重构,
/// 都没解决「进 review 圈卡在正在进去…」。
///
/// 真因不在代码里:仓库变量 `LARES_SIGNALING` 被设成了联调用的局域网
/// 地址 `ws://10.0.0.185:8787`,所有构建都被编译成连那个地址。
/// 手机永远连不通,而服务端日志干干净净 —— 请求根本没到过服务器。
/// 所有状态机修复都是对的,但**根本没机会执行**。
///
/// 而当时 749 个测试全绿 —— 因为它们全都打 fake 或本地服务器,
/// **没有一个验证过「发布构建能连上生产服务器」**。
///
/// 这个文件补上那个缺口:它用生产地址 + 审核备注里写的那套凭据,
/// 走完整的握手 → 进房 → 拿 token 流程。
///
/// ## 跑法
///
/// 默认跳过(CI 里不该依赖外部服务)。要跑:
/// ```
/// dart test -t prod   # 或
/// flutter test test/prod_join_test.dart --dart-define=LARES_PROD_TEST=1
/// ```
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/auth/auth_credential.dart';
import 'package:lares_app/src/net/signaling_client.dart';

/// 生产信令地址 —— 与 `.github/workflows/ios-build.yml` 里的回落值一致。
/// 这两处要一起改,所以在两边都留了注释。
const _prodUrl = 'wss://lares.westus.cloudapp.azure.com:443/ws';

/// 审核备注(`docs/app-store/submission-kit.md` §7)里给审核员的那套。
/// 审核员照着做必须能进 —— 进不去就是 Guideline 2.1 拒绝。
const _reviewCircle = 'review';
const _reviewPasscode = 'amber-cedar-lumen-quiet';

void main() {
  // 这组用例依赖外网与生产服务器,不该在普通 `flutter test` 里跑。
  // 通过 --dart-define 显式开启。
  final enabled = Platform.environment['LARES_PROD_TEST'] == '1';

  group('生产服务器进房联调', skip: enabled ? null : '需环境变量 LARES_PROD_TEST=1', () {
    test('审核员那套凭据能走完握手 → 进房 → 拿到 RTC token', () async {
      final client = SignalingClient(
        url: _prodUrl,
        userId: 'u_prodtest',
        credentials: () => const AuthCredential(
          mode: AuthMode.circle,
          passcode: _reviewPasscode,
          circleId: _reviewCircle,
        ),
      )..authCircleId = _reviewCircle;
      addTearDown(client.dispose);

      final gotToken = Completer<Map<String, dynamic>>();
      final failed = Completer<String>();
      final sub = client.messages.listen((msg) {
        switch (msg['t']) {
          case 'token':
            if (!gotToken.isCompleted) gotToken.complete(msg);
          case 'error':
            if (!failed.isCompleted) {
              failed.complete('服务端 error: ${msg['message']}');
            }
          case '_auth_failed':
            if (!failed.isCompleted) failed.complete('鉴权被拒(4401)');
          case '_rate_limited':
            if (!failed.isCompleted) failed.complete('被限流(4429)');
        }
      });
      addTearDown(sub.cancel);

      client.hello(
        userId: 'u_prodtest',
        deviceId: 'd_prodtest',
        name: '联调',
        platform: 'test',
      );

      // 等握手。生产服务器要算 HMAC 证明,给足时间。
      final shook = await client.waitHandshake(const Duration(seconds: 20));
      expect(shook, isTrue,
          reason: '握不上手 —— 检查网络、服务器状态,以及 $_prodUrl 是否正确');
      expect(client.auth.isAuthenticated, isTrue,
          reason: '握手完成但未通过鉴权:${client.auth.message}');

      client.join(_reviewCircle);

      final result = await Future.any([
        gotToken.future.then((m) => m),
        failed.future.then<Map<String, dynamic>>((e) => throw StateError(e)),
        Future<Map<String, dynamic>>.delayed(
          const Duration(seconds: 25),
          () => throw TimeoutException('25 秒没拿到 token —— 正是「卡在正在进去…」'),
        ),
      ]);

      expect(result['circleId'], _reviewCircle);
      expect(result['url'], isNotEmpty, reason: 'LiveKit 地址不能为空');
      expect(result['token'], isNotEmpty, reason: 'RTC token 不能为空');
      // token 是 JWT,三段点分
      expect((result['token'] as String).split('.').length, 3,
          reason: 'token 不像 JWT,服务端 mint 可能出了问题');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('错口令会被明确拒绝,不是静默卡住', () async {
      final client = SignalingClient(
        url: _prodUrl,
        userId: 'u_prodtest_bad',
        credentials: () => const AuthCredential(
          mode: AuthMode.circle,
          passcode: 'definitely-not-the-passcode',
          circleId: _reviewCircle,
        ),
      )..authCircleId = _reviewCircle;
      addTearDown(client.dispose);

      final rejected = Completer<void>();
      final sub = client.messages.listen((msg) {
        if (msg['t'] == '_auth_failed' && !rejected.isCompleted) {
          rejected.complete();
        }
      });
      addTearDown(sub.cancel);

      client.hello(
        userId: 'u_prodtest_bad',
        deviceId: 'd_prodtest_bad',
        name: '联调',
        platform: 'test',
      );

      // 信令层对 4401 会重试恰好一次,所以要等两轮。
      await rejected.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => fail('错口令既没通过也没报错 —— 这就是静默卡死'),
      );
      expect(client.auth.needsUserAction, isTrue,
          reason: 'UI 要靠这个标志决定弹不弹口令框');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
