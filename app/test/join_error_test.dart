import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/state/join_error.dart';

/// 服务端 error 报文的分类必须钉死。
///
/// 这一组守的是一层**隐式依赖**:`RoomController` 处理服务端的
/// `token_failed` / `auth_scope` 时,并不自己决定文案与「该不该弹口令框」,
/// 而是构造一个 `StateError(...)` 交给本文件按 `toString()` 里的子串分派。
/// 也就是说「弹不弹口令框」这件事实际压在下面这几条 contains 上 ——
/// 谁把 `text.contains('token')` 删了或改了,`token_failed` 就会从
/// serverNotReady 落到 unknown,而 unknown 的文案对这个场景是错的。
///
/// 这种依赖不写成测试就只活在注释里。前三次「卡在正在进去…」的教训是:
/// 没有测试盯着的约定,迟早会有人好心改坏。
void _errorPayloadClassification() {
  group('服务端 error 报文的分类(RoomController 依赖这一层)', () {
    test('token_failed 归 serverNotReady —— 且绝不能弹口令框', () {
      // 服务端 mint LiveKit token 失败时发这条(server/src/index.js:873)。
      // 是服务器侧的媒体服务问题,用户填口令没有任何用 ——
      // 弹口令框会让他去改一个根本没错的东西。
      expect(classifyJoinError(StateError('token_failed')),
          JoinErrorKind.serverNotReady);
      expect(classifyJoinError(StateError('token_failed')),
          isNot(JoinErrorKind.needsPasscode));
    });

    test('rtc_not_configured 与 token_failed 同类:文案本来就该一样', () {
      // 两条都意味着「服务端没能给出可用的语音服务」,现成那句
      // 「服务器还没准备好语音服务…」对两者都准确,不必新增文案。
      expect(classifyJoinError(StateError('rtc_not_configured')),
          JoinErrorKind.serverNotReady);
      expect(humanizeJoinError(StateError('token_failed')),
          humanizeJoinError(StateError('rtc_not_configured')));
    });

    test('auth_required 归 needsPasscode —— auth_scope 走的就是这个载荷', () {
      // join 越权(server/src/index.js:489 的 auth_scope)意味着
      // 「本连接没有这个圈子的口令」,该弹口令框。RoomController 为此
      // 构造 StateError('auth_required'),命中这一条。
      expect(classifyJoinError(StateError('auth_required')),
          JoinErrorKind.needsPasscode);
      expect(humanizeJoinError(StateError('auth_required')), contains('口令'));
    });

    test('进房总超时归 network —— 用现成的「网络不太稳」', () {
      // 看门狗超时用 TimeoutException,落到 network/timeout 那句
      // 「连了一会儿没连上,网络可能不太稳」,不需要新文案。
      expect(
        classifyJoinError(
            TimeoutException('join_timeout', const Duration(seconds: 25))),
        JoinErrorKind.network,
      );
      expect(
        humanizeJoinError(
            TimeoutException('join_timeout', const Duration(seconds: 25))),
        contains('网络'),
      );
    });

    test('这几条的文案都能被反查回原种类', () {
      // RoomController 只存 humanize 之后的句子,UI 靠 kindOfJoinMessage
      // 反查出种类来决定弹不弹口令框。正查反查必须闭环,
      // 否则「该弹的不弹」而且没有任何测试会红。
      for (final e in <Object>[
        StateError('token_failed'),
        StateError('rtc_not_configured'),
        StateError('auth_required'),
        TimeoutException('join_timeout', const Duration(seconds: 25)),
      ]) {
        expect(kindOfJoinMessage(humanizeJoinError(e)), classifyJoinError(e),
            reason: '$e 的正查与反查必须一致');
      }
    });
  });
}

void main() {
  _errorPayloadClassification();

  group('进房错误必须是人话', () {
    // 这一组是整个文件的存在理由:曾经的实现是 `'进房失败:$e'`,
    // 屏幕上真的出现过「ClientException with SocketException: Connection...」。
    test('任何异常都不得把原始 toString 泄露给用户', () {
      final List<Object> errors = <Object>[
        TimeoutException('connect', const Duration(seconds: 10)),
        const SocketException('Connection refused'),
        const SocketException('Failed host lookup: rtc.example.com'),
        const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
        Exception('ClientException with SocketException: Connection reset'),
        StateError('some internal state'),
        'auth_failed',
        4401,
      ];
      for (final Object e in errors) {
        final String msg = humanizeJoinError(e);
        expect(msg, isNotEmpty, reason: '$e 必须有话说');
        // 英文异常类名一律不许出现
        expect(msg, isNot(contains('Exception')), reason: '$e');
        expect(msg, isNot(contains('Error')), reason: '$e');
        expect(msg, isNot(contains('SocketException')), reason: '$e');
        // 长度可控:标题行放得下两行,不能再长
        expect(msg.length, lessThanOrEqualTo(60), reason: '$e 太长会撑爆布局');
      }
    });

    test('超时说的是「等一下再试」而不是协议细节', () {
      final String msg =
          humanizeJoinError(TimeoutException('x', const Duration(seconds: 5)));
      expect(msg, contains('网络'));
    });

    test('域名解析失败要提示检查服务器地址', () {
      final String msg = humanizeJoinError(
          const SocketException('Failed host lookup: rtc.example.com'));
      expect(msg, contains('地址'));
    });

    test('证书问题要单独说 —— 自建服务器最容易撞到', () {
      final String msg =
          humanizeJoinError(const HandshakeException('CERTIFICATE_VERIFY'));
      expect(msg, contains('证书'));
    });

    test('4401 要说口令不对,并指向设置', () {
      expect(humanizeJoinError('closed with 4401'), contains('口令'));
      expect(humanizeJoinError('auth_failed'), contains('口令'));
    });

    test('4429 要说明是频率限制,且给出等待时长', () {
      expect(humanizeJoinError('closed with 4429'), contains('5 分钟'));
    });

    test('完全未知的异常也有兜底,且不拼接原文', () {
      final String msg = humanizeJoinError(StateError('内部状态异常 xyz'));
      expect(msg, isNot(contains('xyz')));
      expect(msg, isNotEmpty);
    });
  });
}
