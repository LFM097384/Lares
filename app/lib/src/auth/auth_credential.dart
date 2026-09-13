import 'dart:convert';

import 'package:crypto/crypto.dart';

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

  /// 按凭据推导出 hello.auth 对象;none 模式返回 null(不带 auth 字段)。
  ///
  /// 每次连接都要用**当次** challenge 的 nonce 重算:nonce 一次性、60s 过期,
  /// 缓存证明去重连必然 auth_failed(服务端 interop 测试已实证)。
  static Map<String, dynamic>? build({
    required AuthCredential credential,
    required String nonce,
    required String userId,
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
        return {
          'mode': 'circle',
          'circleId': circleId,
          'nonce': nonce,
          'proof': circle(
            nonce: nonce,
            userId: userId,
            circleId: circleId,
            passcode: credential.passcode,
          ),
        };
    }
  }

  /// challenge.nonce 合法性:32 位小写 hex(服务端 randomBytes(16).toString('hex'))
  static bool isValidNonce(String? nonce) =>
      nonce != null && RegExp(r'^[0-9a-f]{32}$').hasMatch(nonce);
}
