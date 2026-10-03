/// 字幕胶水层:把 [CaptionController] 接到 RoomController / 设置 / E2EE / LiveKit / 信令上。
///
/// 纯转发,不含业务规则 —— 规则全在 CaptionController 里,那边有单测。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../e2ee/e2ee_controller.dart';
import '../e2ee/e2ee_status.dart';
import '../rtc/livekit_rtc_service.dart';
import '../state/circle_features.dart';
import '../state/models.dart';
import '../state/room_controller.dart';
import '../state/settings_store.dart';
import 'caption_controller.dart';
import 'livekit_caption_session.dart';
import 'qwen_realtime_stt.dart';
import 'stt_socket.dart';
import 'transcript_sink.dart';

/// 通过信令向服务器要一张 DashScope 临时 token(cap_token)。
///
/// 有缓存:未过期(留 60 s 余量)且不要求 fresh 时复用。
class SignalingCaptionTokenSource {
  SignalingCaptionTokenSource({
    required this.send,
    required this.messages,
    required this.e2eeOptIn,
    this.timeout = const Duration(seconds: 12),
  });

  final void Function(Map<String, dynamic> msg) send;
  final Stream<Map<String, dynamic>> messages;

  /// 当前圈子加密且用户同意云端识别时为 true(服务器会校验)。
  final bool Function() e2eeOptIn;
  final Duration timeout;

  CaptionToken? _cached;
  Future<CaptionToken>? _inFlight;

  Future<CaptionToken> call({bool fresh = false}) {
    final CaptionToken? c = _cached;
    if (!fresh &&
        c != null &&
        c.expiresAt - DateTime.now().millisecondsSinceEpoch > 60000) {
      return Future.value(c);
    }
    final Future<CaptionToken>? cur = _inFlight;
    if (cur != null) return cur;
    late final Future<CaptionToken> f;
    f = _mint(_epoch).whenComplete(() {
      if (identical(_inFlight, f)) _inFlight = null;
    });
    return _inFlight = f;
  }

  /// [clear] 后,旧会话里还在路上的签发作废(不进缓存,也不交给新会话)。
  int _epoch = 0;

  Future<CaptionToken> _mint(int epoch) async {
    final Future<Map<String, dynamic>> reply = messages
        .firstWhere((m) => m['t'] == 'cap_token' || m['t'] == 'cap_error')
        .timeout(timeout);
    send({'t': 'cap_token', if (e2eeOptIn()) 'e2eeOptIn': true});
    final Map<String, dynamic> m;
    try {
      m = await reply;
    } on TimeoutException {
      throw CaptionTokenException('timeout');
    } on StateError {
      throw CaptionTokenException('offline');
    }
    if (m['t'] == 'cap_error') {
      throw CaptionTokenException(m['reason'] as String? ?? 'unknown');
    }
    final String? token = m['token'] as String?;
    final String? url = m['url'] as String?;
    if (token == null || token.isEmpty || url == null || url.isEmpty) {
      throw CaptionTokenException('bad_reply');
    }
    final CaptionToken t = CaptionToken(
      token: token,
      expiresAt: (m['expiresAt'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch + 300000,
      url: url,
      model: m['model'] as String? ?? 'qwen3-asr-flash-realtime',
    );
    if (epoch != _epoch) throw CaptionTokenException('stale');
    _cached = t;
    return t;
  }

  void clear() {
    _cached = null;
    _inFlight = null;
    _epoch++;
  }
}

/// 生产用的识别器工厂。
CaptionTranscriberFactory qwenTranscriberFactory(
  CaptionTokenSource tokens, {
  void Function(String)? onLog,
}) =>
    ({required onPartial, required onFinal, required onFatal}) =>
        _QwenTranscriber(QwenRealtimeStt(
          tokenSource: tokens,
          onPartial: onPartial,
          onFinal: onFinal,
          onFatal: onFatal,
          onLog: onLog,
        ));

class _QwenTranscriber implements CaptionTranscriber {
  _QwenTranscriber(this._s);
  final QwenRealtimeStt _s;
  @override
  void start() => _s.start();
  @override
  void addPcm(Uint8List pcm) => _s.addPcm(pcm);
  @override
  Future<void> stop() => _s.stop();
  @override
  Future<void> dispose() => _s.dispose();
}

/// 跟着房间生命周期绑定 / 解绑 LiveKit 会话,并把条件同步进 [CaptionController]。
class CaptionWiring {
  CaptionWiring({
    required this.captions,
    required this.controller,
    required this.rtc,
    required this.settings,
    this.e2ee,
    this.onTokenSourceReset,
    this.transcriptSink,
  }) {
    final TranscriptSink? sink = transcriptSink;
    if (sink != null) {
      captions.onOwnFinal = ownFinalHandler(
        circleId: () => controller.circleId,
        archiveOn: controller.isTranscriptOn,
        sink: sink,
      );
    }
    controller.addListener(_sync);
    settings.addListener(_sync);
    e2ee?.addListener(_sync);
    _sync();
  }

  final CaptionController captions;
  final RoomController controller;
  final LiveKitRtcService rtc;
  final SettingsStore settings;
  final E2EEController? e2ee;
  final VoidCallback? onTokenSourceReset;

  /// 转写记录出口(通常是 [RoutingTranscriptSink]:非加密走信令
  /// `transcript_append`,加密走 transcript 模块注入的加密实现)。
  final TranscriptSink? transcriptSink;

  /// 本人定稿 → 转写记录。只在当前圈子开着转写记录时才交给 [sink]。
  static void Function(String id, String text, DateTime startedAt)
      ownFinalHandler({
    required String? Function() circleId,
    required bool Function(String circleId) archiveOn,
    required TranscriptSink sink,
  }) =>
          (id, text, startedAt) {
            final String? c = circleId();
            if (c == null || c.isEmpty || !archiveOn(c)) return;
            if (text.trim().isEmpty) return;
            sink.appendFinal(
                circleId: c, id: id, text: text, startedAt: startedAt);
          };

  LiveKitCaptionSession? _session;
  String? _lastCircle;
  bool _wasInRoom = false;
  bool _disposed = false;

  bool get _encrypted =>
      e2ee?.statusForActiveCircle(controller.circleId)?.isEncrypted ??
      (controller.circleInfo[controller.circleId]?.e2ee ?? false);

  /// 「本次会话」的圈子:真正退房(idle)才算结束。
  /// 掉线自动恢复(inRoom → joining → inRoom)仍是同一次会话 —— 否则用户点过
  /// 「停止」后,一次信令 / 媒体抖动就会把它清掉,语音又悄悄开始出本机。
  static String? sessionCircle(RoomPhase phase, String? circleId) =>
      phase == RoomPhase.idle ? null : circleId;

  void _sync() {
    if (_disposed) return;
    final bool inRoom = controller.phase == RoomPhase.inRoom;

    final String? circle = sessionCircle(controller.phase, controller.circleId);
    if (circle != _lastCircle) {
      if (_lastCircle != null) {
        captions.resetRoomSession();
        onTokenSourceReset?.call();
      }
      _lastCircle = circle;
    } else if (inRoom && !_wasInRoom) {
      captions.clearFatal();
    }
    _wasInRoom = inRoom;

    // 名字映射:LiveKit identity = userId
    final Map<String, String> names = {
      for (final Member m in controller.members) m.userId: m.name,
    };
    captions.nameOf = (id) => names[id] ?? id;

    // Room 对象可能在闲时降级 / 唤醒时被换掉:按对象身份重绑
    final room = inRoom ? rtc.room : null;
    if (room == null) {
      if (_session != null) {
        captions.unbindSession();
        unawaited(_session!.dispose());
        _session = null;
      }
    } else if (!identical(_session?.room, room)) {
      final LiveKitCaptionSession? old = _session;
      final LiveKitCaptionSession s = LiveKitCaptionSession(room);
      _session = s;
      captions.bindSession(s, s);
      if (old != null) unawaited(old.dispose());
    }

    captions.updateConditions(CaptionConditions(
      // 圈主关了「实时字幕」:本机不再替任何人出字幕(服务器 cap_token 也会拒)
      available: controller.captionsAvailable &&
          kSttSocketSupported &&
          (controller.circleId == null ||
              controller.isFeatureOn(
                  controller.circleId!, CircleFeature.captions)),
      inRoom: inRoom && room != null,
      muted: controller.muted,
      provide: settings.captionsProvide,
      encrypted: _encrypted,
      e2eeCloud: settings.captionsE2eeCloud,
      archive: controller.circleId != null &&
          controller.isTranscriptOn(controller.circleId!),
    ));
  }

  void dispose() {
    _disposed = true;
    controller.removeListener(_sync);
    settings.removeListener(_sync);
    e2ee?.removeListener(_sync);
    if (transcriptSink != null) captions.onOwnFinal = null;
    captions.unbindSession();
    unawaited(_session?.dispose());
    _session = null;
  }
}
