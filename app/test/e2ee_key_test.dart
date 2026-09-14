import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/auth/auth_credential.dart';
import 'package:lares_app/src/e2ee/e2ee_key.dart';

void main() {
  group('E2EE 密钥派生', () {
    test('确定性:同样口令 + 同样圈子 -> 同样密钥', () {
      final a = deriveCircleE2EEKey(passcode: '开门吧芝麻', circleId: 'home');
      final b = deriveCircleE2EEKey(passcode: '开门吧芝麻', circleId: 'home');
      expect(a, b);
      // 两端派生不出同一个密钥 = 互相听不见,所以这条是功能正确性底线
      expect(a.isNotEmpty, isTrue);
    });

    test('不同口令 -> 不同密钥', () {
      final a = deriveCircleE2EEKey(passcode: 'passcode-a', circleId: 'home');
      final b = deriveCircleE2EEKey(passcode: 'passcode-b', circleId: 'home');
      expect(a, isNot(b));
    });

    test('同一口令、不同圈子 -> 不同密钥(口令复用也不串圈)', () {
      final a = deriveCircleE2EEKey(passcode: 'same', circleId: 'home');
      final b = deriveCircleE2EEKey(passcode: 'same', circleId: 'work');
      expect(a, isNot(b));
    });

    test('派生结果 != 口令本身(绝不把口令直接当密钥)', () {
      const pass = 'super-secret-passcode';
      final key = deriveCircleE2EEKey(passcode: pass, circleId: 'home');
      expect(key, isNot(pass));
      expect(key.contains(pass), isFalse);
    });

    test('输出是 64 位小写 hex —— 全 ASCII,五端 codeUnits 一致', () {
      // LiveKit 的 setSharedKey 内部做 key.codeUnits(逐 UTF-16 码元截断)。
      // 只要出现非 ASCII 字符,各端截出来的字节就可能不一样。
      final key = deriveCircleE2EEKey(passcode: '中文口令😀', circleId: '圈子');
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(key), isTrue);
      for (final unit in key.codeUnits) {
        expect(unit, lessThan(128));
      }
    });

    test('与服务端鉴权证明在密码学上分离', () {
      const pass = 'shared-passcode';
      const circleId = 'home';
      // 服务端 circle 模式的证明:hmacHex(passcode, "$nonce:$userId:$circleId")
      const nonce = '0123456789abcdef0123456789abcdef';
      final proof = AuthProof.circle(
        nonce: nonce,
        userId: 'u1',
        circleId: circleId,
        passcode: pass,
      );
      final key = deriveCircleE2EEKey(passcode: pass, circleId: circleId);
      expect(key, isNot(proof));

      // 更强的一条:认证侧消息永远以 32 位 hex nonce 开头,
      // 派生侧永远以字面量前缀开头 —— 消息空间不可能相撞。
      expect(kE2EEKeyDomain.startsWith(RegExp(r'^[0-9a-f]{32}')), isFalse);
      expect(AuthProof.isValidNonce(kE2EEKeyDomain), isFalse);
    });

    test('空口令不许派生(否则得到一个人人可算的常量)', () {
      expect(canDeriveCircleKey(''), isFalse);
      expect(canDeriveCircleKey('x'), isTrue);
    });
  });
}
