import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/auth/auth_credential.dart';
import 'package:lares_app/src/auth/auth_verifier.dart';
import 'package:lares_app/src/e2ee/e2ee_key.dart' show deriveCircleE2EEKeyV2;

/// 跨实现交叉核对:把 Dart 侧推导出的 proof,与 Node 侧
/// `server/test/auth_interop.mjs` 用**同样输入**算出的已知答案逐字节比对。
///
/// 为什么需要这个:客户端自测与服务端自测各自内部自洽,并不能证明两边互通。
/// 真正的互通只能靠「同一组输入、同一个期望输出」来钉死。
/// 下面的期望值由 Node 侧独立算出(见文件末注释的复算命令),
/// 任何一侧改了格式,这里都会立刻红。
void main() {
  // 固定输入 —— 与 Node 侧复算命令保持一致
  const nonce = '0123456789abcdef0123456789abcdef';
  const userId = 'u_test';
  const circleId = 'home';
  const token = 'shared-token';
  const passcode = 'circle-pass';

  group('与 Node 服务端的跨实现交叉核对', () {
    test('token 模式:Dart 推导 == Node 已知答案', () {
      // node -e "const{createHmac}=require('crypto');console.log(
      //   createHmac('sha256','shared-token')
      //     .update('0123456789abcdef0123456789abcdef:u_test').digest('hex'))"
      const expected =
          '6ed4cc720626ee12f6286bc0c100c397f8f37294b403928fb49019820afbab17';

      final actual = Hmac(sha256, utf8.encode(token))
          .convert(utf8.encode('$nonce:$userId'))
          .toString();

      // 先证明我们的实现与裸 HMAC 一致(排除封装层引入的偏差)
      expect(
        AuthProof.token(nonce: nonce, userId: userId, token: token),
        actual,
        reason: '封装层不应改变 HMAC 结果',
      );
      // 再与 Node 的已知答案比对
      expect(actual, expected,
          reason: 'Dart 与 Node 的 token 模式 HMAC 必须逐字节一致');
    });

    test('circle 模式:Dart 推导 == Node 已知答案', () {
      // node -e "const{createHmac}=require('crypto');console.log(
      //   createHmac('sha256','circle-pass')
      //     .update('0123456789abcdef0123456789abcdef:u_test:home').digest('hex'))"
      const expected =
          '000411e0e78515ff81351368034e35753da67465dbceb735063a6fc228f2c3d0';

      final actual = Hmac(sha256, utf8.encode(passcode))
          .convert(utf8.encode('$nonce:$userId:$circleId'))
          .toString();

      expect(
        AuthProof.circle(
            nonce: nonce,
            userId: userId,
            circleId: circleId,
            passcode: passcode),
        actual,
        reason: '封装层不应改变 HMAC 结果',
      );
      expect(actual, expected,
          reason: 'Dart 与 Node 的 circle 模式 HMAC 必须逐字节一致');
    });
  });

  // v2:verifier = hex(Argon2id(UTF-8 口令, salt = UTF-8("lares-auth-v2:"+circleId),
  // m=64MiB t=3 p=1 len=32 v1.3));proof = HMAC(key=verifier 的 hex 串, nonce:userId:circleId)。
  // 期望值由 Node(hash-wasm)独立算出,server/test/circle_registry.mjs 断言同一组值。
  group('v2(Argon2 verifier)与 Node 的交叉核对', () {
    test('env 圈 home:verifier 与 proof 逐字节一致', () {
      final v = deriveAuthVerifier(passcode: passcode, circleId: circleId);
      expect(v,
          'e2a3f817c8709b8ce38d5c605ae5e1b8934da36876d247fd78103b0e560ec683');
      expect(
        AuthProof.circleV2(
            nonce: nonce, userId: userId, circleId: circleId, verifier: v),
        'b446b3479a81e6bd9630b146f283ea16aae130bdc7930e28fd73fdf10c4f6dca',
      );
    });

    test('注册圈 c_…:verifier 与 proof 逐字节一致', () {
      const cid = 'c_abcdefghijklmnopqrstuvwxyz';
      final v = deriveAuthVerifier(
          passcode: 'correct-horse-battery-staple', circleId: cid);
      expect(v,
          '39b0bf40119e65e485309fdb411d78b9c0ce8b5b2bef94b171963006c8beffc9');
      expect(
        AuthProof.circleV2(
            nonce: nonce, userId: userId, circleId: cid, verifier: v),
        'dd598637d102f5082d253176f31f7bc35aa1a4fc35c24dbbd6d2442a713cd9d7',
      );
    });

    test('中文口令按 UTF-8 编码(不是 codeUnits),与 Node 一致', () {
      expect(
        deriveAuthVerifier(
            passcode: '口令测试', circleId: 'c_abcdefghijklmnopqrstuvwxyz'),
        '8a12053fef7de6de56cb5ab1ead068166bfbb415cdfd704794abfe46ee569434',
      );
    });

    test('⚠️ verifier ≠ E2EE 密钥(否则把 verifier 交给服务器就等于交出密钥)', () {
      for (final (p, cid) in [
        (passcode, circleId),
        ('correct-horse-battery-staple', 'c_abcdefghijklmnopqrstuvwxyz'),
      ]) {
        final v = deriveAuthVerifier(passcode: p, circleId: cid);
        final k = deriveCircleE2EEKeyV2(passcode: p, circleId: cid);
        expect(v, isNot(k));
      }
    });
  });
}
