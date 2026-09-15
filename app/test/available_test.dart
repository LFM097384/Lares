import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/state/room_controller.dart';

import 'support/fake_room.dart';

/// 「我有空(挂着)」的客户端状态测试。
///
/// 语义核心:挂着 = 还没进任何房间,但对选定的几个圈子可见;
/// 第一个来找的人把双方拉进那个圈子,挂着态随即取消。
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

  /// 注入一条服务器消息并等它被处理(信令是 stream,异步到达)。
  Future<void> inject(Map<String, dynamic> msg) async {
    signaling.testInject(msg);
    await Future<void>.delayed(Duration.zero);
  }

  group('挂起与收回', () {
    test('默认没挂着', () {
      expect(c.iAmAvailable, isFalse);
      expect(c.myAvailableCircles, isEmpty);
    });

    test('挂起会发协议消息,且本地立即生效', () {
      c.setAvailable(['jia', 'yi']);
      expect(c.iAmAvailable, isTrue);
      expect(c.myAvailableCircles, ['jia', 'yi']);
      final sent = signaling.sent.last;
      expect(sent['t'], 'available');
      expect(sent['circleIds'], ['jia', 'yi']);
    });

    test('挂空列表等于收回,不发无意义的消息', () {
      c.setAvailable(const []);
      expect(c.iAmAvailable, isFalse);
      expect(signaling.sent.where((m) => m['t'] == 'unavailable'), isEmpty);
    });

    test('收回会发消息并清空本地状态', () {
      c.setAvailable(['jia']);
      signaling.sent.clear();
      c.clearAvailable();
      expect(c.iAmAvailable, isFalse);
      expect(signaling.sent.single['t'], 'unavailable');
    });

    test('重复收回是幂等的,不刷消息', () {
      c.clearAvailable();
      c.clearAvailable();
      expect(signaling.sent.where((m) => m['t'] == 'unavailable'), isEmpty);
    });

    test('服务端回执会覆盖本地乐观值', () async {
      c.setAvailable(['jia', 'yi', 'bing']);
      // 服务端只认了两个(第三个没口令)
      await inject({
        't': 'available_ok',
        'circleIds': ['jia', 'yi'],
      });
      expect(c.myAvailableCircles, ['jia', 'yi'],
          reason: '以服务端为准,不能让 UI 显示一个没生效的圈子');
    });
  });

  group('看到别人挂着', () {
    test('收到 member_available 后能按圈子查到', () async {
      await inject({
        't': 'member_available',
        'userId': 'u_other',
        'name': '阿澈',
        'circleIds': ['jia'],
        'since': 1000,
      });
      final inJia = c.availableIn('jia');
      expect(inJia, hasLength(1));
      expect(inJia.single.name, '阿澈');
      expect(c.availableIn('yi'), isEmpty, reason: '没挂在乙圈就不该出现在乙圈');
    });

    test('一个人挂在多个圈子,每个圈子都看得到他', () async {
      await inject({
        't': 'member_available',
        'userId': 'u_other',
        'name': '阿澈',
        'circleIds': ['jia', 'yi'],
        'since': 1,
      });
      expect(c.availableIn('jia'), hasLength(1));
      expect(c.availableIn('yi'), hasLength(1));
    });

    test('member_unavailable 之后就查不到了', () async {
      await inject({
        't': 'member_available',
        'userId': 'u_other',
        'name': '阿澈',
        'circleIds': ['jia'],
        'since': 1,
      });
      await inject({'t': 'member_unavailable', 'userId': 'u_other'});
      expect(c.availableIn('jia'), isEmpty);
    });

    test('不把自己算进「有谁有空」', () async {
      await inject({
        't': 'member_available',
        'userId': 'u_me',
        'name': '我',
        'circleIds': ['jia'],
        'since': 1,
      });
      expect(c.availableIn('jia'), isEmpty,
          reason: '自己挂着不该显示成「有人可约」');
    });
  });

  group('去找人', () {
    test('reach 会发协议消息', () {
      c.reach('u_other', circleId: 'jia');
      final sent = signaling.sent.last;
      expect(sent['t'], 'reach');
      expect(sent['userId'], 'u_other');
      expect(sent['circleId'], 'jia');
    });

    test('不给 circleId 时消息里就不带这个字段', () {
      c.reach('u_other');
      expect(signaling.sent.last.containsKey('circleId'), isFalse);
    });

    test('被找到时清掉自己的挂着态', () async {
      c.setAvailable(['jia', 'yi']);
      await inject({
        't': 'reached',
        'circleId': 'jia',
        'by': '阿澈',
        'byUserId': 'u_other',
      });
      expect(c.iAmAvailable, isFalse, reason: '人已经被拉进房了,不该还显示可约');
      expect(c.reachedBy, '阿澈');
    });

    test('找失败要有人话说明,不能静默', () async {
      await inject({'t': 'reach_failed', 'reason': 'gone'});
      expect(c.reachFailed, isNotNull);
      expect(c.reachFailed, contains('不在'));

      await inject({'t': 'reach_failed', 'reason': 'auth_scope'});
      expect(c.reachFailed, contains('口令'));
    });

    test('提示消费后清空,免得重复弹', () async {
      await inject({'t': 'reach_failed', 'reason': 'gone'});
      c.consumeReachNotices();
      expect(c.reachFailed, isNull);
      expect(c.reachedBy, isNull);
    });
  });

  group('跨服务器聚合', () {
    test('主连接与池子的人合并显示', () async {
      await inject({
        't': 'member_available',
        'userId': 'u_local',
        'name': '本机服务器的人',
        'circleIds': ['jia'],
        'since': 1,
      });
      c.remoteAvailableIn = (cid) => cid == 'jia'
          ? [(userId: 'u_far', name: '别的服务器的人')]
          : const [];
      final all = c.availableIn('jia');
      expect(all, hasLength(2));
      expect(all.map((e) => e.name),
          containsAll(['本机服务器的人', '别的服务器的人']));
    });

    test('同一个人不会因为两个来源都有而出现两次', () async {
      await inject({
        't': 'member_available',
        'userId': 'u_dup',
        'name': '同一个人',
        'circleIds': ['jia'],
        'since': 1,
      });
      // 档案切换的瞬间,同一台服务器可能同时出现在主连接和池子里
      c.remoteAvailableIn = (_) => [(userId: 'u_dup', name: '同一个人')];
      expect(c.availableIn('jia'), hasLength(1),
          reason: '去重按 userId,不能让同一个人在列表里出现两次');
    });

    test('池子里的自己也要排除', () {
      c.remoteAvailableIn = (_) => [(userId: 'u_me', name: '我')];
      expect(c.availableIn('jia'), isEmpty);
    });

    test('没接池子时行为不变', () async {
      await inject({
        't': 'member_available',
        'userId': 'u_x',
        'name': '阿澈',
        'circleIds': ['jia'],
        'since': 1,
      });
      expect(c.remoteAvailableIn, isNull);
      expect(c.availableIn('jia'), hasLength(1));
    });
  });
}
