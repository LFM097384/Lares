// 实时字幕:CaptionController 门控 / 协议 / 节流 / 归属 单测(全部假实现)。
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/captions/caption_controller.dart';
import 'package:lares_app/src/captions/caption_protocol.dart';
import 'package:lares_app/src/captions/caption_wiring.dart';
import 'package:lares_app/src/state/models.dart';
import 'package:lares_app/src/rtc/rtc_service.dart';

import 'helpers/caption_fakes.dart';

class H {
  H({Map<String, String>? names}) {
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
      nameOf: (id) => (names ?? const {'u1': '小明', 'u2': '阿花'})[id] ?? id,
    );
  }

  late final CaptionController captions;
  final FakeChannel ch = FakeChannel();
  final FakeTap tap = FakeTap();
  final List<FakeTranscriber> stts = [];

  FakeTranscriber? get active {
    final a = stts.where((s) => s.active);
    return a.isEmpty ? null : a.single;
  }

  static const CaptionConditions ok = CaptionConditions(
    available: true,
    inRoom: true,
    muted: false,
    provide: true,
  );

  void bind([CaptionConditions c = ok]) {
    captions.bindSession(ch, tap);
    captions.updateConditions(c);
  }

  void requestFrom(String id, {bool on = true}) {
    if (!ch.remotes.contains(id)) ch.remotes.add(id);
    ch.receive(id, {'t': 'capreq', 'on': on});
  }
}

void main() {
  group('门控:只在全部条件满足时转写', () {
    test('没人需要字幕 → 不转写;有远端需要 → 转写并注册麦克风抽头', () {
      fakeAsync((async) {
        final h = H()..bind();
        expect(h.stts, isEmpty);
        h.requestFrom('u1');
        expect(h.active, isNotNull);
        expect(h.tap.attachCount, 1);
        h.tap.frame(3200);
        expect(h.active!.pcmBytes, 3200);
        expect(h.captions.transcribing, isTrue);
        expect(h.captions.requesterNames, ['小明']);
        h.captions.dispose();
      });
    });

    test('只有我自己打开字幕 → 也转写自己(本地显示「我」),但不往外发 cap', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.captions.setWantCaptions(true);
        async.flushMicrotasks();
        expect(h.active, isNotNull, reason: '自字幕:我自己要字幕也算有人需要');
        h.active!.onFinal('s1', '今天天气不错。');
        expect(h.captions.lines.single.isSelf, isTrue);
        expect(h.captions.lines.single.identity, 'me');
        expect(h.ch.sentOfType('cap'), isEmpty, reason: '没有远端请求者:不发');
        // 自己发回来的回声不算请求者
        h.ch.receive('me', {'t': 'capreq', 'on': true});
        expect(h.captions.requesterNames, isEmpty);
        h.captions.setWantCaptions(false);
        async.flushMicrotasks();
        expect(h.active, isNull);
        h.captions.dispose();
      });
    });

    for (final (name, cond) in [
      ('静音', const CaptionConditions(
          available: true, inRoom: true, muted: true, provide: true)),
      ('不在房', const CaptionConditions(
          available: true, inRoom: false, muted: false, provide: true)),
      ('设置关了', const CaptionConditions(
          available: true, inRoom: true, muted: false, provide: false)),
      ('服务器没配', const CaptionConditions(
          available: false, inRoom: true, muted: false, provide: true)),
      ('加密圈未同意云端', const CaptionConditions(
          available: true,
          inRoom: true,
          muted: false,
          provide: true,
          encrypted: true)),
    ]) {
      test('$name → 不转写', () {
        fakeAsync((async) {
          final h = H()..bind(cond);
          h.requestFrom('u1');
          expect(h.stts, isEmpty);
          h.captions.dispose();
        });
      });
    }

    test('加密圈 + 用户同意云端 → 转写', () {
      fakeAsync((async) {
        final h = H()
          ..bind(const CaptionConditions(
              available: true,
              inRoom: true,
              muted: false,
              provide: true,
              encrypted: true,
              e2eeCloud: true));
        h.requestFrom('u1');
        expect(h.active, isNotNull);
        h.captions.dispose();
      });
    });

    test('Lares 显示未静音但 SDK 轨道没在发 → 不转写', () {
      fakeAsync((async) {
        final h = H();
        h.tap.unmuted = false;
        h.bind();
        h.requestFrom('u1');
        expect(h.stts, isEmpty);
        h.tap.unmuted = true;
        h.tap.changed();
        expect(h.active, isNotNull);
        h.captions.dispose();
      });
    });
  });

  group('及时停止并关连接', () {
    test('静音 → 立即 stop(识别器关连接)、摘掉抽头', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.requestFrom('u1');
        final stt = h.active!;
        h.captions.updateConditions(const CaptionConditions(
            available: true, inRoom: true, muted: true, provide: true));
        async.flushMicrotasks();
        expect(stt.stopped, isTrue);
        expect(stt.disposed, isTrue);
        expect(h.tap.attached, isFalse);
        expect(h.captions.transcribing, isFalse);
        // 静音期间的帧不会到识别器
        final before = stt.pcmBytes;
        h.tap.frame();
        expect(stt.pcmBytes, before);
        h.captions.dispose();
      });
    });

    test('唯一的请求者关掉字幕 → 停', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.requestFrom('u1');
        final stt = h.active!;
        h.requestFrom('u1', on: false);
        async.flushMicrotasks();
        expect(stt.stopped, isTrue);
        h.captions.dispose();
      });
    });

    test('唯一的请求者离开房间 → 停;还有别的请求者 → 继续', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.requestFrom('u1');
        h.requestFrom('u2');
        final stt = h.active!;
        h.ch.leave('u1');
        expect(stt.stopped, isFalse);
        expect(h.captions.requesterNames, ['阿花']);
        h.ch.leave('u2');
        async.flushMicrotasks();
        expect(stt.stopped, isTrue);
        h.captions.dispose();
      });
    });

    test('点横幅(本次不再生成)→ 停,且新的请求也不再触发;capack 改为 false', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.requestFrom('u1');
        final stt = h.active!;
        h.captions.stopForSession();
        async.flushMicrotasks();
        expect(stt.stopped, isTrue);
        h.requestFrom('u2');
        expect(h.active, isNull);
        final acks = h.ch.sentOfType('capack').toList();
        expect(acks.last['on'], isFalse);
        // 换圈 / 退房后重置
        h.captions.resetRoomSession();
        h.captions.updateConditions(const CaptionConditions(
            available: true, inRoom: true, muted: true, provide: true));
        h.captions.updateConditions(H.ok);
        expect(h.active, isNotNull);
        h.captions.dispose();
      });
    });

    test('解绑会话(退房 / 媒体降级)→ 停', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.requestFrom('u1');
        final stt = h.active!;
        h.captions.unbindSession();
        async.flushMicrotasks();
        expect(stt.stopped, isTrue);
        expect(h.captions.requesters, isEmpty);
        h.captions.dispose();
      });
    });

    test('识别器报不可恢复错误 → 停止并不再尝试', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.requestFrom('u1');
        h.active!.onFatal('not_configured');
        async.flushMicrotasks();
        expect(h.active, isNull);
        expect(h.captions.fatalReason, 'not_configured');
        h.requestFrom('u2');
        expect(h.active, isNull);
        h.captions.dispose();
      });
    });

    test('掉线自动恢复不算新会话:点过的「本次停止」不被清掉', () {
      // inRoom → joining(掉线恢复)→ inRoom:会话圈子不变,不触发 resetRoomSession
      expect(CaptionWiring.sessionCircle(RoomPhase.inRoom, 'c1'), 'c1');
      expect(CaptionWiring.sessionCircle(RoomPhase.joining, 'c1'), 'c1');
      expect(CaptionWiring.sessionCircle(RoomPhase.error, 'c1'), 'c1');
      expect(CaptionWiring.sessionCircle(RoomPhase.idle, 'c1'), isNull);
      fakeAsync((async) {
        final h = H()..bind();
        h.requestFrom('u1');
        h.captions.stopForSession();
        async.flushMicrotasks();
        // 恢复后只清 fatal,不清「本次停止」
        h.captions.clearFatal();
        h.requestFrom('u2');
        expect(h.active, isNull);
        expect(h.captions.stoppedForSession, isTrue);
        h.captions.dispose();
      });
    });

    test('恢复进房后 clearFatal → 可再试', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.requestFrom('u1');
        h.active!.onFatal('not_in_room');
        async.flushMicrotasks();
        expect(h.active, isNull);
        h.captions.clearFatal();
        expect(h.captions.fatalReason, isNull);
        expect(h.active, isNotNull);
        h.captions.dispose();
      });
    });
  });

  group('麦克风抽头:重新注册与看门狗', () {
    test('轨道变化(unmute / 重新发布 / 重连)→ 取消旧注册并重新注册', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.requestFrom('u1');
        h.tap.frame();
        expect(h.tap.attachCount, 1);
        h.tap.changed(); // 例如 TrackUnmutedEvent:restartTrack 换了底层轨道
        async.flushMicrotasks();
        expect(h.tap.attachCount, 2);
        expect(h.tap.cancelCount, 1);
        final stt = h.active!;
        final before = stt.pcmBytes;
        h.tap.frame(640);
        expect(stt.pcmBytes, before + 640);
        h.captions.dispose();
      });
    });

    test('轨道变化后 SDK 显示已静音 → 停止转写', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.requestFrom('u1');
        final stt = h.active!;
        h.tap.unmuted = false;
        h.tap.changed();
        async.flushMicrotasks();
        expect(stt.stopped, isTrue);
        h.captions.dispose();
      });
    });

    test('2 s 无首帧 → 重新注册一次;仍无帧 → 放弃、停止转写并记录', () {
      fakeAsync((async) {
        final logs = <String>[];
        final h = H();
        final c = CaptionController(
          transcriberFactory: ({
            required onPartial,
            required onFinal,
            required onFatal,
          }) {
            final t = FakeTranscriber(onPartial, onFinal, onFatal);
            h.stts.add(t);
            return t;
          },
          onLog: logs.add,
        );
        h.tap.deliver = false;
        c.bindSession(h.ch, h.tap);
        c.updateConditions(H.ok);
        h.requestFrom('u1');
        expect(h.tap.attachCount, 1);
        async.elapse(const Duration(milliseconds: 1900));
        expect(h.tap.attachCount, 1);
        async.elapse(const Duration(milliseconds: 200));
        expect(h.tap.attachCount, 2, reason: '第一次 2 s 超时 → 重新注册一次');
        expect(h.tap.cancelCount, 1, reason: '重试前先取消旧注册');
        async.elapse(const Duration(seconds: 3));
        expect(h.tap.attachCount, 2, reason: '最多两次');
        expect(c.tapFailed, isTrue);
        expect(c.transcribing, isFalse);
        expect(h.stts.single.stopped, isTrue);
        expect(logs.any((l) => l.contains('没有出帧')), isTrue);
        // 下一次轨道变化(比如用户重开麦)再给机会
        h.tap.deliver = true;
        h.tap.changed();
        expect(c.transcribing, isTrue);
        c.dispose();
      });
    });

    test('第二次注册出帧 → 健康,继续转写', () {
      fakeAsync((async) {
        final h = H();
        h.tap.deliver = false;
        h.bind();
        h.requestFrom('u1');
        async.elapse(const Duration(milliseconds: 2100));
        expect(h.tap.attachCount, 2);
        h.tap.deliver = true;
        h.tap.frame();
        async.elapse(const Duration(seconds: 5));
        expect(h.captions.tapFailed, isFalse);
        expect(h.active, isNotNull);
        h.captions.dispose();
      });
    });
  });

  group('发送:有请求者才广播、partial 节流、语气词撤回', () {
    test('cap 广播(一次转写全员共享),reliable 由通道保证;partial ≤5/s 且只发最新', () {
      fakeAsync((async) {
        final start = DateTime(2026);
        final h = H();
        final c = CaptionController(
          transcriberFactory: ({
            required onPartial,
            required onFinal,
            required onFatal,
          }) {
            final t = FakeTranscriber(onPartial, onFinal, onFatal);
            h.stts.add(t);
            return t;
          },
          now: () => start.add(async.elapsed),
        );
        c.bindSession(h.ch, h.tap);
        c.updateConditions(H.ok);
        h.requestFrom('u1');
        h.ch.remotes.add('u3'); // 在房但不要字幕
        final stt = h.active!;
        // 1 秒内来 20 条 partial
        for (var i = 1; i <= 20; i++) {
          stt.onPartial('it1', '字' * i);
          async.elapse(const Duration(milliseconds: 50));
        }
        async.elapse(const Duration(milliseconds: 300));
        final caps = h.ch.published.where((p) => p.msg['t'] == 'cap').toList();
        expect(caps.length, lessThanOrEqualTo(6), reason: '≤5/s(首条立即 + 每 200 ms 一条)');
        expect(caps.length, greaterThanOrEqualTo(4));
        expect(caps.last.msg['text'], '字' * 20, reason: '窗口结束时发最新的整句');
        expect(caps.every((p) => p.msg['final'] == false), isTrue);
        expect(caps.every((p) => p.to == null), isTrue,
            reason: '契约 §1:cap 广播,不带 destinationIdentities');
        // seq 单调递增
        final seqs = caps.map((p) => p.msg['seq'] as int).toList();
        for (var i = 1; i < seqs.length; i++) {
          expect(seqs[i], greaterThan(seqs[i - 1]));
        }
        // final 永远立即发,不受节流
        stt.onPartial('it2', '明');
        stt.onFinal('it2', '明天见。');
        final last = h.ch.published.last.msg;
        expect(last, containsPair('final', true));
        expect(last['text'], '明天见。');
        expect(last['id'], 'it2');
        // 定稿后迟到的 partial 不再发
        final n = h.ch.published.length;
        stt.onPartial('it2', '明天');
        async.elapse(const Duration(seconds: 1));
        expect(h.ch.published.length, n);
        c.dispose();
      });
    });

    test('节流窗口内被定稿抢先 → 挂起的 partial 丢弃', () {
      fakeAsync((async) {
        final start = DateTime(2026);
        final h = H();
        final c = CaptionController(
          transcriberFactory: ({
            required onPartial,
            required onFinal,
            required onFatal,
          }) {
            final t = FakeTranscriber(onPartial, onFinal, onFatal);
            h.stts.add(t);
            return t;
          },
          now: () => start.add(async.elapsed),
        );
        c.bindSession(h.ch, h.tap);
        c.updateConditions(H.ok);
        h.requestFrom('u1');
        final stt = h.active!;
        stt.onPartial('a', '你'); // 立即发
        stt.onPartial('a', '你好'); // 挂起
        stt.onFinal('a', '你好。');
        async.elapse(const Duration(seconds: 1));
        final caps = h.ch.sentOfType('cap').toList();
        expect(caps.map((m) => m['text']), ['你', '你好。']);
        c.dispose();
      });
    });

    test('语气词定稿 → 发空定稿让对端撤掉已显示的 partial', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.requestFrom('u1');
        h.active!.onFinal('x', '嗯。');
        final m = h.ch.sentOfType('cap').last;
        expect(m['text'], '');
        expect(m['final'], isTrue);
        h.captions.dispose();
      });
    });
  });

  group('请求者协议', () {
    test('打开字幕广播 capreq;有人进房单独补发;关掉广播 capreq off', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.captions.setWantCaptions(true);
        async.flushMicrotasks();
        final req = h.ch.published.last;
        expect(req.msg, {'t': 'capreq', 'on': true});
        expect(req.to, isNull, reason: '广播');
        h.ch.join('u9');
        async.flushMicrotasks();
        final again = h.ch.published.last;
        expect(again.msg, {'t': 'capreq', 'on': true});
        expect(again.to, ['u9'], reason: '只补发给新来的人');
        h.captions.setWantCaptions(false);
        async.flushMicrotasks();
        expect(h.ch.published.last.msg, {'t': 'capreq', 'on': false});
        // 没开字幕时有人进房 → 不发
        final n = h.ch.published.length;
        h.ch.join('u10');
        async.flushMicrotasks();
        expect(h.ch.published.length, n);
        h.captions.dispose();
      });
    });

    test('新房间会话(重连 / 唤醒)绑定时重新广播 capreq', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.captions.setWantCaptions(true);
        async.flushMicrotasks();
        final ch2 = FakeChannel();
        h.captions.bindSession(ch2, h.tap);
        async.flushMicrotasks();
        expect(ch2.published.single.msg, {'t': 'capreq', 'on': true});
        h.captions.dispose();
      });
    });

    test('收到 capreq → 回 capack(我愿不愿意)', () {
      fakeAsync((async) {
        final h = H()
          ..bind(const CaptionConditions(
              available: true, inRoom: true, muted: true, provide: false));
        h.requestFrom('u1');
        async.flushMicrotasks();
        final ack = h.ch.published.last;
        expect(ack.msg, {'t': 'capack', 'on': false});
        expect(ack.to, ['u1']);
        // 设置打开 → 主动告知请求者
        h.captions.updateConditions(const CaptionConditions(
            available: true, inRoom: true, muted: true, provide: true));
        async.flushMicrotasks();
        expect(h.ch.published.last.msg, {'t': 'capack', 'on': true});
        h.captions.dispose();
      });
    });
  });

  group('接收:归属与显示', () {
    test('按发送者 identity 归属到成员名,partial 原地替换,final 定稿', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.ch.remotes.addAll(['u1', 'u2']);
        h.captions.setWantCaptions(true);
        h.ch.receive('u1', {'t': 'cap', 'id': 'a', 'seq': 1, 'text': '今天', 'final': false});
        h.ch.receive('u2', {'t': 'cap', 'id': 'a', 'seq': 1, 'text': 'hello', 'final': false});
        h.ch.receive('u1', {'t': 'cap', 'id': 'a', 'seq': 2, 'text': '今天天气', 'final': false});
        var lines = h.captions.lines;
        expect(lines, hasLength(2), reason: '同一人同一 item 原地替换;不同人同 id 各自一行');
        expect(lines[0].name, '小明');
        expect(lines[0].text, '今天天气');
        expect(lines[0].isFinal, isFalse);
        expect(lines[1].name, '阿花');
        h.ch.receive('u1', {'t': 'cap', 'id': 'a', 'seq': 3, 'text': '今天天气不错。', 'final': true});
        // 乱序:更旧的 partial 不能覆盖定稿
        h.ch.receive('u1', {'t': 'cap', 'id': 'a', 'seq': 2, 'text': '今天天', 'final': false});
        lines = h.captions.lines;
        expect(lines[0].text, '今天天气不错。');
        expect(lines[0].isFinal, isTrue);
        expect(h.captions.providerNames, containsAll(['小明', '阿花']));
        // 空定稿(语气词)撤回
        h.ch.receive('u2', {'t': 'cap', 'id': 'a', 'seq': 2, 'text': '', 'final': true});
        expect(h.captions.lines, hasLength(1));
        h.captions.dispose();
      });
    });

    test('名字映射更新后已有行跟着改名', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.captions.setWantCaptions(true);
        h.ch.receive('u7', {'t': 'cap', 'id': 'a', 'seq': 1, 'text': 'x', 'final': true});
        expect(h.captions.lines.single.name, 'u7');
        h.captions.nameOf = (id) => id == 'u7' ? '老王' : id;
        expect(h.captions.lines.single.name, '老王');
        h.captions.dispose();
      });
    });

    test('只保留最近 30 行;没开字幕不收', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.ch.receive('u1', {'t': 'cap', 'id': 'z', 'seq': 1, 'text': 'x', 'final': true});
        expect(h.captions.lines, isEmpty);
        h.captions.setWantCaptions(true);
        for (var i = 0; i < 45; i++) {
          h.ch.receive('u1', {'t': 'cap', 'id': 'i$i', 'seq': i + 1, 'text': '第$i句', 'final': true});
        }
        expect(h.captions.lines, hasLength(30));
        expect(h.captions.lines.first.text, '第15句');
        expect(h.captions.lines.last.text, '第44句');
        h.captions.setWantCaptions(false);
        expect(h.captions.lines, isEmpty, reason: '关掉即清,不保留');
        h.captions.dispose();
      });
    });

    test('「X 未开启字幕」:开着麦、既没 capack 也没发过 cap 的人', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.ch.join('u1', mic: true);
        h.ch.join('u2', mic: true);
        h.ch.join('u3'); // 静音:不提示
        h.captions.setWantCaptions(true);
        expect(h.captions.notProvidingNames, ['小明', '阿花']);
        h.ch.receive('u1', {'t': 'capack', 'on': true});
        expect(h.captions.notProvidingNames, ['阿花']);
        expect(h.captions.providerNames, ['小明']);
        h.ch.receive('u2', {'t': 'capack', 'on': false});
        expect(h.captions.notProvidingNames, ['阿花'], reason: '明说不提供也提示');
        h.captions.dispose();
      });
    });

    test('畸形 / 非本协议的帧被静默丢弃', () {
      fakeAsync((async) {
        final h = H()..bind();
        h.captions.setWantCaptions(true);
        h.ch.inboundCtl.add(RoomDataFrame(
            senderIdentity: 'u1', bytes: Uint8List.fromList([0xff, 0x00])));
        h.ch.receive('u1', {'t': 'cap', 'id': 'a'});
        h.ch.receive('u1', {'t': 'nope'});
        expect(h.captions.lines, isEmpty);
        h.captions.dispose();
      });
    });
  });

  test('协议编解码往返', () {
    for (final m in <CaptionMessage>[
      const CapReq(true),
      const CapAck(false),
      const Cap(id: 'i', seq: 3, text: '你好', isFinal: true),
    ]) {
      final back = CaptionMessage.decode(m.encode())!;
      expect(back.toJson(), m.toJson());
    }
  });
}
