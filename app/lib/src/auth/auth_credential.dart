import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'auth_verifier.dart';

/// 鉴权模式(与服务端 LARES_AUTH_MODE 一一对应)。
///
/// 服务端 `challenge.modes` 会广播它接受哪几种;UI 据此裁剪可选项,
/// 不给用户看服务器根本不收的模式。
enum AuthMode {
  /// 不鉴权(本地开发 / 内网);服务端 AUTH_REQUIRED=false
  none('none'),

  /// 全局共享令牌:一个口令走天下,不区分圈子
  token('token'),

  /// 按圈口令:证明的是「某个具体圈子」,该连接也被钉死在那个圈子
  circle('circle');

  const AuthMode(this.wire);

  /// 协议线上的字符串值
  final String wire;

  static AuthMode fromWire(String? v) => switch (v) {
        'token' => AuthMode.token,
        'circle' => AuthMode.circle,
        _ => AuthMode.none,
      };

  String get label => switch (this) {
        AuthMode.none => '不需要口令',
        AuthMode.token => '共享令牌',
        AuthMode.circle => '按圈口令',
      };
}

/// 一次连接要用到的凭据快照。
///
/// 故意做成不可变值对象:SignalingClient 在每条 challenge 到达时**重新取一份**,
/// 这样用户改口令后下一次重连自然生效,不会拿着旧密钥反复撞墙。
class AuthCredential {
  const AuthCredential({
    required this.mode,
    this.token = '',
    this.passcode = '',
    this.circleId,
  });

  static const none = AuthCredential(mode: AuthMode.none);

  final AuthMode mode;

  /// token 模式的共享令牌(对应服务端 LARES_AUTH_TOKEN)
  final String token;

  /// circle 模式的圈口令(对应服务端 passcodeFor(circleId))
  final String passcode;

  /// circle 模式要证明的圈子;token/none 模式无意义
  final String? circleId;

  /// 本凭据是否「填齐了」。没填齐就别连,省得白白消耗服务端的失败计数。
  bool get isComplete => switch (mode) {
        AuthMode.none => true,
        AuthMode.token => token.isNotEmpty,
        AuthMode.circle =>
          passcode.isNotEmpty && (circleId?.isNotEmpty ?? false),
      };

  AuthCredential copyWith({String? circleId}) => AuthCredential(
        mode: mode,
        token: token,
        passcode: passcode,
        circleId: circleId ?? this.circleId,
      );

  /// 凭据是否等价。用于判断「用户改了口令 → 需要带新凭据重连」。
  @override
  bool operator ==(Object other) =>
      other is AuthCredential &&
      other.mode == mode &&
      other.token == token &&
      other.passcode == passcode &&
      other.circleId == circleId;

  @override
  int get hashCode => Object.hash(mode, token, passcode, circleId);

  /// 调试输出绝不带明文密钥,只说「有没有」
  @override
  String toString() =>
      'AuthCredential(${mode.wire}, circle=$circleId, secret=${_secretOf(mode).isEmpty ? "空" : "已设置"})';

  String _secretOf(AuthMode m) =>
      m == AuthMode.circle ? passcode : (m == AuthMode.token ? token : '');
}

/// 挑战应答证明的推导(HMAC-SHA256,UTF-8,小写 hex)。
///
/// 与服务端 `server/src/index.js` 严格对齐:
///   `hmacHex(key, msg) = crypto.createHmac('sha256', key).update(msg,'utf8').digest('hex')`
///   token  模式:`hmacHex(AUTH_TOKEN, `${nonce}:${userId}`)`
///   circle 模式:`hmacHex(passcodeFor(circleId), `${nonce}:${userId}:${circleId}`)`
///
/// 分隔符是严格的半角冒号,一个字节都不能差(服务端用 timingSafeEqual 逐字节比)。
/// 纯 Dart、无插件通道,可直接单测。
abstract final class AuthProof {
  /// SHA-256(UTF-8) → 小写 hex。圈主钥匙登记时只报这个,与服务端 sha256Hex 一致。
  static String sha256Hex(String s) => sha256.convert(utf8.encode(s)).toString();

  /// 通用 HMAC-SHA256 → 小写 hex
  static String hmacHex(String key, String message) {
    final mac = Hmac(sha256, utf8.encode(key));
    return mac.convert(utf8.encode(message)).toString(); // Digest.toString() 即小写 hex
  }

  /// token 模式证明:msg = `${nonce}:${userId}`
  static String token({
    required String nonce,
    required String userId,
    required String token,
  }) =>
      hmacHex(token, '$nonce:$userId');

  /// circle 模式证明:msg = `${nonce}:${userId}:${circleId}`
  static String circle({
    required String nonce,
    required String userId,
    required String circleId,
    required String passcode,
  }) =>
      hmacHex(passcode, '$nonce:$userId:$circleId');

  /// v2 的 verifier = `hex(Argon2id(口令, "lares-auth-v2:"+circleId))`(同步、约 250ms)。
  ///
  /// 为什么要多这一层:注册圈的服务器**只存 verifier、不存口令**。
  /// 它用 Argon2 而不是一次 HMAC:服务器磁盘泄露时,离线猜口令每次都要付 64 MiB 的代价。
  /// 盐与 E2EE 密钥的盐不同,verifier 推不出媒体密钥。详见 auth_verifier.dart。
  ///
  /// ⚠️ 慢。信令层走 [AuthVerifierCache](isolate + 安全存储缓存),别在 UI 线程上直接调。
  static String verifierHex({required String passcode, required String circleId}) =>
      deriveAuthVerifier(passcode: passcode, circleId: circleId);

  /// circle 模式 v2 证明:`HMAC(verifier, "${nonce}:${userId}:${circleId}")`
  static String circleV2({
    required String nonce,
    required String userId,
    required String circleId,
    required String verifier,
  }) =>
      hmacHex(verifier, '$nonce:$userId:$circleId');

  /// 按凭据推导出 hello.auth 对象;none 模式返回 null(不带 auth 字段)。
  ///
  /// 每次连接都要用**当次** challenge 的 nonce 重算:nonce 一次性、60s 过期,
  /// 缓存证明去重连必然 auth_failed(服务端 interop 测试已实证)。
  ///
  /// circle 模式一律发 v2(`v:2`)。服务端对 env 圈(home/review)v1/v2 都收,
  /// 对注册圈只收 v2 —— 所以新客户端没理由再发 v1。
  /// [register]:这是本机新建、尚未在服务器登记的圈子 → 带上 verifier 与
  /// `ownerHash = sha256hex(ownerKey)` 请求登记(需同时给 [ownerKey])。
  /// [ownerKey]:本机持有圈主钥匙(本机生成)→ 带上,服务器回显 isOwner。
  static Map<String, dynamic>? build({
    required AuthCredential credential,
    required String nonce,
    required String userId,
    bool register = false,
    String? ownerKey,
    String? verifier,
  }) {
    switch (credential.mode) {
      case AuthMode.none:
        return null;
      case AuthMode.token:
        if (credential.token.isEmpty) return null;
        return {
          'mode': 'token',
          'nonce': nonce, // 回显 nonce:服务端会校验一致性,便于自检串线问题
          'proof': token(
            nonce: nonce,
            userId: userId,
            token: credential.token,
          ),
        };
      case AuthMode.circle:
        final circleId = credential.circleId ?? '';
        if (circleId.isEmpty || credential.passcode.isEmpty) return null;
        // 调用方通常已从缓存拿到 verifier;没给就当场算(慢,仅一次性路径如「测试连接」)。
        final v = verifier ??
            verifierHex(passcode: credential.passcode, circleId: circleId);
        return {
          'mode': 'circle',
          'v': 2,
          'circleId': circleId,
          'nonce': nonce,
          'proof': circleV2(
            nonce: nonce,
            userId: userId,
            circleId: circleId,
            verifier: v,
          ),
          // 登记只报钥匙的 sha256:明文从不离开本机。没钥匙就不登记 ——
          // 缺 ownerHash 的 register 服务器会回 register_invalid(终局 4400)。
          if (register && ownerKey != null && ownerKey.isNotEmpty)
            'register': {'verifier': v, 'ownerHash': sha256Hex(ownerKey)},
          // 登记时也带明文钥匙:服务器据此回显 isOwner,与普通登录走同一条判定。
          if (ownerKey != null && ownerKey.isNotEmpty) 'ownerKey': ownerKey,
        };
    }
  }

  /// challenge.nonce 合法性:32 位小写 hex(服务端 randomBytes(16).toString('hex'))
  static bool isValidNonce(String? nonce) =>
      nonce != null && RegExp(r'^[0-9a-f]{32}$').hasMatch(nonce);
}
