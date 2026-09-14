import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/net/secret_migration.dart';
import 'package:lares_app/src/net/secret_vault.dart';

void main() {
  group('明文 -> 安全存储的迁移', () {
    test('搬完之后源被清掉 —— 只复制不删等于没做', () async {
      final vault = InMemorySecretVault();
      var cleared = false;
      final r = await migrateSecretsToVault(
        vault: vault,
        plaintextPasscodes: {'home': 'p1', 'work': 'p2'},
        plaintextToken: 'tok',
        clearPlaintext: () async => cleared = true,
      );
      expect(r.movedPasscodes, 2);
      expect(r.movedToken, isTrue);
      expect(r.failed, 0);
      expect(cleared, isTrue, reason: '源必须被清掉');
      expect(await vault.read(vaultKeyForPasscode('home')), 'p1');
      expect(await vault.read(kVaultKeyToken), 'tok');
    });

    test('幂等:再跑一次只跳过,不重复搬', () async {
      final vault = InMemorySecretVault();
      await migrateSecretsToVault(
        vault: vault,
        plaintextPasscodes: {'home': 'p1'},
        plaintextToken: '',
        clearPlaintext: () async {},
      );
      final r2 = await migrateSecretsToVault(
        vault: vault,
        plaintextPasscodes: {'home': 'p1'},
        plaintextToken: '',
        clearPlaintext: () async {},
      );
      expect(r2.movedPasscodes, 0);
      expect(r2.skipped, 1);
      expect(r2.failed, 0);
    });

    test('⚠️ 部分失败时绝不清源 —— 否则失败那几条永久丢失', () async {
      final vault = _FlakyVault(failOn: 'work');
      var cleared = false;
      final r = await migrateSecretsToVault(
        vault: vault,
        plaintextPasscodes: {'home': 'p1', 'work': 'p2'},
        plaintextToken: '',
        clearPlaintext: () async => cleared = true,
      );
      expect(r.failed, greaterThan(0));
      expect(cleared, isFalse, reason: '有失败就必须保留明文,宁可不安全也不能丢');
    });

    test('写入后读回不一致 -> 记为失败,不当成功', () async {
      // 模拟部分 Android ROM 在 Keystore 异常时静默吞掉写入
      final vault = _SilentlyDroppingVault();
      var cleared = false;
      final r = await migrateSecretsToVault(
        vault: vault,
        plaintextPasscodes: {'home': 'p1'},
        plaintextToken: '',
        clearPlaintext: () async => cleared = true,
      );
      expect(r.movedPasscodes, 0);
      expect(r.failed, 1, reason: '写了读不回来必须算失败');
      expect(cleared, isFalse);
    });

    test('没有任何东西可搬时,不去碰源', () async {
      final vault = InMemorySecretVault();
      var cleared = false;
      final r = await migrateSecretsToVault(
        vault: vault,
        plaintextPasscodes: const {},
        plaintextToken: '',
        clearPlaintext: () async => cleared = true,
      );
      expect(r.didAnything, isFalse);
      expect(cleared, isFalse, reason: '无事可做就别动源');
    });

    test('空口令被忽略,不会在安全存储里留下空值', () async {
      final vault = InMemorySecretVault();
      final r = await migrateSecretsToVault(
        vault: vault,
        plaintextPasscodes: {'home': '', 'work': 'p2'},
        plaintextToken: '',
        clearPlaintext: () async {},
      );
      expect(r.movedPasscodes, 1);
      expect(await vault.read(vaultKeyForPasscode('home')), isNull);
    });
  });
}

/// 对某个特定圈子的写入抛异常。
class _FlakyVault extends InMemorySecretVault {
  _FlakyVault({required this.failOn});
  final String failOn;

  @override
  Future<void> write(String key, String value) async {
    if (key.contains(failOn)) throw StateError('模拟写入失败');
    return super.write(key, value);
  }
}

/// 写入"成功返回"但实际什么都没存 —— 静默吞掉。
class _SilentlyDroppingVault extends InMemorySecretVault {
  @override
  Future<void> write(String key, String value) async {
    // 假装写了
  }
}
