import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/auth/auth_credential.dart';

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
}
