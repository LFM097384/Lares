/// LiveKit 与采集核心之间的**薄适配层**。
///
/// 这一层刻意保持愚蠢:它只做「把 SDK 事件翻译成 [CaptureSession] 的调用」
/// 和「管好每条轨的 [RendererWatchdog]」两件事,不做任何音频判断。
/// 所有真正的策略(同意门禁、分说话人切分、格式校验、时钟重锚、磁盘封顶)
/// 都在 `capture_session.dart` 里,那边不依赖 SDK,因而能被纯 VM 测试覆盖;
/// 留在这里的、测不到的部分越少越好 —— 本文件就是那个「越少越好」的残量。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import 'capture_session.dart';
import 'utterance.dart';
import 'vad.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 渲染器参数
// ─────────────────────────────────────────────────────────────────────────────

/// 全局**唯一**的渲染器参数,所有注册都必须复用这一个常量。
///
/// 两件事都写死在这里,各有各的坑:
///
/// 1. **`sampleRate` 必须显式写 16000。** SDK 的默认值是 **24000**,不是 16000
///    也不是 48000。漏写就会拿到 24k 的 PCM,而全链路(VAD 门限、离线 ASR
///    声学模型、落盘格式)都按 16k 设计,[CaptureSession] 会直接把这些帧
///    判成格式不符整轨拒收 —— 症状是「一帧都收不到」,极难反推到这一行。
///
/// 2. **必须是同一个常量实例(或至少是相等的值)。** [AudioRendererOptions]
///    实现了基于 (sampleRate, channels, format) 的 `==`/`hashCode`,而 SDK 用它
///    作为轨道内 `_captureGroups` 的**键**。相等的 options ⇒ 共用同一条原生
///    采集管线;稍有不同 ⇒ 在同一条轨上再开一路原生 sink,白白多一份
///    CPU 与内存,两路还会各自独立地喂帧,字节数直接翻倍。
///
/// 另外记两条原生侧的既定行为,免得后人误以为是 bug:
/// - **没有订阅者时帧是被丢弃而不是排队的**(`livekit_plugin.cpp` 明说
///   "live audio must not be queued while no subscriber is attached"),
///   所以每次注册都注定丢掉最前面几十毫秒。这不可恢复,也不必去恢复。
/// - **`channels: 1` 是截断而不是缩混**(`out_channels = min(requested, actual)`,
///   只取第一个声道)。单声道源没问题,但如果哪天有立体声发布者,
///   会**静默**丢掉一半信号。
const AudioRendererOptions kRecordingRendererOptions = AudioRendererOptions(
  sampleRate: kPcmSampleRate, // 必须显式写死 16000:SDK 默认是 24000
  channels: 1,
  format: AudioFormat.Int16,
);

// ─────────────────────────────────────────────────────────────────────────────
// 适配器
// ─────────────────────────────────────────────────────────────────────────────

/// 把一个 LiveKit [Room] 接到一个 [CaptureSession] 上。
class RecordingService extends ChangeNotifier {
  RecordingService({
    required this.room,
    required bool Function() isCaptureAllowed,
    Listenable? consentNotifier,
    bool Function(int additionalBytes)? wouldExceedDisk,
    DateTime Function() now = DateTime.now,
    VadConfig vadConfig = const VadConfig(),
    SpeechDetector? detector,
    this.firstFrameTimeout = kDefaultFirstFrameTimeout,
    this.maxRendererAttempts = kDefaultMaxRendererAttempts,
    this.onLog,
    CaptureSession? session,
  }) : _session =
           session ??
           CaptureSession(
             isCaptureAllowed: isCaptureAllowed,
             now: now,
             consentNotifier: consentNotifier,
             wouldExceedDisk: wouldExceedDisk,
             vadConfig: vadConfig,
             detector: detector,
             onLog: onLog,
           ),
       _ownsSession = session == null;

  final Room room;

  /// 首帧超时,透传给每个 [RendererWatchdog]。
  final Duration firstFrameTimeout;

  /// 渲染器注册的最大尝试次数,透传给每个 [RendererWatchdog]。
  final int maxRendererAttempts;

  final void Function(String message)? onLog;

  final CaptureSession _session;

  /// 注入进来的 session 由调用方负责 dispose,自己造的才自己收。
  final bool _ownsSession;

  final Map<String, RendererWatchdog> _watchdogs =
      <String, RendererWatchdog>{};

  EventsListener<RoomEvent>? _listener;
  bool _started = false;
  bool _disposed = false;

  CaptureSession get session => _session;

  Stream<Utterance> get utterances => _session.utterances;

  CaptureSessionStats get stats => _session.stats;

  // ───────────────────────────────────────────────────────────────────────────
  // 启停
  // ───────────────────────────────────────────────────────────────────────────

  /// 装上房间事件监听,并补扫一遍**已经订阅上**的轨。
  void start() {
    if (_disposed || _started) return;
    _started = true;

    final EventsListener<RoomEvent> listener = room.createListener();
    _listener = listener;

    // TRAP 1:轨道对象在重连/重启后会被 SDK **换成新对象**,老的
    // RemoteAudioTrack 连同它身上的渲染器一起被销毁。所以注册必须发生在
    // 订阅事件的处理器里,拿事件带来的那个**当下的** track;任何被缓存
    // 下来的 AudioTrack 引用在重连之后都是一具尸体。
    listener.on<TrackSubscribedEvent>((TrackSubscribedEvent e) {
      final Track track = e.track;
      if (track is! AudioTrack) return;
      _attach(
        identity: e.participant.identity,
        displayName: _displayNameOf(e.participant),
        track: track,
      );
    });

    listener.on<TrackUnsubscribedEvent>((TrackUnsubscribedEvent e) {
      if (e.track is! AudioTrack) return;
      _detach(e.participant.identity, alsoFlush: true);
    });

    // TRAP 1(本地侧):LocalTrack.restartTrack() 会**静默销毁所有已注册的
    // 渲染器** —— 链路是 restartTrack() → stop() → Track.stopCapture() →
    // _captureGroups.clear(),而随后的 start() → AudioTrack.startCapture()
    // 只打了一行日志,什么都没恢复。setDeviceId() 和 unmute()(命中
    // stopOnMute 时)都会走这条链路,而本应用是「静音入会、开关麦克风
    // 就是发布/取消发布」的用法,这条路径每天要走几十次。
    // 所以:每一次本地轨发布都当成「老渲染器已经死了」,拆掉重挂。
    listener.on<LocalTrackPublishedEvent>((LocalTrackPublishedEvent e) {
      final AudioTrack? track = _audioTrackOf(e.publication.track);
      if (track == null) return;
      _attach(
        identity: e.participant.identity,
        displayName: _displayNameOf(e.participant),
        track: track,
      );
    });

    listener.on<LocalTrackUnpublishedEvent>((LocalTrackUnpublishedEvent e) {
      if (_audioTrackOf(e.publication.track) == null) return;
      _detach(e.participant.identity, alsoFlush: true);
    });

    listener.on<RoomReconnectingEvent>((RoomReconnectingEvent e) {
      _log('房间正在重连,标记所有轨为待重新注册');
      _session.markAllStale();
    });

    // 只做记账,**绝不**在这里重新注册渲染器。
    //
    // RoomReconnected 触发的时刻与「轨道真的回来了」之间可以隔很久:真机
    // 抓到过 19:49:00 就报 Reconnected、直到 19:49:40 才来一个 sid 不同的
    // TrackSubscribed 的日志,中间整整 40 秒 connectionState 是 connected
    // 却一帧音频都没有。在 Reconnected 上抢跑注册,只会拿着一个还没被
    // 替换掉的旧 track 对象去挂渲染器,注册到一具尸体上并且再也不会被
    // 纠正 —— 真正的信号只有 TrackSubscribed。
    listener.on<RoomReconnectedEvent>((RoomReconnectedEvent e) {
      _log('房间已重连,等待 TrackSubscribed 重新注册渲染器(不在此处抢跑)');
      _session.markAllStale();
    });

    _catchUpScan();
    notifyListeners();
  }

  /// 停止采集:拆掉所有渲染器与监听,并把在途语音段收尾产出。
  ///
  /// 与 [dispose] 的区别是本方法**不销毁** [session],停完还能再 [start]。
  Future<void> stop() async {
    if (_disposed) return;
    _started = false;
    await _teardown();
    _session.flushAll();
    notifyListeners();
  }

  @override
  void dispose() {
    // dispose 不能是 async(ChangeNotifier 的签名如此),而拆渲染器与拆
    // 监听器都是异步的。这里先同步地把状态置成已销毁、把在途音频收尾,
    // 再把异步清理挂出去 —— 否则要么阻塞调用方,要么在 widget 树已经
    // 拆掉之后还有帧回调打进来。
    // 幂等:ChangeNotifier.dispose 第二次调用会命中断言,所以重复调用
    // 直接返回,不再透传给 super。
    if (_disposed) return;
    _disposed = true;
    _started = false;
    _session.flushAll();
    final Future<void> teardown = _teardown();
    unawaited(
      teardown.whenComplete(() {
        if (_ownsSession) _session.dispose();
      }),
    );
    super.dispose();
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 内部实现
  // ───────────────────────────────────────────────────────────────────────────

  /// 补扫:监听器装上之前就已经订阅好的轨不会再补发事件。
  ///
  /// 典型场景是「先进房间、后打开录音」—— 房里的人早就订阅完了,不补扫
  /// 就会一个人的声音都收不到,而且没有任何报错。
  void _catchUpScan() {
    for (final RemoteParticipant p in room.remoteParticipants.values) {
      for (final RemoteTrackPublication<RemoteTrack> pub
          in p.trackPublications.values) {
        final AudioTrack? track = _audioTrackOf(pub.track);
        if (track == null) continue;
        _attach(
          identity: p.identity,
          displayName: _displayNameOf(p),
          track: track,
        );
      }
    }

    // localParticipant 是可空的:还没连上、或已断开时为 null。
    final LocalParticipant? local = room.localParticipant;
    if (local == null) return;
    for (final LocalTrackPublication<LocalTrack> pub
        in local.trackPublications.values) {
      final AudioTrack? track = _audioTrackOf(pub.track);
      if (track == null) continue;
      _attach(
        identity: local.identity,
        displayName: _displayNameOf(local),
        track: track,
      );
    }
  }

  /// 给一条轨挂上新的看门狗。已有的先彻底拆掉。
  void _attach({
    required String identity,
    required String displayName,
    required AudioTrack track,
  }) {
    if (_disposed) return;

    // 先拆后挂,而且**不** flush:这不是「这个人走了」,而是「同一个人的
    // 轨换了一个新对象」,在途的半句话应该继续接下去,不该被切断。
    _detach(identity, alsoFlush: false);

    late final RendererWatchdog watchdog;
    watchdog = RendererWatchdog(
      identity: identity,
      firstFrameTimeout: firstFrameTimeout,
      maxAttempts: maxRendererAttempts,
      onLog: onLog,
      onHealth: (RendererHealth health, int attempts) {
        _session.onRendererHealth(identity, displayName, health, attempts);
        notifyListeners();
      },
      attach: (int attempt) {
        try {
          return track.addAudioRenderer(
            options: kRecordingRendererOptions,
            onFrame: (AudioFrame frame) {
              // 先喂看门狗:首帧一到就撤掉超时定时器,避免一条其实活着的
              // 轨被误判成静默失败而白白重注册一次。
              watchdog.noteFrame();
              _session.onFrameBytes(
                identity,
                displayName,
                // 防御性拷贝。原生侧可能复用同一块帧缓冲区,直接把它交给
                // 切分器意味着后续的帧会**就地改写**我们还没处理完的音频
                // (已验证的采集样例同样是用 BytesBuilder(copy: true) 收帧的)。
                // 一帧只有几百字节,这份拷贝的代价可以忽略。
                Uint8List.fromList(frame.data),
                frame.sampleRate,
                frame.channels,
              );
            },
          );
        } on Object catch (e) {
          _log('$identity:第 $attempt 次 addAudioRenderer 抛异常($e)');
          return null;
        }
      },
    );

    _watchdogs[identity] = watchdog;
    watchdog.start();
    _log('$identity:已挂上新的音频渲染器(第 ${watchdog.attempts} 次尝试)');
    notifyListeners();
  }

  /// 拆掉某条轨的看门狗(连带注销渲染器)。
  void _detach(String identity, {required bool alsoFlush}) {
    final RendererWatchdog? watchdog = _watchdogs.remove(identity);
    if (watchdog != null) unawaited(watchdog.dispose());
    if (alsoFlush) _session.onTrackGone(identity);
  }

  Future<void> _teardown() async {
    final List<RendererWatchdog> all = _watchdogs.values.toList();
    _watchdogs.clear();
    for (final RendererWatchdog w in all) {
      await w.dispose();
    }
    final EventsListener<RoomEvent>? listener = _listener;
    _listener = null;
    if (listener != null) await listener.dispose();
  }

  /// 取轨道的音频面。非音频轨、以及尚未就绪的空轨都返回 null。
  AudioTrack? _audioTrackOf(Track? track) =>
      track is AudioTrack ? track : null;

  /// 显示名兜底。
  ///
  /// `Participant.name` 非空但**可能是空字符串**(用户没设昵称时就是),
  /// 直接拿去显示会得到一行空白。identity 至少是可辨认的。
  String _displayNameOf(Participant<TrackPublication<Track>> participant) =>
      participant.name.isEmpty ? participant.identity : participant.name;

  void _log(String message) => onLog?.call(message);
}
