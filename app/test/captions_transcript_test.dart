// 转写记录 + 自字幕 + 一机一识别会话 + 机器人帧(契约 docs/plans/transcript-bot-contract.md)。
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/captions/caption_controller.dart';
import 'package:lares_app/src/captions/caption_protocol.dart';
import 'package:lares_app/src/captions/caption_wiring.dart';
import 'package:lares_app/src/captions/transcript_sink.dart';
import 'package:lares_app/src/state/circle_features.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/ui/caption_panel.dart';

import 'helpers/caption_fakes.dart';
import 'helpers/localized_app.dart';
import 'room_screen_test.dart' show FakeRtcService, FakeSignalingClient;

/// stop/dispose 由测试手动放行的识别器:用来证明「旧的没关完绝不开新的」。
class SlowTranscriber implements CaptionTranscriber {
  SlowTranscriber(this.onPartial, this.onFinal);
  final void Function(String, String) onPartial;
  final void Function(String, String) onFinal;
  bool started = false;
  bool stopping = false;
  bool disposed = false;
  final Completer<void> release = Completer<void>();

  @override
  void start() => started = true;
  @override
  void addPcm(Uint8List pcm) {}
  @override
  Future<void> stop() {
    stopping = true;
    return release.future;
  }

  @override
  Future<void> dispose() async => disposed = true;
}

const CaptionConditions ok = CaptionConditions(
    available: true, inRoom: true, muted: false, provide: true);
const CaptionConditions archiveOk = CaptionConditions(
    available: true, inRoom: true, muted: false, provide: true, archive: true);

class H {
  H() {
    captions = CaptionController(
      transcriberFactory: ({
        required onPartial,
        required onFinal,
        required onFatal,
      }) {
        final t = FakeTranscriber(onPartial, onFinal, onFatal);
        stts.add(t);
        return t;
      },
      nameOf: (id) => const {'u1': '小明', 'u2': '阿花'}[id] ?? id,
      now: () => clock,
    );
  }
  late final CaptionController captions;
  final FakeChannel ch = FakeChannel();
  final FakeTap tap = FakeTap();
  final List<FakeTranscriber> stts = [];
  DateTime clock = DateTime(2026, 1, 1, 10);

  FakeTranscriber? get active {
    final a = stts.where((s) => s.active);
    return a.isEmpty ? null : a.single;
  }

  void bind([CaptionConditions c = ok]) {
    captions.bindSession(ch, tap);
    captions.updateConditions(c);
  }
}

void main() {
  group('自字幕', () {
    test('我开着字幕:自己的 partial/定稿本地插入、标「我」;有请求者时广播', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.captions.setWantCaptions(true);
        async.flushMicrotasks();
        h.ch.remotes.add('u1');
        h.ch.receive('u1', {'t': 'capreq', 'on': true});
        expect(h.stts.length, 1, reason: '我 + 远端请求者:仍只一个会话');
        h.active!.onPartial('a', '你好');
        expect(h.captions.lines.single.isSelf, isTrue);
        expect(h.captions.lines.single.isFinal, isFalse);
        h.active!.onFinal('a', '你好呀。');
        expect(h.captions.lines.single.text, '你好呀。');
        expect(h.captions.lines.single.isFinal, isTrue);
        final caps = h.ch.sentOfType('cap');
        expect(caps.length, 2);
        expect(h.ch.published.where((p) => p.msg['t'] == 'cap').every((p) => p.to == null),
            isTrue, reason: 'cap 广播');
        // 自己的回环帧不会重复插入
        h.ch.receive('me', {'t': 'cap', 'id': 'a', 'seq': 99, 'text': 'x', 'final': true});
        expect(h.captions.lines.length, 1);
        h.captions.dispose();
      });
    });

    testWidgets('面板里自己的行显示「我」', (tester) async {
      final h = H()..bind();
      await tester.pumpWidget(localizedScaffold(CaptionPanel(captions: h.captions)));
      await h.captions.setWantCaptions(true);
      h.active!.onFinal('s1', '大家好。');
      await tester.pump();
      final f = find.byKey(const ValueKey('cap-me-s1'));
      expect((tester.widget<Text>(f).textSpan!).toPlainText(), '我: 大家好。');
      await h.captions.setWantCaptions(false);
      await tester.pump();
      h.captions.dispose();
    });
  });

  group('一机一识别会话', () {
    test('旧识别器 stop 未完成时,条件反复翻转也绝不新建第二个', () {
      fakeAsync((async) {
        final slow = <SlowTranscriber>[];
        final c = CaptionController(transcriberFactory: ({
          required onPartial,
          required onFinal,
          required onFatal,
        }) {
          final t = SlowTranscriber(onPartial, onFinal);
          slow.add(t);
          return t;
        });
        final ch = FakeChannel();
        final tap = FakeTap();
        c.bindSession(ch, tap);
        c.updateConditions(archiveOk);
        expect(slow.length, 1);
        c.updateConditions(ok.copyWithMuted(true));
        expect(slow.single.stopping, isTrue);
        c.updateConditions(archiveOk);
        async.flushMicrotasks();
        expect(slow.length, 1, reason: '旧的还没关完:排队,不开新连接');
        expect(c.liveTranscribers, 1);
        slow.single.release.complete();
        async.flushMicrotasks();
        expect(slow.length, 2, reason: '旧的关完才开新的');
        expect(c.maxConcurrentTranscribers, 1);
        c.dispose();
        slow.last.release.complete();
        async.flushMicrotasks();
      });
    });

    test('压测:请求者进出 / 静音 / 归档开关 / 自字幕乱序翻转 → 并发识别器峰值 = 1', () {
      fakeAsync((async) {
        final rnd = Random(42);
        final slow = <SlowTranscriber>[];
        final c = CaptionController(transcriberFactory: ({
          required onPartial,
          required onFinal,
          required onFatal,
        }) {
          final t = SlowTranscriber(onPartial, onFinal);
          slow.add(t);
          return t;
        });
        final ch = FakeChannel();
        final tap = FakeTap();
        c.bindSession(ch, tap);
        var muted = false;
        var archive = false;
        void apply() => c.updateConditions(CaptionConditions(
            available: true,
            inRoom: true,
            muted: muted,
            provide: true,
            archive: archive));
        apply();
        final ids = ['u1', 'u2', 'u3', 'u4'];
        for (var i = 0; i < 600; i++) {
          final id = ids[rnd.nextInt(ids.length)];
          switch (rnd.nextInt(7)) {
            case 0:
              ch.remotes.add(id);
              ch.receive(id, {'t': 'capreq', 'on': true});
            case 1:
              ch.receive(id, {'t': 'capreq', 'on': false});
            case 2:
              ch.leave(id);
            case 3:
              muted = !muted;
              apply();
            case 4:
              archive = !archive;
              apply();
            case 5:
              unawaited(c.setWantCaptions(rnd.nextBool()));
            case 6:
              // 随机放行一些正在关闭的旧识别器
              for (final s in slow.where((s) => s.stopping && !s.release.isCompleted)) {
                if (rnd.nextBool()) s.release.complete();
              }
          }
          async.flushMicrotasks();
          final alive = slow.where((s) => !s.disposed).length;
          expect(alive, lessThanOrEqualTo(1), reason: '第 $i 步:同时活着的识别器');
          expect(c.liveTranscribers, lessThanOrEqualTo(1));
        }
        expect(slow.length, greaterThan(5), reason: '压测确实反复开关过');
        expect(c.maxConcurrentTranscribers, 1);
        c.dispose();
        for (final s in slow) {
          if (!s.release.isCompleted) s.release.complete();
        }
        async.flushMicrotasks();
      });
    });
  });

  group('转写记录门控', () {
    test('归档开着:没有请求者也转写;静音不转;不愿意不转并广播 capack(false)', () {
      fakeAsync((async) {
        final h = H()..bind(archiveOk);
        expect(h.active, isNotNull, reason: '归档开着、开麦、愿意 → 转写');
        expect(h.captions.archiveOn, isTrue);
        h.captions.updateConditions(const CaptionConditions(
            available: true, inRoom: true, muted: true, provide: true, archive: true));
        async.flushMicrotasks();
        expect(h.active, isNull, reason: '静音不转');
        h.captions.updateConditions(const CaptionConditions(
            available: true, inRoom: true, muted: false, provide: false, archive: true));
        async.flushMicrotasks();
        expect(h.active, isNull, reason: '不愿意(provide 关)不转');
        final acks = h.ch.published.where((p) => p.msg['t'] == 'capack').toList();
        expect(acks.last.msg['on'], isFalse);
        expect(acks.last.to, isNull, reason: '归档时 capack 广播给所有人');
        h.captions.dispose();
      });
    });

    test('点横幅停止 = 本次不进记录:停转写并广播 capack(false)', () {
      fakeAsync((async) {
        final h = H()..bind(archiveOk);
        expect(h.active, isNotNull);
        h.captions.stopForSession();
        async.flushMicrotasks();
        expect(h.active, isNull);
        expect(h.ch.sentOfType('capack').last['on'], isFalse);
        h.captions.dispose();
      });
    });

    testWidgets('全员常驻提示 + 拒绝者显示「未转写」', (tester) async {
      final h = H()..bind(archiveOk);
      h.ch.join('u1', mic: true);
      h.ch.join('u2', mic: true);
      await tester.pumpWidget(
          localizedScaffold(CaptionProvidingBanner(captions: h.captions)));
      expect(find.text('本圈已开启转写记录 · 语音经阿里云识别'), findsOneWidget);
      h.ch.receive('u2', {'t': 'capack', 'on': false});
      await tester.pump();
      expect(find.text('阿花 未转写'), findsOneWidget);
      expect(h.captions.isDeclined('u2'), isTrue);
      expect(h.captions.isDeclined('u1'), isFalse);
      // 点提示 = 本次不再转写我的话
      await tester.tap(find.byKey(const ValueKey('captions-archive-banner')));
      await tester.pump();
      expect(h.active, isNull);
      expect(find.textContaining('你的话这次不转写'), findsOneWidget);
      h.captions.dispose();
    });
  });

  group('定稿出口 → transcript_append', () {
    test('只有定稿进 sink(partial 永不),字段正确;归档关着不发', () {
      fakeAsync((async) {
        final sent = <Map<String, dynamic>>[];
        var archive = true;
        final h = H()..bind(archiveOk);
        h.captions.onOwnFinal = CaptionWiring.ownFinalHandler(
          circleId: () => 'c1',
          archiveOn: (_) => archive,
          sink: RoutingTranscriptSink(
            plain: SignalingTranscriptSink(sent.add),
            isEncrypted: (_) => false,
          ),
        );
        final stt = h.active!;
        stt.onPartial('i1', '今天');
        h.clock = h.clock.add(const Duration(seconds: 3));
        stt.onPartial('i1', '今天开会');
        expect(sent, isEmpty, reason: 'partial 不进记录');
        h.clock = h.clock.add(const Duration(seconds: 2));
        stt.onFinal('i1', ' 今天开会。 ');
        expect(sent, [
          {
            't': 'transcript_append',
            'circleId': 'c1',
            'id': 'i1',
            'text': '今天开会。',
            'startedAt': DateTime(2026, 1, 1, 10).millisecondsSinceEpoch,
          }
        ]);
        stt.onFinal('i1', '今天开会。');
        expect(sent.length, 1, reason: '重复定稿只记一次');
        stt.onFinal('i2', '嗯');
        expect(sent.length, 1, reason: '语气词不进记录');
        archive = false;
        stt.onFinal('i3', '这句不记。');
        expect(sent.length, 1, reason: '归档关着不发');
        h.captions.dispose();
      });
    });

    test('关「提供字幕」/点停止后,关闭途中迟到的定稿不进记录', () {
      fakeAsync((async) {
        for (final optOut in ['provide', 'stop']) {
          final sent = <Map<String, dynamic>>[];
          final h = H()..bind(archiveOk);
          h.captions.onOwnFinal = CaptionWiring.ownFinalHandler(
            circleId: () => 'c1',
            archiveOn: (_) => true,
            sink: RoutingTranscriptSink(
              plain: SignalingTranscriptSink(sent.add),
              isEncrypted: (_) => false,
            ),
          );
          final stt = h.active!;
          if (optOut == 'provide') {
            h.captions.updateConditions(const CaptionConditions(
                available: true, inRoom: true, muted: false, provide: false, archive: true));
          } else {
            h.captions.stopForSession();
          }
          // 识别器 stop 期间把最后一句定稿吐出来
          stt.onFinal('late', '这句是关掉之后才到的。');
          async.flushMicrotasks();
          expect(sent, isEmpty, reason: '$optOut:不愿意之后的定稿绝不归档');
          h.captions.dispose();
        }
      });
    });

    test('E2EE 圈:走 encrypted 槽;槽未注入时丢弃,绝不明文上送', () {
      final plain = <Map<String, dynamic>>[];
      final enc = <String>[];
      final sink = RoutingTranscriptSink(
        plain: SignalingTranscriptSink(plain.add),
        isEncrypted: (id) => id == 'secret',
      );
      final now = DateTime(2026);
      sink.appendFinal(circleId: 'secret', id: 'a', text: 'x', startedAt: now);
      expect(plain, isEmpty);
      sink.encrypted = _Rec(enc);
      sink.appendFinal(circleId: 'secret', id: 'b', text: 'y', startedAt: now);
      expect(enc, ['b']);
      sink.appendFinal(circleId: 'open', id: 'c', text: 'z', startedAt: now);
      expect(plain.single['id'], 'c');
    });
  });

  // TestFlight 46 回归:圈主关了「实时字幕」(chat / study 用途的默认)、只开转写记录 ——
  // 以前 captions 功能位并进了 available → willing=false → 识别从不启动,自己的话进不了记录。
  group('转写记录独立于「实时字幕」功能位', () {
    RoomController roomWith({required bool captionsFeature, required bool transcript}) {
      final sig = FakeSignalingClient();
      final c = RoomController(
          signaling: sig, rtc: FakeRtcService(), userId: 'u_me', deviceId: 'd', userName: '我');
      unawaited(c.join('c1').catchError((Object _) {}));
      sig.testInject({
        't': 'room',
        'circleId': 'c1',
        'members': [
          {'userId': 'u_me', 'name': '我', 'status': 'free'},
        ],
      });
      c.captionsAvailable = true;
      sig.testInject({
        't': 'circle_settings',
        'circle': {
          'id': 'c1',
          'registered': true,
          'transcript': transcript,
          'features': {'captions': captionsFeature, 'transcript': transcript},
        },
      });
      return c;
    }

    CaptionConditions condsOf(RoomController c, {bool provide = true}) =>
        CaptionWiring.conditionsFor(
            controller: c,
            inRoom: true,
            provide: provide,
            encrypted: false,
            e2eeCloud: false,
            sttSupported: true);

    test('胶水层:字幕功能关 + 转写开 → 仍 willing、archive 开', () async {
      final c = roomWith(captionsFeature: false, transcript: true);
      await pumpEventQueue();
      expect(c.circleId, 'c1');
      expect(c.isFeatureOn('c1', CircleFeature.captions), isFalse);
      final cond = condsOf(c);
      expect(cond.liveCaptions, isFalse);
      expect(cond.archive, isTrue);
      expect(cond.willing, isTrue, reason: '实时字幕开关不该否决转写记录');
      expect(condsOf(c, provide: false).willing, isFalse, reason: '本人「提供字幕」关 → 绝不转写');
      c.dispose();
    });

    test('字幕功能关 + 转写开:识别启动,自己的定稿进 sink;不发 cap 帧给请求者', () {
      fakeAsync((async) {
        final sent = <Map<String, dynamic>>[];
        final h = H()
          ..bind(const CaptionConditions(
              available: true,
              inRoom: true,
              muted: false,
              provide: true,
              archive: true,
              liveCaptions: false));
        h.captions.onOwnFinal = CaptionWiring.ownFinalHandler(
          circleId: () => 'c1',
          archiveOn: (_) => true,
          sink: RoutingTranscriptSink(
              plain: SignalingTranscriptSink(sent.add), isEncrypted: (_) => false),
        );
        expect(h.active, isNotNull, reason: '转写记录开着就该识别');
        h.ch.remotes.add('u1');
        h.ch.receive('u1', {'t': 'capreq', 'on': true});
        async.flushMicrotasks();
        h.active!.onFinal('i1', '我自己说的话。');
        async.flushMicrotasks();
        expect(sent.single['text'], '我自己说的话。');
        expect(h.ch.published.where((p) => p.msg['t'] == 'cap'), isEmpty,
            reason: '实时字幕关:字幕帧不外发');
        h.captions.dispose();
      });
    });

    test('字幕功能关 + 转写开 + 本人不提供 → 不识别、不进记录', () {
      fakeAsync((async) {
        final h = H()
          ..bind(const CaptionConditions(
              available: true,
              inRoom: true,
              muted: false,
              provide: false,
              archive: true,
              liveCaptions: false));
        expect(h.active, isNull);
        h.captions.dispose();
      });
    });

    test('字幕功能关 + 转写关:有人请求也不识别', () {
      fakeAsync((async) {
        final h = H()
          ..bind(const CaptionConditions(
              available: true, inRoom: true, muted: false, provide: true, liveCaptions: false));
        h.ch.remotes.add('u1');
        h.ch.receive('u1', {'t': 'capreq', 'on': true});
        unawaited(h.captions.setWantCaptions(true));
        async.flushMicrotasks();
        expect(h.active, isNull);
        h.captions.setWantCaptions(false);
        async.flushMicrotasks();
        h.captions.dispose();
      });
    });
  });

  group('机器人字幕帧', () {
    List<int> bytes(Map<String, dynamic> m) => utf8.encode(jsonEncode(m));
    final botCap = {
      't': 'cap',
      'id': 'b1',
      'seq': 1,
      'text': '会议纪要已开始',
      'final': true,
      'bot': {'id': 'tok1', 'name': '小助手'},
    };

    test('没有 participant + bot 字段 → 归给 bot:<id>', () {
      final a = attributeCaptionFrame(sender: '', bytes: bytes(botCap), localIdentity: 'me')!;
      expect(a.isBot, isTrue);
      expect(a.identity, 'bot:tok1');
      expect(a.botName, '小助手');
      expect(attributeCaptionFrame(sender: null, bytes: bytes(botCap))?.isBot, isTrue);
    });

    test('伪造:成员发带 bot 字段的 cap → 丢弃;无 participant 但没有 bot → 丢弃', () {
      expect(attributeCaptionFrame(sender: 'u1', bytes: bytes(botCap)), isNull);
      expect(attributeCaptionFrame(sender: 'bot:tok1', bytes: bytes({...botCap}..remove('bot'))),
          isNull);
      expect(
          attributeCaptionFrame(sender: '', bytes: bytes({...botCap}..remove('bot'))), isNull);
      expect(attributeCaptionFrame(sender: '', bytes: bytes({'t': 'capreq', 'on': true})),
          isNull);
      final peer = attributeCaptionFrame(
          sender: 'u1', bytes: bytes({...botCap}..remove('bot')), localIdentity: 'me')!;
      expect(peer.isBot, isFalse);
      expect(peer.identity, 'u1');
    });

    test('控制器:机器人行显示机器人名;成员冒充被丢', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.captions.setWantCaptions(true);
        async.flushMicrotasks();
        h.ch.receive('', botCap); // 无 participant(服务器 SendData)
        h.ch.receive('u1', botCap);
        final bots = h.captions.lines.where((l) => l.isBot).toList();
        expect(bots.single.name, '小助手');
        expect(bots.single.identity, 'bot:tok1');
        expect(h.captions.lines.where((l) => l.identity == 'u1'), isEmpty);
        h.captions.setWantCaptions(false);
        async.flushMicrotasks();
        h.captions.dispose();
      });
    });
  });
}

class _Rec implements TranscriptSink {
  _Rec(this.ids);
  final List<String> ids;
  @override
  void appendFinal({
    required String circleId,
    required String id,
    required String text,
    required DateTime startedAt,
  }) =>
      ids.add(id);
}

extension on CaptionConditions {
  CaptionConditions copyWithMuted(bool m) => CaptionConditions(
      available: available, inRoom: inRoom, muted: m, provide: provide, archive: archive);
}
