/// E2EE 圈转写记录的密文格式(纯函数,无插件、无 IO)。
///
/// 严格按 docs/plans/transcript-bot-contract.md §4:
/// - key = HKDF-SHA256(ikm = hex 解码的圈 E2EE 共享密钥, salt = utf8(circleId),
///   info = utf8("lares-transcript-v1"), L = 32)
/// - AES-256-GCM,12 字节随机 nonce,AAD = utf8(circleId),tag 16 字节
/// - blob = base64(0x01 || nonce || ciphertext || tag)
/// - 明文 = UTF-8 JSON {id, uid, name, text, startedAt, ts}
///
/// 互通性由 test/fixtures/transcript_blob_vector.json(Node crypto 生成)守住。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// HKDF info,写死;换方案时升版本号(同时改 blob 版本字节)。
const String kTranscriptHkdfInfo = 'lares-transcript-v1';

/// blob 首字节:格式版本。
const int kTranscriptBlobVersion = 0x01;

const int _nonceLen = 12;
const int _tagLen = 16;

/// 解不开(密钥不对 / 被篡改 / 格式坏 / 版本不认)。
class TranscriptCryptoException implements Exception {
  TranscriptCryptoException(this.reason);
  final String reason;
  @override
  String toString() => 'TranscriptCryptoException($reason)';
}

/// 一条转写(明文载荷)。
class TranscriptPlain {
  const TranscriptPlain({
    required this.id,
    required this.uid,
    required this.name,
    required this.text,
    required this.startedAt,
    required this.ts,
  });

  final String id;
  final String uid;
  final String name;
  final String text;

  /// 毫秒时间戳
  final int startedAt;
  final int ts;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'uid': uid,
        'name': name,
        'text': text,
        'startedAt': startedAt,
        'ts': ts,
      };

  static TranscriptPlain? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], uid = j['uid'], name = j['name'], text = j['text'];
    final st = j['startedAt'], ts = j['ts'];
    if (id is! String || uid is! String || text is! String) return null;
    if (st is! num || ts is! num) return null;
    return TranscriptPlain(
      id: id,
      uid: uid,
      name: name is String ? name : uid,
      text: text,
      startedAt: st.toInt(),
      ts: ts.toInt(),
    );
  }
}

Uint8List _hexDecode(String hex) {
  final h = hex.trim();
  if (h.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(h)) {
    throw TranscriptCryptoException('bad_key_hex');
  }
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// 派生本圈转写密钥(32 字节)。
Uint8List deriveTranscriptKey({
  required String circleKeyHex,
  required String circleId,
}) {
  final ikm = _hexDecode(circleKeyHex);
  if (ikm.isEmpty) throw TranscriptCryptoException('bad_key_hex');
  final hkdf = HKDFKeyDerivator(SHA256Digest())
    ..init(HkdfParameters(
      ikm,
      32,
      Uint8List.fromList(utf8.encode(circleId)),
      Uint8List.fromList(utf8.encode(kTranscriptHkdfInfo)),
    ));
  final out = Uint8List(32);
  hkdf.deriveKey(null, 0, out, 0);
  return out;
}

Uint8List _randomNonce() {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(_nonceLen, (_) => r.nextInt(256)));
}

/// 用已派生好的 [key] 加密。[nonce] 只给测试向量用,生产必须留空(随机)。
String encryptTranscriptBlobWithKey({
  required Uint8List key,
  required String circleId,
  required String plaintext,
  Uint8List? nonce,
}) {
  final iv = nonce ?? _randomNonce();
  if (iv.length != _nonceLen) throw ArgumentError('nonce must be 12 bytes');
  final gcm = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(KeyParameter(key), _tagLen * 8, iv,
          Uint8List.fromList(utf8.encode(circleId))),
    );
  final ct = gcm.process(Uint8List.fromList(utf8.encode(plaintext)));
  final b = BytesBuilder(copy: false)
    ..addByte(kTranscriptBlobVersion)
    ..add(iv)
    ..add(ct);
  return base64.encode(b.toBytes());
}

/// 解密得到明文字符串;任何失败统一抛 [TranscriptCryptoException]。
String decryptTranscriptBlobWithKey({
  required Uint8List key,
  required String circleId,
  required String blob,
}) {
  final Uint8List raw;
  try {
    raw = base64.decode(blob);
  } on FormatException {
    throw TranscriptCryptoException('bad_base64');
  }
  if (raw.length < 1 + _nonceLen + _tagLen) {
    throw TranscriptCryptoException('too_short');
  }
  if (raw[0] != kTranscriptBlobVersion) {
    throw TranscriptCryptoException('bad_version');
  }
  final iv = Uint8List.sublistView(raw, 1, 1 + _nonceLen);
  final body = Uint8List.sublistView(raw, 1 + _nonceLen);
  final gcm = GCMBlockCipher(AESEngine())
    ..init(
      false,
      AEADParameters(KeyParameter(key), _tagLen * 8, iv,
          Uint8List.fromList(utf8.encode(circleId))),
    );
  final Uint8List pt;
  try {
    pt = gcm.process(body);
  } on Object {
    // pointycastle 在 tag 不符时抛 InvalidCipherTextException
    throw TranscriptCryptoException('auth_failed');
  }
  try {
    return utf8.decode(pt);
  } on FormatException {
    throw TranscriptCryptoException('bad_utf8');
  }
}

/// 便捷:从圈密钥 hex 直接加密一条明文载荷。
String encryptTranscriptLine({
  required String circleKeyHex,
  required String circleId,
  required TranscriptPlain line,
  Uint8List? nonce,
}) =>
    encryptTranscriptBlobWithKey(
      key: deriveTranscriptKey(circleKeyHex: circleKeyHex, circleId: circleId),
      circleId: circleId,
      plaintext: jsonEncode(line.toJson()),
      nonce: nonce,
    );

/// 便捷:解密并解析明文载荷;JSON 形状不对也抛 [TranscriptCryptoException]。
TranscriptPlain decryptTranscriptLine({
  required String circleKeyHex,
  required String circleId,
  required String blob,
}) {
  final s = decryptTranscriptBlobWithKey(
    key: deriveTranscriptKey(circleKeyHex: circleKeyHex, circleId: circleId),
    circleId: circleId,
    blob: blob,
  );
  final Object? j;
  try {
    j = jsonDecode(s);
  } on FormatException {
    throw TranscriptCryptoException('bad_json');
  }
  final p = TranscriptPlain.fromJson(j);
  if (p == null) throw TranscriptCryptoException('bad_shape');
  return p;
}
