/// 转写记录(归档)的出口:本人每一句**定稿**字幕都交给这里(partial 永不进来)。
///
/// 契约见 docs/plans/transcript-bot-contract.md §3/§4:
/// - 非 E2EE 圈 → [SignalingTranscriptSink]:信令发 `transcript_append`。
/// - E2EE 圈 → 由 `lib/src/transcript/` 提供的加密实现(加密后 `transcript_relay`,
///   并在本地落库)。通过 [RoutingTranscriptSink.encrypted] 槽位注入。
library;

/// 本人定稿句的归档出口。实现必须不抛异常(失败自行记日志 / 丢弃),
/// 因为它在字幕热路径上被同步调用。
abstract interface class TranscriptSink {
  void appendFinal({
    required String circleId,
    required String id,
    required String text,
    required DateTime startedAt,
  });
}

/// 非 E2EE 圈:直接经信令把明文句子交给服务器。
class SignalingTranscriptSink implements TranscriptSink {
  SignalingTranscriptSink(this.send);

  /// 信令发送函数(RoomController 的 signaling send)。
  final void Function(Map<String, dynamic> msg) send;

  /// 线格式(纯函数,便于测试)。
  static Map<String, dynamic> appendMessage({
    required String circleId,
    required String id,
    required String text,
    required DateTime startedAt,
  }) =>
      <String, dynamic>{
        't': 'transcript_append',
        'circleId': circleId,
        'id': id,
        'text': text,
        'startedAt': startedAt.millisecondsSinceEpoch,
      };

  @override
  void appendFinal({
    required String circleId,
    required String id,
    required String text,
    required DateTime startedAt,
  }) {
    try {
      send(appendMessage(
          circleId: circleId, id: id, text: text, startedAt: startedAt));
    } on Object {
      // 离线等:归档尽力而为,不影响字幕
    }
  }
}

/// 按圈子是否加密分流:非加密走 [plain],加密走 [encrypted](未注入则丢弃)。
class RoutingTranscriptSink implements TranscriptSink {
  RoutingTranscriptSink({
    required this.plain,
    required this.isEncrypted,
    this.encrypted,
  });

  final TranscriptSink plain;

  /// E2EE 圈的加密实现;由 transcript 模块在启动时填入。
  TranscriptSink? encrypted;

  final bool Function(String circleId) isEncrypted;

  @override
  void appendFinal({
    required String circleId,
    required String id,
    required String text,
    required DateTime startedAt,
  }) {
    final TranscriptSink? target =
        isEncrypted(circleId) ? encrypted : plain;
    target?.appendFinal(
        circleId: circleId, id: id, text: text, startedAt: startedAt);
  }
}
