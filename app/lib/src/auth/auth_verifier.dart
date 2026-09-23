/// v2 鉴权的 verifier:`hex(Argon2id(口令, salt = UTF-8("lares-auth-v2:" + circleId)))`。
///
/// ## 为什么要慢
///
/// 注册圈的服务器**只存 verifier**,不存口令。verifier 若是一次 HMAC,
/// 拿到服务器磁盘(运维、备份、泄露)的人每秒能离线试上亿个口令,
/// 猜中口令就等于拿到 E2EE 密钥。换成 Argon2id,每猜一次都要付 64 MiB 的代价。
///
/// ## 为什么盐与 E2EE 不同
///
/// E2EE 的盐是 `sha256("lares-e2ee-v2:"+circleId)` 的前 16 字节(见 e2ee_key.dart)。
/// 这里用字面量 `lares-auth-v2:`+circleId 的 UTF-8。两者若相同,verifier 本身就是
/// E2EE 密钥 —— 交给服务器比存明文口令还糟。`auth_crosscheck_test` 断言二者不等。
///
/// ## 为什么用 UTF-8 而不是 codeUnits
///
/// 服务端 hash-wasm 把字符串按 UTF-8 编码;Dart 的 `codeUnits` 是 UTF-16 码元,
/// 中文口令两边会算出不同的字节。E2EE 那边用 codeUnits 是既成事实(只在客户端之间比),
/// 这里要跨语言对齐,必须是 UTF-8。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter/foundation.dart';
import 'package:hashlib/hashlib.dart' show Argon2, Argon2Type, Argon2Version;

import '../e2ee/e2ee_key.dart'
    show kArgon2Iterations, kArgon2KeyLength, kArgon2MemoryKiB, kArgon2Parallelism;
import '../net/secret_vault.dart';

const String kAuthVerifierSaltPrefix = 'lares-auth-v2:';

/// 同步派生。约 250ms(桌面),**UI 线程上别直接调**,走 [deriveAuthVerifierAsync]。
String deriveAuthVerifier({required String passcode, required String circleId}) {
  return Argon2(
    version: Argon2Version.v13,
    type: Argon2Type.argon2id,
    hashLength: kArgon2KeyLength,
    iterations: kArgon2Iterations,
    parallelism: kArgon2Parallelism,
    memorySizeKB: kArgon2MemoryKiB,
    salt: utf8.encode('$kAuthVerifierSaltPrefix$circleId'),
  ).convert(utf8.encode(passcode)).hex();
}

/// 后台 isolate 里算,不卡 UI。
Future<String> deriveAuthVerifierAsync({
  required String passcode,
  required String circleId,
}) =>
    compute(_deriveInIsolate, (passcode: passcode, circleId: circleId));

String _deriveInIsolate(({String passcode, String circleId}) a) =>
    deriveAuthVerifier(passcode: a.passcode, circleId: a.circleId);

typedef AuthVerifierDeriver = Future<String> Function({
  required String passcode,
  required String circleId,
});

/// 测试 / 默认用:同步算、包成 Future。在 fakeAsync 里只占一个微任务。
Future<String> deriveAuthVerifierInline({
  required String passcode,
  required String circleId,
}) async =>
    deriveAuthVerifier(passcode: passcode, circleId: circleId);

/// verifier 缓存:内存 + (可选)安全存储。
///
/// 为什么要缓存:每次重连都要一份证明,而证明 = HMAC(verifier, nonce…)。
/// 不缓存就是每次重连多付 250ms + 64 MiB —— 手机切网络时一分钟可能重连好几次。
///
/// 为什么按「口令指纹」存:口令一变 verifier 就失效。存储里记的是
/// `指纹:verifier`,读出来指纹对不上就当没有、重新算并覆盖 —— 换口令时
/// 不需要谁记得去清缓存,旧值自然作废。指纹是 HMAC(口令, 固定域),
/// 不可逆地短(16 hex),而它本来就和口令同住一个安全存储。
class AuthVerifierCache {
  AuthVerifierCache({SecretVault? vault, AuthVerifierDeriver? deriver})
      : _vault = vault,
        _derive = deriver ?? deriveAuthVerifierInline;

  final SecretVault? _vault;
  final AuthVerifierDeriver _derive;
  final Map<String, String> _mem = <String, String>{};
  final Map<String, Future<String>> _inflight = <String, Future<String>>{};

  static String _memKey(String circleId, String passcode) =>
      '$circleId\u0000${_fingerprint(circleId, passcode)}';

  static String _fingerprint(String circleId, String passcode) {
    final mac = c.Hmac(c.sha256, utf8.encode(passcode));
    return mac
        .convert(utf8.encode('lares-verifier-cache:$circleId'))
        .toString()
        .substring(0, 16);
  }

  /// 同步取:只看内存。命中就能当场算证明,不引入任何异步间隙。
  String? peek(String circleId, String passcode) =>
      _mem[_memKey(circleId, passcode)];

  /// 取或算。并发的同一请求合并成一次 Argon2。
  Future<String> get(String circleId, String passcode) {
    final mk = _memKey(circleId, passcode);
    final hit = _mem[mk];
    if (hit != null) return SynchronousFuture<String>(hit);
    // ⚠️ 回调必须是块体、不返回值:`() => _inflight.remove(mk)` 返回的恰好是
    // 这个 future 自己,whenComplete 会去等它 —— 自己等自己,永远不完成(实测踩过)。
    return _inflight[mk] ??=
        _load(circleId, passcode, mk).whenComplete(() {
      _inflight.remove(mk);
    });
  }

  Future<String> _load(String circleId, String passcode, String mk) async {
    final fp = _fingerprint(circleId, passcode);
    final vault = _vault;
    if (vault != null) {
      try {
        final raw = await vault.read(vaultKeyForVerifier(circleId));
        if (raw != null) {
          final i = raw.indexOf(':');
          if (i > 0 && raw.substring(0, i) == fp) {
            final v = raw.substring(i + 1);
            if (RegExp(r'^[0-9a-f]{64}$').hasMatch(v)) {
              _mem[mk] = v;
              return v;
            }
          }
        }
      } catch (e) {
        debugPrint('[lares] verifier 缓存读取失败,改为现算: $e');
      }
    }
    final v = await _derive(passcode: passcode, circleId: circleId);
    _mem[mk] = v;
    if (vault != null) {
      try {
        await vault.write(vaultKeyForVerifier(circleId), '$fp:$v');
      } catch (e) {
        debugPrint('[lares] verifier 缓存写入失败(下次重算即可): $e');
      }
    }
    return v;
  }

  /// 圈子被删 / 解散时清掉,不留悬空的派生物。
  Future<void> forget(String circleId) async {
    _mem.removeWhere((k, _) => k.startsWith('$circleId\u0000'));
    try {
      await _vault?.delete(vaultKeyForVerifier(circleId));
    } catch (_) {}
  }
}
