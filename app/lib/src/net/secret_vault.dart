/// 敏感凭据的安全存储(圈口令 / 鉴权令牌)。
///
/// ## 为什么需要它
///
/// 这些值原本和普通设置一起存在 `shared_preferences` 里,而那在所有平台上
/// 都是**明文**的:Android 是 SharedPreferences XML、iOS 是 NSUserDefaults
/// plist、Windows 是本地文件。拿到设备文件系统就能直接读出来。
///
/// 更要紧的是:E2EE 的密钥由圈口令派生。口令泄露 = 密钥泄露 =
/// 端到端加密形同虚设。所以口令的存储强度是 E2EE 安全性的**上界**,
/// 用 Argon2id 把派生做得再硬,也架不住口令本身躺在明文文件里。
///
/// `flutter_secure_storage` 转交给操作系统的安全存储:
/// iOS/macOS Keychain、Android Keystore(EncryptedSharedPreferences)、
/// Windows DPAPI、Linux libsecret。这些是硬件或系统级保护。
///
/// ## 一条纪律:迁移必须**搬走**,不是**复制**
///
/// 从明文迁到安全存储时,必须把旧位置的值删掉。只写不删等于什么都没做 ——
/// 攻击者照样从旧位置读。这个类的 [migrateFrom] 会在写入成功后才删源,
/// 顺序不能反(先删后写,中途失败就把用户的口令弄丢了)。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 抽象出接口:测试注入内存实现,不碰真实 Keychain
/// (在 `flutter test` 里平台通道根本不存在,真调必然抛 MissingPluginException)。
abstract interface class SecretVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<Map<String, String>> readAll();
}

/// 生产实现:交给操作系统。
class PlatformSecretVault implements SecretVault {
  PlatformSecretVault([FlutterSecureStorage? storage])
      : _s = storage ??
            const FlutterSecureStorage(
              // Android:11.x 起默认就走加密存储,不再需要
              // encryptedSharedPreferences 开关(该参数已从 API 中移除)。
              // 保留 resetOnError 的默认值 true:部分 ROM 在系统升级后
              // 会让旧密钥失效,不重置的话之后每次读都抛异常、永远恢复不了。
              aOptions: AndroidOptions(),
              // iOS/macOS:不要 kSecAttrAccessibleAlways。
              // first_unlock_this_device = 开机首次解锁后可读,且**不进 iCloud 备份**,
              // 换机不会把口令带过去 —— 这正是我们想要的:新设备重新输一次。
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
              mOptions: MacOsOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final FlutterSecureStorage _s;

  @override
  Future<String?> read(String key) => _s.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _s.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _s.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => _s.readAll();
}

/// 内存实现。给测试用,也给「安全存储不可用」时兜底。
///
/// ⚠️ 它**不持久化**。兜底时的行为是「这次能用,重启就没了」,
/// 那比悄悄退回明文存储好 —— 后者会让用户以为自己受保护。
class InMemorySecretVault implements SecretVault {
  final Map<String, String> _m = <String, String>{};

  @override
  Future<String?> read(String key) async => _m[key];

  @override
  Future<void> write(String key, String value) async => _m[key] = value;

  @override
  Future<void> delete(String key) async => _m.remove(key);

  @override
  Future<Map<String, String>> readAll() async => Map<String, String>.from(_m);
}

/// 存 key 的前缀,避免和别的模块撞名。
const String kVaultPrefix = 'lares.secret.';

/// 圈口令的 key。
String vaultKeyForPasscode(String circleId) =>
    '${kVaultPrefix}passcode.$circleId';

/// 全局鉴权令牌的 key。
const String kVaultKeyToken = '${kVaultPrefix}token';

/// 试探安全存储在本设备上是否真的能用。
///
/// 为什么要试:Linux 上没装 libsecret、Android 某些定制 ROM 阉割了 Keystore、
/// Web 上根本没有系统级安全存储 —— 这些情况下插件会抛异常而不是返回 false。
/// 与其在第一次存口令时炸,不如启动时就问清楚。
Future<bool> probeSecretVault(SecretVault vault) async {
  const probeKey = '${kVaultPrefix}_probe';
  try {
    await vault.write(probeKey, 'ok');
    final v = await vault.read(probeKey);
    await vault.delete(probeKey);
    return v == 'ok';
  } catch (e) {
    debugPrint('[lares] 安全存储不可用,将退回内存存储: $e');
    return false;
  }
}
