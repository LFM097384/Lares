/// 多人点对点:**星形**拓扑,一个人当主机转发。
///
/// ## 为什么是星形而不是全网状
///
/// 全网状下每个人上行 N-1 路;选出主机之后,普通成员只上行 1 路。
///
/// | | 全网状 | 主机转发 |
/// |---|---|---|
/// | 4 人时**普通成员**上行 | 3 路 | **1 路** |
/// | 连接数 | 6 条 | **3 条** |
///
/// 真正省的不是主机的带宽,是**其他人的** —— 而手机通常就在"其他人"里。
/// 主机由 `host_election.dart` 选出,桌面端优先。
///
/// ## 主机只转发,不解码不混音
///
/// 原样抄字节。CPU 负担极低,延迟也低。
/// (混音更省带宽,但 `flutter_webrtc 1.6.0` 没有暴露解码后的 PCM,
/// 也没有插入自定义音频源的接口 —— 查过全部 API,做不了。)
///
/// ## 为什么只在有服务器信令时可用
///
/// 就算是星形,3 人也要建 2 条连接、交换 4 段码。手动传不现实。
/// 所以多人**只走服务器信令**,手动连接码保持 1 对 1。
///
/// 服务器在这里仍然只当邮差(见 server 的 `p2p_signal`):
/// 不解析 SDP、不存储,只检查同圈后转发。媒体流全程不经过它。
///
/// ## glare:双方同时开口的问题
///
/// 两个人同时给对方发 offer 会把连接撞坏(WebRTC 里叫 glare)。
/// 解法是一条**确定性**规则:userId 字典序小的那个负责发起。
/// 两端各自算,结果必然一致,不需要额外协商。
///
/// ## 人数上限
///
/// 主机要扛 N-1 路上下行。4 人时主机上行 3 路(Opus 约 32kbps/路,
/// 合计 ~96kbps)—— 桌面轻松,手机也还行。再多就该用 SFU 了。
/// 这条路本来就是「没有服务器时的底线」,不是拿来替代 SFU 的。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'host_election.dart';
import 'p2p_session.dart';

/// 建议的人数上限。超过这个数应当改用 SFU。
const int kMeshMaxPeers = 4;

/// 一个对端的连接状态。
@immutable
class MeshPeer {
  const MeshPeer({
    required this.userId,
    required this.name,
    required this.phase,
    this.failure,
  });

  final String userId;
  final String name;
  final P2PPhase phase;
  final String? failure;

  bool get isConnected => phase == P2PPhase.connected;
}

/// 多人网状会话。
///
/// 用法:
/// ```
/// mesh.onOutgoing = (toUserId, code) => signaling.sendP2PSignal(toUserId, code);
/// await mesh.connectTo('u_b', '小满');   // 主动连一个人
/// mesh.handleIncoming('u_b', '小满', code); // 收到对方的码
/// ```
class P2PMesh extends ChangeNotifier {
  P2PMesh({
    required String myUserId,
    required IceConfig Function() ice,
    P2PSession Function(IceConfig)? sessionFactory,
  })  : _me = myUserId,
        _ice = ice,
        _factory = sessionFactory ?? ((c) => P2PSession(ice: c));

  final String _me;
  final IceConfig Function() _ice;
  final P2PSession Function(IceConfig) _factory;

  final Map<String, P2PSession> _sessions = {};
  final Map<String, String> _names = {};

  /// 把连接码发给某个人。由调用方接到信令层。
  void Function(String toUserId, String payload)? onOutgoing;

  /// 当前所有对端。
  List<MeshPeer> get peers => [
        for (final e in _sessions.entries)
          MeshPeer(
            userId: e.key,
            name: _names[e.key] ?? '',
            phase: e.value.phase,
            failure: e.value.failure,
          ),
      ];

  int get connectedCount =>
      _sessions.values.where((s) => s.phase == P2PPhase.connected).length;

  bool get isFull => _sessions.length >= kMeshMaxPeers;

  /// 当前主机的 userId。null 表示还没选出来。
  String? hostId;

  /// 我是不是主机。
  bool get iAmHost => hostId == _me;

  /// 按成员名单同步连接。
  ///
  /// 这是星形拓扑的核心:**只连主机**(我是主机时则连所有人),
  /// 而不是人人互连。连接数从 N×(N-1)/2 降到 N-1。
  ///
  /// 主机由 [electHost] 选出 —— 纯函数、确定性,所有人算出同一个答案。
  /// 换主机要过 [shouldSwitchHost] 的防抖闸门:网络抖一下就换人,
  /// 会导致反复中断,那比延迟高一点糟得多。
  Future<void> syncRoster(List<HostCandidate> roster) async {
    if (roster.isEmpty) {
      hostId = null;
      await closeAll();
      return;
    }

    final elected = electHost(roster);
    final current = hostId == null
        ? null
        : roster.cast<HostCandidate?>().firstWhere(
              (c) => c?.userId == hostId,
              orElse: () => null,
            );

    // 现任还在名单里就走防抖;不在了(离开/断线)则必须换。
    if (shouldSwitchHost(current: current, next: elected)) {
      hostId = elected?.userId;
      // 换主机要全员重连 —— 旧的星形拓扑整个作废了
      await closeAll();
    }

    final host = hostId;
    if (host == null) return;

    // 该连谁:我是主机就连所有人,否则只连主机。
    // 写成显式循环而不是集合字面量里嵌 if/for/else —— 后者能编译,
    // 但语义不直观,读的人得停下来想一秒。
    final want = <String>{};
    if (iAmHost) {
      for (final c in roster) {
        if (c.userId != _me) want.add(c.userId);
      }
    } else {
      want.add(host);
    }
    want.remove(_me);

    // 断掉不再需要的
    for (final id in _sessions.keys.toList()) {
      if (!want.contains(id)) await disconnect(id);
    }
    // 连上该连的
    for (final id in want) {
      if (_sessions.containsKey(id)) continue;
      await connectTo(id, _names[id] ?? '');
    }
  }

  /// 我是否应当**主动**向 [peerId] 发起握手。
  ///
  /// 确定性规则:userId 字典序小的那个发起。
  /// 两端各自算出的答案必然相反,于是有且只有一方开口 ——
  /// 这就避开了双方同时 offer 造成的 glare。
  bool shouldInitiateTo(String peerId) => _me.compareTo(peerId) < 0;

  /// 主动连一个人。
  ///
  /// 若按规则该由对方发起,这里**什么都不做** —— 等对方的 offer 过来。
  /// 直接返回而不是报错:这是正常路径,不是异常。
  Future<void> connectTo(String peerId, String name) async {
    if (peerId == _me) return;
    if (_sessions.containsKey(peerId)) return;
    if (isFull) return;
    _names[peerId] = name;
    // 按 glare 规则该对方开口时,这里**仍然要建 session 占位** ——
    // 只是不发 offer,等对方的过来。
    //
    // 原来这里直接 return(注释写着「先占位」却什么都没占),
    // 结果是字典序大的一方在等待期间 peers 里根本没有这个人,
    // UI 上看不到「正在连」,用户以为点了没反应。
    final s = _spawn(peerId);
    if (!shouldInitiateTo(peerId)) return;
    await s.createOffer();
    final code = s.localCode;
    if (code != null) onOutgoing?.call(peerId, code);
  }

  /// 收到某人发来的连接码。
  Future<void> handleIncoming(
    String fromId,
    String name,
    String payload,
  ) async {
    if (fromId == _me) return;
    _names[fromId] = name;

    var s = _sessions[fromId];
    if (s == null) {
      if (isFull) return;
      s = _spawn(fromId);
    }

    await s.acceptRemoteCode(payload);
    // 应答方会生成自己的码,回给对方
    final code = s.localCode;
    if (code != null && s.phase == P2PPhase.waitingForPeer) {
      onOutgoing?.call(fromId, code);
    }
  }

  P2PSession _spawn(String peerId) {
    final s = _factory(_ice());
    _sessions[peerId] = s;
    s.addListener(_onPeerChanged);
    notifyListeners();
    return s;
  }

  void _onPeerChanged() => notifyListeners();

  /// 断开某个人。
  Future<void> disconnect(String peerId) async {
    final s = _sessions.remove(peerId);
    _names.remove(peerId);
    if (s == null) return;
    s.removeListener(_onPeerChanged);
    await s.close();
    s.dispose();
    notifyListeners();
  }

  /// 全部断开。
  Future<void> closeAll() async {
    for (final id in _sessions.keys.toList()) {
      await disconnect(id);
    }
  }

  @override
  void dispose() {
    // 不 await:dispose 是同步的。各 session 自己会清理。
    for (final s in _sessions.values) {
      s.removeListener(_onPeerChanged);
      unawaited(s.close());
      s.dispose();
    }
    _sessions.clear();
    super.dispose();
  }
}

