import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/auth/auth_credential.dart';
import 'package:lares_app/src/net/presence_pool.dart';
import 'package:lares_app/src/net/server_profile.dart';
import 'package:lares_app/src/net/signaling_client.dart';

/// 跨服务器 presence 池的测试。
///
/// 核心语义:客户端同时连 N 台服务器,在每台上各自挂起;
/// 服务器之间不通信,聚合发生在客户端。
///
/// 最要紧的一条不变量:**(serverId, userId) 合起来才唯一**。
/// userId 是本地生成的,两台服务器上可能撞车 —— 只用 userId 做键
/// 会让甲服务器的人覆盖掉乙服务器的人。
void main() {
  late List<_FakeLink> links;

  PresencePool makePool({String me = 'u_me'}) {
    links = [];
    return PresencePool(
      userId: me,
      credentialFor: (_, _) => AuthCredential.none,
      clientFactory: (url, creds) {
        final l = _FakeLink(url);
        links.add(l);
        return l;
      },
    );
  }

  ServerProfile profile(String id, String url) =>
      ServerProfile(id: id, label: id, url: url, authMode: AuthMode.none);

  group('连哪几台', () {
    test('按档案连,排除主连接已在用的那台', () async {
      final pool = makePool();
      addTearDown(pool.dispose);
      pool.syncProfiles([
        profile('p1', 'wss://a/ws'),
        profile('p2', 'wss://b/ws'),
        profile('p3', 'wss://c/ws'),
      ], exclude: 'p2');

      expect(links, hasLength(2), reason: 'p2 由主连接负责,不重复连');
      expect(links.map((l) => l.url), containsAll(['wss://a/ws', 'wss://c/ws']));
    });

    test('档案消失时断开对应链路,并清掉那台机器上的人', () async {
      final pool = makePool();
      addTearDown(pool.dispose);
      pool.syncProfiles([profile('p1', 'wss://a/ws')]);
      await links[0].emit({'t': 'welcome'});
      await links[0].emit({
        't': 'member_available',
        'userId': 'u_x',
        'name': '阿澈',
        'circleIds': ['jia'],
        'since': 1,
      });
      expect(pool.availableIn('jia'), hasLength(1));

      pool.syncProfiles(const []);
      expect(pool.availableIn('jia'), isEmpty,
          reason: '链路断了还留着人,就是个点不动的幽灵');
    });

    test('地址为空的档案不连', () async {
      final pool = makePool();
      addTearDown(pool.dispose);
      pool.syncProfiles([profile('p1', '')]);
      expect(links, isEmpty);
    });
  });

  group('⚠️ 跨服务器的键必须是 (serverId, userId)', () {
    test('两台服务器上同名同 id 的人不会互相覆盖', () async {
      final pool = makePool();
      addTearDown(pool.dispose);
      pool.syncProfiles([
        profile('p1', 'wss://a/ws'),
        profile('p2', 'wss://b/ws'),
      ]);
      // userId 是本地生成的,两台机器上撞车完全可能
      for (final l in links) {
        await l.emit({'t': 'welcome'});
        await l.emit({
          't': 'member_available',
          'userId': 'u_same',
          'name': '撞车的人',
          'circleIds': ['jia'],
          'since': 1,
        });
      }
      expect(pool.availableIn('jia'), hasLength(2),
          reason: '只用 userId 做键的话这里会是 1 —— 一个人被另一个覆盖了');
      expect(
        pool.availableIn('jia').map((r) => r.serverId).toSet(),
        {'p1', 'p2'},
      );
    });

    test('去找人时发到正确的那台服务器', () async {
      final pool = makePool();
      addTearDown(pool.dispose);
      pool.syncProfiles([
        profile('p1', 'wss://a/ws'),
        profile('p2', 'wss://b/ws'),
      ]);
      await links[1].emit({'t': 'welcome'});
      await links[1].emit({
        't': 'member_available',
        'userId': 'u_x',
        'name': '阿澈',
        'circleIds': ['yi'],
        'since': 1,
      });

      pool.reach(pool.availableIn('yi').single, circleId: 'yi');
      expect(links[0].sent, isEmpty, reason: '不该发给不相干的服务器');
      expect(links[1].sent.single['t'], 'reach');
      expect(links[1].sent.single['userId'], 'u_x');
    });
  });

  group('挂起', () {
    test('分服务器挂:各发各的圈子 id', () async {
      final pool = makePool();
      addTearDown(pool.dispose);
      pool.syncProfiles([
        profile('p1', 'wss://a/ws'),
        profile('p2', 'wss://b/ws'),
      ]);
      for (final l in links) {
        await l.emit({'t': 'welcome'});
      }
      pool.setAvailable({
        'p1': ['jia'],
        'p2': ['yi', 'bing'],
      });
      expect(links[0].sent.single['circleIds'], ['jia']);
      expect(links[1].sent.single['circleIds'], ['yi', 'bing']);
    });

    test('断线重连后自动补发挂着状态', () async {
      final pool = makePool();
      addTearDown(pool.dispose);
      pool.syncProfiles([profile('p1', 'wss://a/ws')]);
      await links[0].emit({'t': 'welcome'});
      pool.setAvailable({
        'p1': ['jia'],
      });
      links[0].sent.clear();

      // 模拟断线重连:再来一次 welcome
      await links[0].emit({'t': 'welcome'});
      expect(links[0].sent.single['t'], 'available',
          reason: '不补发的话用户以为还挂着,其实早掉了');
      expect(links[0].sent.single['circleIds'], ['jia']);
    });

    test('收回会通知所有挂过的链路', () async {
      final pool = makePool();
      addTearDown(pool.dispose);
      pool.syncProfiles([
        profile('p1', 'wss://a/ws'),
        profile('p2', 'wss://b/ws'),
      ]);
      for (final l in links) {
        await l.emit({'t': 'welcome'});
      }
      pool.setAvailable({
        'p1': ['jia'],
        'p2': ['yi'],
      });
      for (final l in links) {
        l.sent.clear();
      }
      pool.clearAvailable();
      for (final l in links) {
        expect(l.sent.single['t'], 'unavailable');
      }
    });

    test('不把自己算进「有谁有空」', () async {
      final pool = makePool(me: 'u_me');
      addTearDown(pool.dispose);
      pool.syncProfiles([profile('p1', 'wss://a/ws')]);
      await links[0].emit({'t': 'welcome'});
      await links[0].emit({
        't': 'member_available',
        'userId': 'u_me',
        'name': '我',
        'circleIds': ['jia'],
        'since': 1,
      });
      expect(pool.availableIn('jia'), isEmpty);
    });
  });

  group('链路状态', () {
    test('welcome 之前是 connecting,之后是 online', () async {
      final pool = makePool();
      addTearDown(pool.dispose);
      pool.syncProfiles([profile('p1', 'wss://a/ws')]);
      expect(pool.stateOf('p1'), PresenceLinkState.connecting);
      await links[0].emit({'t': 'welcome'});
      expect(pool.stateOf('p1'), PresenceLinkState.online);
    });
  });

  /// 信令层在同一条 messages 流上合成的内部消息(`_disconnected` 等)。
  ///
  /// 这类消息不走 `onError` —— socket 正常关闭时流本身没出错,
  /// 所以订阅上的 onError 一次都不会响。池子不自己认这几条,
  /// 断线后名单就永远停在断线那一刻。
  group('链路掉了之后', () {
    test('断线清掉那台服务器上的人,并且不再自称 online', () async {
      final pool = makePool();
      addTearDown(pool.dispose);
      pool.syncProfiles([profile('p1', 'wss://a/ws')]);
      await links[0].emit({'t': 'welcome'});
      await links[0].emit({
        't': 'member_available',
        'userId': 'u_x',
        'name': '阿澈',
        'circleIds': ['jia'],
        'since': 1,
      });
      expect(pool.availableIn('jia'), hasLength(1));
      expect(pool.stateOf('p1'), PresenceLinkState.online);

      await links[0].emit({'t': '_disconnected'});

      expect(pool.availableIn('jia'), isEmpty,
          reason: '连不上了还显示成「有空」,点下去 reach 发进死 socket,是个死按钮');
      expect(pool.stateOf('p1'), isNot(PresenceLinkState.online),
          reason: '这个 enum 存在的意义就是如实说「哪台没连上」');
      expect(pool.stateOf('p1'), PresenceLinkState.connecting,
          reason: '它确实在重连,UI 该画「正在重连」而不是「废了」');
    });

    test('一台断线不许动到另一台的人', () async {
      final pool = makePool();
      addTearDown(pool.dispose);
      pool.syncProfiles([
        profile('p1', 'wss://a/ws'),
        profile('p2', 'wss://b/ws'),
      ]);
      for (final l in links) {
        await l.emit({'t': 'welcome'});
        await l.emit({
          't': 'member_available',
          'userId': 'u_same',
          'name': '撞车的人',
          'circleIds': ['jia'],
          'since': 1,
        });
      }
      expect(pool.availableIn('jia'), hasLength(2));

      await links[0].emit({'t': '_disconnected'});

      final left = pool.availableIn('jia');
      expect(left, hasLength(1), reason: 'remote 的键是 serverId/userId,只该清掉 p1 那一半');
      expect(left.single.serverId, 'p2');
      expect(pool.stateOf('p2'), PresenceLinkState.online,
          reason: 'p2 根本没断,别被 p1 连坐');
    });

    test('_auth_failed 是终局:failed,且人要清掉', () async {
      final pool = makePool();
      addTearDown(pool.dispose);
      pool.syncProfiles([profile('p1', 'wss://a/ws')]);
      await links[0].emit({'t': 'welcome'});
      await links[0].emit({
        't': 'member_available',
        'userId': 'u_x',
        'name': '阿澈',
        'circleIds': ['jia'],
        'since': 1,
      });

      // 信令层第二次 4401 后就**彻底不再重连**,此后一条 _disconnected 都不会来
      await links[0].emit({'t': '_auth_failed', 'message': 'auth_failed'});

      expect(pool.stateOf('p1'), PresenceLinkState.failed,
          reason: '不会自己好了,画成 connecting 就是让用户白等');
      expect(pool.availableIn('jia'), isEmpty);
    });

    test('_rate_limited 记成 failed,不画成转圈圈', () async {
      final pool = makePool();
      addTearDown(pool.dispose);
      pool.syncProfiles([profile('p1', 'wss://a/ws')]);
      await links[0].emit({'t': 'welcome'});
      await links[0].emit({
        't': 'member_available',
        'userId': 'u_x',
        'name': '阿澈',
        'circleIds': ['jia'],
        'since': 1,
      });

      // 真实顺序:4429 先发 _disconnected,紧接着才发 _rate_limited
      await links[0].emit({'t': '_disconnected', 'closeCode': 4429});
      expect(pool.stateOf('p1'), PresenceLinkState.connecting);
      await links[0].emit({'t': '_rate_limited'});

      expect(pool.stateOf('p1'), PresenceLinkState.failed,
          reason: '硬退避 60s 起步,这几分钟的事实就是「这台现在不好使」');
      expect(pool.availableIn('jia'), isEmpty);
    });

    test('⚠️ 断线不许清掉「我想挂着」,重连后还得补发', () async {
      final pool = makePool();
      addTearDown(pool.dispose);
      pool.syncProfiles([profile('p1', 'wss://a/ws')]);
      await links[0].emit({'t': 'welcome'});
      pool.setAvailable({
        'p1': ['jia'],
      });
      links[0].sent.clear();

      await links[0].emit({'t': '_disconnected'});
      // 重连上了
      await links[0].emit({'t': 'welcome'});

      expect(links[0].sent.single['t'], 'available',
          reason: '断线顺手清掉 _mine 的话,一次抖动之后用户就悄无声息地不挂着了');
      expect(links[0].sent.single['circleIds'], ['jia']);
      expect(pool.stateOf('p1'), PresenceLinkState.online);
    });

    test('赴约不受轻连接断线影响:reached 不该被吞掉', () async {
      final pool = makePool();
      addTearDown(pool.dispose);
      pool.syncProfiles([profile('p1', 'wss://a/ws')]);
      await links[0].emit({'t': 'welcome'});
      await links[0].emit({'t': 'reached', 'circleId': 'jia', 'by': '阿澈'});
      expect(pool.reached, isNotNull);

      await links[0].emit({'t': '_disconnected'});

      expect(pool.reached, isNotNull,
          reason: '赴约走的是主连接,这条 presence 轻连接断了不代表这个约不该赴');
    });

    test('这些状态变化都要通知出去', () async {
      final pool = makePool();
      addTearDown(pool.dispose);
      pool.syncProfiles([profile('p1', 'wss://a/ws')]);
      await links[0].emit({'t': 'welcome'});
      await links[0].emit({
        't': 'member_available',
        'userId': 'u_x',
        'name': '阿澈',
        'circleIds': ['jia'],
        'since': 1,
      });

      var n = 0;
      pool.addListener(() => n++);

      await links[0].emit({'t': '_disconnected'});
      expect(n, 1, reason: '不通知的话 UI 还照着旧名单画');

      // 已经是 connecting、人也清空了,再来一条什么都没变 —— 不该白白重建
      await links[0].emit({'t': '_disconnected'});
      expect(n, 1, reason: '沿用本文件的约定:真变了才通知');

      await links[0].emit({'t': '_auth_failed', 'message': 'auth_failed'});
      expect(n, 2, reason: 'connecting → failed 是实打实的变化');
    });
  });

  group('被找到', () {
    test('报告是哪台服务器、哪个圈子、谁来的', () async {
      final pool = makePool();
      addTearDown(pool.dispose);
      pool.syncProfiles([
        profile('p1', 'wss://a/ws'),
        profile('p2', 'wss://b/ws'),
      ]);
      await links[1].emit({'t': 'welcome'});
      await links[1].emit({'t': 'reached', 'circleId': 'yi', 'by': '阿澈'});

      expect(pool.reached, isNotNull);
      expect(pool.reached!.serverId, 'p2');
      expect(pool.reached!.circleId, 'yi');
      expect(pool.reached!.by, '阿澈');

      pool.consumeReached();
      expect(pool.reached, isNull);
    });
  });
}

/// 假链路:不碰网络,只记录发出去的消息、并能手工灌入服务器消息。
class _FakeLink extends SignalingClient {
  _FakeLink(String url) : super(url: url);

  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  @override
  void connect() {}

  @override
  void send(Map<String, dynamic> msg) => sent.add(msg);

  @override
  Future<void> dispose() async {}

  /// 灌一条「服务器发来的」消息,并等它被处理完。
  ///
  /// 必须是异步的:`testInject` 走 stream,监听方要到下一个事件循环才收到。
  /// 同步断言会在消息还没到达时就跑,表现为「明明发了却读不到」。
  Future<void> emit(Map<String, dynamic> msg) async {
    testInject(msg);
    await Future<void>.delayed(Duration.zero);
  }
}





