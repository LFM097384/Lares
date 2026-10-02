/// E2EE 圈转写记录的**本机**存储:每圈一个 JSONL 文件(服务器只见密文,
/// 历史只能存在各自设备上)。
///
/// 存储后端可注入:生产用 [defaultTranscriptBackend](文档目录下
/// `lares_transcripts/<圈>.jsonl`;Web 没有文件系统 → 内存),测试注入
/// [DirectoryTranscriptBackend] 指向临时目录或 [MemoryTranscriptBackend]。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'transcript_backend_stub.dart'
    if (dart.library.io) 'transcript_backend_io.dart' as platform;
import 'transcript_models.dart';

/// 落盘接口:按圈追加行 / 读全部行 / 删除。
abstract class TranscriptBackend {
  Future<List<String>> readLines(String circleId);
  Future<void> appendLines(String circleId, List<String> lines);
  Future<void> delete(String circleId);
}

/// 纯内存后端(Web 与测试)。
class MemoryTranscriptBackend implements TranscriptBackend {
  final Map<String, List<String>> files = {};
  @override
  Future<List<String>> readLines(String circleId) async =>
      List<String>.of(files[circleId] ?? const []);
  @override
  Future<void> appendLines(String circleId, List<String> lines) async =>
      (files[circleId] ??= []).addAll(lines);
  @override
  Future<void> delete(String circleId) async => files.remove(circleId);
}

/// 生产默认后端。
TranscriptBackend defaultTranscriptBackend() => platform.createDefaultBackend();

/// 文件名安全化:圈 id 可能含任意字符,一律 base64url。
String transcriptFileStem(String circleId) =>
    base64Url.encode(utf8.encode(circleId)).replaceAll('=', '');

/// 本机转写记录(全部圈)。
class LocalTranscriptStore extends ChangeNotifier {
  LocalTranscriptStore({TranscriptBackend? backend})
      : _backend = backend ?? defaultTranscriptBackend();

  final TranscriptBackend _backend;

  /// 已载入的圈:circleId -> (dedupeKey -> entry)
  final Map<String, Map<String, TranscriptEntry>> _cache = {};

  /// 串行化每个圈的读写,避免并发 append / clear 交错。
  final Map<String, Future<void>> _locks = {};

  Future<T> _serial<T>(String circleId, Future<T> Function() body) {
    final prev = _locks[circleId] ?? Future<void>.value();
    final next = prev.then((_) => body());
    _locks[circleId] = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<Map<String, TranscriptEntry>> _load(String circleId) async {
    final hit = _cache[circleId];
    if (hit != null) return hit;
    final map = <String, TranscriptEntry>{};
    for (final line in await _backend.readLines(circleId)) {
      if (line.trim().isEmpty) continue;
      try {
        final e = TranscriptEntry.fromJson(jsonDecode(line));
        if (e != null) map.putIfAbsent(e.dedupeKey, () => e);
      } on FormatException {
        // 坏行(崩溃时写了半行):跳过,不毁整份
      }
    }
    return _cache[circleId] = map;
  }

  /// 追加若干条;按 (userId,id) 去重。返回实际新增条数。
  Future<int> addAll(String circleId, Iterable<TranscriptEntry> entries) =>
      _serial(circleId, () async {
        final map = await _load(circleId);
        final fresh = <TranscriptEntry>[];
        for (final e in entries) {
          if (map.containsKey(e.dedupeKey)) continue;
          map[e.dedupeKey] = e;
          fresh.add(e);
        }
        if (fresh.isEmpty) return 0;
        await _backend.appendLines(
            circleId, [for (final e in fresh) jsonEncode(e.toJson())]);
        notifyListeners();
        return fresh.length;
      });

  Future<bool> add(String circleId, TranscriptEntry e) async =>
      await addAll(circleId, [e]) > 0;

  /// 新 → 旧分页。[offset] 为已取条数。
  Future<TranscriptPage> page(String circleId,
          {int offset = 0, int limit = 50}) =>
      _serial(circleId, () async {
        final all = (await _load(circleId)).values.toList()
          ..sort((a, b) {
            final c = b.startedAt.compareTo(a.startedAt);
            return c != 0 ? c : b.ts.compareTo(a.ts);
          });
        final start = offset.clamp(0, all.length);
        final end = (start + limit).clamp(0, all.length);
        return TranscriptPage(
          items: all.sublist(start, end),
          more: end < all.length,
          cursor: end,
        );
      });

  Future<int> count(String circleId) =>
      _serial(circleId, () async => (await _load(circleId)).length);

  /// 清空本圈(圈主清空 / transcript_cleared)。
  Future<void> clear(String circleId) => _serial(circleId, () async {
        _cache[circleId] = {};
        await _backend.delete(circleId);
        notifyListeners();
      });
}

/// 本机版历史(E2EE 圈)。
class LocalTranscriptHistory extends ChangeNotifier
    implements TranscriptHistory {
  LocalTranscriptHistory(this.store, this.circleId) {
    store.addListener(notifyListeners);
  }

  final LocalTranscriptStore store;
  final String circleId;

  @override
  Future<TranscriptPage> page({Object? cursor, int limit = 50}) =>
      store.page(circleId, offset: cursor is int ? cursor : 0, limit: limit);

  @override
  void dispose() {
    store.removeListener(notifyListeners);
    super.dispose();
  }
}
