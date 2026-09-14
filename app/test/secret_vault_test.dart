import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/net/biometric_gate.dart';
import 'package:lares_app/src/net/secret_vault.dart';

void main() {
  group('SecretVault', () {
    test('读写删的基本契约', () async {
      final v = InMemorySecretVault();
      expect(await v.read('k'), isNull);
      await v.write('k', 'secret');
      expect(await v.read('k'), 'secret');
      await v.delete('k');
      expect(await v.read('k'), isNull);
    });

    test('key 命名按圈子隔离,且带统一前缀', () {
      final a = vaultKeyForPasscode('home');
      final b = vaultKeyForPasscode('work');
      expect(a, isNot(b), reason: '不同圈子不能撞 key');
      expect(a, startsWith(kVaultPrefix));
      expect(kVaultKeyToken, startsWith(kVaultPrefix));
      // 令牌与任何圈口令都不能撞
      expect(a, isNot(kVaultKeyToken));
    });

    test('探针在可用时返回 true,且不留下垃圾键', () async {
      final v = InMemorySecretVault();
      expect(await probeSecretVault(v), isTrue);
      // 探测用的那个 key 必须被清掉,不能污染 readAll()
      expect((await v.readAll()).keys, isEmpty);
    });

    test('探针在存储抛异常时返回 false 而不是崩掉', () async {
      expect(await probeSecretVault(_BrokenVault()), isFalse);
    });
  });

  group('BiometricGate', () {
    test('没有验证能力时放行 —— 绝不能让用户拿不回自己的口令', () async {
      const g = AlwaysOpenGate();
      expect(await g.isAvailable, isFalse);
      expect(await g.authenticate('看口令'), isTrue,
          reason: '不具备验证能力 = 放行,否则是死锁');
    });

    test('有能力但没验过时拒绝', () async {
      const g = AlwaysDeniedGate();
      expect(await g.isAvailable, isTrue);
      expect(await g.authenticate('看口令'), isFalse);
    });
  });
}

/// 模拟「平台不支持安全存储」:每个操作都抛。
class _BrokenVault implements SecretVault {
  @override
  Future<String?> read(String key) async => throw UnimplementedError();
  @override
  Future<void> write(String key, String value) async =>
      throw UnimplementedError();
  @override
  Future<void> delete(String key) async => throw UnimplementedError();
  @override
  Future<Map<String, String>> readAll() async => throw UnimplementedError();
}
