/// LiveKit 实现:把一个 [Room] 适配成字幕需要的 [LocalAudioTap] + [RoomDataChannel]。
///
/// 会话级:绑定一个 Room,Room 被 dispose(退房 / 闲时降级)后必须换新实例。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:livekit_client/livekit_client.dart';

import '../rtc/rtc_service.dart';
import 'caption_protocol.dart';

/// 16 kHz 单声道 Int16:与识别服务要求一致。必须显式写 16000(SDK 默认 24000)。
const AudioRendererOptions kCaptionRendererOptions = AudioRendererOptions(
  sampleRate: 16000,
  channels: 1,
  format: AudioFormat.Int16,
);

class LiveKitCaptionSession implements LocalAudioTap, RoomDataChannel {
  LiveKitCaptionSession(this._room) {
    _listener = _room.createListener()
      ..on<DataReceivedEvent>(_onData)
      ..on<ParticipantConnectedEvent>(
          (e) => _joined.add(e.participant.identity))
      ..on<ParticipantDisconnectedEvent>(
          (e) => _left.add(e.participant.identity))
      ..on<TrackMutedEvent>((e) => _onMuteChange(e.participant))
      ..on<TrackUnmutedEvent>((e) => _onMuteChange(e.participant))
      ..on<TrackPublishedEvent>((_) => _remoteMic.add(null))
      ..on<TrackUnpublishedEvent>((_) => _remoteMic.add(null))
      // 本地轨道被换掉的所有路径:首次发布、取消发布、重连(ICE 重启可能重建发送端)
      ..on<LocalTrackPublishedEvent>((_) => _trackChanges.add(null))
      ..on<LocalTrackUnpublishedEvent>((_) => _trackChanges.add(null))
      ..on<RoomReconnectedEvent>((_) => _trackChanges.add(null));
  }

  final Room _room;
  late final EventsListener<RoomEvent> _listener;

  final StreamController<RoomDataFrame> _inbound =
      StreamController<RoomDataFrame>.broadcast();
  final StreamController<String> _joined = StreamController<String>.broadcast();
  final StreamController<String> _left = StreamController<String>.broadcast();
  final StreamController<void> _trackChanges =
      StreamController<void>.broadcast();
  final StreamController<void> _remoteMic = StreamController<void>.broadcast();
  bool _disposed = false;

  Room get room => _room;

  void _onMuteChange(Participant p) {
    if (p is LocalParticipant) {
      // unmute 走 restartTrack:底层 MediaStreamTrack 已换,旧渲染器哑了
      _trackChanges.add(null);
    } else {
      _remoteMic.add(null);
    }
  }

  void _onData(DataReceivedEvent e) {
    if (_disposed) return;
    // SDK 实际给的是空串而非 null
    if ((e.topic ?? '') != kCaptionTopic) return;
    final String identity = e.participant?.identity ?? '';
    if (identity.isEmpty) return;
    _inbound.add(RoomDataFrame(
      senderIdentity: identity,
      bytes: Uint8List.fromList(e.data),
    ));
  }

  // ── LocalAudioTap ───────────────────────────────────────────────────────

  LocalAudioTrack? get _micTrack {
    final LocalTrackPublication? pub = _room.localParticipant
        ?.getTrackPublicationBySource(TrackSource.microphone);
    final Track? t = pub?.track;
    return t is LocalAudioTrack ? t : null;
  }

  @override
  bool get micPublishedAndUnmuted {
    final LocalTrackPublication? pub = _room.localParticipant
        ?.getTrackPublicationBySource(TrackSource.microphone);
    return pub != null && !pub.muted && pub.track != null;
  }

  @override
  LocalAudioTapCancel? attach(void Function(Uint8List pcm16) onFrame) {
    final LocalAudioTrack? track = _micTrack;
    if (track == null) return null;
    final CancelListenFunc cancel = track.addAudioRenderer(
      options: kCaptionRendererOptions,
      onFrame: (AudioFrame f) {
        if (f.format != AudioFormat.Int16 || f.sampleRate != 16000) return;
        onFrame(f.channels == 1 ? f.data : _firstChannel(f.data, f.channels));
      },
    );
    return () => cancel();
  }

  static Uint8List _firstChannel(Uint8List data, int channels) {
    final int frames = data.length ~/ (2 * channels);
    final Uint8List out = Uint8List(frames * 2);
    for (int i = 0; i < frames; i++) {
      out[2 * i] = data[2 * i * channels];
      out[2 * i + 1] = data[2 * i * channels + 1];
    }
    return out;
  }

  @override
  Stream<void> get trackChanges => _trackChanges.stream;

  // ── RoomDataChannel ─────────────────────────────────────────────────────

  @override
  String? get localIdentity => _room.localParticipant?.identity;

  @override
  Set<String> get remoteIdentities =>
      _room.remoteParticipants.values.map((p) => p.identity).toSet();

  @override
  bool isRemoteMicOn(String identity) {
    for (final RemoteParticipant p in _room.remoteParticipants.values) {
      if (p.identity == identity) return p.isMicrophoneEnabled();
    }
    return false;
  }

  @override
  Stream<void> get remoteMicChanged => _remoteMic.stream;

  @override
  Stream<RoomDataFrame> get inbound => _inbound.stream;

  @override
  Stream<String> get participantJoined => _joined.stream;

  @override
  Stream<String> get participantLeft => _left.stream;

  @override
  Future<void> publish(Uint8List data, {List<String>? to}) async {
    final LocalParticipant? lp = _room.localParticipant;
    if (lp == null || _disposed) return;
    // reliable 无默认值,不传即 LOSSY
    await lp.publishData(
      data,
      reliable: true,
      topic: kCaptionTopic,
      destinationIdentities: to,
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _listener.dispose();
    await _inbound.close();
    await _joined.close();
    await _left.close();
    await _trackChanges.close();
    await _remoteMic.close();
  }
}
