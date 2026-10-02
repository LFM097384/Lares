/// 实时字幕的业务核心(纯 Dart,不碰 LiveKit / 网络,全部依赖可注入)。
///
/// 两个方向:
/// - **看字幕**:本机打开「字幕」→ 广播 `capreq{on:true}`(新人进房时单独补发),
///   收到的 `cap` 按发送者 identity 归属、按 item_id 原地替换,面板只留最近 30 行。
/// - **供字幕**:有人需要(远端请求者,或我自己开着字幕),或圈子开了转写记录,
///   且本机在房、开着麦、麦克风轨道真的在出帧、设置允许(E2EE 圈还要单独同意)时,
///   才把**自己的**麦克风送去云端识别。结果 `cap` **广播**;我自己的行本地直接插入
///   (标「我」)。任何条件不再满足立即停、关连接。
/// - **只转一次**:不论多少请求者 / 是否归档,本机同一时刻最多一个识别会话;
///   旧会话 stop+dispose 完成前绝不建新的(见 [CaptionController.liveTranscribers])。
/// - **定稿出口**:本人每句定稿(从不含 partial)交给 [CaptionController.onOwnFinal],
///   由胶水层决定是否归档(转写记录)。
///
/// 字幕面板只存在内存里,退房即清。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../recording/capture_session.dart'
    show RendererHealth, RendererWatchdog;
import '../rtc/rtc_service.dart';
import 'caption_protocol.dart';

/// 面板最多保留的行数。
const int kCaptionMaxLines = 30;

/// partial 的最小发送间隔(≤5 条/秒)。
const Duration kCaptionPartialInterval = Duration(milliseconds: 200);

/// 识别器的最小接口;生产实现是 QwenRealtimeStt。
abstract interface class CaptionTranscriber {
  void start();
  void addPcm(Uint8List pcm);

  /// 定稿后关连接(最多等 ~1 s)。
  Future<void> stop();
  Future<void> dispose();
}

typedef CaptionTranscriberFactory = CaptionTranscriber Function({
  required void Function(String itemId, String text) onPartial,
  required void Function(String itemId, String text) onFinal,
  required void Function(String reason) onFatal,
});

/// 决定「能不能替别人转写」的外部条件,由胶水层从 RoomController / 设置 / E2EE 汇总。
@immutable
class CaptionConditions {
  const CaptionConditions({
    this.available = false,
    this.inRoom = false,
    this.muted = true,
    this.provide = true,
    this.encrypted = false,
    this.e2eeCloud = false,
    this.archive = false,
  });

  /// 圈主开了「转写记录」(circleInfo.transcript):愿意的人一开麦就转写,
  /// 不再要求有人请求字幕。
  final bool archive;

  /// 服务器提供字幕(welcome.captions)。
  final bool available;
  final bool inRoom;

  /// Lares 层的静音状态。
  final bool muted;

  /// 设置「为需要的人生成字幕」。
  final bool provide;

  /// 当前圈子是否端到端加密。
  final bool encrypted;

  /// 设置「加密圈也允许云端识别」。
  final bool e2eeCloud;

  /// 抛开「有没有人要」「麦在不在出帧」之外,本机是否愿意为别人转写。
  bool get willing => available && provide && (!encrypted || e2eeCloud);

  @override
  bool operator ==(Object other) =>
      other is CaptionConditions &&
      other.available == available &&
      other.inRoom == inRoom &&
      other.muted == muted &&
      other.provide == provide &&
      other.encrypted == encrypted &&
      other.e2eeCloud == e2eeCloud &&
      other.archive == archive;

  @override
  int get hashCode => Object.hash(
      available, inRoom, muted, provide, encrypted, e2eeCloud, archive);
}

/// 面板上的一行字幕。
@immutable
class CaptionLine {
  const CaptionLine({
    required this.identity,
    required this.name,
    required this.itemId,
    required this.text,
    required this.isFinal,
    required this.seq,
    this.isSelf = false,
    this.isBot = false,
  });

  final String identity;
  final String name;
  final String itemId;
  final String text;
  final bool isFinal;
  final int seq;

  /// 本机自己说的话(本地直接插入;界面上名字显示「我」)。
  final bool isSelf;

  /// 机器人(服务器代发)的字幕;[name] 是机器人名。
  final bool isBot;

  CaptionLine copyWith({String? text, bool? isFinal, int? seq, String? name}) =>
      CaptionLine(
        identity: identity,
        name: name ?? this.name,
        itemId: itemId,
        text: text ?? this.text,
        isFinal: isFinal ?? this.isFinal,
        seq: seq ?? this.seq,
        isSelf: isSelf,
        isBot: isBot,
      );
}

class CaptionController extends ChangeNotifier {
  CaptionController({
    required CaptionTranscriberFactory transcriberFactory,
    String Function(String identity)? nameOf,
    this.onLog,
    this.firstFrameTimeout = const Duration(seconds: 2),
    this.partialInterval = kCaptionPartialInterval,
    DateTime Function()? now,
    this.onOwnFinal,
  })  : _factory = transcriberFactory,
        _now = now ?? DateTime.now,
        _nameOf = nameOf ?? ((id) => id);

  final CaptionTranscriberFactory _factory;
  String Function(String identity) _nameOf;
  final void Function(String message)? onLog;
  final Duration firstFrameTimeout;
  final Duration partialInterval;
  final DateTime Function() _now;

  /// 本人的一句**定稿**(只在定稿时调用,partial 永不进来;语气词定稿不进来)。
  /// [startedAt] = 这句话第一次被识别到的时刻。胶水层据此归档(转写记录)。
  void Function(String id, String text, DateTime startedAt)? onOwnFinal;

  // ── 会话绑定 ────────────────────────────────────────────────────────────
  RoomDataChannel? _channel;
  LocalAudioTap? _tap;
  final List<StreamSubscription<Object?>> _subs = [];

  CaptionConditions _cond = const CaptionConditions();
  CaptionConditions get conditions => _cond;

  // ── 看字幕 ──────────────────────────────────────────────────────────────
  bool _want = false;

  /// 本机是否打开了字幕(只看这个决定显示与否)。
  bool get wantCaptions => _want;

  final List<CaptionLine> _lines = <CaptionLine>[];
  List<CaptionLine> get lines => List.unmodifiable(_lines);

  /// identity -> 对方 capack 的 on。
  final Map<String, bool> _acks = <String, bool>{};

  /// 发过 cap 的人。
  final Set<String> _sentCap = <String>{};

  // ── 供字幕 ──────────────────────────────────────────────────────────────
  /// 需要字幕的远端 identity。
  final Set<String> _requesters = <String>{};
  Set<String> get requesters => Set.unmodifiable(_requesters);

  /// 用户点了横幅:本次在房期间不再替别人转写。
  bool _stoppedForSession = false;
  bool get stoppedForSession => _stoppedForSession;

  /// 服务端说不可恢复(没配 / E2EE 未同意……),本次会话不再尝试。
  String? _fatal;
  String? get fatalReason => _fatal;

  /// 抽头看门狗判定麦克风轨道不出帧;等下一次轨道变化再试。
  bool _tapFailed = false;
  bool get tapFailed => _tapFailed;

  CaptionTranscriber? _stt;
  RendererWatchdog? _watchdog;

  /// 上一个识别器的 stop+dispose 还没完成:新会话必须等它(一机一连接)。
  Future<void>? _stopping;
  bool _restartQueued = false;

  /// 已创建、尚未 dispose 完成的识别器数量(结构性保证 ≤ 1)。
  int _live = 0;
  int _maxLive = 0;

  /// 此刻活着(含正在关闭)的识别器数。
  @visibleForTesting
  int get liveTranscribers => _live;

  /// 自创建以来同时活着的识别器数的峰值 —— 必须永远 ≤ 1。
  @visibleForTesting
  int get maxConcurrentTranscribers => _maxLive;

  /// 本人每句话第一次出现的时刻(item_id -> 时刻),定稿时取作 startedAt。
  final Map<String, DateTime> _startedAt = <String, DateTime>{};

  int _seq = 0;
  DateTime? _lastPartialAt;
  Timer? _partialTimer;
  ({String id, String text})? _pendingPartial;

  /// 已定稿的 item_id(防止定稿之后迟到的 partial 覆盖)。
  final Set<String> _finalizedIds = <String>{};

  /// 最近广播出去的 capack(避免重复发)。
  bool? _lastAckSent;

  bool _disposed = false;

  /// 此刻是否正在把自己的声音送去云端识别(横幅据此显示)。
  bool get transcribing => _stt != null;

  /// 横幅上的「为 X」:需要字幕的人的名字。
  List<String> get requesterNames =>
      _requesters.map(_nameOf).toList(growable: false);

  /// 本圈开着转写记录(且我在房):全员可见的常驻提示。
  bool get archiveOn => _cond.archive && _cond.inRoom;

  /// 本机此刻是否愿意被转写(设置允许、没点过停止、没有不可恢复错误)。
  bool get willingNow => _willingNow;

  /// 明确表示不愿被转写的远端(capack on:false)—— 转写记录开着时标「未转写」。
  List<String> get declinedNames {
    final Set<String> remote = _channel?.remoteIdentities ?? const {};
    return remote
        .where((id) => _acks[id] == false)
        .map(_nameOf)
        .toList(growable: false);
  }

  /// 某位远端是否明说不被转写(给成员卡片等处用)。
  bool isDeclined(String identity) => _acks[identity] == false;

  /// 正在给我提供字幕的人(capack on 或已发过字幕)。
  List<String> get providerNames {
    final Set<String> remote = _channel?.remoteIdentities ?? const {};
    return remote
        .where((id) => _acks[id] == true || _sentCap.contains(id))
        .map(_nameOf)
        .toList(growable: false);
  }

  /// 开着麦、却没给我任何字幕信号(或明说不提供)的人 —— 面板上提示「X 未开启字幕」。
  List<String> get notProvidingNames {
    if (!_want) return const [];
    final RoomDataChannel? ch = _channel;
    if (ch == null) return const [];
    return ch.remoteIdentities
        .where((id) =>
            ch.isRemoteMicOn(id) &&
            _acks[id] != true &&
            !_sentCap.contains(id))
        .map(_nameOf)
        .toList(growable: false);
  }

  set nameOf(String Function(String identity) f) {
    _nameOf = f;
    // 名字可能变了:已有行重新取名
    for (int i = 0; i < _lines.length; i++) {
      // 机器人名来自帧本身;自己的行由界面显示「我」
      if (_lines[i].isBot || _lines[i].isSelf) continue;
      _lines[i] = _lines[i].copyWith(name: f(_lines[i].identity));
    }
    _notify();
  }

  // ── 生命周期 ────────────────────────────────────────────────────────────

  /// 进入(或换了一个)房间会话。旧会话的一切状态作废。
  void bindSession(RoomDataChannel channel, LocalAudioTap tap) {
    if (_disposed) return;
    if (identical(channel, _channel) && identical(tap, _tap)) return;
    _unbindInternal();
    _channel = channel;
    _tap = tap;
    _subs
      ..add(channel.inbound.listen(_onData))
      ..add(channel.participantJoined.listen(_onJoined))
      ..add(channel.participantLeft.listen(_onLeft))
      ..add(channel.remoteMicChanged.listen((_) => _notify()))
      ..add(tap.trackChanges.listen((_) => _onTrackChanged()));
    if (_want) unawaited(_publish(const CapReq(true)));
    _reevaluate();
    _notify();
  }

  /// 离开房间会话(媒体断开 / 退房)。
  void unbindSession() {
    _unbindInternal();
    _notify();
  }

  /// 彻底离开这个圈子:连「本次不再转写」也一起重置。
  void resetRoomSession() {
    _stoppedForSession = false;
    _fatal = null;
    _lines.clear();
    _notify();
  }

  /// 掉线恢复后重新进房:服务端的「不可恢复」判断(如恢复途中的 not_in_room)
  /// 值得再试一次;但用户点过的「本次停止」保持不变。
  void clearFatal() {
    if (_fatal == null) return;
    _fatal = null;
    _broadcastAckIfChanged();
    _reevaluate();
    _notify();
  }

  void _unbindInternal() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    _channel = null;
    _tap = null;
    _requesters.clear();
    _acks.clear();
    _sentCap.clear();
    _lastAckSent = null;
    _tapFailed = false;
    unawaited(_stopTranscribing());
  }

  void updateConditions(CaptionConditions c) {
    if (c == _cond) return;
    final bool willingBefore = _cond.willing;
    final bool archiveBefore = _cond.archive && _cond.inRoom;
    _cond = c;
    if (!c.inRoom) {
      // 出房:不显示任何残留
      _lines.clear();
    }
    final bool archiveNow = c.archive && c.inRoom;
    if (archiveNow && !archiveBefore) {
      // 转写记录刚打开(或刚进房):让所有人知道我转不转
      _broadcastAckIfChanged(force: true);
    } else if (c.willing != willingBefore) {
      _broadcastAckIfChanged();
    }
    _reevaluate();
    _notify();
  }

  // ── 看字幕 ──────────────────────────────────────────────────────────────

  Future<void> setWantCaptions(bool on) async {
    if (_want == on) return;
    _want = on;
    if (!on) _lines.clear();
    // 我自己开着字幕也算「有人需要」:自己的话也转写(本地显示)
    _reevaluate();
    _notify();
    await _publish(CapReq(on));
  }

  Future<void> toggleWantCaptions() => setWantCaptions(!_want);

  void _onJoined(String identity) {
    // 后来的人不知道我要字幕:单独告诉他
    if (_want) unawaited(_publish(const CapReq(true), to: [identity]));
    // 转写记录开着:告诉他我转不转(他据此显示「未转写」)
    if (_cond.archive && _cond.inRoom) {
      unawaited(_publish(CapAck(_willingNow), to: [identity]));
    }
    _notify();
  }

  void _onLeft(String identity) {
    _acks.remove(identity);
    _sentCap.remove(identity);
    final bool wasRequester = _requesters.remove(identity);
    if (wasRequester) _reevaluate();
    _notify();
  }

  void _onData(RoomDataFrame f) {
    // 归属规则(含机器人帧防伪造)在纯函数里,见 attributeCaptionFrame
    final CaptionAttribution? a = attributeCaptionFrame(
      sender: f.senderIdentity,
      bytes: f.bytes,
      localIdentity: _channel?.localIdentity,
    );
    if (a == null) return;
    final String from = a.identity;
    final CaptionMessage m = a.message;
    if (a.isBot) {
      if (m is Cap && _want) {
        _applyCaption(from, m, name: a.botName, isBot: true);
        _notify();
      }
      return;
    }
    switch (m) {
      case CapReq(:final on):
        final bool changed =
            on ? _requesters.add(from) : _requesters.remove(from);
        if (on) {
          // 回应:我会不会替你转写
          unawaited(_publish(CapAck(_willingNow), to: [from]));
        }
        if (changed) _reevaluate();
        _notify();
      case CapAck(:final on):
        _acks[from] = on;
        _notify();
      case Cap():
        _sentCap.add(from);
        if (_want) _applyCaption(from, m);
        _notify();
    }
  }

  void _applyCaption(
    String identity,
    Cap c, {
    String? name,
    bool isSelf = false,
    bool isBot = false,
  }) {
    final int idx =
        _lines.indexWhere((l) => l.identity == identity && l.itemId == c.id);
    if (idx >= 0) {
      final CaptionLine old = _lines[idx];
      // 乱序保护:更旧的序号、或定稿后的 partial,一律不覆盖
      if (c.seq <= old.seq || (old.isFinal && !c.isFinal)) return;
      if (c.isFinal && c.text.trim().isEmpty) {
        _lines.removeAt(idx); // 发送方判定为语气词,撤回
        return;
      }
      _lines[idx] = old.copyWith(text: c.text, isFinal: c.isFinal, seq: c.seq);
      return;
    }
    if (c.text.trim().isEmpty) return;
    _lines.add(CaptionLine(
      identity: identity,
      name: name ?? _nameOf(identity),
      itemId: c.id,
      text: c.text,
      isFinal: c.isFinal,
      seq: c.seq,
      isSelf: isSelf,
      isBot: isBot,
    ));
    while (_lines.length > kCaptionMaxLines) {
      _lines.removeAt(0);
    }
  }

  // ── 供字幕 ──────────────────────────────────────────────────────────────

  bool get _willingNow => _cond.willing && !_stoppedForSession && _fatal == null;

  /// 告诉别人「我愿不愿意被转写」。转写记录开着时广播给所有人(大家都要知道
  /// 谁「未转写」);否则只告诉请求者。[force] = 即使没变也再发一次。
  void _broadcastAckIfChanged({bool force = false}) {
    final bool now = _willingNow;
    if (!force && _lastAckSent == now) return;
    _lastAckSent = now;
    if (_cond.archive && _cond.inRoom) {
      unawaited(_publish(CapAck(now)));
      return;
    }
    if (_requesters.isEmpty) return;
    unawaited(_publish(CapAck(now), to: _requesters.toList()));
  }

  /// 用户点了横幅:本次在房期间不再转写我的话(不为别人生成字幕、也不进转写记录)。
  void stopForSession() {
    _stoppedForSession = true;
    _broadcastAckIfChanged();
    _reevaluate();
    _notify();
  }

  /// 有没有人需要我的话:远端请求者、我自己开着字幕、或圈子开着转写记录。
  bool get _needed => _requesters.isNotEmpty || _want || _cond.archive;

  bool get _shouldTranscribe =>
      _channel != null &&
      _tap != null &&
      _cond.inRoom &&
      !_cond.muted &&
      _willingNow &&
      _needed &&
      !_tapFailed &&
      (_tap?.micPublishedAndUnmuted ?? false);

  void _reevaluate() {
    if (_disposed) return;
    if (_shouldTranscribe) {
      if (_stt != null) return;
      if (_stopping != null) {
        // 上一个识别器还没关干净:等它关完再开(一机永远只有一个连接)
        _restartQueued = true;
        return;
      }
      _startTranscribing();
    } else if (_stt != null) {
      unawaited(_stopTranscribing());
    }
  }

  void _onTrackChanged() {
    // 轨道可能换了:旧抽头已静默失效。给看门狗一次新机会。
    _tapFailed = false;
    if (_stt != null) {
      if (_tap?.micPublishedAndUnmuted ?? false) {
        _attachTap();
      } else {
        unawaited(_stopTranscribing());
      }
    } else {
      _reevaluate();
    }
    _notify();
  }

  void _startTranscribing() {
    assert(_stt == null && _stopping == null);
    _log('开始转写(请求者 ${_requesters.length} 人'
        '${_want ? ' + 我' : ''}${_cond.archive ? ' + 转写记录' : ''})');
    final CaptionTranscriber stt = _factory(
      onPartial: _onLocalPartial,
      onFinal: _onLocalFinal,
      onFatal: (reason) {
        if (_disposed) return;
        _log('字幕不可用: $reason');
        _fatal = reason;
        _broadcastAckIfChanged();
        _reevaluate();
        _notify();
      },
    );
    _live++;
    if (_live > _maxLive) _maxLive = _live;
    _stt = stt;
    stt.start();
    _attachTap();
    _notify();
  }

  void _attachTap() {
    _detachTap();
    final LocalAudioTap? tap = _tap;
    if (tap == null) return;
    late final RendererWatchdog wd;
    wd = RendererWatchdog(
      identity: 'local-mic',
      firstFrameTimeout: firstFrameTimeout,
      maxAttempts: 2,
      retryBackoff: Duration.zero,
      onLog: (m) => _log(m),
      onHealth: (h, attempts) {
        if (h == RendererHealth.failed && identical(_watchdog, wd)) {
          _log('本地麦克风 $attempts 次注册都没有出帧,停止转写');
          _tapFailed = true;
          unawaited(_stopTranscribing());
          _notify();
        }
      },
      attach: (attempt) {
        final LocalAudioTapCancel? c = tap.attach((Uint8List pcm) {
          wd.noteFrame();
          _stt?.addPcm(pcm);
        });
        return c == null ? null : () => c();
      },
    );
    _watchdog = wd;
    wd.start();
  }

  void _detachTap() {
    final RendererWatchdog? wd = _watchdog;
    _watchdog = null;
    if (wd != null) unawaited(wd.dispose());
  }

  Future<void> _stopTranscribing() {
    final CaptionTranscriber? stt = _stt;
    if (stt == null) return _stopping ?? Future<void>.value();
    _stt = null;
    _detachTap();
    _log('停止转写');
    _notify();
    late final Future<void> f;
    f = _closeTranscriber(stt).whenComplete(() {
      _live--;
      if (identical(_stopping, f)) _stopping = null;
      _flushPendingPartial(send: false);
      if (_restartQueued) {
        _restartQueued = false;
        _reevaluate();
        _notify();
      }
    });
    _stopping = f;
    return f;
  }

  Future<void> _closeTranscriber(CaptionTranscriber stt) async {
    // 定稿会在 stop 期间到达:仍然发出去(_onLocalFinal 不依赖 _stt)
    try {
      await stt.stop();
    } on Object catch (e) {
      _log('识别器 stop 出错: $e');
    }
    try {
      await stt.dispose();
    } on Object catch (e) {
      _log('识别器 dispose 出错: $e');
    }
  }

  void _onLocalPartial(String id, String text) {
    if (_finalizedIds.contains(id)) return;
    final DateTime now = _now();
    _startedAt.putIfAbsent(id, () => now);
    final DateTime? last = _lastPartialAt;
    if (last == null || now.difference(last) >= partialInterval) {
      _pendingPartial = null;
      _partialTimer?.cancel();
      _partialTimer = null;
      _lastPartialAt = now;
      _sendCap(id, text, isFinal: false);
      return;
    }
    // 节流窗口内:只留最新一条,窗口结束时发
    _pendingPartial = (id: id, text: text);
    _partialTimer ??= Timer(partialInterval - now.difference(last), () {
      _partialTimer = null;
      _flushPendingPartial(send: true);
    });
  }

  void _flushPendingPartial({required bool send}) {
    final p = _pendingPartial;
    _pendingPartial = null;
    if (!send) {
      _partialTimer?.cancel();
      _partialTimer = null;
    }
    if (p == null || !send || _finalizedIds.contains(p.id)) return;
    _lastPartialAt = _now();
    _sendCap(p.id, p.text, isFinal: false);
  }

  void _onLocalFinal(String id, String text) {
    if (_pendingPartial?.id == id) {
      _pendingPartial = null;
      _partialTimer?.cancel();
      _partialTimer = null;
    }
    if (_finalizedIds.contains(id)) return; // 重复定稿
    _finalizedIds.add(id);
    if (_finalizedIds.length > 200) _finalizedIds.remove(_finalizedIds.first);
    final DateTime startedAt = _startedAt.remove(id) ?? _now();
    if (_startedAt.length > 200) _startedAt.remove(_startedAt.keys.first);
    final bool filler = isFillerOnly(text);
    // 语气词定稿:发一条空定稿,让对端把已显示的 partial 撤掉
    _sendCap(id, filler ? '' : text.trim(), isFinal: true);
    // 关识别器期间仍可能到达定稿:用户已关「提供字幕」或点了停止,就绝不再进记录
    if (!filler && _willingNow) {
      try {
        onOwnFinal?.call(id, text.trim(), startedAt);
      } on Object catch (e) {
        _log('定稿出口出错(不影响字幕): $e');
      }
    }
  }

  /// 发一条本人字幕:我开着字幕就本地插入(标「我」,不靠回环);
  /// 有远端请求者就**广播**出去(不带 destinationIdentities,契约 §1)。
  void _sendCap(String id, String text, {required bool isFinal}) {
    _seq++;
    final Cap c = Cap(id: id, seq: _seq, text: text, isFinal: isFinal);
    if (_want) {
      _applyCaption(_selfIdentity, c, name: '', isSelf: true);
      _notify();
    }
    if (_requesters.isEmpty) return;
    unawaited(_publish(c));
  }

  String get _selfIdentity => _channel?.localIdentity ?? '';

  Future<void> _publish(CaptionMessage m, {List<String>? to}) async {
    final RoomDataChannel? ch = _channel;
    if (ch == null) return;
    if (to != null && to.isEmpty) return;
    try {
      await ch.publish(m.encode(), to: to);
    } on Object catch (e) {
      _log('发送字幕消息失败(不影响语音): $e');
    }
  }

  void _log(String m) => onLog?.call('[captions] $m');

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _partialTimer?.cancel();
    _unbindInternal();
    super.dispose();
  }
}
