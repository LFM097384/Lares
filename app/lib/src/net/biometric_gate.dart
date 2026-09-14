/// 敏感操作前的本机身份验证(指纹 / 面容 / 系统 PIN)。
///
/// ## 它保护什么,不保护什么
///
/// 保护的是「别人拿起你解锁着的手机,翻出圈子口令」这个场景。
/// **不**保护离线攻击 —— 口令的真正防线是 [SecretVault] 那层系统安全存储,
/// 这里只是一道操作闸门。把两者搞混会高估它的作用。
///
/// ## 一条纪律:绝不能变成死锁
///
/// 设备可能根本没有生物识别、可能用户没录指纹、可能系统连 PIN 都没设。
/// 在那些情况下如果「验证失败 = 不给看口令」,用户就**永远拿不回自己的口令**。
/// 所以 [authenticate] 在「本机不具备验证能力」时返回 true(放行),
/// 只有在「有能力但验证没通过」时才返回 false。
///
/// 这个取舍是刻意的:这道闸门防的是顺手翻看,不是防有备而来的攻击者。
/// 为了防住后者而把前者的正常使用锁死,不划算。
library;

import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// 抽象出来是为了测试 —— `flutter test` 里没有平台通道,
/// 真调 local_auth 必然抛 MissingPluginException。
abstract interface class BiometricGate {
  /// 本机是否具备任何形式的本地验证能力(生物识别或系统 PIN/图案)。
  Future<bool> get isAvailable;

  /// 请求一次验证。[reason] 会显示在系统弹窗上,要写清楚**为什么**要验。
  ///
  /// 返回 true 表示放行。注意:本机不具备验证能力时也返回 true,见类注释。
  Future<bool> authenticate(String reason);
}

/// 生产实现。
class LocalAuthGate implements BiometricGate {
  LocalAuthGate([LocalAuthentication? auth])
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> get isAvailable async {
    try {
      // isDeviceSupported: 系统层面支不支持(有没有 PIN/生物识别硬件)
      // canCheckBiometrics: 有没有**已录入**的生物特征
      // 两者取或:只设了 PIN 没录指纹的设备也应该能用 PIN 验证。
      final supported = await _auth.isDeviceSupported();
      return supported;
    } catch (e) {
      debugPrint('[lares] 查询本机验证能力失败,视为不可用: $e');
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      if (!await isAvailable) {
        // 没有验证能力 —— 放行。否则用户永远拿不回自己的口令。
        debugPrint('[lares] 本机不支持本地验证,跳过');
        return true;
      }
      // 注意:local_auth 3.x 把参数拍平了,不再有 AuthenticationOptions。
      return await _auth.authenticate(
        localizedReason: reason,
        // 允许退回系统 PIN/图案:只录了 PIN 没录指纹的设备也要能用。
        biometricOnly: false,
        // 切后台再回来应当重新验,而不是沿用上次结果。
        persistAcrossBackgrounding: false,
      );
    } catch (e) {
      // 这里**不能**放行 —— 异常意味着「有能力但没验成」,
      // 与「根本没能力」是两回事。
      debugPrint('[lares] 本地验证失败: $e');
      return false;
    }
  }
}

/// 测试/降级用:永远放行。
class AlwaysOpenGate implements BiometricGate {
  const AlwaysOpenGate();

  @override
  Future<bool> get isAvailable async => false;

  @override
  Future<bool> authenticate(String reason) async => true;
}

/// 测试用:永远拒绝,用来验证调用方真的会挡住。
class AlwaysDeniedGate implements BiometricGate {
  const AlwaysDeniedGate();

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> authenticate(String reason) async => false;
}
