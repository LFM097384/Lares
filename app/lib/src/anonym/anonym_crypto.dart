/// 隐名之约的签名原语:规范 JSON、每场一次性的 Ed25519 密钥、nonce。
///
/// ## 规范化(必须与 server/anonym-agent/core/crypto.mjs 的 `approvalMessage` 逐字节一致)
///
/// 放行签名的消息是下面这个对象的**规范 JSON** 的 UTF-8 字节:
///
/// ```json
/// {"draftHash":"…","draftId":"…","nonce":"…","sid":"…"}
/// ```
///
/// - 对象键按 UTF-16 码元字典序递归排序(= JS `Array.prototype.sort()` 默认序;
///   这四个键都是 ASCII,结果固定为 draftHash, draftId, nonce, sid);
/// - 无任何空白;数组保持原序;值为 null 的键**保留**(JS 只省略 undefined —— 我们从不传 null);
/// - 字符串转义与 `JSON.stringify` 相同。Dart 的 [jsonEncode] 对 `"` `\` 与控制字符的
///   转义和 JS 一致,非 ASCII 字符原样输出(不转成 \uXXXX),与 JS 一致。
///   唯一已知差异是孤立代理项(lone surrogate):JS 输出 `\udXXX`,Dart 原样输出 ——
///   协议字段(sid / draftId / draftHash / nonce)都是 ASCII,不会碰到。
/// - 签名:Ed25519(RFC 8032,纯 Ed25519,无预哈希无 context),64 字节;
///   `sig` 与 `pubKey` 用**标准带填充 base64**(服务器两种 base64 都收)。
/// - `pubKey` 是 32 字节原始公钥(不是 SPKI/PEM)。
/// - `nonce`:16 字节 `Random.secure()` 随机数,base64url **无填充**(22 个字符)。
///   每次放行重新生成;服务器对同一 nonce 重放拒收。
///
/// 测试向量见 docs/plans/chatham/client-canonicalisation.md 与
/// test/anonym/anonym_crypto_test.dart。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

/// 递归按键排序的规范 JSON(见库注释)。
String canonicalJson(Object? value) {
  if (value is Map) {
    final List<String> keys = value.keys.map((k) => k.toString()).toList()
      ..sort();
    final StringBuffer b = StringBuffer('{');
    for (int i = 0; i < keys.length; i++) {
      if (i > 0) b.write(',');
      b
        ..write(jsonEncode(keys[i]))
        ..write(':')
        ..write(canonicalJson(value[keys[i]]));
    }
    b.write('}');
    return b.toString();
  }
  if (value is List) {
    return '[${value.map(canonicalJson).join(',')}]';
  }
  if (value is double && !value.isFinite) {
    throw ArgumentError('canonicalJson: non-finite number');
  }
  return jsonEncode(value);
}

/// 放行时签的那串字符串。
String approvalMessage({
  required String sid,
  required String draftId,
  required String draftHash,
  required String nonce,
}) => canonicalJson(<String, String>{
  'sid': sid,
  'draftId': draftId,
  'draftHash': draftHash,
  'nonce': nonce,
});

/// 16 字节安全随机数,base64url 无填充。
String newNonce([Random? random]) {
  final Random r = random ?? Random.secure();
  final Uint8List bytes = Uint8List.fromList(
    List<int>.generate(16, (_) => r.nextInt(256)),
  );
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// 一场隐名之约的一次性密钥。只在内存里;[wipe] 后不可再用。
class AnonymKeys {
  AnonymKeys._(this._private, this._public);

  /// 新的随机密钥(Random.secure)。
  factory AnonymKeys.generate() {
    final ed.KeyPair kp = ed.generateKey();
    return AnonymKeys._(
      Uint8List.fromList(kp.privateKey.bytes),
      Uint8List.fromList(kp.publicKey.bytes),
    );
  }

  /// 由 32 字节种子确定性派生(RFC 8032 私钥)。仅测试 / 测试向量用。
  factory AnonymKeys.fromSeed(List<int> seed) {
    final ed.PrivateKey pk = ed.newKeyFromSeed(Uint8List.fromList(seed));
    final Uint8List priv = Uint8List.fromList(pk.bytes);
    return AnonymKeys._(priv, Uint8List.fromList(priv.sublist(32, 64)));
  }

  Uint8List? _private;
  final Uint8List _public;

  bool get wiped => _private == null;

  /// 32 字节原始公钥的标准 base64。
  String get pubKeyB64 => base64.encode(_public);

  /// 签 [message] 的 UTF-8 字节,返回标准 base64 签名。
  String sign(String message) {
    final Uint8List? p = _private;
    if (p == null) throw StateError('AnonymKeys wiped');
    final Uint8List sig = ed.sign(
      ed.PrivateKey(p),
      Uint8List.fromList(utf8.encode(message)),
    );
    return base64.encode(sig);
  }

  /// 把私钥字节清零后丢掉。
  void wipe() {
    final Uint8List? p = _private;
    if (p != null) p.fillRange(0, p.length, 0);
    _private = null;
  }
}

/// 校验(测试 / 自检用)。[pubKeyB64]、[sigB64] 接受标准或 url 安全 base64。
bool verifyApproval(String pubKeyB64, String message, String sigB64) {
  try {
    final Uint8List pub = _b64(pubKeyB64);
    final Uint8List sig = _b64(sigB64);
    if (pub.length != 32 || sig.length != 64) return false;
    return ed.verify(
      ed.PublicKey(pub),
      Uint8List.fromList(utf8.encode(message)),
      sig,
    );
  } catch (_) {
    return false;
  }
}

Uint8List _b64(String s) {
  String t = s.replaceAll('-', '+').replaceAll('_', '/');
  t += '=' * ((4 - t.length % 4) % 4);
  return base64.decode(t);
}
