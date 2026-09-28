/// 实时字幕的业务核心(纯 Dart,不碰 LiveKit / 网络,全部依赖可注入)。
///
/// 两个方向:
/// - **看字幕**:本机打开「字幕」→ 广播 `capreq{on:true}`(新人进房时单独补发),
///   收到的 `cap` 按发送者 identity 归属、按 item_id 原地替换,面板只留最近 30 行。
/// - **供字幕**:房里至少有一位**远端**需要字幕的人,且本机在房、开着麦、
///   麦克风轨道真的在出帧、设置允许(E2EE 圈还要单独同意)时,才把**自己的**
///   麦克风送去云端识别,识别结果只发给需要的人。任何条件不再满足立即停、关连接。
///
/// 什么都不落盘:字幕只存在内存里,退房即清。
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
  });

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
      other.e2eeCloud == e2eeCloud;

  @override
  int get hashCode =>
      Object.hash(available, inRoom, muted, provide, encrypted, e2eeCloud);
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
  });

  final String identity;
  final String name;
  final String itemId;
  final String text;
  final bool isFinal;
  final int seq;

  CaptionLine copyWith({String? text, bool? isFinal, int? seq, String? name}) =>
      CaptionLine(
        identity: identity,
        name: name ?? this.name,
        itemId: itemId,
        text: text ?? this.text,
        isFinal: isFinal ?? this.isFinal,
        seq: seq ?? this.seq,
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
  })  : _factory = transcriberFactory,
        _now = now ?? DateTime.now,
        _nameOf = nameOf ?? ((id) => id);

  final CaptionTranscriberFactory _factory;
  String Function(String identity) _nameOf;
  final void Function(String message)? onLog;
  final Duration firstFrameTimeout;
  final Duration partialInterval;
  final DateTime Function() _now;

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
    _cond = c;
    if (!c.inRoom) {
      // 出房:不显示任何残留
      _lines.clear();
    }
    if (c.willing != willingBefore) _broadcastAckIfChanged();
    _reevaluate();
    _notify();
  }

  // ── 看字幕 ──────────────────────────────────────────────────────────────

  Future<void> setWantCaptions(bool on) async {
    if (_want == on) return;
    _want = on;
    if (!on) _lines.clear();
    _notify();
    await _publish(CapReq(on));
  }

  Future<void> toggleWantCaptions() => setWantCaptions(!_want);

  void _onJoined(String identity) {
    // 后来的人不知道我要字幕:单独告诉他
    if (_want) unawaited(_publish(const CapReq(true), to: [identity]));
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
    final String? me = _channel?.localIdentity;
    if (f.senderIdentity.isEmpty || f.senderIdentity == me) return;
    final CaptionMessage? m = CaptionMessage.decode(f.bytes);
    switch (m) {
      case null:
        return;
      case CapReq(:final on):
        final bool changed = on
            ? _requesters.add(f.senderIdentity)
            : _requesters.remove(f.senderIdentity);
        if (on) {
          // 回应:我会不会替你转写
          unawaited(_publish(CapAck(_willingNow), to: [f.senderIdentity]));
        }
        if (changed) _reevaluate();
        _notify();
      case CapAck(:final on):
        _acks[f.senderIdentity] = on;
        _notify();
      case Cap():
        _sentCap.add(f.senderIdentity);
        if (_want) _applyCaption(f.senderIdentity, m);
        _notify();
    }
  }

  void _applyCaption(String identity, Cap c) {
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
      name: _nameOf(identity),
      itemId: c.id,
      text: c.text,
      isFinal: c.isFinal,
      seq: c.seq,
    ));
    while (_lines.length > kCaptionMaxLines) {
      _lines.removeAt(0);
    }
  }

  // ── 供字幕 ──────────────────────────────────────────────────────────────

  bool get _willingNow => _cond.willing && !_stoppedForSession && _fatal == null;

  void _broadcastAckIfChanged() {
    final bool now = _willingNow;
    if (_lastAckSent == now) return;
    _lastAckSent = now;
    if (_requesters.isEmpty) return;
    unawaited(_publish(CapAck(now), to: _requesters.toList()));
  }

  /// 用户点了横幅:本次在房期间不再替别人转写。
  void stopForSession() {
    _stoppedForSession = true;
    _broadcastAckIfChanged();
    _reevaluate();
    _notify();
  }

  bool get _shouldTranscribe =>
      _channel != null &&
      _tap != null &&
      _cond.inRoom &&
      !_cond.muted &&
      _willingNow &&
      _requesters.isNotEmpty &&
      !_tapFailed &&
      (_tap?.micPublishedAndUnmuted ?? false);

  void _reevaluate() {
    if (_disposed) return;
    if (_shouldTranscribe) {
      if (_stt == null) _startTranscribing();
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
    _log('开始为 ${_requesters.length} 人转写');
    final CaptionTranscriber stt = _factory(
      onPartial: _onLocalPartial,
      onFinal: _onLocalFinal,
      onFatal: (reason) {
        _log('字幕不可用: $reason');
        _fatal = reason;
        _broadcastAckIfChanged();
        _reevaluate();
        _notify();
      },
    );
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

  Future<void> _stopTranscribing() async {
    final CaptionTranscriber? stt = _stt;
    if (stt == null) return;
    _stt = null;
    _detachTap();
    _log('停止转写');
    _notify();
    // 定稿会在 stop 期间到达:仍然发出去(_onLocalFinal 不依赖 _stt)
    await stt.stop();
    await stt.dispose();
    _flushPendingPartial(send: false);
  }

  void _onLocalPartial(String id, String text) {
    if (_finalizedIds.contains(id)) return;
    final DateTime now = _now();
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
    _finalizedIds.add(id);
    if (_finalizedIds.length > 200) _finalizedIds.remove(_finalizedIds.first);
    // 语气词定稿:发一条空定稿,让对端把已显示的 partial 撤掉
    _sendCap(id, isFillerOnly(text) ? '' : text.trim(), isFinal: true);
  }

  void _sendCap(String id, String text, {required bool isFinal}) {
    if (_requesters.isEmpty) return;
    _seq++;
    unawaited(_publish(
      Cap(id: id, seq: _seq, text: text, isFinal: isFinal),
      to: _requesters.toList(),
    ));
  }

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
