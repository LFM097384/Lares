/// 隐名之约 v2:把本圈 E2EE 媒体密钥密封给隐名 agent 的临时 X25519 公钥。
/// 格式以 server/anonym-agent/SEALING.md 为准(逐字节一致);客户端说明见
/// docs/plans/chatham/client-sealing.md。
///
/// ```
/// eph        = X25519 临时密钥对(每次密封现生成)
/// shared     = X25519(eph.priv, agentPub)                               // 32 字节
/// key        = HKDF-SHA256(ikm = shared, salt = ephPub ‖ agentPub,
///                          info = "lares-anon-seal-v1:" + circleId, L = 32)
/// nonce      = 12 字节随机
/// ct‖tag     = AES-256-GCM(key, nonce, utf8(mediaKeyHex), aad = utf8(circleId))
/// sealed     = base64(0x01 ‖ ephPub(32) ‖ nonce(12) ‖ ct ‖ tag(16))   // 标准带填充 base64
/// ```
///
/// plaintext 是媒体密钥 **hex 字符串**(`e2eeKeyHex` 派生值,小写 hex)
/// 的 UTF-8 字节,不是口令,也不是 hex 解码后的字节。
///
/// 纯 Dart(`cryptography` 包),全平台一致。
library;

import 'dart:convert';
import 'dart:math';

import 'package:cryptography/dart.dart';
import 'package:cryptography/cryptography.dart';

const int kAnonSealVersion = 0x01;
const String kAnonSealInfoPrefix = 'lares-anon-seal-v1:';

/// 解析 agent 公钥:标准 / url base64(有无填充均可)或 64 位 hex。不是 32 字节 → null。
List<int>? parseX25519Pub(Object? v) {
  if (v is! String) return null;
  final String s = v.trim();
  if (s.isEmpty) return null;
  if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s)) {
    return [
      for (int i = 0; i < 64; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
    ];
  }
  try {
    String b = s.replaceAll('-', '+').replaceAll('_', '/');
    while (b.length % 4 != 0) {
      b += '=';
    }
    final List<int> out = base64.decode(b);
    return out.length == 32 ? out : null;
  } on FormatException {
    return null;
  }
}

Future<SecretKey> _deriveKey(
  SecretKey shared,
  List<int> ephPub,
  List<int> agentPub,
  String circleId,
) =>
    DartHkdf(hmac: DartHmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: <int>[...ephPub, ...agentPub],
      info: utf8.encode('$kAnonSealInfoPrefix$circleId'),
    );

/// 密封。[ephemeralSeed] / [nonce] 只给测试向量用;生产代码不传(用安全随机数)。
Future<String> anonSeal({
  required List<int> agentPub,
  required String plaintext,
  required String circleId,
  List<int>? ephemeralSeed,
  List<int>? nonce,
}) async {
  if (agentPub.length != 32) {
    throw ArgumentError('agentPub must be 32 bytes');
  }
  final Random rnd = Random.secure();
  final List<int> seed =
      ephemeralSeed ?? List<int>.generate(32, (_) => rnd.nextInt(256));
  final List<int> iv = nonce ?? List<int>.generate(12, (_) => rnd.nextInt(256));
  if (seed.length != 32 || iv.length != 12) {
    throw ArgumentError('seed must be 32 bytes, nonce 12 bytes');
  }
  final DartX25519 x = DartX25519();
  final SimpleKeyPair eph = await x.newKeyPairFromSeed(seed);
  final List<int> ephPub = (await eph.extractPublicKey()).bytes;
  final SecretKey shared = await x.sharedSecretKey(
    keyPair: eph,
    remotePublicKey: SimplePublicKey(agentPub, type: KeyPairType.x25519),
  );
  final SecretKey key = await _deriveKey(shared, ephPub, agentPub, circleId);
  final SecretBox box = await DartAesGcm.with256bits().encrypt(
    utf8.encode(plaintext),
    secretKey: key,
    nonce: iv,
    aad: utf8.encode(circleId),
  );
  return base64.encode(<int>[
    kAnonSealVersion,
    ...ephPub,
    ...iv,
    ...box.cipherText,
    ...box.mac.bytes,
  ]);
}

/// 解封(只给测试 / 自检用:客户端从不解封,agent 才解)。
Future<String> anonUnseal({
  required List<int> agentSeed,
  required String sealed,
  required String circleId,
}) async {
  final List<int> raw = base64.decode(sealed);
  if (raw.length < 1 + 32 + 12 + 16 + 1 || raw[0] != kAnonSealVersion) {
    throw const FormatException('unseal_failed');
  }
  final DartX25519 x = DartX25519();
  final SimpleKeyPair me = await x.newKeyPairFromSeed(agentSeed);
  final List<int> myPub = (await me.extractPublicKey()).bytes;
  final List<int> ephPub = raw.sublist(1, 33);
  final SecretKey shared = await x.sharedSecretKey(
    keyPair: me,
    remotePublicKey: SimplePublicKey(ephPub, type: KeyPairType.x25519),
  );
  final SecretKey key = await _deriveKey(shared, ephPub, myPub, circleId);
  final List<int> body = raw.sublist(45);
  final List<int> clear = await DartAesGcm.with256bits().decrypt(
    SecretBox(
      body.sublist(0, body.length - 16),
      nonce: raw.sublist(33, 45),
      mac: Mac(body.sublist(body.length - 16)),
    ),
    secretKey: key,
    aad: utf8.encode(circleId),
  );
  return utf8.decode(clear);
}

/// 由种子算 X25519 公钥(测试向量 / agent 侧对照用)。
Future<List<int>> x25519PubFromSeed(List<int> seed) async {
  final SimpleKeyPair kp = await DartX25519().newKeyPairFromSeed(seed);
  return (await kp.extractPublicKey()).bytes;
}
