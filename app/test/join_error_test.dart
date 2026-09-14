import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/state/join_error.dart';

void main() {
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
