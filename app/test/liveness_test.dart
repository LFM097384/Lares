/// 连接探活:pong 超时检测 + 回前台主动戳。
///
/// ## 为什么需要
///
/// 审计(`docs/signaling-audit.md`)留下的两条未修风险都源于同一件事:
/// **客户端没有任何独立的「这条连接还活着吗」的判断**,全靠 socket
/// 自己报错。而 iOS 切后台、WiFi→蜂窝 切换时,socket 常常是
/// **静默死亡** —— 不报 close,只是再也不通。
///
/// 后果:`phase` 一直显示 `inRoom`,界面说人还在房里,实际早就断了。
/// 用户对着一个撒谎的界面操作,直到主动做点什么才发现。
///
/// 原本的心跳只发不收 —— 20 秒发一个 ping 用来测延迟,
/// 却从不检查 pong 有没有回来。本文件守住修复后的行为。
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/net/signaling_client.dart';

import 'signaling_auth_test.dart' show FakeTransport, makeClient, challenge;

/// 把客户端推到「已握手、心跳已启动」的状态。
void _connectAndHandshake(SignalingClient c, FakeTransport t, FakeAsync async) {
  c.hello(userId: 'u_liu', deviceId: 'd_1', name: '我', platform: 'test');
  async.flushMicrotasks();
  t.last.serverSend(challenge('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'));
  async.flushMicrotasks();
  t.last.serverSend({'t': 'welcome', 'userId': 'u_liu'});
  async.flushMicrotasks();
}

void main() {
  group('pong 超时:链路静默死亡要能被发现', () {
    test('连续两次没收到 pong 就断开,触发重连链路', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        addTearDown(c.dispose);
        _connectAndHandshake(c, t, async);

        expect(t.last.closedByClient, isFalse);

        // 第 1 个 20s 周期:上一发 ping 没回音,记一次欠账,再发一个
        async.elapse(const Duration(seconds: 20));
        expect(t.last.closedByClient, isFalse, reason: '一次丢包不该断线');

        // 第 2 个周期:欠账到 2,判死
        async.elapse(const Duration(seconds: 20));
        expect(t.last.closedByClient, isTrue,
            reason: '40 秒没有任何回音,这条链路必须被判死');

        async.flushTimers();
      });
    });

    test('收到 pong 就归零,不会误杀健康连接', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        addTearDown(c.dispose);
        _connectAndHandshake(c, t, async);

        // 每个周期都老实回 pong
        for (var i = 0; i < 6; i++) {
          t.last.serverSend({'t': 'pong'});
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 20));
        }

        expect(t.last.closedByClient, isFalse, reason: '健康连接被误杀是更糟的 bug');
        async.flushTimers();
      });
    });

    test('一次丢包后恢复,欠账要清掉', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        addTearDown(c.dispose);
        _connectAndHandshake(c, t, async);

        // 丢一次
        async.elapse(const Duration(seconds: 20));
        expect(t.last.closedByClient, isFalse);

        // 回来了
        t.last.serverSend({'t': 'pong'});
        async.flushMicrotasks();

        // 再过两个周期都正常 —— 若欠账没清,这里就会被误杀
        t.last.serverSend({'t': 'pong'});
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 20));
        t.last.serverSend({'t': 'pong'});
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 20));

        expect(t.last.closedByClient, isFalse, reason: '恢复之后不该还记着旧账');
        async.flushTimers();
      });
    });
  });

  group('pokeAlive:回前台立刻探活', () {
    test('连接还在时只发 ping,不重连', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        addTearDown(c.dispose);
        _connectAndHandshake(c, t, async);

        final before = t.channels.length;
        t.last.sent.clear();

        c.pokeAlive();
        async.flushMicrotasks();

        expect(t.channels.length, before,
            reason: '健康连接不该被重连 —— 重连要重算 Argon2 证明,既慢又浪费');
        expect(t.last.sentOfType('ping').isNotEmpty, isTrue,
            reason: '要立刻问一声,而不是干等下一个 20 秒周期');

        async.flushTimers();
      });
    });

    test('没有连接时会去连', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        addTearDown(c.dispose);

        expect(t.channels, isEmpty);
        c.pokeAlive();
        async.flushMicrotasks();

        expect(t.channels, isNotEmpty, reason: '断了就该连回去');
        async.flushTimers();
      });
    });

    test('上一发 ping 还没回音时,poke 不会把欠账盖掉', () {
      // 若每次 poke 都重置 _pingSentAt,欠账永远攒不到 2,
      // 探活就形同虚设 —— 频繁切前后台的用户尤其容易撞上。
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        addTearDown(c.dispose);
        _connectAndHandshake(c, t, async);

        // 握手时已发过一个 ping 且没回音。再 poke 一次 → 欠账 1。
        c.pokeAlive();
        async.flushMicrotasks();
        expect(t.last.closedByClient, isFalse);

        // 下一个周期发现仍无回音 → 欠账 2 → 判死
        async.elapse(const Duration(seconds: 20));
        expect(t.last.closedByClient, isTrue,
            reason: 'poke 不该掩盖既有的欠账');

        async.flushTimers();
      });
    });
  });
}
