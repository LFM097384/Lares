// AI 状态帧(lares.ai)解析 + AiStateHolder:发送者过滤、seq 去旧、过期、兜底、钉住。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/state/ai_state.dart';

List<int> _f(Object json) => utf8.encode(jsonEncode(json));

void main() {
  group('parseAiStateFrame', () {
    test('合法帧', () {
      final f = parseAiStateFrame(
          'u_ai_1', _f({'t': 'state', 'state': 'thinking', 'seq': 3}));
      expect(f, isNotNull);
      expect(f!.state, AiActivity.thinking);
      expect(f.seq, 3);
    });

    test('不是 u_ai_ 发的 → null', () {
      expect(
          parseAiStateFrame(
              'u_1', _f({'t': 'state', 'state': 'speaking', 'seq': 1})),
          isNull);
      expect(
          parseAiStateFrame(
              '', _f({'t': 'state', 'state': 'speaking', 'seq': 1})),
          isNull);
    });

    test('坏数据 → null', () {
      expect(parseAiStateFrame('u_ai_1', [0xff, 0x00]), isNull);
      expect(parseAiStateFrame('u_ai_1', _f([1, 2])), isNull);
      expect(parseAiStateFrame('u_ai_1', _f({'t': 'x', 'state': 'idle', 'seq': 1})),
          isNull);
      expect(
          parseAiStateFrame(
              'u_ai_1', _f({'t': 'state', 'state': 'dancing', 'seq': 1})),
          isNull);
      expect(parseAiStateFrame('u_ai_1', _f({'t': 'state', 'state': 'idle'})),
          isNull);
      expect(
          parseAiStateFrame(
              'u_ai_1', _f({'t': 'state', 'state': 'idle', 'seq': '1'})),
          isNull);
    });

    test('四种状态都认', () {
      for (final a in AiActivity.values) {
        expect(parseAiStateJson({'t': 'state', 'state': a.name, 'seq': 0})!.state,
            a);
      }
    });
  });

  test('fallbackAiActivity', () {
    expect(fallbackAiActivity(speaking: true, trigger: 'ptt'),
        AiActivity.speaking);
    expect(fallbackAiActivity(speaking: false, trigger: 'ptt'), AiActivity.idle);
    expect(fallbackAiActivity(speaking: false, trigger: 'wake'),
        AiActivity.listening);
    expect(fallbackAiActivity(speaking: false, trigger: 'always'),
        AiActivity.listening);
    expect(fallbackAiActivity(speaking: false), AiActivity.listening);
  });

  group('AiStateHolder', () {
    late DateTime now;
    late AiStateHolder h;
    late int notified;

    setUp(() {
      now = DateTime(2026, 1, 1, 12);
      h = AiStateHolder(now: () => now, scheduleStaleCheck: false);
      notified = 0;
      h.addListener(() => notified++);
    });
    tearDown(() => h.dispose());

    bool feed(String who, String state, int seq) =>
        h.ingest(who, _f({'t': 'state', 'state': state, 'seq': seq}));

    test('收帧 → reported;通知一次', () {
      expect(h.isKnown('u_ai_1'), isFalse);
      expect(h.reported('u_ai_1'), isNull);
      expect(feed('u_ai_1', 'thinking', 1), isTrue);
      expect(h.isKnown('u_ai_1'), isTrue);
      expect(h.reported('u_ai_1'), AiActivity.thinking);
      expect(notified, 1);
    });

    test('seq 不大于上一帧 → 丢', () {
      feed('u_ai_1', 'speaking', 5);
      expect(feed('u_ai_1', 'idle', 5), isFalse);
      expect(feed('u_ai_1', 'idle', 4), isFalse);
      expect(h.reported('u_ai_1'), AiActivity.speaking);
      expect(feed('u_ai_1', 'listening', 6), isTrue);
      expect(h.reported('u_ai_1'), AiActivity.listening);
    });

    test('seq 按发送者分开记', () {
      feed('u_ai_1', 'speaking', 9);
      expect(feed('u_ai_2', 'thinking', 1), isTrue);
      expect(h.reported('u_ai_2'), AiActivity.thinking);
    });

    test('非 AI 发送者 → 不认', () {
      expect(feed('u_1', 'speaking', 1), isFalse);
      expect(h.isKnown('u_1'), isFalse);
      expect(notified, 0);
    });

    test('thinking / speaking 超过 30 秒没更新 → listening;idle 不过期', () {
      feed('u_ai_1', 'thinking', 1);
      now = now.add(const Duration(seconds: 29));
      expect(h.reported('u_ai_1'), AiActivity.thinking);
      now = now.add(const Duration(seconds: 2));
      expect(h.reported('u_ai_1'), AiActivity.listening);

      feed('u_ai_2', 'idle', 1);
      now = now.add(const Duration(minutes: 10));
      expect(h.reported('u_ai_2'), AiActivity.idle);
    });

    test('resolve:没帧走兜底,有帧用帧', () {
      expect(h.resolve('u_ai_1', speaking: false, trigger: 'ptt'),
          AiActivity.idle);
      expect(h.resolve('u_ai_1', speaking: false, trigger: 'wake'),
          AiActivity.listening);
      expect(h.resolve('u_ai_1', speaking: true), AiActivity.speaking);
      feed('u_ai_1', 'thinking', 1);
      expect(h.resolve('u_ai_1', speaking: false, trigger: 'ptt'),
          AiActivity.thinking);
    });

    test('force 钉住:不过期、clear 后还在;null 取消', () {
      h.force('u_ai_1', AiActivity.speaking);
      now = now.add(const Duration(minutes: 5));
      expect(h.reported('u_ai_1'), AiActivity.speaking);
      h.clear();
      expect(h.reported('u_ai_1'), AiActivity.speaking);
      h.force('u_ai_1', null);
      expect(h.reported('u_ai_1'), isNull);
    });

    test('remove / clear 忘掉帧', () {
      feed('u_ai_1', 'thinking', 1);
      feed('u_ai_2', 'thinking', 1);
      h.remove('u_ai_1');
      expect(h.isKnown('u_ai_1'), isFalse);
      expect(h.isKnown('u_ai_2'), isTrue);
      h.clear();
      expect(h.isKnown('u_ai_2'), isFalse);
      // 清空后 seq 重新从头认
      expect(feed('u_ai_2', 'idle', 0), isTrue);
    });
  });

  test('过期定时器到点通知界面', () async {
    final h = AiStateHolder(staleAfter: const Duration(milliseconds: 20));
    var n = 0;
    h.addListener(() => n++);
    h.ingest('u_ai_1', _f({'t': 'state', 'state': 'speaking', 'seq': 1}));
    expect(n, 1);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(n, 2);
    expect(h.reported('u_ai_1'), AiActivity.listening);
    h.dispose();
  });
}
