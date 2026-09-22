/// 端到端验证:**一条带口令的邀请链接**能否直接走到进房。
///
/// ## 为什么必须有这个
///
/// `invite_link_test.dart` 证明的是「链接能被解析成三个字段」,
/// `prod_join_test.dart` 证明的是「用正确凭据能进生产服务器」。
/// 两者都绿,但**中间那段没人验过** —— 解析出来的地址和口令
/// 真的能拼成一次成功的握手吗?
///
/// 2026-09 的教训正是这类缝隙:每一段单测都绿,合起来却不通
/// (编译进去的信令地址指向局域网,而所有测试都打 fake 或本地服务器)。
///
/// 这个文件把整条缝补上:拿用户手里那条真链接,解析 → 用解析结果
/// 连生产服务器 → 进房 → 拿到 token。任何一环错了都会在这里红。
///
/// ## 跑法
///
/// 默认跳过(CI 不该依赖外部服务)。要跑:
/// ```
/// $env:LARES_PROD_TEST="1"; flutter test test/prod_invite_link_test.dart
/// ```
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/auth/auth_credential.dart';
import 'package:lares_app/src/net/signaling_client.dart';
import 'package:lares_app/src/state/invite_link.dart';

/// 给用户测试用的那条链接,一字不改。
/// 它同时也是「审核员那套凭据」的链接形态。
const _link =
    'lares://circle/review?name=Review'
    '&server=wss%3A%2F%2Flares.westus.cloudapp.azure.com%3A443%2Fws'
    '&pass=amber-cedar-lumen-quiet';

void main() {
  final enabled = Platform.environment['LARES_PROD_TEST'] == '1';

  group(
    '带口令的邀请链接 → 真实进房',
    skip: enabled ? null : '需环境变量 LARES_PROD_TEST=1',
    () {
      test('解析出的三个字段能直接拼成一次成功的进房', () async {
        // ── 1) 解析 ────────────────────────────────────────────────
        final invite = parseInviteLink(_link);
        expect(invite, isNotNull, reason: '链接本身要能解析');
        expect(invite!.circleId, 'review');
        expect(invite.hasServer, isTrue, reason: '没带服务器就得手动换,普通用户做不到');
        expect(invite.hasPasscode, isTrue, reason: '没带口令就还要再问一次');

        // ── 2) 用解析结果连生产服务器 ──────────────────────────────
        // 关键:这里的 url / passcode / circleId **全部来自链接**,
        // 没有一个是测试里硬写的 —— 否则就验不到「链接是否管用」。
        final client = SignalingClient(
          url: invite.serverUrl!,
          userId: 'u_invitetest',
          credentials: () => AuthCredential(
            mode: AuthMode.circle,
            passcode: invite.passcode!,
            circleId: invite.circleId,
          ),
        )..authCircleId = invite.circleId;
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
              if (!failed.isCompleted) failed.complete('鉴权被拒 —— 链接里的口令不对');
            case '_rate_limited':
              if (!failed.isCompleted) failed.complete('被限流(4429)');
          }
        });
        addTearDown(sub.cancel);

        client.hello(
          userId: 'u_invitetest',
          deviceId: 'd_invitetest',
          name: '链接联调',
          platform: 'test',
        );

        final shook = await client.waitHandshake(const Duration(seconds: 20));
        expect(shook, isTrue, reason: '握不上手 —— 链接里的服务器地址可能不对');
        expect(client.auth.isAuthenticated, isTrue,
            reason: '握手了但没通过鉴权:${client.auth.message}');

        // ── 3) 进房 ────────────────────────────────────────────────
        client.join(invite.circleId);

        final result = await Future.any([
          gotToken.future,
          failed.future.then<Map<String, dynamic>>((e) => throw StateError(e)),
          Future<Map<String, dynamic>>.delayed(
            const Duration(seconds: 25),
            () => throw TimeoutException('25 秒没拿到 token —— 即「卡在正在进去…」'),
          ),
        ]);

        expect(result['circleId'], invite.circleId);
        expect(result['url'], isNotEmpty);
        // token 是 JWT,三段点分。只验形状 —— 内容由服务端签,验不了也不该验。
        expect((result['token'] as String).split('.').length, 3);
      }, timeout: const Timeout(Duration(seconds: 60)));
    },
  );
}
