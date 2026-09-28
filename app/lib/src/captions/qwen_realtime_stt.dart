/// 阿里云百炼 qwen3-asr-flash-realtime 流式识别客户端(纯 Dart)。
///
/// 协议(与 phase0 实测一致):
/// 1. `wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime`,
///    头 `Authorization: Bearer <st- 临时 token>`。token 只管握手,连上之后过期无妨。
/// 2. 收到 `session.created` 后发 `session.update`:PCM 16 kHz、服务端 VAD、
///    静音 800 ms 断句、**不给语言提示**(中英混说时给了反而更差)。
/// 3. 音频按 100 ms(3200 字节)一块,base64 放进 `input_audio_buffer.append`。
/// 4. 下行:`...transcription.text`(item_id, text, stash)是 partial,显示 text+stash;
///    `...transcription.completed`(item_id, transcript)是定稿。
/// 5. 结束发 `session.finish`,等 `session.finished` 再关。
///
/// 服务端对 600 s 的会话以 1011 关闭:只要还在转写,就用**新签**的 token 退避重连。
/// 停止转写必须关掉连接 —— 绝不在静音时挂着一条通往云端的麦克风通道。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'stt_socket.dart';

/// 服务器(cap_token)签给客户端的临时凭据。
class CaptionToken {
  const CaptionToken({
    required this.token,
    required this.expiresAt,
    required this.url,
    required this.model,
  });

  final String token;

  /// 毫秒时间戳。
  final int expiresAt;
  final String url;
  final String model;

  Uri get uri {
    final Uri base = Uri.parse(url);
    return base.replace(queryParameters: {
      ...base.queryParameters,
      'model': model,
    });
  }
}

/// 拿不到 token。[reason] 是服务器 cap_error 的原因码(或 `timeout` / `offline`)。
class CaptionTokenException implements Exception {
  CaptionTokenException(this.reason);
  final String reason;

  /// 重试也没用的原因:服务器没配、E2EE 圈没同意、根本不在房里。
  bool get fatal => const {
        'not_configured',
        'e2ee_opt_in_required',
        'not_in_room',
        'say_hello_first',
      }.contains(reason);

  /// 限流:退避要长得多。
  bool get rateLimited =>
      reason == 'rate_limited' || reason == 'global_rate_limited';

  @override
  String toString() => 'CaptionTokenException($reason)';
}

/// [fresh] 为 true 时必须重新签发(断线重连);否则可复用尚未过期的缓存。
typedef CaptionTokenSource = Future<CaptionToken> Function({bool fresh});

const int kSttSampleRate = 16000;

/// 100 ms 的 16 kHz 单声道 PCM16。
const int kSttChunkBytes = 3200;

/// 连接建立前最多缓存多少音频(块数)。握手 + 签 token 实测 1-4 s,
/// 缓存 6 s 让开口第一句不被吃掉;更早的丢弃(说明连接出了问题)。
const int kSttMaxBufferedChunks = 60;

class QwenRealtimeStt {
  QwenRealtimeStt({
    required this.tokenSource,
    required this.onPartial,
    required this.onFinal,
    SttSocketConnector? connector,
    this.onSessionEnded,
    this.onFatal,
    this.onLog,
    this.silenceDurationMs = 800,
    this.vadThreshold = 0.2,
    this.finishTimeout = const Duration(milliseconds: 1000),
    this.connectTimeout = const Duration(seconds: 10),
    this.backoffBase = const Duration(milliseconds: 500),
    this.backoffMax = const Duration(seconds: 8),
    this.rateLimitBackoff = const Duration(seconds: 60),
  }) : _connector = connector ?? connectSttSocket;

  final CaptionTokenSource tokenSource;

  /// partial:整句替换语义(text + stash)。
  final void Function(String itemId, String text) onPartial;

  /// 定稿。
  final void Function(String itemId, String text) onFinal;

  /// 一次连接结束(正常停止或掉线)。调用方借此把悬着的 partial 收尾。
  final void Function()? onSessionEnded;

  /// 不可恢复的错误(如服务器没配字幕);之后本实例不再自动重连。
  final void Function(String reason)? onFatal;
  final void Function(String message)? onLog;

  final int silenceDurationMs;
  final double vadThreshold;
  final Duration finishTimeout;
  final Duration connectTimeout;
  final Duration backoffBase;
  final Duration backoffMax;
  final Duration rateLimitBackoff;

  final SttSocketConnector _connector;

  bool _running = false;
  int _gen = 0;

  SttSocket? _socket;
  StreamSubscription<String>? _sub;

  /// 已收到 session.created 并发出 session.update,可以直接推音频。
  bool _live = false;

  /// 不足一块的尾巴。
  final BytesBuilder _partialChunk = BytesBuilder(copy: true);

  /// 连接就绪前攒下的整块。
  final List<Uint8List> _queue = <Uint8List>[];

  Completer<void>? _finished;

  /// 当前连接的「已结束」信号;teardown 时一并完成,免得会话循环永远挂在 await 上。
  Completer<void>? _sessionClosed;
  Timer? _backoffTimer;
  Completer<void>? _backoffWait;

  /// 连续失败次数(成功建立会话后清零)。
  int _failures = 0;

  /// 调试 / 测试可见。
  int connectAttempts = 0;
  int chunksSent = 0;

  bool get running => _running;

  /// 连接已就绪、音频正实时上行。
  bool get live => _live;

  /// 开始转写。重复调用无效。
  void start() {
    if (_running) return;
    _running = true;
    _failures = 0;
    final int gen = ++_gen;
    unawaited(_loop(gen));
  }

  /// 喂入 16 kHz 单声道 PCM16(小端)。未 [start] 时丢弃。
  void addPcm(Uint8List pcm) {
    if (!_running || pcm.isEmpty) return;
    _partialChunk.add(pcm);
    while (_partialChunk.length >= kSttChunkBytes) {
      final Uint8List all = _partialChunk.takeBytes();
      final Uint8List chunk = Uint8List.sublistView(all, 0, kSttChunkBytes);
      if (all.length > kSttChunkBytes) {
        _partialChunk.add(Uint8List.sublistView(all, kSttChunkBytes));
      }
      _enqueue(Uint8List.fromList(chunk));
    }
  }

  void _enqueue(Uint8List chunk) {
    if (_live && _socket != null) {
      _sendChunk(_socket!, chunk);
      return;
    }
    _queue.add(chunk);
    if (_queue.length > kSttMaxBufferedChunks) _queue.removeAt(0);
  }

  void _sendChunk(SttSocket s, Uint8List chunk) {
    try {
      s.send(jsonEncode({
        'type': 'input_audio_buffer.append',
        'audio': base64Encode(chunk),
      }));
      chunksSent++;
    } on Object catch (e) {
      _log('发送音频失败: $e');
    }
  }

  /// 停止转写:把剩余音频交给服务端定稿(最多等 [finishTimeout]),然后关连接。
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _gen++;
    _backoffTimer?.cancel();
    _backoffTimer = null;
    if (_backoffWait != null && !_backoffWait!.isCompleted) {
      _backoffWait!.complete();
    }
    final SttSocket? s = _socket;
    if (s != null && _live) {
      // 不足一块的尾巴也发掉:最后半个字常在这里
      final Uint8List tail = _partialChunk.takeBytes();
      if (tail.isNotEmpty) _sendChunk(s, tail);
      final Completer<void> done = _finished ??= Completer<void>();
      try {
        s.send(jsonEncode({'type': 'session.finish'}));
        await done.future.timeout(finishTimeout);
      } on Object {
        // 超时 / 已断:不等了
      }
    }
    _partialChunk.clear();
    _queue.clear();
    await _teardown();
  }

  Future<void> _teardown() async {
    final SttSocket? s = _socket;
    _socket = null;
    final bool wasLive = _live;
    _live = false;
    // 不 await:已结束的订阅 cancel() 返回根 zone 的空 future,等它没有意义
    unawaited(_sub?.cancel());
    _sub = null;
    _finished = null;
    final Completer<void>? sc = _sessionClosed;
    _sessionClosed = null;
    if (sc != null && !sc.isCompleted) sc.complete();
    if (s != null) {
      await s.close(1000);
    }
    if (wasLive || s != null) onSessionEnded?.call();
  }

  Future<void> _loop(int gen) async {
    bool fresh = false;
    while (_running && gen == _gen) {
      connectAttempts++;
      CaptionToken token;
      try {
        token = await tokenSource(fresh: fresh);
      } on CaptionTokenException catch (e) {
        if (gen != _gen) return;
        _log('签发字幕 token 失败: ${e.reason}');
        if (e.fatal) {
          _running = false;
          onFatal?.call(e.reason);
          return;
        }
        await _backoff(gen, rateLimited: e.rateLimited);
        fresh = true;
        continue;
      } on Object catch (e) {
        if (gen != _gen) return;
        _log('签发字幕 token 出错: $e');
        await _backoff(gen);
        fresh = true;
        continue;
      }
      if (!_running || gen != _gen) return;

      final bool ok = await _runSession(gen, token);
      if (!_running || gen != _gen) return;
      // 走到这里就是掉线(含 600 s 的 1011):用新 token 重连
      if (ok) _failures = 0;
      fresh = true;
      await _backoff(gen);
    }
  }

  /// 跑一条连接直到它断开。返回这次是否成功建立过会话。
  Future<bool> _runSession(int gen, CaptionToken token) async {
    final SttSocket s;
    try {
      s = _connector(token.uri, {'Authorization': 'Bearer ${token.token}'});
    } on Object catch (e) {
      _log('连接识别服务失败: $e');
      return false;
    }
    _socket = s;
    final Completer<void> closed = Completer<void>();
    _sessionClosed = closed;
    bool established = false;
    _sub = s.messages.listen(
      (String raw) {
        // stop() 期间 gen 已变但连接仍在等定稿,所以只按「是不是当前连接」判断
        if (_socket != s) return;
        final bool created = _onMessage(s, raw);
        if (created) established = true;
      },
      onError: (Object e) {
        _log('识别连接出错: $e');
        if (!closed.isCompleted) closed.complete();
      },
      onDone: () {
        if (!closed.isCompleted) closed.complete();
      },
      cancelOnError: true,
    );
    try {
      await s.ready.timeout(connectTimeout);
    } on Object catch (e) {
      _log('识别服务握手失败: $e');
      if (_socket == s) await _teardown();
      return false;
    }
    // 等连接自然结束,或被 stop() 拆掉
    await closed.future;
    if (_socket == s) {
      _log('识别连接断开(code ${s.closeCode}),${_running ? '准备重连' : '已停止'}');
      final Completer<void>? f = _finished;
      if (f != null && !f.isCompleted) f.complete();
      await _teardown();
    }
    return established;
  }

  /// 返回 true 表示这条是 session.created。
  bool _onMessage(SttSocket s, String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on Object {
      return false;
    }
    if (decoded is! Map) return false;
    final Object? type = decoded['type'];
    switch (type) {
      case 'session.created':
        s.send(jsonEncode({
          'type': 'session.update',
          'session': {
            'modalities': ['text'],
            'input_audio_format': 'pcm',
            'sample_rate': kSttSampleRate,
            // 不给 language:中英混说时自动检测最好(phase0 实测)
            'input_audio_transcription': <String, Object?>{},
            'turn_detection': {
              'type': 'server_vad',
              'threshold': vadThreshold,
              'silence_duration_ms': silenceDurationMs,
            },
          },
        }));
        _live = true;
        _failures = 0;
        for (final Uint8List c in _queue) {
          _sendChunk(s, c);
        }
        _queue.clear();
        return true;
      case 'conversation.item.input_audio_transcription.text':
        final String id = decoded['item_id'] as String? ?? '';
        final String text =
            '${decoded['text'] as String? ?? ''}${decoded['stash'] as String? ?? ''}';
        if (id.isNotEmpty) onPartial(id, text);
        return false;
      case 'conversation.item.input_audio_transcription.completed':
        final String id = decoded['item_id'] as String? ?? '';
        final String text = decoded['transcript'] as String? ?? '';
        if (id.isNotEmpty) onFinal(id, text);
        return false;
      case 'session.finished':
        final Completer<void>? f = _finished;
        if (f != null && !f.isCompleted) f.complete();
        return false;
      case 'error':
        // 只记类型与错误码,不打原文(可能带用户语音内容)
        final Object? err = decoded['error'];
        final Object? code = err is Map ? err['code'] : null;
        _log('识别服务报错: ${code ?? 'unknown'}');
        return false;
    }
    return false;
  }

  Future<void> _backoff(int gen, {bool rateLimited = false}) async {
    if (!_running || gen != _gen) return;
    _failures++;
    final Duration d = rateLimited
        ? rateLimitBackoff
        : Duration(
            milliseconds: math.min(
              backoffMax.inMilliseconds,
              backoffBase.inMilliseconds * (1 << math.min(_failures - 1, 10)),
            ),
          );
    final Completer<void> c = Completer<void>();
    _backoffWait = c;
    _backoffTimer = Timer(d, () {
      if (!c.isCompleted) c.complete();
    });
    await c.future;
    _backoffTimer = null;
    _backoffWait = null;
  }

  void _log(String m) => onLog?.call('[captions] $m');

  /// 彻底放弃(不定稿,直接关)。dispose 用。
  Future<void> dispose() async {
    _running = false;
    _gen++;
    _backoffTimer?.cancel();
    if (_backoffWait != null && !_backoffWait!.isCompleted) {
      _backoffWait!.complete();
    }
    await _teardown();
  }
}
