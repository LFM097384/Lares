@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/auth/auth_credential.dart';
import 'package:lares_app/src/net/connection_test.dart';
import 'package:lares_app/src/net/signaling_client.dart';

/// 端到端联调:把**真实的** SignalingClient 接到**真实的** Node 信令服务端上跑一遍。
///
/// 单测里的假通道只能证明「我以为的协议」自洽;这一组才能证明客户端与服务端
/// 真的谈得拢 —— HMAC 格式、challenge 时序、4401/4429 关闭码,一个都不含糊。
///
/// 需要本机有 node 且 server/ 依赖已安装。缺任一条件时整组跳过,不污染常规 CI。
/// 单独运行:flutter test test/signaling_live_auth_test.dart
void main() {
  final repoRoot = Directory.current.parent.path;
  final serverDir = Directory('$repoRoot${Platform.pathSeparator}server');
  final hasServer =
      File('${serverDir.path}${Platform.pathSeparator}src${Platform.pathSeparator}index.js')
          .existsSync();

  const token = 'live-shared-token';
  const passcode = '炉灵开门';
  const userId = 'u_live';

  Process? proc;
  var port = 0;

  /// 起一个服务端实例,等 /health 通
  Future<bool> startServer(Map<String, String> env, int p) async {
    proc = await Process.start(
      'node',
      ['src/index.js'],
      workingDirectory: serverDir.path,
      environment: {...Platform.environment, 'LARES_PORT': '$p', ...env},
    );
    proc!.stdout.drain<void>();
    proc!.stderr.drain<void>();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    final client = HttpClient();
    while (DateTime.now().isBefore(deadline)) {
      try {
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:$p/health'));
        final res = await req.close();
        await res.drain<void>();
        if (res.statusCode == 200) return true;
      } catch (_) {
        // 还没起来,继续等
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  tearDown(() async {
    proc?.kill();
    proc = null;
  });

  /// 连上去跑完整握手,返回首个 welcome(或 error)
  Future<Map<String, dynamic>> handshake(
    SignalingClient c, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    final done = Completer<Map<String, dynamic>>();
    late StreamSubscription<Map<String, dynamic>> sub;
    sub = c.messages.listen((m) {
      if (m['t'] == 'welcome' || m['t'] == 'error' || m['t'] == '_auth_failed') {
        if (!done.isCompleted) {
          done.complete(m);
          sub.cancel();
        }
      }
    });
    c.connect();
    c.hello(
      userId: userId,
      deviceId: 'd-live',
      name: '联调',
      platform: 'test',
    );
    return done.future.timeout(timeout, onTimeout: () => {'t': '_timeout'});
  }

  group('真实服务端联调', skip: !hasServer ? '未找到 server/src/index.js' : null, () {
    test('token 模式:真实客户端的证明被真实服务端接受', () async {
      port = 18941;
      expect(
        await startServer(
            {'LARES_AUTH_MODE': 'token', 'LARES_AUTH_TOKEN': token}, port),
        isTrue,
        reason: '服务端未能启动(需要 node + server/node_modules)',
      );

      final c = SignalingClient(
        url: 'ws://127.0.0.1:$port/ws',
        userId: userId,
        credentials: () =>
            const AuthCredential(mode: AuthMode.token, token: token),
      );
      final msg = await handshake(c);

      expect(msg['t'], 'welcome', reason: '真实服务端拒绝了客户端推导的 proof');
      expect(msg['authMode'], 'token');
      expect(c.auth.phase, AuthPhase.authenticated);
      expect(c.auth.serverModes, contains('token'));
      expect(c.auth.authRequired, isTrue);
      await c.dispose();
    });

    test('circle 模式:三段式证明被接受,且 authMode 回报 circle', () async {
      port = 18942;
      expect(
        await startServer({
          'LARES_AUTH_MODE': 'circle',
          'LARES_CIRCLE_PASSCODES': jsonEncode({'home': passcode}),
        }, port),
        isTrue,
      );

      final c = SignalingClient(
        url: 'ws://127.0.0.1:$port/ws',
        userId: userId,
        credentials: () => const AuthCredential(
            mode: AuthMode.circle, passcode: passcode, circleId: 'home'),
      );
      final msg = await handshake(c);

      expect(msg['t'], 'welcome');
      expect(msg['authMode'], 'circle');
      await c.dispose();
    });

    test('口令错:真实 4401 不会触发无限重连', () async {
      port = 18943;
      expect(
        await startServer(
            {'LARES_AUTH_MODE': 'token', 'LARES_AUTH_TOKEN': token}, port),
        isTrue,
      );

      final c = SignalingClient(
        url: 'ws://127.0.0.1:$port/ws',
        userId: userId,
        credentials: () =>
            const AuthCredential(mode: AuthMode.token, token: 'wrong-token'),
      );
      await handshake(c);
      // 留出时间走完「重试一次」的窗口
      await Future<void>.delayed(const Duration(seconds: 4));

      expect(c.auth.phase, AuthPhase.failed);
      expect(c.auth.needsUserAction, isTrue);
      expect(c.isConnected, isFalse);
      await c.dispose();
    });

    test('重连必须换新 nonce:断开后重连仍能通过(证明没有重放旧证明)', () async {
      port = 18944;
      expect(
        await startServer(
            {'LARES_AUTH_MODE': 'token', 'LARES_AUTH_TOKEN': token}, port),
        isTrue,
      );

      final c = SignalingClient(
        url: 'ws://127.0.0.1:$port/ws',
        userId: userId,
        credentials: () =>
            const AuthCredential(mode: AuthMode.token, token: token),
      );
      expect((await handshake(c))['t'], 'welcome');

      // 模拟「改了设置」触发的干净重连:必须拿新 challenge 重新推导
      final second = Completer<Map<String, dynamic>>();
      final sub = c.messages.listen((m) {
        if (m['t'] == 'welcome' && !second.isCompleted) second.complete(m);
      });
      c.reconnectWithNewCredential();

      final again = await second.future
          .timeout(const Duration(seconds: 10), onTimeout: () => {'t': '_timeout'});
      expect(again['t'], 'welcome', reason: '重连若重放旧 proof,服务端会判 auth_failed');
      expect(c.auth.phase, AuthPhase.authenticated);
      await sub.cancel();
      await c.dispose();
    });

    test('测试连接:口令对报 ok、口令错报 authFailed、地址不通报 unreachable', () async {
      port = 18945;
      expect(
        await startServer(
            {'LARES_AUTH_MODE': 'token', 'LARES_AUTH_TOKEN': token}, port),
        isTrue,
      );

      final tester = ConnectionTester(timeout: const Duration(seconds: 8));

      final ok = await tester.test(
        url: 'ws://127.0.0.1:$port/ws',
        credential: const AuthCredential(mode: AuthMode.token, token: token),
        userId: userId,
      );
      expect(ok.outcome, ConnectionTestOutcome.ok);
      expect(ok.authMode, AuthMode.token);
      expect(ok.serverModes, contains('token'));

      final bad = await tester.test(
        url: 'ws://127.0.0.1:$port/ws',
        credential: const AuthCredential(mode: AuthMode.token, token: 'nope'),
        userId: userId,
      );
      expect(bad.outcome, ConnectionTestOutcome.authFailed);
      expect(bad.needsCredentialFix, isTrue);

      // 没人监听的端口
      final dead = await tester.test(
        url: 'ws://127.0.0.1:18999/ws',
        credential: AuthCredential.none,
        userId: userId,
      );
      expect(dead.outcome, ConnectionTestOutcome.unreachable);

      // 地址本身非法:压根不发起连接
      final bogus = await tester.test(
        url: 'https://rtc.example.com/ws',
        credential: AuthCredential.none,
        userId: userId,
      );
      expect(bogus.outcome, ConnectionTestOutcome.invalidUrl);
    });

    test('none 模式:服务端也发 challenge,客户端照常握手', () async {
      port = 18946;
      expect(await startServer({'LARES_AUTH_MODE': 'none'}, port), isTrue);

      final c = SignalingClient(
        url: 'ws://127.0.0.1:$port/ws',
        userId: userId,
        credentials: () => AuthCredential.none,
      );
      final msg = await handshake(c);

      expect(msg['t'], 'welcome');
      expect(msg['authMode'], 'none');
      expect(c.auth.authRequired, isFalse);
      expect(c.auth.serverModes, isEmpty);
      await c.dispose();
    });
  });
}
