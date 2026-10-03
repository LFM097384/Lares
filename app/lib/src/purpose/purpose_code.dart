/// 用途分享码(features-purpose-contract §3.5)。
///
/// `lares-purpose:` + base64url(gzip(UTF-8 JSON)),无填充。
/// 解压上限 64 KB(防炸弹),解出的 JSON ≤ 32 KB。
/// 服务端 `server/src/purpose.js` 有同一套编解码,两边用同一份夹具互测。
///
/// 不碰 dart:io:archive 在 Web 上自动换成纯 Dart 的 inflate。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

const String kPurposeCodePrefix = 'lares-purpose:';

/// 解码后 JSON 的字节上限。
const int kPurposeJsonMax = 32 * 1024;

/// 解压上限(防 gzip 炸弹)。
const int kPurposeInflateMax = 64 * 1024;

/// 分享码解不开的原因。
enum PurposeCodeErrorKind {
  /// 没有 `lares-purpose:` 前缀(也没在文字里找到)
  prefix,

  /// base64url 不合法
  base64,

  /// gzip 坏了
  gzip,

  /// 解压后超过 64 KB,或 JSON 超过 32 KB
  tooLarge,

  /// 不是 UTF-8 / 不是 JSON
  json,

  /// 是 JSON,但不是对象
  notObject,
}

class PurposeCodeException implements Exception {
  const PurposeCodeException(this.kind, [this.message]);
  final PurposeCodeErrorKind kind;
  final String? message;

  @override
  String toString() =>
      'PurposeCodeException(${kind.name}${message == null ? '' : ': $message'})';
}

/// 把用途 JSON 编成分享码。
String encodePurposeCode(Map<String, dynamic> purpose) {
  final bytes = utf8.encode(jsonEncode(purpose));
  final gz = const GZipEncoder().encodeBytes(bytes);
  return kPurposeCodePrefix + base64Url.encode(gz).replaceAll('=', '');
}

final RegExp _embedded = RegExp(r'lares-purpose:[A-Za-z0-9_-]+=*');

/// 从一段文字里找出分享码(粘贴时常带着「快用这个:…」之类的前后文)。
/// 找不到返回 null。
String? findPurposeCode(String text) => _embedded.firstMatch(text)?.group(0);

/// 解分享码。失败抛 [PurposeCodeException]。
///
/// 只解码,不校验用途结构(结构校验见 purpose_schema.dart)。
Map<String, dynamic> decodePurposeCode(String input) {
  var s = input.trim();
  if (!s.startsWith(kPurposeCodePrefix)) {
    final found = findPurposeCode(s);
    if (found == null) {
      throw const PurposeCodeException(PurposeCodeErrorKind.prefix);
    }
    s = found;
  }
  // 中间夹了换行 / 空格(聊天软件折行)也认
  // 带 = 填充的(别的实现编出来的)也认
  final body = s
      .substring(kPurposeCodePrefix.length)
      .replaceAll(RegExp(r'\s'), '')
      .replaceFirst(RegExp(r'=+$'), '');
  if (body.isEmpty ||
      body.length > kPurposeInflateMax * 2 ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(body)) {
    throw const PurposeCodeException(PurposeCodeErrorKind.base64);
  }
  final Uint8List gz;
  try {
    gz = base64Url.decode(base64Url.normalize(body));
  } on FormatException catch (e) {
    throw PurposeCodeException(PurposeCodeErrorKind.base64, e.message);
  }
  final raw = _gunzipCapped(gz);
  if (raw.length > kPurposeJsonMax) {
    throw const PurposeCodeException(PurposeCodeErrorKind.tooLarge);
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(const Utf8Decoder().convert(raw));
  } on FormatException catch (e) {
    throw PurposeCodeException(PurposeCodeErrorKind.json, e.message);
  }
  if (decoded is! Map) {
    throw const PurposeCodeException(PurposeCodeErrorKind.notObject);
  }
  return Map<String, dynamic>.from(decoded);
}

Uint8List _gunzipCapped(Uint8List gz) {
  if (gz.length < 18 || gz[0] != 0x1f || gz[1] != 0x8b) {
    throw const PurposeCodeException(PurposeCodeErrorKind.gzip);
  }
  final out = _CappedOutput(kPurposeInflateMax);
  bool ok;
  try {
    ok = const GZipDecoder().decodeStream(InputMemoryStream(gz), out);
  } on _TooLarge {
    throw const PurposeCodeException(PurposeCodeErrorKind.tooLarge);
  } catch (e) {
    throw PurposeCodeException(PurposeCodeErrorKind.gzip, '$e');
  }
  if (!ok) throw const PurposeCodeException(PurposeCodeErrorKind.gzip);
  return Uint8List.fromList(out.getBytes());
}

class _TooLarge implements Exception {
  const _TooLarge();
}

/// 写超过上限就抛 —— 解压在半路就停,不会先把炸弹整个展开。
class _CappedOutput extends OutputMemoryStream {
  _CappedOutput(this.cap) : super(size: 4096);
  final int cap;

  void _check(int add) {
    if (length + add > cap) throw const _TooLarge();
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }
}
