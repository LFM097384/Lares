import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/p2p/host_election.dart';

/// 选主机的测试。
///
/// 两条不变量决定这个功能成不成立:
///   1. **确定性** —— 所有人必须算出同一个主机,否则房间会裂成几半
///   2. **不抖** —— 网络波动不该导致反复切换,每次切换都是一次中断
void main() {
  HostCandidate desktop(String id, int ms) =>
      HostCandidate(userId: id, isDesktop: true, latencyMs: ms);
  HostCandidate phone(String id, int ms) =>
      HostCandidate(userId: id, isDesktop: false, latencyMs: ms);

  group('基本选择', () {
    test('空名单返回 null', () {
      expect(electHost(const []), isNull);
    });

    test('只有一个人就是他', () {
      expect(electHost([phone('u_a', 50)])!.userId, 'u_a');
    });

    test('同为手机时,延迟低的赢', () {
      final h = electHost([phone('u_a', 200), phone('u_b', 50)]);
      expect(h!.userId, 'u_b');
    });

    test('同等延迟时,桌面端赢', () {
      final h = electHost([phone('u_a', 100), desktop('u_b', 100)]);
      expect(h!.userId, 'u_b', reason: '桌面插电、WiFi、上行稳,适合扛 N-1 路');
    });
  });

  group('桌面加分是有限的,不该压倒明显更好的网络', () {
    test('延迟 200 的桌面 赢过 延迟 100 的手机', () {
      // 200 - 150 = 50 < 100
      final h = electHost([desktop('u_pc', 200), phone('u_ph', 100)]);
      expect(h!.userId, 'u_pc');
    });

    test('延迟 200 的桌面 输给 延迟 30 的手机', () {
      // 200 - 150 = 50 > 30 —— 网络明显更好的手机该赢
      final h = electHost([desktop('u_pc', 200), phone('u_ph', 30)]);
      expect(h!.userId, 'u_ph',
          reason: '桌面优势是真实的,但不该压倒一个网络明显更好的手机');
    });
  });

  group('⚠️ 确定性:所有人必须算出同一个主机', () {
    test('候选顺序不影响结果', () {
      final a = [phone('u_a', 100), desktop('u_b', 120), phone('u_c', 90)];
      final b = [phone('u_c', 90), phone('u_a', 100), desktop('u_b', 120)];
      final c = [desktop('u_b', 120), phone('u_c', 90), phone('u_a', 100)];
      expect(electHost(a)!.userId, electHost(b)!.userId);
      expect(electHost(b)!.userId, electHost(c)!.userId);
    });

    test('完全平分时用 userId 字典序兜底 —— 不能随机', () {
      final h1 = electHost([phone('u_b', 100), phone('u_a', 100)]);
      final h2 = electHost([phone('u_a', 100), phone('u_b', 100)]);
      expect(h1!.userId, 'u_a');
      expect(h2!.userId, 'u_a');
      // 跑十次结果都一样
      for (var i = 0; i < 10; i++) {
        expect(electHost([phone('u_b', 100), phone('u_a', 100)])!.userId, 'u_a');
      }
    });
  });

  group('延迟未知', () {
    test('没测到延迟的人排在测到的之后', () {
      final h = electHost([phone('u_a', -1), phone('u_b', 500)]);
      expect(h!.userId, 'u_b', reason: '宁可选一个已知慢的,也不赌一个未知的');
    });

    test('全都未知时,桌面端仍然优先', () {
      final h = electHost([phone('u_a', -1), desktop('u_b', -1)]);
      expect(h!.userId, 'u_b');
    });
  });

  group('⚠️ 换主机要防抖', () {
    test('现任不在了:必须切', () {
      expect(
        shouldSwitchHost(current: null, next: phone('u_a', 100)),
        isTrue,
      );
    });

    test('还是同一个人:不切', () {
      final me = phone('u_a', 100);
      expect(shouldSwitchHost(current: me, next: me), isFalse);
    });

    test('新人只好一点点:不切 —— 切换的中断成本更高', () {
      final now = phone('u_a', 300);
      final next = phone('u_b', 200); // 只好 100ms,低于 300ms 阈值
      expect(shouldSwitchHost(current: now, next: next), isFalse,
          reason: '网络抖一下就换人,会导致反复中断');
    });

    test('新人明显更好:才切', () {
      final now = phone('u_a', 600);
      final next = phone('u_b', 100); // 好 500ms,超过阈值
      expect(shouldSwitchHost(current: now, next: next), isTrue);
    });

    test('没有候选人时不切', () {
      expect(shouldSwitchHost(current: phone('u_a', 100), next: null), isFalse);
    });

    test('抖动场景:延迟在阈值内来回变,一次都不该切', () {
      final host = desktop('u_pc', 100);
      // 模拟手机延迟在 80~350 之间抖动
      for (final ms in [80, 350, 120, 300, 90, 200]) {
        final other = phone('u_ph', ms);
        final winner = electHost([host, other])!;
        // 就算某一刻手机得分更低,也不该真的切
        if (winner.userId != host.userId) {
          expect(shouldSwitchHost(current: host, next: winner), isFalse,
              reason: '$ms ms 时不该切 —— 差距没到阈值');
        }
      }
    });
  });
}
