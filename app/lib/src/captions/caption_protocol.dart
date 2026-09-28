/// 实时字幕在 LiveKit data channel 上的线格式(topic = [kCaptionTopic])。
///
/// 三种消息,都是 UTF-8 JSON:
/// - `{t:'capreq', on:bool}`   我需要 / 不再需要字幕(广播;新人进房时单独补发给他)
/// - `{t:'capack', on:bool}`   有人需要时我会不会为他们转写(回应 capreq,或设置变化时广播)
/// - `{t:'cap', id, seq, text, final}` 一条字幕。`id` 是识别服务给的 item_id,
///   同一句话的 partial 以整句替换的方式不断更新,final 定稿。
///
/// 数据通道在圈子开了 E2EE 时随 `encryption:` 一起加密(见 LiveKitRtcService.join)。
library;

import 'dart:convert';
import 'dart:typed_data';

const String kCaptionTopic = 'lares.cap';

/// 单条字幕文本上限:防止对端灌超长串把 UI 撑爆。
const int kCaptionMaxTextLength = 2000;

sealed class CaptionMessage {
  const CaptionMessage();

  Map<String, Object?> toJson();

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  /// 解析一帧;格式不对返回 null(对端版本不同 / 恶意帧,一律静默丢弃)。
  static CaptionMessage? decode(List<int> bytes) {
    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(bytes));
    } on Object {
      return null;
    }
    if (raw is! Map) return null;
    switch (raw['t']) {
      case 'capreq':
        final on = raw['on'];
        return on is bool ? CapReq(on) : null;
      case 'capack':
        final on = raw['on'];
        return on is bool ? CapAck(on) : null;
      case 'cap':
        final id = raw['id'];
        final seq = raw['seq'];
        final text = raw['text'];
        final fin = raw['final'];
        if (id is! String || id.isEmpty || id.length > 200) return null;
        if (seq is! num || text is! String || fin is! bool) return null;
        final String clipped = text.length > kCaptionMaxTextLength
            ? text.substring(0, kCaptionMaxTextLength)
            : text;
        return Cap(id: id, seq: seq.toInt(), text: clipped, isFinal: fin);
    }
    return null;
  }
}

class CapReq extends CaptionMessage {
  const CapReq(this.on);
  final bool on;
  @override
  Map<String, Object?> toJson() => {'t': 'capreq', 'on': on};
}

class CapAck extends CaptionMessage {
  const CapAck(this.on);
  final bool on;
  @override
  Map<String, Object?> toJson() => {'t': 'capack', 'on': on};
}

class Cap extends CaptionMessage {
  const Cap({
    required this.id,
    required this.seq,
    required this.text,
    required this.isFinal,
  });
  final String id;
  final int seq;
  final String text;
  final bool isFinal;
  @override
  Map<String, Object?> toJson() =>
      {'t': 'cap', 'id': id, 'seq': seq, 'text': text, 'final': isFinal};
}

/// 只由语气词和标点组成的定稿不值得发:它们刷掉真正有内容的行,
/// 对看字幕的人毫无信息量(识别服务常把咳嗽、附和识别成「嗯。」)。
/// 空串、纯标点也算(没有任何可读内容)。
final RegExp _fillerOnly = RegExp(
  r'^[\s嗯对啊哦呃噢唔额，。！？、,.!?;；:：…~～\-—]*$',
);

bool isFillerOnly(String text) => _fillerOnly.hasMatch(text);
