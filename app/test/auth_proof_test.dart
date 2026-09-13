import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/auth/auth_credential.dart';

/// 独立实现一份 HMAC,不复用被测代码 —— 否则「自己跟自己对」证明不了任何事。
/// 这份写法直接照抄服务端 server/src/index.js:84 的语义:
///   crypto.createHmac('sha256', key).update(msg, 'utf8').digest('hex')
String referenceHmacHex(String key, String msg) =>
    Hmac(sha256, utf8.encode(key)).convert(utf8.encode(msg)).toString();

void main() {
  group('HMAC 证明推导', () {
    // 固定向量:nonce 取 32 位小写 hex,与服务端 randomBytes(16).toString('hex') 同形
    const nonce = '0123456789abcdef0123456789abcdef';
    const userId = 'u_liu';
    const circleId = 'home';
    const token = 'super-secret-token';
    const passcode = '炉灵开门';

    test('token 模式:msg 为 `nonce:userId`,与服务端 index.js:173 一致', () {
      // 服务端:const expect = hmacHex(AUTH_TOKEN, `${sessionNonce}:${userId}`);
      final expected = referenceHmacHex(token, '$nonce:$userId');
      final actual =
          AuthProof.token(nonce: nonce, userId: userId, token: token);

      expect(actual, expected);
      // 小写 hex,64 字符(SHA-256)
      expect(actual, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(actual.length, 64);
    });

    test('circle 模式:msg 为 `nonce:userId:circleId`,与服务端 index.js:183 一致', () {
      // 服务端:const expect = hmacHex(pass, `${sessionNonce}:${userId}:${circleId}`);
      final expected =
          referenceHmacHex(passcode, '$nonce:$userId:$circleId');
      final actual = AuthProof.circle(
        nonce: nonce,
        userId: userId,
        circleId: circleId,
        passcode: passcode,
      );

      expect(actual, expected);
      expect(actual, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('分隔符必须是半角冒号:换成 | 就对不上(服务端 interop 实测会 auth_failed)', () {
      final right =
          AuthProof.token(nonce: nonce, userId: userId, token: token);
      final wrong = referenceHmacHex(token, '$nonce|$userId');
      expect(right, isNot(wrong));
    });

    test('circleId 真的参与签名:给 home 签的证明不等于给 work 签的', () {
      final forHome = AuthProof.circle(
        nonce: nonce,
        userId: userId,
        circleId: 'home',
        passcode: passcode,
      );
      final forWork = AuthProof.circle(
        nonce: nonce,
        userId: userId,
        circleId: 'work',
        passcode: passcode,
      );
      expect(forHome, isNot(forWork));
    });

    test('nonce 变了证明就必须变:这正是禁止缓存证明的原因', () {
      const other = 'fedcba9876543210fedcba9876543210';
      final a = AuthProof.token(nonce: nonce, userId: userId, token: token);
      final b = AuthProof.token(nonce: other, userId: userId, token: token);
      expect(a, isNot(b));
    });

    test('UTF-8 中文口令按字节参与 HMAC,不退化成 code unit', () {
      // 「炉灵开门」是多字节字符;若实现误用 codeUnits 会与服务端(utf8)对不上
      final expected = referenceHmacHex(passcode, '$nonce:$userId:$circleId');
      final actual = AuthProof.circle(
        nonce: nonce,
        userId: userId,
        circleId: circleId,
        passcode: passcode,
      );
      expect(actual, expected);
      expect(utf8.encode(passcode).length, greaterThan(passcode.length));
    });
  });

  group('auth 对象组装', () {
    const nonce = '0123456789abcdef0123456789abcdef';

    test('token 模式产出 mode/proof,并回显 nonce', () {
      final obj = AuthProof.build(
        credential: const AuthCredential(mode: AuthMode.token, token: 't'),
        nonce: nonce,
        userId: 'u1',
      );
      expect(obj, isNotNull);
      expect(obj!['mode'], 'token');
      expect(obj['nonce'], nonce); // 回显必须与本连接的一致,否则服务端判 auth_failed
      expect(obj['proof'],
          AuthProof.token(nonce: nonce, userId: 'u1', token: 't'));
      expect(obj.containsKey('circleId'), isFalse);
    });

    test('circle 模式带上 circleId', () {
      final obj = AuthProof.build(
        credential: const AuthCredential(
            mode: AuthMode.circle, passcode: 'p', circleId: 'home'),
        nonce: nonce,
        userId: 'u1',
      );
      expect(obj!['mode'], 'circle');
      expect(obj['circleId'], 'home');
      expect(
        obj['proof'],
        AuthProof.circle(
            nonce: nonce, userId: 'u1', circleId: 'home', passcode: 'p'),
      );
    });

    test('none 模式不产出 auth 字段', () {
      expect(
        AuthProof.build(
            credential: AuthCredential.none, nonce: nonce, userId: 'u1'),
        isNull,
      );
    });

    test('凭据不全时返回 null,避免发出注定失败的 hello', () {
      expect(
        AuthProof.build(
          credential: const AuthCredential(mode: AuthMode.token, token: ''),
          nonce: nonce,
          userId: 'u1',
        ),
        isNull,
      );
      expect(
        AuthProof.build(
          credential: const AuthCredential(
              mode: AuthMode.circle, passcode: 'p', circleId: ''),
          nonce: nonce,
          userId: 'u1',
        ),
        isNull,
      );
    });
  });

  group('nonce 形态校验', () {
    test('32 位小写 hex 通过,其它一律拒绝', () {
      expect(AuthProof.isValidNonce('0123456789abcdef0123456789abcdef'), isTrue);
      expect(AuthProof.isValidNonce('0123456789ABCDEF0123456789ABCDEF'), isFalse);
      expect(AuthProof.isValidNonce('too-short'), isFalse);
      expect(AuthProof.isValidNonce(null), isFalse);
      expect(AuthProof.isValidNonce(''), isFalse);
    });
  });

  group('凭据值对象', () {
    test('相等性驱动「换了口令要重连」的判断', () {
      const a = AuthCredential(mode: AuthMode.token, token: 'x');
      const b = AuthCredential(mode: AuthMode.token, token: 'x');
      const c = AuthCredential(mode: AuthMode.token, token: 'y');
      expect(a, b);
      expect(a, isNot(c));
    });

    test('toString 绝不泄露明文密钥', () {
      const c = AuthCredential(mode: AuthMode.token, token: 'super-secret');
      expect(c.toString(), isNot(contains('super-secret')));
      expect(c.toString(), contains('已设置'));
    });
  });
}
