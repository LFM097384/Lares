/// 把明文存储里的敏感值搬进安全存储。
///
/// ## 一条纪律:是**搬走**,不是**复制**
///
/// 只写新位置、不删旧位置,等于什么都没做 —— 攻击者照样从
/// `shared_preferences` 的明文文件里读。
///
/// 但顺序不能反:**必须写成功之后才删源**。先删后写的话,
/// 中途任何失败(存储不可用、进程被杀)都会把用户的口令彻底弄丢,
/// 而口令丢了意味着进不去圈子、E2EE 的圈子里的历史消息也解不开。
///
/// ## 迁移必须是幂等的
///
/// 它每次启动都会跑。已经搬过的不该重复搬,更不该因为源已经没了就报错。
library;

import 'package:flutter/foundation.dart';

import 'secret_vault.dart';

/// 一次迁移的结果,用来在日志里说清楚到底做了什么。
@immutable
class SecretMigrationReport {
  const SecretMigrationReport({
    required this.movedPasscodes,
    required this.movedToken,
    required this.skipped,
    required this.failed,
  });

  /// 搬走了几个圈口令
  final int movedPasscodes;

  /// 全局令牌有没有搬
  final bool movedToken;

  /// 因为已经在安全存储里而跳过的条数
  final int skipped;

  /// 搬失败的条数。**大于零时源不会被删** —— 宁可留着明文,
  /// 也不能让用户丢掉唯一的口令。
  final int failed;

  bool get didAnything => movedPasscodes > 0 || movedToken;

  @override
  String toString() => '迁移: 口令 $movedPasscodes 条, 令牌 $movedToken, '
      '跳过 $skipped, 失败 $failed';
}

/// 把一批明文凭据搬进 [vault]。
///
/// [readPlaintext] 给出当前明文里的东西,[clearPlaintext] 在**全部成功之后**
/// 才会被调用一次。两者都由调用方注入,这样这个函数不依赖
/// `shared_preferences`,可以直接在纯 VM 测试里驱动。
Future<SecretMigrationReport> migrateSecretsToVault({
  required SecretVault vault,
  required Map<String, String> plaintextPasscodes,
  required String plaintextToken,
  required Future<void> Function() clearPlaintext,
}) async {
  var moved = 0;
  var skipped = 0;
  var failed = 0;
  var movedToken = false;

  for (final e in plaintextPasscodes.entries) {
    if (e.value.isEmpty) continue;
    final key = vaultKeyForPasscode(e.key);
    try {
      // 已经在安全存储里就别再写一遍 —— 幂等。
      if (await vault.read(key) != null) {
        skipped++;
        continue;
      }
      await vault.write(key, e.value);
      // 写完立刻读回来核对。写入"成功返回"不等于"真的存进去了":
      // 部分 Android ROM 在 Keystore 异常时会静默吞掉写入。
      if (await vault.read(key) != e.value) {
        failed++;
        debugPrint('[lares] 口令 ${e.key} 写入安全存储后读回不一致');
        continue;
      }
      moved++;
    } catch (err) {
      failed++;
      debugPrint('[lares] 迁移口令 ${e.key} 失败: $err');
    }
  }

  if (plaintextToken.isNotEmpty) {
    try {
      if (await vault.read(kVaultKeyToken) != null) {
        skipped++;
      } else {
        await vault.write(kVaultKeyToken, plaintextToken);
        if (await vault.read(kVaultKeyToken) == plaintextToken) {
          movedToken = true;
        } else {
          failed++;
          debugPrint('[lares] 令牌写入安全存储后读回不一致');
        }
      }
    } catch (err) {
      failed++;
      debugPrint('[lares] 迁移令牌失败: $err');
    }
  }

  // ⚠️ 只有**一条都没失败**时才清明文。
  // 部分成功就清,等于把失败那几条永久弄丢。
  if (failed == 0 && (moved > 0 || movedToken)) {
    try {
      await clearPlaintext();
    } catch (err) {
      // 清不掉不是灾难(值已经安全存了一份),但要说出来。
      debugPrint('[lares] 清理明文失败,明文仍在原处: $err');
    }
  }

  return SecretMigrationReport(
    movedPasscodes: moved,
    movedToken: movedToken,
    skipped: skipped,
    failed: failed,
  );
}
