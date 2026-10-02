/// 转写记录的客户端协调层(契约 docs/plans/transcript-bot-contract.md §3/§4)。
///
/// - 非 E2EE 圈:历史在服务器,[ServerTranscriptHistory] 用 `transcript_get` 分页。
/// - E2EE 圈:服务器只转发密文。收到 `transcript_relay` → 解密 → 落本机 →
///   `transcript_relay_ack`;本人定稿句经 [EncryptedTranscriptSink] 加密后
///   `transcript_relay`,并立即落本机(服务器不回推给发送者)。
/// - `transcript_cleared`:清本机。
/// - 圈主操作(开关 / 清空 / 机器人 token)自带回执等待,不依赖 RoomController。
///
/// 只依赖 `send` + `messages` 两个函数,测试用假信令直接驱动。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../captions/transcript_sink.dart';
import 'local_transcript_store.dart';
import 'transcript_crypto.dart';
import 'transcript_models.dart';
import 'transcript_wire.dart';

/// 机器人 token 列表项。
@immutable
class BotTokenInfo {
  const BotTokenInfo({required this.id, required this.name, this.createdAt});
  final String id;
  final String name;
  final int? createdAt;

  static BotTokenInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'], c = j['createdAt'];
    if (id is! String) return null;
    return BotTokenInfo(
        id: id, name: name is String ? name : id, createdAt: c is num ? c.toInt() : null);
  }
}

/// 刚建好的 token(明文只此一次)。
@immutable
class BotTokenCreated {
  const BotTokenCreated({required this.info, required this.token});
  final BotTokenInfo info;
  final String token;
}

/// 圈主操作失败(reason 为服务器 owner_error.reason,或 no_key / timeout)。
class TranscriptOpException implements Exception {
  TranscriptOpException(this.reason);
  final String reason;
  @override
  String toString() => 'TranscriptOpException($reason)';
}

class TranscriptService extends ChangeNotifier {
  TranscriptService({
    required this.send,
    required Stream<Map<String, dynamic>> messages,
    required this.ownerKeyFor,
    required this.circleKeyFor,
    required this.isE2EE,
    required this.myUserId,
    required this.myName,
    LocalTranscriptStore? store,
    bool Function(String circleId)? transcriptOn,
    this.timeout = const Duration(seconds: 15),
  })  : store = store ?? LocalTranscriptStore(),
        transcriptOn = transcriptOn ?? ((_) => true) {
    _sub = messages.listen(_onMessage);
  }

  final void Function(Map<String, dynamic> msg) send;

  /// 本机持有的圈主钥匙;null = 不是圈主。
  final String? Function(String circleId) ownerKeyFor;

  /// 本圈 E2EE 共享密钥 hex(E2EEController.sharedKeyFor);null = 本机无口令。
  final Future<String?> Function(String circleId) circleKeyFor;

  /// 这个圈子是不是 E2EE 圈(决定历史走本机还是服务器)。
  final bool Function(String circleId) isE2EE;
  final String Function() myUserId;
  final String Function() myName;
  final LocalTranscriptStore store;

  /// 圈主开没开转写记录(RoomController.isTranscriptOn)。
  final bool Function(String circleId) transcriptOn;
  final Duration timeout;

  late final StreamSubscription<Map<String, dynamic>> _sub;

  /// 解不开而被丢弃的密文条数(密钥不对 / 被篡改)。
  int undecryptableCount = 0;

  /// 每圈「被清空」的代数:UI 据此判断要不要整表重置。
  final Map<String, int> _epochs = {};
  int epochOf(String circleId) => _epochs[circleId] ?? 0;

  /// 非 E2EE 圈实时追加的新行(transcript_line)。
  final StreamController<({String circleId, TranscriptEntry entry})> _lines =
      StreamController.broadcast();
  Stream<({String circleId, TranscriptEntry entry})> get lines => _lines.stream;

  // ── 收 ────────────────────────────────────────────────────────────

  final List<({String circleId, Completer<TranscriptPage> done})> _pageWaiters =
      [];
  final List<({String op, String circleId, Completer<Map<String, dynamic>> done})>
      _opWaiters = [];

  /// 串行处理 relay,保证同一批的落库与 ack 顺序。
  Future<void> _relayChain = Future<void>.value();

  void _onMessage(Map<String, dynamic> msg) {
    final t = msg['t'];
    final cid = msg['circleId'];
    if (cid is! String) return;
    switch (t) {
      case 'transcript_page':
        final items = <TranscriptEntry>[
          for (final raw in (msg['items'] as List? ?? const []))
            ?TranscriptEntry.fromJson(raw),
        ];
        final more = msg['more'] == true;
        final lastSeq = items.isEmpty ? null : items.last.seq;
        _settlePage(
            cid,
            TranscriptPage(
                items: items, more: more && lastSeq != null, cursor: lastSeq));
      case 'transcript_error':
        if (msg['op'] == 'get') {
          final w = _takePageWaiter(cid);
          w?.done.completeError(
              TranscriptOpException(msg['reason'] as String? ?? 'unknown'));
        }
      case 'transcript_line':
        final e = TranscriptEntry.fromJson(msg['item']);
        if (e != null) _lines.add((circleId: cid, entry: e));
      case 'transcript_relay':
        final items = msg['items'];
        if (items is List) {
          _relayChain = _relayChain
              .then((_) => _onRelay(cid, items))
              .catchError((Object e) => debugPrint('[lares] relay 处理失败: $e'));
        }
      case 'transcript_cleared':
        _epochs[cid] = epochOf(cid) + 1;
        unawaited(store.clear(cid));
        notifyListeners();
      case 'bot_token':
        _settleOp('bot_token_create', cid, msg);
      case 'bot_tokens':
        _settleOp('bot_token_list', cid, msg);
      case 'owner_ok':
        final op = msg['op'];
        if (op is String) _settleOp(op, cid, msg);
      case 'owner_error':
        final op = msg['op'];
        if (op is String) {
          _failOp(op, cid, msg['reason'] as String? ?? 'unknown');
        }
    }
  }

  /// 处理完成的 Future(测试等待用)。
  Future<void> get idle => _relayChain;

  Future<void> _onRelay(String circleId, List<Object?> items) async {
    final key = await circleKeyFor(circleId);
    if (key == null) {
      // 本机没有口令:不 ack —— 服务器留着,等有口令时再补推。
      return;
    }
    final Uint8List aesKey;
    try {
      aesKey = deriveTranscriptKey(circleKeyHex: key, circleId: circleId);
    } on TranscriptCryptoException {
      return;
    }
    final rids = <String>[];
    final entries = <TranscriptEntry>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final rid = raw['rid'];
      final blob = raw['blob'];
      if (rid is! String) continue;
      rids.add(rid);
      if (blob is! String) {
        undecryptableCount++;
        continue;
      }
      try {
        final s = decryptTranscriptBlobWithKey(
            key: aesKey, circleId: circleId, blob: blob);
        final p = TranscriptPlain.fromJson(_tryJson(s));
        if (p == null) {
          undecryptableCount++;
          continue;
        }
        entries.add(TranscriptEntry(
          userId: p.uid,
          name: p.name,
          id: p.id,
          text: p.text,
          startedAt: p.startedAt,
          ts: p.ts,
        ));
      } on TranscriptCryptoException {
        undecryptableCount++;
      }
    }
    if (entries.isNotEmpty) await store.addAll(circleId, entries);
    // 落盘之后才 ack:ack 了服务器就删,落盘前崩溃会丢。
    if (rids.isNotEmpty) send(TranscriptWire.relayAck(circleId, rids));
  }

  static Object? _tryJson(String s) {
    try {
      return jsonDecode(s);
    } on FormatException {
      return null;
    }
  }

  ({String circleId, Completer<TranscriptPage> done})? _takePageWaiter(
      String cid) {
    final i = _pageWaiters.indexWhere((w) => w.circleId == cid);
    if (i < 0) return null;
    return _pageWaiters.removeAt(i);
  }

  void _settlePage(String cid, TranscriptPage page) {
    final w = _takePageWaiter(cid);
    if (w != null && !w.done.isCompleted) w.done.complete(page);
  }

  void _settleOp(String op, String cid, Map<String, dynamic> msg) {
    _opWaiters.removeWhere((w) {
      if (w.op != op || w.circleId != cid) return false;
      if (!w.done.isCompleted) w.done.complete(msg);
      return true;
    });
  }

  void _failOp(String op, String cid, String reason) {
    _opWaiters.removeWhere((w) {
      if (w.op != op || w.circleId != cid) return false;
      if (!w.done.isCompleted) w.done.completeError(TranscriptOpException(reason));
      return true;
    });
  }

  Future<Map<String, dynamic>> _ownerOp(String op, String circleId,
      Map<String, dynamic> Function(String ownerKey) build) {
    final key = ownerKeyFor(circleId);
    if (key == null) return Future.error(TranscriptOpException('no_key'));
    final done = Completer<Map<String, dynamic>>();
    final waiter = (op: op, circleId: circleId, done: done);
    _opWaiters.add(waiter);
    send(build(key));
    return done.future.timeout(timeout, onTimeout: () {
      _opWaiters.remove(waiter);
      throw TranscriptOpException('timeout');
    });
  }

  // ── 发 ────────────────────────────────────────────────────────────

  /// 拉服务器历史一页(新 → 旧)。[before] 为 seq。
  Future<TranscriptPage> fetchPage(String circleId, {int? before, int limit = 50}) {
    final done = Completer<TranscriptPage>();
    final waiter = (circleId: circleId, done: done);
    _pageWaiters.add(waiter);
    send(TranscriptWire.get(circleId, before: before, limit: limit));
    return done.future.timeout(timeout, onTimeout: () {
      _pageWaiters.remove(waiter);
      throw TranscriptOpException('timeout');
    });
  }

  /// 圈主开关转写记录。
  Future<void> setTranscriptOn(String circleId, bool on) => _ownerOp(
      'circle_transcript_set',
      circleId,
      (k) => TranscriptWire.circleTranscriptSet(circleId, on: on, ownerKey: k));

  /// 圈主清空。成功后本机也清(服务器还会广播 transcript_cleared)。
  Future<void> clearAsOwner(String circleId) async {
    await _ownerOp('transcript_clear', circleId,
        (k) => TranscriptWire.clear(circleId, ownerKey: k));
    _epochs[circleId] = epochOf(circleId) + 1;
    await store.clear(circleId);
    notifyListeners();
  }

  Future<BotTokenCreated> createBotToken(String circleId, String name) async {
    final m = await _ownerOp('bot_token_create', circleId,
        (k) => TranscriptWire.botTokenCreate(circleId, name: name, ownerKey: k));
    final info = BotTokenInfo.fromJson(m);
    final token = m['token'];
    if (info == null || token is! String || token.isEmpty) {
      throw TranscriptOpException('bad_reply');
    }
    return BotTokenCreated(info: info, token: token);
  }

  Future<List<BotTokenInfo>> listBotTokens(String circleId) async {
    final m = await _ownerOp('bot_token_list', circleId,
        (k) => TranscriptWire.botTokenList(circleId, ownerKey: k));
    return [
      for (final raw in (m['items'] as List? ?? const []))
        ?BotTokenInfo.fromJson(raw),
    ];
  }

  Future<void> revokeBotToken(String circleId, String id) => _ownerOp(
      'bot_token_revoke',
      circleId,
      (k) => TranscriptWire.botTokenRevoke(circleId, id: id, ownerKey: k));

  /// E2EE 圈本人定稿句:加密 → relay,并立即落本机。
  Future<void> relayOwnLine({
    required String circleId,
    required String id,
    required String text,
    required DateTime startedAt,
  }) async {
    if (!transcriptOn(circleId)) return; // 圈主没开转写记录
    final key = await circleKeyFor(circleId);
    if (key == null) return; // 没口令就没有密钥,绝不发明文
    final now = DateTime.now().millisecondsSinceEpoch;
    final plain = TranscriptPlain(
      id: id,
      uid: myUserId(),
      name: myName(),
      text: text,
      startedAt: startedAt.millisecondsSinceEpoch,
      ts: now,
    );
    await store.add(
        circleId,
        TranscriptEntry(
          userId: plain.uid,
          name: plain.name,
          id: plain.id,
          text: plain.text,
          startedAt: plain.startedAt,
          ts: plain.ts,
        ));
    final blob = encryptTranscriptLine(
        circleKeyHex: key, circleId: circleId, line: plain);
    send(TranscriptWire.relay(circleId, blob));
  }

  /// 给 RoutingTranscriptSink.encrypted 槽位用。
  late final EncryptedTranscriptSink encryptedSink = EncryptedTranscriptSink(this);

  /// 某圈的历史来源(E2EE → 本机,否则服务器)。
  TranscriptHistory historyFor(String circleId) => isE2EE(circleId)
      ? LocalTranscriptHistory(store, circleId)
      : ServerTranscriptHistory(this, circleId);

  @override
  void dispose() {
    unawaited(_sub.cancel());
    unawaited(_lines.close());
    super.dispose();
  }
}

/// E2EE 圈的归档出口(契约 §4)。不抛异常。
class EncryptedTranscriptSink implements TranscriptSink {
  EncryptedTranscriptSink(this.service);
  final TranscriptService service;

  @override
  void appendFinal({
    required String circleId,
    required String id,
    required String text,
    required DateTime startedAt,
  }) {
    if (text.trim().isEmpty) return;
    unawaited(service
        .relayOwnLine(
            circleId: circleId, id: id, text: text, startedAt: startedAt)
        .catchError((Object e) {
      debugPrint('[lares] 加密转写发送失败: $e');
    }));
  }
}

/// 服务器版历史(非 E2EE 圈)。
class ServerTranscriptHistory extends ChangeNotifier implements TranscriptHistory {
  ServerTranscriptHistory(this.service, this.circleId) {
    _sub = service.lines.where((l) => l.circleId == circleId).listen((_) {
      notifyListeners();
    });
    service.addListener(notifyListeners);
  }

  final TranscriptService service;
  final String circleId;
  late final StreamSubscription<Object?> _sub;

  @override
  Future<TranscriptPage> page({Object? cursor, int limit = 50}) =>
      service.fetchPage(circleId, before: cursor is int ? cursor : null, limit: limit);

  @override
  void dispose() {
    unawaited(_sub.cancel());
    service.removeListener(notifyListeners);
    super.dispose();
  }
}
