import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/state/models.dart';
import 'package:lares_app/src/state/room_controller.dart';

import 'support/fake_room.dart';

/// 成员新字段(platform / latencyMs)的测试。
///
/// 这两个字段是**选主机的输入** —— 抹掉它们会让选举结果飘,
/// 而选举一旦在不同设备上算出不同答案,房间就会裂成几半。
void main() {
  late RoomController c;
  late FakeSignalingClient signaling;

  setUp(() {
    signaling = FakeSignalingClient();
    c = RoomController(
      signaling: signaling,
      rtc: FakeRtcService(),
      userId: 'u_me',
      deviceId: 'd_1',
      userName: '我',
    );
    addTearDown(c.dispose);
  });

  /// 先进房再注入 —— controller 会丢弃 circleId 对不上的消息,
  /// 而 circleId 是 join() 设的。直接注入 room 消息是走不通的。
  Future<void> joinRoom() async {
    c.join('home');
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> inject(Map<String, dynamic> msg) async {
    signaling.testInject(msg);
    await Future<void>.delayed(Duration.zero);
  }

  group('从服务器解析', () {
    test('platform 与 latencyMs 能读进来', () {
      final m = Member.fromWire(const {
        'userId': 'u_a',
        'name': '阿澈',
        'status': 'free',
        'platform': 'windows',
        'latencyMs': 42,
      });
      expect(m.platform, 'windows');
      expect(m.latencyMs, 42);
      expect(m.isDesktop, isTrue);
    });

    test('老服务器不发这两个字段时有安全默认值', () {
      final m = Member.fromWire(const {
        'userId': 'u_a',
        'name': '阿澈',
        'status': 'free',
      });
      expect(m.platform, '');
      expect(m.latencyMs, -1, reason: '未知按最差处理,不能当成 0');
      expect(m.isDesktop, isFalse);
    });

    test('桌面判定覆盖三个桌面平台,手机端为 false', () {
      Member p(String plat) => Member(
            userId: 'x',
            name: 'x',
            status: MemberStatus.free,
            platform: plat,
          );
      expect(p('windows').isDesktop, isTrue);
      expect(p('macos').isDesktop, isTrue);
      expect(p('linux').isDesktop, isTrue);
      expect(p('android').isDesktop, isFalse);
      expect(p('ios').isDesktop, isFalse);
      expect(p('web').isDesktop, isFalse);
    });
  });

  group('⚠️ 本地状态更新不能抹掉服务器发来的字段', () {
    test('改状态之后 platform/latency 还在', () async {
      await joinRoom();
      await inject({
        't': 'room',
        'circleId': 'home',
        'members': [
          {
            'userId': 'u_a',
            'name': '阿澈',
            'status': 'free',
            'platform': 'macos',
            'latencyMs': 30,
          },
        ],
      });
      expect(c.members.single.platform, 'macos');

      // 只更新状态 —— 这条路径走的是 _upsertMember,
      // 它重建 Member 时如果漏掉新字段,就会把它们抹成默认值
      await inject({
        't': 'member_status',
        'circleId': 'home',
        'userId': 'u_a',
        'status': 'busy',
      });

      final m = c.members.single;
      expect(m.status, MemberStatus.busy);
      expect(m.platform, 'macos', reason: '抹掉的话选主机会飘');
      expect(m.latencyMs, 30);
    });
  });

  group('选主机的候选名单', () {
    test('从成员列表映射出来,字段一一对应', () async {
      await joinRoom();
      await inject({
        't': 'room',
        'circleId': 'home',
        'members': [
          {
            'userId': 'u_pc',
            'name': '台式',
            'status': 'free',
            'platform': 'windows',
            'latencyMs': 20,
          },
          {
            'userId': 'u_ph',
            'name': '手机',
            'status': 'free',
            'platform': 'android',
            'latencyMs': 80,
          },
        ],
      });
      final cands = c.hostCandidates;
      expect(cands, hasLength(2));
      final pc = cands.firstWhere((x) => x.userId == 'u_pc');
      expect(pc.isDesktop, isTrue);
      expect(pc.latencyMs, 20);
    });
  });

  group('延迟上报要节流', () {
    test('没进房时不报', () {
      c.reportLatency(50);
      expect(signaling.sent.where((m) => m['t'] == 'latency'), isEmpty);
    });

    test('进房后首次会报', () async {
      await joinRoom();
      await inject({
        't': 'room', 'circleId': 'home', 'members': <Map<String, dynamic>>[]});
      signaling.sent.clear();
      c.reportLatency(50);
      expect(signaling.sent.single['t'], 'latency');
      expect(signaling.sent.single['ms'], 50);
    });

    test('变化小于 50ms 不重复报 —— 选举有 300ms 阈值,没必要吵', () async {
      await joinRoom();
      await inject({
        't': 'room', 'circleId': 'home', 'members': <Map<String, dynamic>>[]});
      c.reportLatency(50);
      signaling.sent.clear();
      c.reportLatency(60);
      c.reportLatency(45);
      expect(signaling.sent, isEmpty);
    });

    test('变化够大才再报', () async {
      await joinRoom();
      await inject({
        't': 'room', 'circleId': 'home', 'members': <Map<String, dynamic>>[]});
      c.reportLatency(50);
      signaling.sent.clear();
      c.reportLatency(200);
      expect(signaling.sent.single['ms'], 200);
    });

    test('负数(还没测到)不报', () async {
      await joinRoom();
      await inject({
        't': 'room', 'circleId': 'home', 'members': <Map<String, dynamic>>[]});
      signaling.sent.clear();
      c.reportLatency(-1);
      expect(signaling.sent, isEmpty);
    });
  });
}


