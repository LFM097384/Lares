/// 实时字幕在 LiveKit data channel 上的线格式(topic = [kCaptionTopic])。
///
/// 三种消息,都是 UTF-8 JSON:
/// - `{t:'capreq', on:bool}`   我需要 / 不再需要字幕(广播;新人进房时单独补发给他)
/// - `{t:'capack', on:bool}`   有人需要时我会不会为他们转写(回应 capreq,或设置变化时广播)
/// - `{t:'cap', id, seq, text, final}` 一条字幕(广播)。`id` 是识别服务给的 item_id,
///   同一句话的 partial 以整句替换的方式不断更新,final 定稿。
///   服务器代机器人发的帧另带 `bot:{id,name}`,只在没有 participant 时才认。
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
        CaptionBot? bot;
        if (raw.containsKey('bot')) {
          bot = CaptionBot.fromJson(raw['bot']);
          if (bot == null) return null; // 有 bot 字段却不成形:整帧丢弃
        }
        return Cap(
            id: id, seq: seq.toInt(), text: clipped, isFinal: fin, bot: bot);
    }
    return null;
  }
}

/// 服务器代机器人发的字幕帧里的 `bot:{id,name}`。
class CaptionBot {
  const CaptionBot({required this.id, required this.name});
  final String id;
  final String name;

  static CaptionBot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || id.isEmpty || id.length > 200) return null;
    if (name is! String) return null;
    final String n = name.length > 64 ? name.substring(0, 64) : name;
    return CaptionBot(id: id, name: n);
  }

  Map<String, Object?> toJson() => {'id': id, 'name': name};
}

/// 一帧入站字幕消息的归属结果。
class CaptionAttribution {
  const CaptionAttribution({
    required this.identity,
    required this.message,
    this.botName,
  });

  /// 真人 = LiveKit identity;机器人 = `bot:<tokenId>`。
  final String identity;
  final CaptionMessage message;

  /// 机器人名字(仅机器人帧)。
  final String? botName;

  bool get isBot => botName != null;
}

/// 决定一帧字幕数据认不认、算谁的(纯函数,见 transcript-bot-contract §1)。
///
/// - [sender] 为 null / 空 = 没有 participant(只有服务器经 RoomService.SendData
///   才能发出这种帧):只认带 `bot` 的 `cap`,归属到 `bot:<id>`。
/// - 有 participant 的帧带 `bot` 字段 → 伪造,整帧丢弃。
/// - 自己发的(回环)丢弃。
CaptionAttribution? attributeCaptionFrame({
  required String? sender,
  required List<int> bytes,
  String? localIdentity,
}) {
  final CaptionMessage? m = CaptionMessage.decode(bytes);
  if (m == null) return null;
  if (sender == null || sender.isEmpty) {
    if (m is Cap && m.bot != null) {
      return CaptionAttribution(
        identity: 'bot:${m.bot!.id}',
        message: m,
        botName: m.bot!.name,
      );
    }
    return null;
  }
  if (sender == localIdentity) return null;
  if (sender.startsWith('bot:')) return null;
  if (m is Cap && m.bot != null) return null;
  return CaptionAttribution(identity: sender, message: m);
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
    this.bot,
  });
  final String id;
  final int seq;
  final String text;
  final bool isFinal;

  /// 只有服务器代发的机器人字幕带(客户端永不发)。
  final CaptionBot? bot;
  @override
  Map<String, Object?> toJson() => {
        't': 'cap',
        'id': id,
        'seq': seq,
        'text': text,
        'final': isFinal,
        if (bot != null) 'bot': bot!.toJson(),
      };
}

/// 只由语气词和标点组成的定稿不值得发:它们刷掉真正有内容的行,
/// 对看字幕的人毫无信息量(识别服务常把咳嗽、附和识别成「嗯。」)。
/// 空串、纯标点也算(没有任何可读内容)。
final RegExp _fillerOnly = RegExp(
  r'^[\s嗯对啊哦呃噢唔额，。！？、,.!?;；:：…~～\-—]*$',
);

bool isFillerOnly(String text) => _fillerOnly.hasMatch(text);
