// 实时字幕:QwenRealtimeStt 协议客户端单测(假 socket + 假 token 源,不出网)。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/captions/caption_protocol.dart';
import 'package:lares_app/src/captions/caption_wiring.dart';
import 'package:lares_app/src/captions/qwen_realtime_stt.dart';
import 'package:lares_app/src/captions/stt_socket.dart';

class FakeSttSocket implements SttSocket {
  FakeSttSocket(this.url, this.headers);

  final Uri url;
  final Map<String, String> headers;
  final StreamController<String> _in = StreamController<String>();
  final Completer<void> _ready = Completer<void>();
  final List<Map<String, dynamic>> sent = [];
  bool closed = false;
  int? _closeCode;

  @override
  Stream<String> get messages => _in.stream;

  @override
  Future<void> get ready => _ready.future;

  @override
  int? get closeCode => _closeCode;

  @override
  void send(String text) {
    if (closed) throw StateError('closed');
    final m = jsonDecode(text) as Map<String, dynamic>;
    sent.add(m);
    if (m['type'] == 'session.finish' && autoFinish) {
      scheduleMicrotask(() => serverSend({'type': 'session.finished'}));
    }
  }

  bool autoFinish = true;

  void open() => _ready.complete();
  void serverSend(Map<String, dynamic> m) {
    if (!_in.isClosed) _in.add(jsonEncode(m));
  }

  /// 服务端主动关闭(如 600 s 的 1011)。
  void serverClose(int code) {
    _closeCode = code;
    closed = true;
    _in.close();
  }

  @override
  Future<void> close([int? code]) async {
    closed = true;
    _closeCode ??= code;
    // 不 await:订阅已被取消的单订阅 controller,其 close() future 永不完成
    if (!_in.isClosed) unawaited(_in.close());
  }

  Iterable<Map<String, dynamic>> ofType(String t) =>
      sent.where((m) => m['type'] == t);
}

class Harness {
  final List<FakeSttSocket> sockets = [];
  final List<bool> tokenCalls = []; // fresh?
  int _n = 0;
  final List<(String, String)> partials = [];
  final List<(String, String)> finals = [];
  final List<String> fatals = [];
  Object? tokenError;
  bool autoOpen = true;

  late final QwenRealtimeStt stt = QwenRealtimeStt(
    tokenSource: ({bool fresh = false}) async {
      tokenCalls.add(fresh);
      final e = tokenError;
      if (e != null) throw e;
      _n++;
      return CaptionToken(
        token: 'st-$_n',
        expiresAt: 0,
        url: 'wss://example.test/api-ws/v1/realtime',
        model: 'qwen3-asr-flash-realtime',
      );
    },
    connector: (url, headers) {
      final s = FakeSttSocket(url, headers);
      sockets.add(s);
      if (autoOpen) {
        scheduleMicrotask(() {
          s.open();
          s.serverSend({'type': 'session.created'});
        });
      }
      return s;
    },
    onPartial: (id, t) => partials.add((id, t)),
    onFinal: (id, t) => finals.add((id, t)),
    onFatal: fatals.add,
  );
}

Uint8List pcm(int bytes) => Uint8List(bytes);

void main() {
  test('握手:Bearer 头、model 参数、session.update 配置(server_vad 800ms、无语言提示)',
      () {
    fakeAsync((async) {
      final h = Harness();
      h.stt.start();
      async.flushMicrotasks();
      expect(h.sockets, hasLength(1));
      final s = h.sockets.single;
      expect(s.headers['Authorization'], 'Bearer st-1');
      expect(s.url.queryParameters['model'], 'qwen3-asr-flash-realtime');
      expect(s.url.host, 'example.test');
      final upd = s.ofType('session.update').single['session'] as Map;
      expect(upd['sample_rate'], 16000);
      expect(upd['input_audio_format'], 'pcm');
      expect(upd['input_audio_transcription'], isEmpty,
          reason: '不给语言提示(中英混说时自动检测更准)');
      final td = upd['turn_detection'] as Map;
      expect(td['type'], 'server_vad');
      expect(td['silence_duration_ms'], 800);
      expect(h.stt.live, isTrue);
      h.stt.dispose();
    });
  });

  test('音频按 3200 字节(100 ms)切块,base64 发送;就绪前的音频先缓存再补发', () {
    fakeAsync((async) {
      final h = Harness()..autoOpen = false;
      h.stt.start();
      async.flushMicrotasks();
      // 连接还没就绪:喂 250 ms
      h.stt.addPcm(pcm(1000));
      h.stt.addPcm(pcm(7000));
      final s = h.sockets.single;
      expect(s.ofType('input_audio_buffer.append'), isEmpty);
      s.open();
      s.serverSend({'type': 'session.created'});
      async.flushMicrotasks();
      final appends = s.ofType('input_audio_buffer.append').toList();
      expect(appends, hasLength(2), reason: '8000 字节 = 两整块 + 1600 尾巴');
      for (final a in appends) {
        expect(base64Decode(a['audio'] as String).length, kSttChunkBytes);
      }
      // 就绪后直接发
      h.stt.addPcm(pcm(1600));
      expect(s.ofType('input_audio_buffer.append'), hasLength(3));
      h.stt.dispose();
    });
  });

  test('partial = text + stash,按 item_id;final 取 transcript', () {
    fakeAsync((async) {
      final h = Harness();
      h.stt.start();
      async.flushMicrotasks();
      final s = h.sockets.single;
      s.serverSend({
        'type': 'conversation.item.input_audio_transcription.text',
        'item_id': 'it1',
        'text': '今天',
        'stash': '天气',
      });
      s.serverSend({
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': 'it1',
        'transcript': '今天天气不错。',
      });
      async.flushMicrotasks();
      expect(h.partials, [('it1', '今天天气')]);
      expect(h.finals, [('it1', '今天天气不错。')]);
      h.stt.dispose();
    });
  });

  test('stop:发尾巴 + session.finish,等 session.finished 后关连接,不再重连', () {
    fakeAsync((async) {
      final h = Harness();
      h.stt.start();
      async.flushMicrotasks();
      final s = h.sockets.single;
      h.stt.addPcm(pcm(1000)); // 不足一块
      var done = false;
      h.stt.stop().then((_) => done = true);
      async.flushMicrotasks();
      expect(done, isTrue);
      expect(s.closed, isTrue);
      expect(s.ofType('session.finish'), hasLength(1));
      final appends = s.ofType('input_audio_buffer.append').toList();
      expect(base64Decode(appends.last['audio'] as String).length, 1000);
      async.elapse(const Duration(seconds: 30));
      expect(h.sockets, hasLength(1), reason: '停止后绝不自动重连');
      // 停止后的音频被丢弃
      h.stt.addPcm(pcm(6400));
      expect(s.ofType('input_audio_buffer.append'), hasLength(appends.length));
    });
  });

  test('stop:服务端不回 session.finished 时最多等 ~1 s 就关', () {
    fakeAsync((async) {
      final h = Harness();
      h.stt.start();
      async.flushMicrotasks();
      final s = h.sockets.single..autoFinish = false;
      var done = false;
      h.stt.stop().then((_) => done = true);
      async.elapse(const Duration(milliseconds: 900));
      expect(done, isFalse);
      async.elapse(const Duration(milliseconds: 200));
      expect(done, isTrue);
      expect(s.closed, isTrue);
    });
  });

  test('服务端 1011(600 s 会话上限)→ 用新签的 token 退避重连', () {
    fakeAsync((async) {
      final h = Harness();
      h.stt.start();
      async.flushMicrotasks();
      expect(h.tokenCalls, [false]);
      h.sockets.single.serverClose(1011);
      async.flushMicrotasks();
      expect(h.sockets, hasLength(1), reason: '先退避,不立刻重连');
      async.elapse(const Duration(seconds: 1));
      expect(h.sockets, hasLength(2));
      expect(h.tokenCalls, [false, true], reason: '重连必须重新签 token');
      expect(h.sockets[1].headers['Authorization'], 'Bearer st-2');
      expect(h.stt.live, isTrue);
      h.stt.dispose();
    });
  });

  test('连续失败指数退避;期间 stop 立即生效', () {
    fakeAsync((async) {
      final h = Harness()..autoOpen = false;
      h.stt.start();
      async.flushMicrotasks();
      // 握手超时(10 s)
      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();
      expect(h.sockets.first.closed, isTrue);
      async.elapse(const Duration(milliseconds: 500));
      expect(h.sockets, hasLength(2));
      async.elapse(const Duration(seconds: 10));
      async.elapse(const Duration(milliseconds: 900));
      expect(h.sockets, hasLength(2), reason: '第二次退避 1 s');
      async.elapse(const Duration(milliseconds: 200));
      expect(h.sockets, hasLength(3));
      h.stt.stop();
      async.elapse(const Duration(minutes: 1));
      expect(h.sockets, hasLength(3));
      expect(h.sockets.every((s) => s.closed), isTrue);
    });
  });

  test('不可恢复的 token 错误(not_configured)→ onFatal,不再重试', () {
    fakeAsync((async) {
      final h = Harness()
        ..tokenError = CaptionTokenException('not_configured');
      h.stt.start();
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 1));
      expect(h.fatals, ['not_configured']);
      expect(h.tokenCalls, hasLength(1));
      expect(h.sockets, isEmpty);
      expect(h.stt.running, isFalse);
    });
  });

  test('限流 → 长退避(60 s)后用 fresh token 再试', () {
    fakeAsync((async) {
      final h = Harness()..tokenError = CaptionTokenException('rate_limited');
      h.stt.start();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 59));
      expect(h.tokenCalls, hasLength(1));
      h.tokenError = null;
      async.elapse(const Duration(seconds: 2));
      expect(h.tokenCalls, [false, true]);
      expect(h.sockets, hasLength(1));
      h.stt.dispose();
    });
  });

  group('语气词过滤', () {
    for (final s in ['嗯。', '对对对', '啊?', '哦!', '呃……', '  ', '。', '嗯,对。']) {
      test('「$s」是纯语气词', () => expect(isFillerOnly(s), isTrue));
    }
    for (final s in ['对,明天见。', '嗯我觉得可以', 'OK', '好的', '啊这个方案不行']) {
      test('「$s」有内容', () => expect(isFillerOnly(s), isFalse));
    }
  });

  group('SignalingCaptionTokenSource', () {
    test('换圈 / 退房 clear() 后,旧会话在路上的签发作废,不缓存也不复用', () async {
      final inbox = StreamController<Map<String, dynamic>>.broadcast();
      final sent = <Map<String, dynamic>>[];
      final src = SignalingCaptionTokenSource(
        send: sent.add,
        messages: inbox.stream,
        e2eeOptIn: () => false,
      );
      final old = src.call();
      expect(sent, hasLength(1));
      src.clear();
      // 新会话要 token:必须重新签,不能拿到旧圈子的那张
      final fresh = src.call();
      expect(sent, hasLength(2));
      final expires = DateTime.now().millisecondsSinceEpoch + 300000;
      inbox.add({'t': 'cap_token', 'token': 'st-a', 'expiresAt': expires, 'url': 'wss://x'});
      await expectLater(old, throwsA(isA<CaptionTokenException>()));
      expect((await fresh).token, 'st-a');
      await inbox.close();
    });
  });
}