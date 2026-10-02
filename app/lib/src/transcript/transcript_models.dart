/// 转写记录的共用模型 + 历史抽象(服务器版 / 本机版共用一个 UI)。
library;

import 'package:flutter/foundation.dart';

/// 一句转写记录。
@immutable
class TranscriptEntry {
  const TranscriptEntry({
    required this.userId,
    required this.name,
    required this.id,
    required this.text,
    required this.startedAt,
    required this.ts,
    this.seq,
  });

  final String userId;
  final String name;

  /// 说话人本地生成的句子 id;与 [userId] 一起唯一。
  final String id;
  final String text;

  /// 毫秒时间戳
  final int startedAt;
  final int ts;

  /// 服务器分配的序号(只有服务器版有;本机版为 null)。
  final int? seq;

  String get dedupeKey => '$userId\u0000$id';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'userId': userId,
        'name': name,
        'id': id,
        'text': text,
        'startedAt': startedAt,
        'ts': ts,
        if (seq != null) 'seq': seq,
      };

  /// 契约 item 形状 `{seq, ts, userId, name, id, text, startedAt}`;坏数据返回 null。
  static TranscriptEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final uid = j['userId'], id = j['id'], text = j['text'];
    final ts = j['ts'];
    if (uid is! String || id is! String || text is! String || ts is! num) {
      return null;
    }
    final st = j['startedAt'];
    final name = j['name'];
    final seq = j['seq'];
    return TranscriptEntry(
      userId: uid,
      name: name is String && name.isNotEmpty ? name : uid,
      id: id,
      text: text,
      startedAt: st is num ? st.toInt() : ts.toInt(),
      ts: ts.toInt(),
      seq: seq is num ? seq.toInt() : null,
    );
  }
}

/// 一页(新 → 旧)。[cursor] 交回 [TranscriptHistory.page] 取下一页。
@immutable
class TranscriptPage {
  const TranscriptPage({
    required this.items,
    required this.more,
    this.cursor,
  });

  static const empty = TranscriptPage(items: [], more: false);

  final List<TranscriptEntry> items;
  final bool more;
  final Object? cursor;
}

/// 历史来源。UI 只认这个接口。
abstract class TranscriptHistory implements Listenable {
  /// 取一页;[cursor] 为 null 取最新一页。失败抛异常(UI 显示错误态)。
  Future<TranscriptPage> page({Object? cursor, int limit = 50});
}
