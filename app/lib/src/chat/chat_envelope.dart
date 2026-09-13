/// 聊天帧的「信封」编解码(设计.md §8.1 RTC 抽象层)。
///
/// 线格式 —— 混合二进制帧,而非纯 JSON:
/// ```text
/// [ 4 字节 大端 uint32 headerLength ]
/// [ headerLength 字节 UTF-8 JSON header ]
/// [ 余下全部字节 原始二进制 payload(可为空) ]
/// ```
/// 为什么不用 base64-in-JSON:base64 会把载荷撑大 +33%,
/// 在 15000 字节的单包预算下等于白扔三分之一带宽。
///
/// header 恒为带版本号的 JSON 对象,必含 `"v"`。两种形态:
///
/// 文字帧(payload 为空):
/// ```json
/// {"v":1,"t":"text","id":..,"sid":..,"sn":..,"cid":..,"ts":<epochMs>,"body":"..."}
/// ```
///
/// 图片分片帧(payload 为该分片的原始字节):
/// ```json
/// {"v":1,"t":"img","id":..,"sid":..,"sn":..,"cid":..,"ts":<epochMs>,
///  "seq":<int>,"n":<总片数>,"total":<总字节>,"w":<int?>,"h":<int?>,"mime":"image/png"}
/// ```
///
/// 本文件**刻意不依赖** `chat_limits.dart`:信封层只管结构,
/// 长度策略属于上层业务,耦合进来会让协议层随调参一起抖动。
/// 因此这里只做「缓冲越界」检查,不校验 `maxPacketBytes`。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 当前协议版本
const int chatProtocolVersion = 1;

/// 帧类型标签:文字
const String chatTypeText = 'text';

/// 帧类型标签:图片分片
const String chatTypeImage = 'img';

/// 编码一帧:4 字节大端长度前缀 + UTF-8 JSON header + 原始 payload。
///
/// [payload] 缺省为空,文字帧直接省略即可。
Uint8List encodeFrame(
  Map<String, dynamic> header, [
  List<int> payload = const <int>[],
]) {
  final Uint8List headerBytes = utf8.encode(jsonEncode(header));
  final int headerLength = headerBytes.length;
  final Uint8List frame = Uint8List(4 + headerLength + payload.length);
  // 长度前缀写大端:跨语言实现(将来若有 Web/后端旁路)读起来无歧义
  ByteData.sublistView(frame, 0, 4).setUint32(0, headerLength, Endian.big);
  frame.setRange(4, 4 + headerLength, headerBytes);
  if (payload.isNotEmpty) {
    frame.setRange(4 + headerLength, frame.length, payload);
  }
  return frame;
}

/// 解码结果的判定
enum ChatFrameStatus {
  /// 结构与版本都正常,可按 `t` 分发
  ok,

  /// 结构损坏(长度越界/非 UTF-8/非 JSON/非对象/缺 v),整帧丢弃
  invalid,

  /// 结构正常但版本号不是 [chatProtocolVersion],本端看不懂,应静默忽略
  unsupportedVersion,
}

/// 解码结果。永远是一个值对象,不承载异常。
class ChatFrame {
  /// 构造一个解码结果(通常由 [decodeFrame] 产出)
  const ChatFrame({
    required this.status,
    required this.header,
    required this.payload,
  });

  /// 结构/版本判定
  final ChatFrameStatus status;

  /// 解析出的 header;`invalid` 时为空 Map
  final Map<String, dynamic> header;

  /// 原始二进制载荷;`invalid` 或文字帧时为空
  final Uint8List payload;

  /// 是否可直接投递给上层
  bool get isOk => status == ChatFrameStatus.ok;

  /// 协议版本;缺失或非 int 时为 -1
  int get version {
    final Object? v = header['v'];
    return v is int ? v : -1;
  }

  /// 帧类型标签;缺失或非字符串时为空串
  String get type {
    final Object? t = header['t'];
    return t is String ? t : '';
  }
}

/// `invalid` 结果的共享实例。顶层 final 在 Dart 里是惰性初始化的,
/// 不会拖慢启动;共享一份省掉每次解码失败的无谓分配。
final ChatFrame _invalidFrame = ChatFrame(
  status: ChatFrameStatus.invalid,
  header: const <String, dynamic>{},
  payload: Uint8List(0),
);

/// 解码一帧。**永不抛异常**:任何结构问题一律返回
/// `status == ChatFrameStatus.invalid`。
///
/// 失败软着陆覆盖:长度不足 4 字节、headerLength 为 0、headerLength 超出
/// 实际缓冲、header 非合法 UTF-8、header 非合法 JSON、JSON 顶层不是对象
/// (如 `[1,2,3]` 或裸数字)、`v` 缺失或不是 int。
///
/// 前向兼容:
/// - 结构合法但 `v` 不等于 [chatProtocolVersion](例如 99)时,
///   header 与 payload 仍**完整填充**,只判定为
///   [ChatFrameStatus.unsupportedVersion],既不抛也不算 invalid;
/// - JSON 里多出来的未知键原样保留在 [ChatFrame.header],绝不致命;
/// - 未知的 `t` 值**不归信封层管**:仍返回 `ok`,由调用方自行忽略。
ChatFrame decodeFrame(List<int> bytes) {
  // 非 Uint8List 入参(如 jsonDecode 出来的普通 List<int>)一次性转换
  final Uint8List data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

  if (data.length < 4) return _invalidFrame;

  final int headerLength = ByteData.sublistView(
    data,
    0,
    4,
  ).getUint32(0, Endian.big);
  // 空 header 无意义;越界说明帧被截断或长度字段是伪造的
  if (headerLength == 0) return _invalidFrame;
  if (headerLength > data.length - 4) return _invalidFrame;

  // 这里一律用宽 catch 而非 `on FormatException`:本函数对外承诺「永不抛」,
  // 宽 catch 才是真正总是成立的契约,不赌解析器只抛某一种异常。
  final Map<String, dynamic> header;
  try {
    final String headerText = utf8.decode(
      Uint8List.sublistView(data, 4, 4 + headerLength),
      allowMalformed: false,
    );
    final Object? decoded = jsonDecode(headerText);
    // JSON 顶层必须是对象:数组/裸数字/裸字符串都判 invalid
    if (decoded is! Map<String, dynamic>) return _invalidFrame;
    header = decoded;
  } catch (_) {
    return _invalidFrame;
  }

  final Object? rawVersion = header['v'];
  if (rawVersion is! int) return _invalidFrame;

  // 用 fromList 把视图「拆下来」:sublistView 会持有整帧大缓冲的引用,
  // 若把它长期存进重组表,整个原始帧都无法被 GC 回收。
  final Uint8List payload = data.length > 4 + headerLength
      ? Uint8List.fromList(Uint8List.sublistView(data, 4 + headerLength))
      : Uint8List(0);

  return ChatFrame(
    status: rawVersion == chatProtocolVersion
        ? ChatFrameStatus.ok
        : ChatFrameStatus.unsupportedVersion,
    header: header,
    payload: payload,
  );
}

/// 组装文字帧的 header
Map<String, dynamic> buildTextHeader({
  required String id,
  required String senderId,
  required String senderName,
  required String circleId,
  required DateTime timestamp,
  required String body,
}) {
  return <String, dynamic>{
    'v': chatProtocolVersion,
    't': chatTypeText,
    'id': id,
    'sid': senderId,
    'sn': senderName,
    'cid': circleId,
    'ts': timestamp.millisecondsSinceEpoch,
    'body': body,
  };
}

/// 组装图片分片帧的 header。
///
/// [width]/[height] 为 null 时**整个键都不写入**(而不是写 `null`):
/// 少一个键就少几个字节,且接收方只需判 `containsKey`,省掉 null 语义分支。
Map<String, dynamic> buildImageChunkHeader({
  required String id,
  required String senderId,
  required String senderName,
  required String circleId,
  required DateTime timestamp,
  required int seq,
  required int totalChunks,
  required int totalBytes,
  int? width,
  int? height,
  String mime = 'image/png',
}) {
  final Map<String, dynamic> header = <String, dynamic>{
    'v': chatProtocolVersion,
    't': chatTypeImage,
    'id': id,
    'sid': senderId,
    'sn': senderName,
    'cid': circleId,
    'ts': timestamp.millisecondsSinceEpoch,
    'seq': seq,
    'n': totalChunks,
    'total': totalBytes,
    'mime': mime,
  };
  if (width != null) header['w'] = width;
  if (height != null) header['h'] = height;
  return header;
}
