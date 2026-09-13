/// 屏蔽名单的**声音侧**执行器(App Store 审核指南 1.2)。
///
/// 屏蔽一个人,只把他的聊天消息过滤掉是不够的 —— 审核同学会直接用耳朵测:
/// 屏蔽之后还能听见对方说话,这一条就过不了。本类负责把 [BlockStore] 的名单
/// 落到 LiveKit 的远端音频轨上。
///
/// **为什么要单独一个类、还要拿具体的 [LiveKitRtcService]**:
/// `RtcService` 是刻意保持厂商无关的抽象层(设计.md §8.1),里面不能出现
/// `Room`;而且它有两个测试 fake 实现,往接口上加成员会直接弄坏整套测试。
/// 所以这里沿用 `chat/session_chat_transport.dart` 已经验证过的做法:
/// 把**具体实现**作为独立的构造参数传进来,抽象层一个字都不用改。
///
/// **生命周期纪律**:`LiveKitRtcService.room` 只在 `join()` 与 `leave()` 之间
/// 非空,`leave()` 会把它 dispose 掉。因此房间监听必须**每次进房重新挂**,
/// 绝不可跨会话缓存 —— 缓存了不会报错,只会静默失灵,那才是最难查的故障。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import '../rtc/livekit_rtc_service.dart';
import '../state/models.dart';
import '../state/room_controller.dart';
import 'block_store.dart';

/// 取当前 `Room` 的种子。默认实现是 `() => rtc.room`,
/// 测试里可以换成 `() => null`(未进房)或一个桩对象。
typedef RoomGetter = Room? Function();

// ─────────────────────────────────────────────────────────────────────────────
// 纯决策逻辑
//
// 刻意做成顶层纯函数:不碰 LiveKit、不碰异步、不碰任何插件通道,
// 于是「谁该被静音」这件事可以在 `flutter test` 里被完整驱动,
// 不需要真机、不需要房间、不需要第二个人对着麦克风说话。
// ─────────────────────────────────────────────────────────────────────────────

/// 本次应当处于静音状态的 identity 集合 = 屏蔽名单 ∩ 当前在房的人。
///
/// 注意两点语义:
/// 1. **只按 identity 精确匹配**。identity 就是 `state/identity.dart` 生成的
///    `u_xxxxxxx`,和昵称无关 —— 对方改个显示名不该让屏蔽失效,
///    反过来别人顶着同样的昵称也不该被误伤。
/// 2. 被屏蔽但**当前不在房**的人不出现在结果里:没有轨可操作,是纯 no-op。
Set<String> selectIdentitiesToMute({
  required Set<String> blockedIds,
  required Iterable<String> presentIdentities,
}) {
  final Set<String> out = <String>{};
  for (final String id in presentIdentities) {
    if (id.isEmpty) continue; // 防御:空 identity 永远不匹配任何屏蔽项
    if (blockedIds.contains(id)) out.add(id);
  }
  return out;
}

/// 本次应当**恢复**声音的 identity 集合。
///
/// 只恢复「我们自己之前压过的、现在不该再压、而且人还在房里」的那些 ——
/// 绝不对从没碰过的轨调 `enable()`:那会和 dynacast / adaptiveStream
/// 的自动订阅策略抢方向盘,属于越权。
Set<String> selectIdentitiesToRestore({
  required Set<String> previouslyMuted,
  required Set<String> desiredMuted,
  required Iterable<String> presentIdentities,
}) {
  final Set<String> present = presentIdentities.toSet();
  return previouslyMuted
      .where((String id) => !desiredMuted.contains(id) && present.contains(id))
      .toSet();
}

// ─────────────────────────────────────────────────────────────────────────────
// 执行器
// ─────────────────────────────────────────────────────────────────────────────

/// 让 LiveKit 的远端音频状态始终跟随 [BlockStore]。
class BlockAudioEnforcer {
  BlockAudioEnforcer({
    required LiveKitRtcService rtc,
    required RoomController controller,
    required BlockStore blocks,
    // 测试种子:默认就是 `() => rtc.room`。单测里换成 `() => null`
    // 即可在完全没有 LiveKit 连接的情况下驱动整套生命周期逻辑。
    RoomGetter? roomGetter,
  })  : _controller = controller,
        _blocks = blocks,
        _roomGetter = roomGetter ?? (() => rtc.room) {
    _blocks.addListener(_onBlocksChanged);
    _controller.addListener(_onPhase);
    _onPhase(); // 可能已在房里(热重载/重连)
  }

  final RoomController _controller;
  final BlockStore _blocks;
  final RoomGetter _roomGetter;

  /// 当前挂着监听的那个 `Room`。用**对象身份**比对,
  /// 因为每次进房都是全新的 `Room` 实例。
  Room? _attachedRoom;
  EventsListener<RoomEvent>? _listener;

  /// 我们**自己**压下去的 identity。只恢复这里面的人,不越权动别人的轨。
  /// 换了房间要清空:新 `Room` 里的 publication 全是新对象,旧记录没有意义。
  final Set<String> _appliedMutes = <String>{};

  bool _disposed = false;

  /// 扫描是异步的(每条轨两次 await),而事件可能密集到来。
  /// 用「进行中 + 待重跑」这一对标志把并发扫描压成串行,
  /// 避免两轮扫描交叉写 `_appliedMutes`。
  bool _sweeping = false;
  bool _resweepPending = false;

  /// 测试与调试用:当前被我们压住的 identity 快照。
  @visibleForTesting
  Set<String> get appliedMutes => Set<String>.unmodifiable(_appliedMutes);

  /// 测试用:同步地把一次扫描跑完(生产路径都是即发即忘)。
  @visibleForTesting
  Future<void> applyNow() => _sweep();

  // ───────────────────────────────────────────────────────────────────────────
  // 监听接线
  // ───────────────────────────────────────────────────────────────────────────

  void _onBlocksChanged() {
    if (_disposed) return;
    _scheduleSweep();
  }

  /// 房间阶段变化:进房要(重新)挂监听并补扫,退房要拆干净。
  void _onPhase() {
    if (_disposed) return;

    final bool inRoom = _controller.phase == RoomPhase.inRoom;
    // phase 可能先于 room 就绪(竞态),没拿到就等下一次通知。
    final Room? room = inRoom ? _safeRoom() : null;

    if (room == null) {
      _detachRoom();
      return;
    }

    if (!identical(room, _attachedRoom)) {
      _detachRoom();
      _attachRoom(room);
    }

    // 每次进房都补扫一次:监听器装上之前就已经订阅好的轨不会再补发事件,
    // 「先进房、后屏蔽」与「先屏蔽、后进房」两条路径都得走到。
    _scheduleSweep();
  }

  void _attachRoom(Room room) {
    try {
      final EventsListener<RoomEvent> listener = room.createListener();
      _attachedRoom = room;
      _listener = listener;

      // 这几个事件都是「被屏蔽者的声音可能重新冒出来」的时刻:
      // 有人进房、有人发布新轨、我们订阅上了新轨、对方取消静音、房间重连。
      // 任何一个漏掉,都会表现为「屏蔽了但偶尔还能听见」—— 审核必挂。
      listener.on<ParticipantConnectedEvent>((_) => _scheduleSweep());
      listener.on<TrackPublishedEvent>((_) => _scheduleSweep());
      listener.on<TrackSubscribedEvent>((_) => _scheduleSweep());
      listener.on<TrackUnmutedEvent>((_) => _scheduleSweep());
      listener.on<RoomReconnectedEvent>((_) {
        // 重连后服务端那边的 UpdateTrackSettings 可能已经丢了,
        // 之前压过的记录不能再信,整体重来一遍。
        _appliedMutes.clear();
        _scheduleSweep();
      });
    } catch (e) {
      debugPrint('[lares] 屏蔽音频执行器挂载房间监听失败: $e');
      _attachedRoom = null;
      _listener = null;
    }
  }

  void _detachRoom() {
    final EventsListener<RoomEvent>? listener = _listener;
    _listener = null;
    _attachedRoom = null;
    // 房间换了,旧 publication 全部作废。
    _appliedMutes.clear();
    if (listener == null) return;
    // dispose 是异步的,但拆监听不该阻塞状态机;失败也只是日志。
    unawaited(_disposeListener(listener));
  }

  static Future<void> _disposeListener(EventsListener<RoomEvent> listener) async {
    try {
      await listener.dispose();
    } catch (e) {
      debugPrint('[lares] 屏蔽音频执行器拆除房间监听失败(已忽略): $e');
    }
  }

  /// 取 `Room` 并吞掉任何异常:种子是注入的,不能假定它一定安全。
  Room? _safeRoom() {
    try {
      return _roomGetter();
    } catch (e) {
      debugPrint('[lares] 屏蔽音频执行器取 Room 失败: $e');
      return null;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 扫描与执行
  // ───────────────────────────────────────────────────────────────────────────

  void _scheduleSweep() {
    if (_disposed) return;
    if (_sweeping) {
      _resweepPending = true;
      return;
    }
    unawaited(_sweep());
  }

  Future<void> _sweep() async {
    if (_disposed) return;
    if (_sweeping) {
      _resweepPending = true;
      return;
    }
    _sweeping = true;
    try {
      do {
        _resweepPending = false;
        await _sweepOnce();
      } while (_resweepPending && !_disposed);
    } catch (e) {
      // 绝不向上抛:这是后台维护动作,炸了不能影响通话主路径。
      debugPrint('[lares] 屏蔽音频执行器扫描异常(已忽略): $e');
    } finally {
      _sweeping = false;
    }
  }

  Future<void> _sweepOnce() async {
    // 未进房就是纯 no-op —— `room` 只在 join()/leave() 之间非空。
    final Room? room = _safeRoom();
    if (room == null) {
      _appliedMutes.clear();
      return;
    }

    final Map<String, RemoteParticipant> remotes;
    try {
      remotes = Map<String, RemoteParticipant>.from(room.remoteParticipants);
    } catch (e) {
      debugPrint('[lares] 屏蔽音频执行器读取远端成员失败: $e');
      return;
    }

    // remoteParticipants 是按 identity 建索引的(SDK: core/room.dart:79),
    // 但这里仍以 participant.identity 为准,不依赖 map key。
    final List<String> present =
        remotes.values.map((RemoteParticipant p) => p.identity).toList();

    final Set<String> desired = selectIdentitiesToMute(
      blockedIds: _blocks.blockedIds,
      presentIdentities: present,
    );
    final Set<String> restore = selectIdentitiesToRestore(
      previouslyMuted: _appliedMutes,
      desiredMuted: desired,
      presentIdentities: present,
    );

    for (final RemoteParticipant p in remotes.values) {
      final String identity = p.identity;
      if (desired.contains(identity)) {
        await _muteParticipant(p);
      } else if (restore.contains(identity)) {
        await _unmuteParticipant(p);
      }
    }

    _appliedMutes
      ..clear()
      ..addAll(desired);
  }

  /// 把某人的所有音频轨压成静音。
  ///
  /// **两步缺一不可,且顺序不能反**:
  /// 1. `track.disable()` —— 直接把 `mediaStreamTrack.enabled` 置 false
  ///    (SDK: track/track.dart:159-168),**本地立即生效**,这一下才是
  ///    「点了屏蔽,耳朵马上听不见」的那个瞬间;
  /// 2. `publication.disable()` —— 告诉 SFU 别再往下发这条轨
  ///    (SDK: publication/remote.dart:341-345),省带宽省电。但它走的是
  ///    **防抖 1500ms** 的 `UpdateTrackSettings`,单靠它会有一秒多的漏音窗口,
  ///    所以绝不能只做这一步。
  ///
  /// 反过来只做第 1 步也不行:声音是静了,但服务端还在一直发,流量白烧。
  /// 两者缺一不可。
  ///
  /// ⚠️ livekit_client 2.12.0 **没有** `setVolume` 这个 API(整包搜过,
  /// 唯一的 "volume" 命中是 web 端音量可视化的计量辅助,与播放无关),
  /// 所以「本地 disable + 服务端 disable」这一对就是本 SDK 版本下的正解,
  /// 不要再去找音量接口了。
  Future<void> _muteParticipant(RemoteParticipant p) async {
    for (final RemoteTrackPublication<RemoteAudioTrack> pub
        in p.audioTrackPublications) {
      try {
        await pub.track?.disable(); // 1. 本地立即静音
        await pub.disable(); // 2. 通知服务端停发
      } catch (e) {
        // 单条轨出问题不能中断整轮扫描 —— 还有别人的声音等着被压。
        debugPrint('[lares] 屏蔽静音失败 identity=${p.identity}: $e');
      }
    }
  }

  /// 解除屏蔽:严格按相反顺序还原 —— 先让服务端恢复下发,再放开本地轨。
  /// 反过来的话会先把本地轨打开、而服务端还没开始发,徒增一段无声期。
  Future<void> _unmuteParticipant(RemoteParticipant p) async {
    for (final RemoteTrackPublication<RemoteAudioTrack> pub
        in p.audioTrackPublications) {
      try {
        await pub.enable(); // 1. 服务端恢复下发
        await pub.track?.enable(); // 2. 本地放开
      } catch (e) {
        debugPrint('[lares] 解除屏蔽静音失败 identity=${p.identity}: $e');
      }
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 释放
  // ───────────────────────────────────────────────────────────────────────────

  /// 幂等:重复调用不报错,也不会重复摘监听。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _blocks.removeListener(_onBlocksChanged);
    _controller.removeListener(_onPhase);
    _detachRoom();
  }
}
