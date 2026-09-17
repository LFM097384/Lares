import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/p2p/host_election.dart';
import 'package:lares_app/src/p2p/p2p_mesh.dart';
import 'package:lares_app/src/p2p/p2p_session.dart';

/// 星形拓扑(主机转发)的测试。
///
/// 这个拓扑存在的理由是省**普通成员**的上行:
/// 全网状每人上行 N-1 路,星形下只有主机扛 N-1 路,其他人 1 路。
/// 所以最该验的是:连接真的只建在「我 ↔ 主机」之间,而不是人人互连。
void main() {
  late List<_FakeSession> made;

  P2PMesh makeMesh(String me) {
    made = [];
    return P2PMesh(
      myUserId: me,
      ice: () => const IceConfig(),
      sessionFactory: (_) {
        final s = _FakeSession();
        made.add(s);
        return s;
      },
    );
  }

  HostCandidate pc(String id, [int ms = 50]) =>
      HostCandidate(userId: id, isDesktop: true, latencyMs: ms);
  HostCandidate ph(String id, [int ms = 50]) =>
      HostCandidate(userId: id, isDesktop: false, latencyMs: ms);

  group('⚠️ 星形:只连主机,不是人人互连', () {
    test('我是普通成员:只建 1 条连接(连主机)', () async {
      // u_b 是桌面,会被选为主机
      final m = makeMesh('u_a');
      addTearDown(m.dispose);
      await m.syncRoster([ph('u_a'), pc('u_b'), ph('u_c'), ph('u_d')]);

      expect(m.hostId, 'u_b');
      expect(m.iAmHost, isFalse);
      expect(m.peers, hasLength(1),
          reason: '全网状要 3 条,星形只要 1 条 —— 这就是省下来的');
      expect(m.peers.single.userId, 'u_b');
    });

    test('我是主机:连所有人', () async {
      final m = makeMesh('u_pc');
      addTearDown(m.dispose);
      await m.syncRoster([pc('u_pc'), ph('u_a'), ph('u_b')]);

      expect(m.iAmHost, isTrue);
      expect(m.peers, hasLength(2), reason: '主机扛 N-1 条');
      expect(m.peers.map((p) => p.userId).toSet(), {'u_a', 'u_b'});
    });

    test('不会连自己', () async {
      final m = makeMesh('u_a');
      addTearDown(m.dispose);
      await m.syncRoster([pc('u_a'), ph('u_b')]);
      expect(m.peers.any((p) => p.userId == 'u_a'), isFalse);
    });
  });

  group('主机选举', () {
    test('桌面端优先当主机', () async {
      final m = makeMesh('u_a');
      addTearDown(m.dispose);
      await m.syncRoster([ph('u_a', 50), pc('u_b', 60)]);
      expect(m.hostId, 'u_b', reason: '桌面插电、WiFi、上行稳');
    });

    test('所有人算出同一个主机', () async {
      final roster = [ph('u_a', 100), pc('u_b', 120), ph('u_c', 90)];
      final a = makeMesh('u_a');
      final b = makeMesh('u_b');
      final c = makeMesh('u_c');
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      addTearDown(c.dispose);
      await a.syncRoster(roster);
      await b.syncRoster(roster);
      await c.syncRoster(roster);
      expect(a.hostId, b.hostId);
      expect(b.hostId, c.hostId,
          reason: '算出不同主机的话,房间会裂成几个互不相通的小房间');
    });
  });

  group('主机离开', () {
    test('主机不在名单里了 -> 换人并全员重连', () async {
      final m = makeMesh('u_a');
      addTearDown(m.dispose);
      await m.syncRoster([ph('u_a'), pc('u_host'), ph('u_c')]);
      expect(m.hostId, 'u_host');
      final firstCount = made.length;

      // 主机走了
      await m.syncRoster([ph('u_a'), ph('u_c')]);
      expect(m.hostId, isNot('u_host'));
      expect(m.hostId, isNotNull, reason: '必须选出新主机');
      expect(made.length, greaterThan(firstCount),
          reason: '换主机后旧连接作废,要重新建');
    });

    test('只剩自己:仍选得出主机(就是自己)', () async {
      final m = makeMesh('u_a');
      addTearDown(m.dispose);
      await m.syncRoster([ph('u_a')]);
      expect(m.hostId, 'u_a');
      expect(m.iAmHost, isTrue);
      expect(m.peers, isEmpty, reason: '没人可连');
    });

    test('名单空了:清空一切', () async {
      final m = makeMesh('u_a');
      addTearDown(m.dispose);
      await m.syncRoster([ph('u_a'), pc('u_b')]);
      expect(m.peers, isNotEmpty);
      await m.syncRoster(const []);
      expect(m.hostId, isNull);
      expect(m.peers, isEmpty);
    });
  });

  group('⚠️ 防抖:不因网络波动反复换主机', () {
    test('新候选只好一点点,不换 —— 换一次就是一次中断', () async {
      final m = makeMesh('u_a');
      addTearDown(m.dispose);
      await m.syncRoster([ph('u_a', 500), ph('u_b', 400)]);
      final first = m.hostId;

      // u_a 的延迟稍微变好,但差距没到阈值
      await m.syncRoster([ph('u_a', 350), ph('u_b', 400)]);
      expect(m.hostId, first, reason: '差距没到 300ms 阈值,不该换');
    });
  });

  group('glare:避免双方同时开口', () {
    test('userId 字典序小的一方负责发起', () {
      final a = makeMesh('u_a');
      final b = makeMesh('u_b');
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      // 两端各自算,结果必然相反 —— 有且只有一方开口
      expect(a.shouldInitiateTo('u_b'), isTrue);
      expect(b.shouldInitiateTo('u_a'), isFalse);
    });
  });
}

/// 假会话:不碰真实 WebRTC。
class _FakeSession implements P2PSession {
  @override
  P2PPhase phase = P2PPhase.idle;

  @override
  String? localCode;

  @override
  String? failure;

  @override
  Future<void> createOffer() async {
    phase = P2PPhase.waitingForPeer;
    localCode = 'LARES-O1:fake';
  }

  @override
  Future<void> acceptRemoteCode(String code) async {
    phase = P2PPhase.connecting;
  }

  @override
  Future<void> close() async {
    phase = P2PPhase.closed;
  }

  @override
  void dispose() {}

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

