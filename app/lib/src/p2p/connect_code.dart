/// 连接码:把 WebRTC 的连接信息(SDP)编成一段可以手动传递的短文本。
///
/// ## 为什么需要它
///
/// 跨网络 P2P 必须先交换 SDP,而交换本身需要一个通道。
/// 通常这个通道是信令服务器 —— 但那就又依赖了别人的服务器。
///
/// 连接码把这一步**交还给用户**:生成一段文本,你用微信、短信、
/// 当面扫码……任何你已经有的渠道发给对方。整个过程零服务器。
///
/// ## 实测的体积
///
/// 一份含 6 条 ICE 候选的真实 SDP 约 1804 字节,
/// base64 后 2408 字节 —— 太长,没法手动传。
/// gzip 之后再 base64 只有 **688 字节**(29%),二维码放得下
/// (版本 40-L 上限 2953 字节),复制粘贴也不算离谱。
///
/// 所以压缩不是优化,是这个方案能不能成立的前提。
library;

import 'dart:convert';

import 'codec_io.dart' if (dart.library.js_interop) 'codec_web.dart';

/// 连接码的类型。一次握手要来回两次。
enum ConnectCodeKind {
  /// 发起方生成,交给对方
  offer,

  /// 应答方生成,交回给发起方
  answer,
}

/// 连接码格式版本。
///
/// 写进载荷而不是靠约定:两端版本不一致时要能**明确报错**,
/// 而不是解出一堆乱码再莫名其妙地连不上。
const int kConnectCodeVersion = 1;

/// 人眼可见的前缀,帮用户认出这是个 Lares 连接码
/// (而不是一段乱码或别的什么东西)。
const String kOfferPrefix = 'LARES-O1:';
const String kAnswerPrefix = 'LARES-A1:';

/// 解析失败的原因。做成枚举而不是抛异常:
/// 用户粘错东西是**常见路径**,不是异常情况,UI 要能说人话。
enum ConnectCodeError {
  /// 不是 Lares 连接码(前缀对不上)
  notLaresCode,

  /// 是 Lares 码,但版本不认识 —— 多半是对方 App 太新或太旧
  versionMismatch,

  /// 前缀对但内容坏了(传输中被截断、被输入法改了字符等)
  corrupted,

  /// 类型不对:比如该贴 answer 的地方贴了 offer
  wrongKind,
}

/// 解析结果。成功时 [sdp] 非空,失败时 [error] 非空。
class ConnectCodeResult {
  const ConnectCodeResult.ok(this.kind, this.sdp) : error = null;
  const ConnectCodeResult.fail(this.error)
      : kind = null,
        sdp = null;

  final ConnectCodeKind? kind;
  final String? sdp;
  final ConnectCodeError? error;

  bool get isOk => sdp != null;

  /// 给用户看的一句话。
  ///
  /// ⚠️ **未本地化的遗留路径。** 本地化后的文案在 UI 层
  /// (`ui/p2p_screen.dart` 的 `connectCodeErrorLabel`),按 [error] 查表。
  ///
  /// 这里之所以还留着中文:[P2PSession.failure] 是个 `String?`,
  /// 拿不到 [ConnectCodeError] 本身,UI 只收到一段已经拼好的文字。
  /// 要彻底去掉本 getter,得先让 P2PSession 把错误码原样带出来
  /// (加一个 `ConnectCodeError? codeError` 字段),再让 `_Status` 去查表。
  /// 那是 `p2p_session.dart` 的改动,不在本批次范围内。
  String get message => switch (error) {
        null => '',
        ConnectCodeError.notLaresCode => '这段文字不是 Lares 连接码,再确认一下?',
        ConnectCodeError.versionMismatch => '对方的 Lares 版本和你差太多,更新一下再试',
        ConnectCodeError.corrupted => '连接码不完整,可能复制时少了一截',
        ConnectCodeError.wrongKind => '贴反了 —— 这是发起码,该贴的是对方回给你的应答码',
      };
}

/// 把 SDP 编成连接码。
String encodeConnectCode(ConnectCodeKind kind, String sdp) {
  final payload = jsonEncode(<String, Object>{
    'v': kConnectCodeVersion,
    'sdp': sdp,
  });
  final packed = base64Url.encode(compressBytes(utf8.encode(payload)));
  return (kind == ConnectCodeKind.offer ? kOfferPrefix : kAnswerPrefix) +
      packed;
}

/// 解析连接码。[expect] 非空时会校验类型。
ConnectCodeResult decodeConnectCode(
  String input, {
  ConnectCodeKind? expect,
}) {
  // 用户从聊天软件复制过来常带首尾空白和换行,先收拾干净。
  // 特别是有些输入法会插入零宽字符,一并去掉。
  final text = input
      .trim()
      .replaceAll(RegExp(r'[\s\u200b-\u200f\ufeff]'), '');
  if (text.isEmpty) return const ConnectCodeResult.fail(ConnectCodeError.notLaresCode);

  final ConnectCodeKind kind;
  final String body;
  if (text.startsWith(kOfferPrefix)) {
    kind = ConnectCodeKind.offer;
    body = text.substring(kOfferPrefix.length);
  } else if (text.startsWith(kAnswerPrefix)) {
    kind = ConnectCodeKind.answer;
    body = text.substring(kAnswerPrefix.length);
  } else {
    return const ConnectCodeResult.fail(ConnectCodeError.notLaresCode);
  }

  if (expect != null && kind != expect) {
    return const ConnectCodeResult.fail(ConnectCodeError.wrongKind);
  }

  try {
    final raw = decompressBytes(base64Url.decode(body));
    final obj = jsonDecode(utf8.decode(raw));
    if (obj is! Map) {
      return const ConnectCodeResult.fail(ConnectCodeError.corrupted);
    }
    final v = obj['v'];
    if (v is! int) {
      return const ConnectCodeResult.fail(ConnectCodeError.corrupted);
    }
    if (v != kConnectCodeVersion) {
      return const ConnectCodeResult.fail(ConnectCodeError.versionMismatch);
    }
    final sdp = obj['sdp'];
    if (sdp is! String || sdp.isEmpty) {
      return const ConnectCodeResult.fail(ConnectCodeError.corrupted);
    }
    return ConnectCodeResult.ok(kind, sdp);
  } catch (_) {
    // base64 坏了、gzip 坏了、JSON 坏了 —— 对用户来说都是同一件事:
    // 这段码不完整。不必区分。
    return const ConnectCodeResult.fail(ConnectCodeError.corrupted);
  }
}
