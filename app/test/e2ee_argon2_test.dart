import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/e2ee/e2ee_key.dart';

/// Argon2id 派生的测试。
///
/// ⚠️ 这些用例真的会跑 Argon2(每次约 250ms),所以**刻意只保留必要的几条**。
/// 控制器层的测试用注入的假派生器,不走这里。
void main() {
  group('Argon2id 密钥派生', () {
    test('确定性:同口令同圈子,两次派生必须一致', () {
      final a = deriveCircleE2EEKeyV2(passcode: '我们的圈', circleId: 'home');
      final b = deriveCircleE2EEKeyV2(passcode: '我们的圈', circleId: 'home');
      expect(a, b);
    });

    test('同口令不同圈子 -> 不同密钥(复用口令的圈子之间互不解密)', () {
      final a = deriveCircleE2EEKeyV2(passcode: '同一个口令', circleId: 'c1');
      final b = deriveCircleE2EEKeyV2(passcode: '同一个口令', circleId: 'c2');
      expect(a, isNot(b));
    });

    test('不同口令同圈子 -> 不同密钥', () {
      final a = deriveCircleE2EEKeyV2(passcode: '口令甲', circleId: 'home');
      final b = deriveCircleE2EEKeyV2(passcode: '口令乙', circleId: 'home');
      expect(a, isNot(b));
    });

    test('密钥不等于口令本身,也不等于 v1 的 HMAC 派生', () {
      const pass = '一个口令';
      final v2 = deriveCircleE2EEKeyV2(passcode: pass, circleId: 'home');
      expect(v2, isNot(pass));
      // v1 与 v2 必须落在不同的密钥空间,否则升级时新老客户端
      // 会各自算出不同的密钥却都以为对 —— 症状是「连上了但听不见」。
      final v1 = deriveCircleE2EEKey(passcode: pass, circleId: 'home');
      expect(v2, isNot(v1));
    });

    test('输出是 64 位小写 hex —— 全 ASCII', () {
      // 这条不是格式洁癖:LiveKit 的 setSharedKey 内部用 codeUnits
      // 逐 UTF-16 码元截断,非 ASCII 会在各端截出不一致的字节。
      final key = deriveCircleE2EEKeyV2(
        passcode: '中文口令🔥带emoji',
        circleId: '中文圈子名',
      );
      expect(key.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(key), isTrue);
      for (final c in key.codeUnits) {
        expect(c, lessThan(128), reason: '必须全部是 ASCII');
      }
    });

    test('参数是密钥的一部分 —— 改了就解不开老圈子', () {
      // 这条测试锁住那三个常量。它们不是配置项:
      // 任何一个变化都会让所有既有圈子的密钥改变。
      // 实测确认过并行度也影响输出,所以「慢设备上降并行度」是不允许的。
      expect(kArgon2MemoryKiB, 64 * 1024);
      expect(kArgon2Iterations, 3);
      expect(kArgon2Parallelism, 1);
      expect(kArgon2KeyLength, 32);
    });

    test('异步版与同步版结果一致', () async {
      const pass = '口令';
      const circle = 'home';
      final sync = deriveCircleE2EEKeyV2(passcode: pass, circleId: circle);
      final async = await deriveCircleE2EEKeyAsync(
        passcode: pass,
        circleId: circle,
      );
      expect(async, sync);
    });
  });
}
