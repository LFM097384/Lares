import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/recording/recording_consent.dart';

const String kMe = 'u_me';
const String kCircle = 'c1';

/// 出站消息收集器,顺带记录采集许可的**全部**变化轨迹 ——
/// 「结束时没在采集」和「自始至终没采集过」是两回事,
/// 伦理上必须能验证后者,所以要留轨迹而不是只看终值。
class Harness {
  Harness({this.throwOnSend = false}) {
    controller = RecordingConsentController(
      userId: kMe,
      send: (Map<String, dynamic> msg) {
        sent.add(msg);
        if (throwOnSend) throw StateError('模拟网络故障');
      },
      now: () => clock,
      onCaptureAllowedChanged: permissionLog.add,
    );
  }

  final bool throwOnSend;
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  final List<bool> permissionLog = <bool>[];
  DateTime clock = DateTime.utc(2026, 1, 1);
  late final RecordingConsentController controller;

  /// 某个 `t` 的出站条数
  int countOf(String type) => sent.where((Map<String, dynamic> m) => m['t'] == type).length;

  bool get everAllowed => permissionLog.contains(true);

  /// 服务器把 `member_rec` 回显给某人
  void memberRec({
    required String userId,
    required bool active,
    String name = '阿明',
    String circleId = kCircle,
    int sinceMs = 1700000000000,
  }) => controller.handleMessage(<String, dynamic>{
    't': 'member_rec',
    'circleId': circleId,
    'userId': userId,
    'name': name,
    'active': active,
    'since': sinceMs,
  });

  void disconnect() =>
      controller.handleMessage(<String, dynamic>{'t': '_disconnected'});
}

void main() {
  group('默认关闭', () {
    test('新建的控制器不允许采集,状态为 idle,房间里没人在录', () {
      final Harness h = Harness();
      expect(h.controller.captureAllowed, isFalse);
      expect(h.controller.state, RecordingConsentState.idle);
      expect(h.controller.room.anyoneRecording, isFalse);
      expect(h.controller.message, isNull);
      expect(h.sent, isEmpty);
      h.controller.dispose();
    });
  });

  group('起录流程', () {
    test('happy path:先发 rec_start 且不采集,收到自己的回显后才放行', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        bool? result;
        h.controller.requestStart(kCircle).then((bool v) => result = v);
        async.flushMicrotasks();

        // 发出去了,但绝不能已经在采集 —— 房间还没被告知。
        expect(h.sent.single, <String, dynamic>{'t': 'rec_start', 'circleId': kCircle});
        expect(h.controller.state, RecordingConsentState.arming);
        expect(h.controller.captureAllowed, isFalse);
        expect(h.everAllowed, isFalse);

        h.memberRec(userId: kMe, active: true, name: '我');
        async.flushMicrotasks();

        expect(h.controller.state, RecordingConsentState.recording);
        expect(h.controller.captureAllowed, isTrue);
        expect(result, isTrue);
        expect(h.controller.message, isNull);
        expect(h.controller.room.localRecording, isTrue);
        expect(h.permissionLog, <bool>[true]);

        h.controller.dispose();
      });
    });

    test('arming 超时:5 秒没等到回显则失败,且全程从未允许采集', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        bool? result;
        h.controller.requestStart(kCircle).then((bool v) => result = v);
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 4));
        expect(h.controller.state, RecordingConsentState.arming);
        expect(h.controller.captureAllowed, isFalse);

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        expect(h.controller.state, RecordingConsentState.failed);
        expect(h.controller.captureAllowed, isFalse);
        expect(result, isFalse);
        expect(h.controller.message, isNotNull);
        expect(h.controller.message, isNotEmpty);
        expect(h.controller.message, contains('未能确认'));
        // 核心断言:许可在任何一个瞬间都没有被给出过。
        expect(h.everAllowed, isFalse);
        expect(h.permissionLog, isEmpty);

        h.controller.dispose();
      });
    });

    test('arming 超时会补发 rec_stop,撤销可能已在房间里亮起的幽灵指示', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        h.controller.requestStart(kCircle);
        async.elapse(const Duration(seconds: 6));

        expect(h.countOf('rec_start'), 1);
        expect(h.countOf('rec_stop'), 1);
        h.controller.dispose();
      });
    });

    test('回显的 circleId 不匹配时不放行,防止旧圈子的滞留广播骗过 arming', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        h.controller.requestStart(kCircle);
        async.flushMicrotasks();

        h.memberRec(userId: kMe, active: true, circleId: 'other_circle');
        async.flushMicrotasks();

        expect(h.controller.state, RecordingConsentState.arming);
        expect(h.controller.captureAllowed, isFalse);

        async.elapse(const Duration(seconds: 6));
        expect(h.controller.state, RecordingConsentState.failed);
        expect(h.everAllowed, isFalse);
        h.controller.dispose();
      });
    });

    test('同一圈子重复 requestStart 是幂等的,不重复发包', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        h.controller.requestStart(kCircle);
        async.flushMicrotasks();
        h.memberRec(userId: kMe, active: true);
        async.flushMicrotasks();

        bool? second;
        h.controller.requestStart(kCircle).then((bool v) => second = v);
        async.flushMicrotasks();

        expect(second, isTrue);
        expect(h.countOf('rec_start'), 1);
        h.controller.dispose();
      });
    });
  });

  group('心跳', () {
    test('录音期间按 15 秒间隔发出 rec_ping', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        h.controller.requestStart(kCircle);
        async.flushMicrotasks();
        h.memberRec(userId: kMe, active: true);
        async.flushMicrotasks();

        expect(h.countOf('rec_ping'), 0);
        async.elapse(const Duration(seconds: 15));
        expect(h.countOf('rec_ping'), 1);
        async.elapse(const Duration(seconds: 30));
        expect(h.countOf('rec_ping'), 3);

        for (final Map<String, dynamic> m in h.sent.where(
          (Map<String, dynamic> m) => m['t'] == 'rec_ping',
        )) {
          expect(m['circleId'], kCircle);
        }

        h.controller.dispose();
      });
    });

    test('停止录音后心跳不再发出', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        h.controller.requestStart(kCircle);
        async.flushMicrotasks();
        h.memberRec(userId: kMe, active: true);
        async.elapse(const Duration(seconds: 15));
        expect(h.countOf('rec_ping'), 1);

        h.controller.stop();
        async.elapse(const Duration(seconds: 60));
        expect(h.countOf('rec_ping'), 1);
        h.controller.dispose();
      });
    });
  });

  group('录音中断线', () {
    test('宽限期内仍允许采集,两秒抖动不毁录音', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        h.controller.requestStart(kCircle);
        async.flushMicrotasks();
        h.memberRec(userId: kMe, active: true);
        async.flushMicrotasks();

        h.disconnect();
        expect(h.controller.captureAllowed, isTrue);
        expect(h.controller.inGracePeriod, isTrue);

        async.elapse(const Duration(seconds: 2));
        expect(h.controller.captureAllowed, isTrue);
        h.controller.dispose();
      });
    });

    test('断线时立刻补发 rec_start 重新声明(规则 5,靠 outbox 在重连后补发)', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        h.controller.requestStart(kCircle);
        async.flushMicrotasks();
        h.memberRec(userId: kMe, active: true);
        async.flushMicrotasks();
        expect(h.countOf('rec_start'), 1);

        h.disconnect();
        expect(h.countOf('rec_start'), 2);
        h.controller.dispose();
      });
    });

    test('宽限期满仍未重新确认,自动撤销采集并给出中文警告', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        h.controller.requestStart(kCircle);
        async.flushMicrotasks();
        h.memberRec(userId: kMe, active: true);
        async.flushMicrotasks();

        h.disconnect();
        async.elapse(const Duration(seconds: 11));
        async.flushMicrotasks();

        expect(h.controller.captureAllowed, isFalse);
        expect(h.controller.state, RecordingConsentState.failed);
        expect(h.controller.message, isNotNull);
        expect(h.controller.message, contains('自动停止录音'));
        expect(h.permissionLog, <bool>[true, false]);
        expect(h.controller.room.localRecording, isFalse);
        h.controller.dispose();
      });
    });

    test('宽限期内重新确认:录音不中断,警告被清除', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        h.controller.requestStart(kCircle);
        async.flushMicrotasks();
        h.memberRec(userId: kMe, active: true);
        async.flushMicrotasks();

        h.disconnect();
        async.elapse(const Duration(seconds: 3));
        expect(h.controller.message, isNotNull);

        h.memberRec(userId: kMe, active: true);
        async.flushMicrotasks();

        expect(h.controller.state, RecordingConsentState.recording);
        expect(h.controller.captureAllowed, isTrue);
        expect(h.controller.inGracePeriod, isFalse);
        expect(h.controller.message, isNull);

        // 再等很久也不该被旧的宽限计时器误杀
        async.elapse(const Duration(seconds: 30));
        expect(h.controller.captureAllowed, isTrue);
        // 许可自始至终只翻转过一次:采集从未中断
        expect(h.permissionLog, <bool>[true]);
        h.controller.dispose();
      });
    });

    test('反复断线不会把宽限期无限续期', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        h.controller.requestStart(kCircle);
        async.flushMicrotasks();
        h.memberRec(userId: kMe, active: true);
        async.flushMicrotasks();

        // 每 3 秒断一次,若每次都重置宽限期就永远停不下来
        h.disconnect();
        async.elapse(const Duration(seconds: 3));
        h.disconnect();
        async.elapse(const Duration(seconds: 3));
        h.disconnect();
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();

        expect(h.controller.captureAllowed, isFalse);
        h.controller.dispose();
      });
    });
  });

  group('停止', () {
    test('stop() 同步撤销采集许可', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        h.controller.requestStart(kCircle);
        async.flushMicrotasks();
        h.memberRec(userId: kMe, active: true);
        async.flushMicrotasks();
        expect(h.controller.captureAllowed, isTrue);

        h.controller.stop();

        // 不推进时间、不冲微任务,就地断言 —— 必须是同步生效的
        expect(h.controller.captureAllowed, isFalse);
        expect(h.controller.state, RecordingConsentState.idle);
        expect(h.countOf('rec_stop'), 1);
        expect(h.controller.room.localRecording, isFalse);
        h.controller.dispose();
      });
    });

    test('send 抛异常时 stop() 仍然撤销许可,且异常不外泄', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness(throwOnSend: true);
        // 连 requestStart 的发送都会抛,状态机也必须扛住
        h.controller.requestStart(kCircle);
        async.flushMicrotasks();
        h.memberRec(userId: kMe, active: true);
        async.flushMicrotasks();
        expect(h.controller.captureAllowed, isTrue);

        expect(h.controller.stop, returnsNormally);
        expect(h.controller.captureAllowed, isFalse);
        expect(h.controller.state, RecordingConsentState.idle);
        expect(h.countOf('rec_stop'), 1);
        h.controller.dispose();
      });
    });

    test('arming 期间 stop():挂起的 Future 以 false 兑现,不会永远悬着', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        bool? result;
        h.controller.requestStart(kCircle).then((bool v) => result = v);
        async.flushMicrotasks();

        h.controller.stop();
        async.flushMicrotasks();

        expect(result, isFalse);
        expect(h.controller.captureAllowed, isFalse);
        expect(h.countOf('rec_stop'), 1);
        expect(h.everAllowed, isFalse);

        // arming 计时器已被取消,不该再有后续动作
        async.elapse(const Duration(seconds: 10));
        expect(h.controller.state, RecordingConsentState.idle);
        h.controller.dispose();
      });
    });

    test('未在录音时 stop() 是安全的空操作', () {
      final Harness h = Harness();
      expect(h.controller.stop, returnsNormally);
      expect(h.sent, isEmpty);
      expect(h.controller.captureAllowed, isFalse);
      h.controller.dispose();
    });
  });

  group('他人录音指示', () {
    test('别人在录:anyoneRecording 为真并带出名字与开始时间,但不放行我的采集', () {
      final Harness h = Harness();
      h.memberRec(
        userId: 'u_other',
        active: true,
        name: '小林',
        sinceMs: 1700000000000,
      );

      expect(h.controller.room.anyoneRecording, isTrue);
      expect(h.controller.room.localRecording, isFalse);
      expect(h.controller.captureAllowed, isFalse);

      final RemoteRecorder? r = h.controller.room.recorderOf('u_other');
      expect(r, isNotNull);
      expect(r!.name, '小林');
      expect(r.since, DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(h.controller.room.others.length, 1);
      h.controller.dispose();
    });

    test('多人同时录音:两人都在列;其中一人停止,另一人仍在', () {
      final Harness h = Harness();
      h.memberRec(userId: 'u_a', active: true, name: 'A', sinceMs: 1700000000000);
      h.memberRec(userId: 'u_b', active: true, name: 'B', sinceMs: 1700000005000);

      expect(h.controller.room.recorderCount, 2);
      expect(
        h.controller.room.recorders.map((RemoteRecorder r) => r.userId),
        <String>['u_a', 'u_b'],
      );

      h.memberRec(userId: 'u_a', active: false, name: 'A');

      expect(h.controller.room.recorderCount, 1);
      expect(h.controller.room.recorderOf('u_a'), isNull);
      expect(h.controller.room.recorderOf('u_b'), isNotNull);
      expect(h.controller.room.anyoneRecording, isTrue);
      h.controller.dispose();
    });

    test('我在录的同时别人也在录,两条都在全景里', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        h.controller.requestStart(kCircle);
        async.flushMicrotasks();
        h.memberRec(userId: kMe, active: true, name: '我', sinceMs: 1700000000000);
        h.memberRec(userId: 'u_b', active: true, name: 'B', sinceMs: 1700000009000);
        async.flushMicrotasks();

        expect(h.controller.room.recorderCount, 2);
        expect(h.controller.room.localRecording, isTrue);
        expect(h.controller.room.others.length, 1);
        expect(h.controller.room.others.single.name, 'B');
        expect(h.controller.captureAllowed, isTrue);
        h.controller.dispose();
      });
    });
  });

  group('房间快照(迟到者)', () {
    test('快照里带 rec 字段的成员被正确识别为正在录音', () {
      final Harness h = Harness();
      h.controller.handleMessage(<String, dynamic>{
        't': 'room',
        'circleId': kCircle,
        'members': <Object?>[
          <String, dynamic>{'userId': 'u_x', 'name': '老张'},
          <String, dynamic>{
            'userId': 'u_y',
            'name': '小王',
            'rec': <String, dynamic>{'since': 1700000000000},
          },
        ],
      });

      expect(h.controller.room.anyoneRecording, isTrue);
      expect(h.controller.room.recorderCount, 1);
      final RemoteRecorder? r = h.controller.room.recorderOf('u_y');
      expect(r, isNotNull);
      expect(r!.name, '小王');
      expect(r.since, DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(h.controller.room.recorderOf('u_x'), isNull);
      expect(h.controller.captureAllowed, isFalse);
      h.controller.dispose();
    });

    test('快照是全量权威:先前记录的录音者若不在快照里则被清除', () {
      final Harness h = Harness();
      h.memberRec(userId: 'u_a', active: true, name: 'A');
      expect(h.controller.room.recorderCount, 1);

      h.controller.handleMessage(<String, dynamic>{
        't': 'room',
        'circleId': kCircle,
        'members': <Object?>[
          <String, dynamic>{'userId': 'u_a', 'name': 'A'},
        ],
      });

      expect(h.controller.room.anyoneRecording, isFalse);
      h.controller.dispose();
    });

    test('快照漏掉我时走宽限期而非立刻停,期满才自动停', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        h.controller.requestStart(kCircle);
        async.flushMicrotasks();
        h.memberRec(userId: kMe, active: true);
        async.flushMicrotasks();

        h.controller.handleMessage(<String, dynamic>{
          't': 'room',
          'circleId': kCircle,
          'members': <Object?>[
            <String, dynamic>{'userId': kMe, 'name': '我'},
          ],
        });

        // 重连窗口里服务器可能还没处理我的 rec_start,不该立刻毁掉录音
        expect(h.controller.captureAllowed, isTrue);
        expect(h.controller.inGracePeriod, isTrue);

        async.elapse(const Duration(seconds: 11));
        async.flushMicrotasks();
        expect(h.controller.captureAllowed, isFalse);
        h.controller.dispose();
      });
    });
  });

  group('矛盾情报', () {
    test('服务器把我标记为 active:false 时立刻停采(正面矛盾不给宽限)', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        h.controller.requestStart(kCircle);
        async.flushMicrotasks();
        h.memberRec(userId: kMe, active: true);
        async.flushMicrotasks();
        expect(h.controller.captureAllowed, isTrue);

        h.memberRec(userId: kMe, active: false);
        async.flushMicrotasks();

        expect(h.controller.captureAllowed, isFalse);
        expect(h.controller.state, RecordingConsentState.failed);
        expect(h.controller.message, contains('自动停止录音'));
        expect(h.permissionLog, <bool>[true, false]);
        h.controller.dispose();
      });
    });

    test('member_left 清除该用户的录音状态,消失的人不会被永远显示为在录', () {
      final Harness h = Harness();
      h.memberRec(userId: 'u_a', active: true, name: 'A');
      h.memberRec(userId: 'u_b', active: true, name: 'B');
      expect(h.controller.room.recorderCount, 2);

      h.controller.handleMessage(<String, dynamic>{
        't': 'member_left',
        'circleId': kCircle,
        'userId': 'u_a',
      });

      expect(h.controller.room.recorderCount, 1);
      expect(h.controller.room.recorderOf('u_a'), isNull);
      h.controller.dispose();
    });

    test('我自己被移出房间时立刻停采', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        h.controller.requestStart(kCircle);
        async.flushMicrotasks();
        h.memberRec(userId: kMe, active: true);
        async.flushMicrotasks();

        h.controller.handleMessage(<String, dynamic>{
          't': 'member_left',
          'circleId': kCircle,
          'userId': kMe,
        });

        expect(h.controller.captureAllowed, isFalse);
        expect(h.controller.message, contains('自动停止录音'));
        h.controller.dispose();
      });
    });
  });

  group('畸形消息不致命', () {
    test('缺字段 / 类型错误 / members 为 null 一律安全忽略', () {
      final Harness h = Harness();
      final List<Map<String, dynamic>> junk = <Map<String, dynamic>>[
        <String, dynamic>{},
        <String, dynamic>{'t': 123},
        <String, dynamic>{'t': 'member_rec'},
        <String, dynamic>{'t': 'member_rec', 'userId': 42, 'active': true},
        <String, dynamic>{'t': 'member_rec', 'userId': '', 'active': true},
        <String, dynamic>{'t': 'member_rec', 'userId': 'u_z', 'active': 'yes'},
        <String, dynamic>{'t': 'room', 'members': null},
        <String, dynamic>{'t': 'room', 'members': 'not a list'},
        <String, dynamic>{'t': 'room', 'members': <Object?>[null, 5, 'x']},
        <String, dynamic>{
          't': 'room',
          'members': <Object?>[
            <String, dynamic>{'userId': 'u_q', 'rec': 'not a map'},
          ],
        },
        <String, dynamic>{'t': 'member_left'},
        <String, dynamic>{'t': 'member_left', 'userId': <String>['a']},
        <String, dynamic>{'t': '完全没听说过的类型'},
      ];

      for (final Map<String, dynamic> m in junk) {
        expect(() => h.controller.handleMessage(m), returnsNormally,
            reason: '这条消息把 handleMessage 打挂了: $m');
      }

      expect(h.controller.captureAllowed, isFalse);
      expect(h.controller.room.anyoneRecording, isFalse);
      h.controller.dispose();
    });

    test('active:"yes" 这类非 bool 被当作「没在录」,指示器宁可少亮不可乱亮', () {
      final Harness h = Harness();
      h.controller.handleMessage(<String, dynamic>{
        't': 'member_rec',
        'circleId': kCircle,
        'userId': 'u_z',
        'name': 'Z',
        'active': 'yes',
      });
      expect(h.controller.room.anyoneRecording, isFalse);
      h.controller.dispose();
    });

    test('since 缺失或类型错误时退化为当前时钟,而不是丢掉「有人在录」这个事实', () {
      final Harness h = Harness();
      h.controller.handleMessage(<String, dynamic>{
        't': 'member_rec',
        'circleId': kCircle,
        'userId': 'u_z',
        'name': 'Z',
        'active': true,
        'since': 'yesterday',
      });

      final RemoteRecorder? r = h.controller.room.recorderOf('u_z');
      expect(r, isNotNull);
      expect(r!.since, h.clock);
      h.controller.dispose();
    });

    test('name 缺失时退化为 userId,不出现没有主语的「 正在录音」', () {
      final Harness h = Harness();
      h.controller.handleMessage(<String, dynamic>{
        't': 'member_rec',
        'circleId': kCircle,
        'userId': 'u_z',
        'active': true,
        'since': 1700000000000,
      });
      expect(h.controller.room.recorderOf('u_z')!.name, 'u_z');
      h.controller.dispose();
    });

    test('since 为 double(JSON 可能解析成浮点)也能正确转换', () {
      final Harness h = Harness();
      h.controller.handleMessage(<String, dynamic>{
        't': 'member_rec',
        'circleId': kCircle,
        'userId': 'u_z',
        'active': true,
        'since': 1700000000000.0,
      });
      expect(
        h.controller.room.recorderOf('u_z')!.since,
        DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      h.controller.dispose();
    });
  });

  group('生命周期', () {
    test('dispose 撤销采集许可并清掉所有定时器', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        h.controller.requestStart(kCircle);
        async.flushMicrotasks();
        h.memberRec(userId: kMe, active: true);
        async.flushMicrotasks();
        expect(h.controller.captureAllowed, isTrue);

        final int before = h.sent.length;
        h.controller.dispose();

        // 录音服务必须被明确告知「不准再采了」
        expect(h.permissionLog.last, isFalse);

        // 没有遗留定时器:再推进时间不会有任何新动作,
        // fakeAsync 也不会因挂起的定时器而报错
        async.elapse(const Duration(minutes: 5));
        expect(h.sent.length, before);
      });
    });

    test('dispose 后的 handleMessage / requestStart / stop 都是安全空操作', () {
      fakeAsync((FakeAsync async) {
        final Harness h = Harness();
        h.controller.dispose();

        expect(
          () => h.controller.handleMessage(<String, dynamic>{
            't': 'member_rec',
            'userId': kMe,
            'active': true,
          }),
          returnsNormally,
        );
        expect(h.controller.stop, returnsNormally);

        bool? result;
        h.controller.requestStart(kCircle).then((bool v) => result = v);
        async.flushMicrotasks();
        expect(result, isFalse);
        expect(h.controller.captureAllowed, isFalse);
      });
    });
  });

  group('值类型语义', () {
    test('RemoteRecorder 按字段比较,copyWith 只改指定字段', () {
      final DateTime t = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final RemoteRecorder a = RemoteRecorder(userId: 'u', name: 'N', since: t);
      final RemoteRecorder b = RemoteRecorder(userId: 'u', name: 'N', since: t);
      final RemoteRecorder c = a.copyWith(name: 'M');

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(c.userId, 'u');
      expect(c.since, t);
      expect(a.toString(), contains('u'));
    });

    test('RoomRecordingState 按内容比较', () {
      final DateTime t = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final List<RemoteRecorder> rs = <RemoteRecorder>[
        RemoteRecorder(userId: 'u', name: 'N', since: t),
      ];
      final RoomRecordingState s1 =
          RoomRecordingState(recorders: rs, localUserId: 'me');
      final RoomRecordingState s2 = RoomRecordingState(
        recorders: <RemoteRecorder>[
          RemoteRecorder(userId: 'u', name: 'N', since: t),
        ],
        localUserId: 'me',
      );

      expect(s1, equals(s2));
      expect(s1.hashCode, equals(s2.hashCode));
      expect(RoomRecordingState.empty.anyoneRecording, isFalse);
      expect(RoomRecordingState.empty.localRecording, isFalse);
      expect(s1.toString(), contains('me'));
    });

    test('录音者列表按开始时间稳定排序,顺序不随到达次序抖动', () {
      final Harness h1 = Harness();
      h1.memberRec(userId: 'u_a', active: true, sinceMs: 1700000005000);
      h1.memberRec(userId: 'u_b', active: true, sinceMs: 1700000000000);

      final Harness h2 = Harness();
      h2.memberRec(userId: 'u_b', active: true, sinceMs: 1700000000000);
      h2.memberRec(userId: 'u_a', active: true, sinceMs: 1700000005000);

      expect(
        h1.controller.room.recorders.map((RemoteRecorder r) => r.userId),
        <String>['u_b', 'u_a'],
      );
      expect(h1.controller.room, equals(h2.controller.room));
      h1.controller.dispose();
      h2.controller.dispose();
    });
  });
}
