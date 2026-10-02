/// 转写记录 / 机器人 token 的信令线格式(客户端 → 服务器)。
///
/// 纯函数,契约见 docs/plans/transcript-bot-contract.md §3。
library;

abstract final class TranscriptWire {
  static Map<String, dynamic> circleTranscriptSet(String circleId,
          {required bool on, required String ownerKey}) =>
      {'t': 'circle_transcript_set', 'circleId': circleId, 'on': on, 'ownerKey': ownerKey};

  static Map<String, dynamic> get(String circleId, {int? before, int? limit}) => {
        't': 'transcript_get',
        'circleId': circleId,
        'before': ?before,
        'limit': ?limit,
      };

  static Map<String, dynamic> clear(String circleId, {required String ownerKey}) =>
      {'t': 'transcript_clear', 'circleId': circleId, 'ownerKey': ownerKey};

  static Map<String, dynamic> relay(String circleId, String blob) =>
      {'t': 'transcript_relay', 'circleId': circleId, 'blob': blob};

  static Map<String, dynamic> relayAck(String circleId, List<String> rids) =>
      {'t': 'transcript_relay_ack', 'circleId': circleId, 'rids': rids};

  static Map<String, dynamic> botTokenCreate(String circleId,
          {required String name, required String ownerKey}) =>
      {'t': 'bot_token_create', 'circleId': circleId, 'name': name, 'ownerKey': ownerKey};

  static Map<String, dynamic> botTokenList(String circleId, {required String ownerKey}) =>
      {'t': 'bot_token_list', 'circleId': circleId, 'ownerKey': ownerKey};

  static Map<String, dynamic> botTokenRevoke(String circleId,
          {required String id, required String ownerKey}) =>
      {'t': 'bot_token_revoke', 'circleId': circleId, 'id': id, 'ownerKey': ownerKey};
}
