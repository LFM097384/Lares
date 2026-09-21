/// 跨服务器 presence 连接池:同时连 N 台服务器,只为「我有空」这件事。
///
/// ## 为什么要它
///
/// 主连接([SignalingClient])是单条的,负责进房、RTC token、聊天 ——
/// 那条链路很重,不该为了一个可见性标记去动它。
///
/// 但「我有空」天生是跨圈的:甲圈在我的服务器、乙圈在朋友的服务器,
/// 两边都该看到我。于是另开若干**只做 presence** 的轻连接,
/// 在每台服务器上各自挂起。
///
/// ## 为什么服务器之间不用通信
///
/// 这是整个设计里最省事的一点:**根本不存在「跨服」这回事**。
///
/// 你在甲服务器是甲身份(用甲的圈口令认证),在乙服务器是乙身份。
/// 两台机器谁都不知道对方存在,也不需要验证「这是同一个人」——
/// 聚合发生在**客户端**。
///
/// 代价只有「客户端要管多条连接」;换来的是零协议变更、零新信任假设。
/// 对照组是 Matrix/ActivityPub 式的服务器互联:那需要跨服身份体系、
/// 服务器发现、信任模型、抗滥用,是数月级的子项目。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../auth/auth_credential.dart';
import 'server_profile.dart';
import 'signaling_client.dart';

/// 一台服务器上看到的可约者。
@immutable
class RemoteAvailable {
  const RemoteAvailable({
    required this.serverId,
    required this.userId,
    required this.name,
    required this.circleIds,
    required this.since,
  });

  /// 来自哪台服务器([ServerProfile.id])。
  ///
  /// **必须带着** —— 去找这个人时要知道往哪台机器发 reach,
  /// 而且两台服务器上可能有同名甚至同 userId 的人(userId 是本地生成的,
  /// 不同服务器之间毫无关系),只有 (serverId, userId) 合起来才唯一。
  final String serverId;
  final String userId;
  final String name;
  final List<String> circleIds;
  final int since;

  /// 跨服务器唯一的键。
  String get key => '$serverId/$userId';
}

/// 一条轻连接的运行状态,用于 UI 如实呈现「哪台服务器没连上」。
enum PresenceLinkState { connecting, online, failed }

/// 跨服务器 presence 池。
///
/// 生命周期由调用方掌握:[syncProfiles] 决定连哪几台,
/// [setAvailable] / [clearAvailable] 广播到所有在线的链路。
class PresencePool extends ChangeNotifier {
  /// [userId] 只用来把自己从「有谁有空」里排除掉。
  /// 昵称与 deviceId 不在这里传 —— `SignalingClient` 自己管 hello 握手。
  PresencePool({
    required String userId,
    required AuthCredential Function(String serverId, String? circleId)
        credentialFor,
    SignalingClient Function(String url, CredentialSource creds)? clientFactory,
  })  : _userId = userId,
        _credentialFor = credentialFor,
        _factory = clientFactory ?? _defaultFactory;

  static SignalingClient _defaultFactory(String url, CredentialSource creds) =>
      SignalingClient(url: url, credentials: creds);

  final String _userId;
  final AuthCredential Function(String serverId, String? circleId)
      _credentialFor;
  final SignalingClient Function(String url, CredentialSource creds) _factory;

  final Map<String, SignalingClient> _links = {};
  final Map<String, StreamSubscription<Map<String, dynamic>>> _subs = {};
  final Map<String, PresenceLinkState> _states = {};

  /// 跨服务器聚合后的可约者。键是 `serverId/userId`。
  final Map<String, RemoteAvailable> remote = {};

  /// 我此刻在每台服务器上挂着哪几个圈子。
  final Map<String, List<String>> _mine = {};

  /// 「有人来找我了」——(serverId, circleId, 来找的人)
  ({String serverId, String circleId, String by})? reached;

  PresenceLinkState stateOf(String serverId) =>
      _states[serverId] ?? PresenceLinkState.connecting;

  Map<String, PresenceLinkState> get linkStates => Map.unmodifiable(_states);

  /// 某个圈子里有谁挂着(跨所有服务器聚合,排除自己)。
  List<RemoteAvailable> availableIn(String circleId) => [
        for (final r in remote.values)
          if (r.userId != _userId && r.circleIds.contains(circleId)) r,
      ];

  /// 决定要连哪几台服务器。
  ///
  /// [exclude] 是主连接已经在用的那台 —— 不重复连,
  /// 它的可约者由主连接自己的消息流提供。
  void syncProfiles(List<ServerProfile> profiles, {String? exclude}) {
    final want = {
      for (final p in profiles)
        if (p.id != exclude && p.url.isNotEmpty) p.id: p,
    };
    // 断掉不再需要的
    for (final id in _links.keys.toList()) {
      if (!want.containsKey(id)) _drop(id);
    }
    // 连上新增的
    for (final e in want.entries) {
      if (_links.containsKey(e.key)) continue;
      _connect(e.key, e.value.url);
    }
    notifyListeners();
  }

  void _connect(String serverId, String url) {
    final client = _factory(
      url,
      () => _credentialFor(serverId, null),
    );
    _links[serverId] = client;
    _states[serverId] = PresenceLinkState.connecting;
    _subs[serverId] = client.messages.listen(
      (msg) => _onMessage(serverId, msg),
      onError: (Object e) {
        debugPrint('[lares] presence 链路 $serverId 出错: $e');
        // ⚠️ 这里以前只改状态、**不清人**,是和 _disconnected 一模一样的幽灵条目:
        // 链路都报错了,那台服务器上看到的「有空」全都联系不上,
        // UI 却还照常画出来,点下去 reach 发进一条死流,什么都不会发生。
        // 走 _linkDown 一并收尾,别让两条失败路径各清各的、其中一条忘了清。
        _linkDown(serverId, PresenceLinkState.failed);
      },
    );
    client.connect();
  }

  void _drop(String serverId) {
    _subs.remove(serverId)?.cancel();
    _links.remove(serverId)?.dispose();
    _states.remove(serverId);
    _mine.remove(serverId);
    // 这台机器上看到的人一并清掉,否则会留下永远点不动的幽灵
    remote.removeWhere((_, r) => r.serverId == serverId);
  }

  /// 链路掉了、但对象还得留着(它自己会重连)时的收尾。
  ///
  /// 和 [_drop] 的分工:_drop 是「不再需要这台服务器」,退订 + dispose;
  /// 这里链路要原样留着等它爬回来,所以只清**从服务器观测来的事实**。
  /// 拿 _drop 来对付一次抖动会把客户端销毁掉,自动重连也就没了。
  ///
  /// ⚠️ 不碰 `_mine[serverId]`:那是我**自己的意图**(想在哪几个圈子里挂着),
  /// 不是观测来的事实。断线时它发不出去没关系,welcome 会补发;
  /// 在这里顺手清掉,用户就会在一次网络抖动之后悄无声息地不再挂着 ——
  /// 那是拿一个 bug 换另一个更难发现的 bug。
  ///
  /// 也不碰 `reached`:「某时刻有人来找过我」是一次性事实,不是链路状态;
  /// 何况赴约走的是**主连接**(见 main.dart),不是这条 presence 轻连接,
  /// 轻连接断了并不表示这个约不该赴。为它清掉只会凭空吞掉一次邀请。
  void _linkDown(String serverId, PresenceLinkState state) {
    final before = remote.length;
    remote.removeWhere((_, r) => r.serverId == serverId);
    final changed = remote.length != before || _states[serverId] != state;
    _states[serverId] = state;
    // 沿用本文件的约定:真变了才通知,不为一次无变化的抖动触发重建
    if (changed) notifyListeners();
  }

  void _onMessage(String serverId, Map<String, dynamic> msg) {
    switch (msg['t']) {
      case 'welcome':
        _states[serverId] = PresenceLinkState.online;
        // 连上了就把我的挂着状态补发过去 ——
        // 断线重连后必须自动恢复,否则用户以为自己还挂着,其实早掉了。
        final mine = _mine[serverId];
        if (mine != null && mine.isNotEmpty) {
          _links[serverId]?.setAvailable(mine);
        }
        notifyListeners();
      case 'member_available':
        final uid = msg['userId'] as String?;
        if (uid == null) return;
        final r = RemoteAvailable(
          serverId: serverId,
          userId: uid,
          name: msg['name'] as String? ?? '',
          circleIds:
              (msg['circleIds'] as List? ?? []).whereType<String>().toList(),
          since: (msg['since'] as num?)?.toInt() ?? 0,
        );
        remote[r.key] = r;
        notifyListeners();
      case 'member_unavailable':
        final uid = msg['userId'] as String?;
        if (uid == null) return;
        if (remote.remove('$serverId/$uid') != null) notifyListeners();
      case 'available_ok':
        _mine[serverId] =
            (msg['circleIds'] as List? ?? []).whereType<String>().toList();
        notifyListeners();
      case 'reached':
        // 有人在**这台**服务器上来找我了。
        // 池子不负责进房 —— 那是主连接的事,这里只把事实报上去。
        reached = (
          serverId: serverId,
          circleId: msg['circleId'] as String? ?? '',
          by: msg['by'] as String? ?? '',
        );
        _mine.remove(serverId);
        notifyListeners();
      // ↓ 以下三条是信令层自己合成的内部消息(见 signaling_client.dart),
      //   不是服务端报文。它们和真报文走同一条 messages 流。
      //
      //   订阅上的 onError 盖不住这些:onError 只在流真出错时才响,
      //   socket 正常关闭、以及这三条合成消息,都不会走到那里。
      case '_disconnected':
        // 一次抖动。链路会自己指数退避重连,重连后服务端重发
        // member_available、welcome 补发我的挂起 —— 名单会自愈。
        //
        // 那为什么还要立刻清:名单自愈要等几秒,这几秒里 UI 会把
        // 连不上的人显示成「有空」,点下去 reach 发进一个死 socket,
        // 什么都不会发生 —— 一个看着能按、其实是死的按钮。
        // 宁可闪一下也不撒谎:这个功能问的就是「此刻找得着这个人吗」。
        // 状态给 connecting 而不是 failed,UI 才能如实画「正在重连」。
        _linkDown(serverId, PresenceLinkState.connecting);
      case '_rate_limited':
        // 4429:被限流。信令层从 60s 起步硬退避,虽然最终还会再试,
        // 但用户这几分钟看到的事实就是「这台服务器现在不好使」。
        // 给 failed 而不是 connecting:前一条 _disconnected 已经写过
        // connecting 了,再写一遍等于什么都没说,UI 会把一次数分钟的
        // 封禁画成转圈圈,让人一直等一个不会马上回来的东西。
        _linkDown(serverId, PresenceLinkState.failed);
      case '_auth_failed':
        // 终局:第二次 4401,信令层**彻底不再重连**了
        // (见 _onAuthRejected —— 继续重试必然撞 4429 封 IP)。
        // 所以此后一条 _disconnected 都不会再来,上面那条分支等不到,
        // 不在这里收尾的话,这台服务器会永远停在 online 并挂着
        // 一整屏永远联系不上的人。口令得用户去改,我们只负责别撒谎。
        _linkDown(serverId, PresenceLinkState.failed);
    }
  }

  /// 在各台服务器上挂起。[byServer] 指明每台服务器上要挂哪几个圈子。
  ///
  /// 分服务器传而不是给一个大列表:圈子 id 只在它所属的服务器上有意义,
  /// 把甲服务器的圈子 id 发给乙服务器,轻则被拒(auth_scope),
  /// 重则误挂进乙服务器上一个同名的圈子。
  void setAvailable(Map<String, List<String>> byServer) {
    for (final e in byServer.entries) {
      final link = _links[e.key];
      if (link == null || e.value.isEmpty) continue;
      _mine[e.key] = List.unmodifiable(e.value);
      // 断线时发不出去也没关系:welcome 时会补发(见 _onMessage)
      link.setAvailable(e.value);
    }
    notifyListeners();
  }

  void clearAvailable() {
    for (final e in _links.entries) {
      if (_mine.containsKey(e.key)) e.value.clearAvailable();
    }
    _mine.clear();
    notifyListeners();
  }

  /// 去找某个可约者。必须指明是哪台服务器上的那个人。
  void reach(RemoteAvailable target, {String? circleId}) {
    _links[target.serverId]?.reach(target.userId, circleId: circleId);
  }

  void consumeReached() {
    if (reached == null) return;
    reached = null;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final id in _links.keys.toList()) {
      _drop(id);
    }
    super.dispose();
  }
}
