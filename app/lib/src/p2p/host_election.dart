/// 选主机:多人直连时挑一个人转发音频。
///
/// ## 为什么要有主机
///
/// 全网状下每个人上行 N-1 路音频;选出主机之后,
/// **普通成员只上行 1 路**,主机上行 N-1 路。
///
/// | | 全网状 | 主机转发 |
/// |---|---|---|
/// | 4 人时主机上行 | 3 路 | 3 路 |
/// | 4 人时**其他人**上行 | 3 路 | **1 路** |
/// | 连接数 | 6 条 | 3 条 |
///
/// 真正省的不是主机的带宽,是**其他三个人的** —— 而手机通常就在那三个人里。
///
/// ## 主机只转发,不解码
///
/// 原样抄字节给其他人,不解码不混音。CPU 负担极低。
///
/// (「桌面端解码混音、手机端不混」这个想法更省带宽,但落不了地:
/// `flutter_webrtc 1.6.0` 没有暴露解码后的 PCM,也没有插入自定义音频源的
/// 接口 —— 查过全部 API,只有音频设备管理类。所以走不了那条路。)
///
/// ## 桌面端优先
///
/// 桌面通常插着电、连着 WiFi、上行更稳,适合扛 N-1 路。
/// 所以选主机时它天然加分 —— 这是「电脑当主机」这个直觉的正确落点。
///
/// ## 必须是确定性的
///
/// 所有人要算出**同一个**主机。否则会分裂成几个互不相通的小房间,
/// 而且谁都不知道出了什么事。所以:纯函数、输入相同则输出相同、
/// 平分时用 userId 字典序兜底(而不是随机或「先到先得」)。
library;

import 'package:flutter/foundation.dart';

/// 参与选举的一个候选人。
@immutable
class HostCandidate {
  const HostCandidate({
    required this.userId,
    required this.isDesktop,
    required this.latencyMs,
  });

  final String userId;

  /// 桌面端(Windows/macOS/Linux)。
  final bool isDesktop;

  /// 到**信令服务器**的往返延迟。
  ///
  /// 不是真实的点对点延迟 —— 那要先建立 N×(N-1)/2 条连接才测得到,
  /// 而建连接正是我们想避免的(鸡生蛋)。
  /// 用到服务器的延迟是个强相关的近似:网络差的人到哪儿都慢。
  ///
  /// 负数表示未知(还没测到),按最差处理。
  final int latencyMs;
}

/// 桌面端的加分,折算成毫秒。
///
/// 150ms 的量级意味着:一个延迟 200ms 的桌面端会赢过延迟 100ms 的手机
/// (200-150=50 < 100),但赢不过延迟 30ms 的手机。
/// 这是刻意的 —— 桌面优势是真实的(电源、WiFi、上行稳定),
/// 但不该压倒一个网络明显更好的手机。
const int kDesktopBonusMs = 150;

/// 未知延迟按这个值算。取得足够大,让「测到的」总是优先于「没测到的」。
const int kUnknownLatencyMs = 9999;

/// 一个候选人的得分。**越低越好**。
int hostScore(HostCandidate c) {
  final base = c.latencyMs < 0 ? kUnknownLatencyMs : c.latencyMs;
  return c.isDesktop ? base - kDesktopBonusMs : base;
}

/// 从候选人里选出主机。
///
/// 返回 null 表示没有候选人。
///
/// 排序规则(依次):
///  1. 得分低的赢(延迟低 + 桌面加分)
///  2. 得分相同时,**userId 字典序小的赢** —— 必须有这条,
///     否则平分时不同设备可能选出不同的主机,房间会裂开
HostCandidate? electHost(List<HostCandidate> candidates) {
  if (candidates.isEmpty) return null;
  final sorted = [...candidates]..sort((a, b) {
      final d = hostScore(a).compareTo(hostScore(b));
      if (d != 0) return d;
      return a.userId.compareTo(b.userId);
    });
  return sorted.first;
}

/// 主机换人时,值不值得真的切。
///
/// 切换要全员重新握手,有一两秒中断。所以**只在两种情况下切**:
///  1. 现任主机已经不在了(必须切,没得选)
///  2. 新候选明显更好(差距超过阈值)
///
/// 第 2 条要有阈值,否则网络抖动会导致反复切换,
/// 而每次切换都是一次中断 —— 那比延迟高一点糟得多。
const int kSwitchThresholdMs = 300;

bool shouldSwitchHost({
  required HostCandidate? current,
  required HostCandidate? next,
}) {
  if (next == null) return false;
  // 现任不在了:必须切
  if (current == null) return true;
  if (current.userId == next.userId) return false;
  // 明显更好才切,否则宁可忍着 —— 切换的中断成本是实打实的
  return hostScore(current) - hostScore(next) > kSwitchThresholdMs;
}
