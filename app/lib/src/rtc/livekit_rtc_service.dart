import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import '../audio/audio_processor_provider.dart';
import '../platform/platform_info.dart'
    if (dart.library.io) '../platform/platform_info_io.dart';
import 'rtc_service.dart';

/// LiveKit 实现。进房默认静音(设计.md §2.1-4:想来就来,不打扰)。
class LiveKitRtcService implements RtcService {
  LiveKitRtcService({this.hostOnlyIce = false});

  /// 局域网联调:只用主机候选,跳过 STUN 收集(可省 ~2s 进房时间)
  final bool hostOnlyIce;

  Room? _room;
  CancelListenFunc? _cancelEvents;

  final _speaking = StreamController<Set<String>>.broadcast();
  final _disconnected = StreamController<void>.broadcast();

  ResolvedAudioTuning? _activeTuning;
  TrackProcessor<AudioProcessorOptions>? _processor;

  /// 处理器的 onPublish 只应调用一次;进房默认静音时会推迟到首次开麦。
  bool _processorPublished = false;

  @override
  bool get inRoom => _room != null;

  /// 底层 Room,仅供聊天传输层(`chat/livekit_chat_transport.dart`)取用。
  ///
  /// 刻意**不**放进 `RtcService` 接口:那一层要保持与厂商无关(设计.md §8.1),
  /// 接口里出现 `Room` 会迫使 `rtc_service.dart` import livekit_client,
  /// 并连带弄坏两个测试 fake。
  ///
  /// ⚠️ 仅在 `join()` 与 `leave()` 之间非空,`leave()` 会 dispose 掉它 ——
  /// 传输层必须**每次进房重建**,绝不可跨会话缓存。
  Room? get room => _room;

  @override
  Stream<Set<String>> get speakingIdentities => _speaking.stream;

  @override
  Stream<void> get onDisconnected => _disconnected.stream;

  @override
  ResolvedAudioTuning? get activeTuning => _activeTuning;

  /// 同步预览:不 await 处理器的 isSupported(),而是用
  /// 「平台白名单 + 是否已注册 provider」作为诚实但乐观的近似值。
  /// 权威结果是进房后的 [activeTuning]。
  @override
  ResolvedAudioTuning previewTuning(AudioTuning tuning) {
    final String platform = PlatformInfo.current;
    return resolveAudioTuning(
      tuning,
      AudioPlatformCapabilities(
        platform: platform,
        supportsAudioSession: _platformSupportsAudioSession(platform),
        supportsEnhanced:
            kKrispCapablePlatforms.contains(platform) &&
            AudioProcessorRegistry.instance.hasProvider,
      ),
    );
  }

  static bool _platformSupportsAudioSession(String platform) =>
      platform == 'ios' || platform == 'android';

  /// 权威能力探测:比 [previewTuning] 多一步 provider.isSupported() 的异步确认。
  Future<AudioPlatformCapabilities> _detectCapabilities() async {
    final String platform = PlatformInfo.current;
    bool enhanced = false;

    if (kKrispCapablePlatforms.contains(platform)) {
      final AudioProcessorProvider? provider =
          AudioProcessorRegistry.instance.provider;
      if (provider != null) {
        try {
          enhanced = await provider.isSupported();
        } catch (e) {
          debugPrint('[lares] 增强降噪能力探测失败,按不支持处理: $e');
          enhanced = false;
        }
      }
    }

    return AudioPlatformCapabilities(
      platform: platform,
      supportsAudioSession: _platformSupportsAudioSession(platform),
      supportsEnhanced: enhanced,
    );
  }

  /// 仅在解析结果确实启用增强档时才创建处理器实例。
  Future<TrackProcessor<AudioProcessorOptions>?> _createProcessor() async {
    final AudioProcessorProvider? provider =
        AudioProcessorRegistry.instance.provider;
    if (provider == null) return null;
    try {
      return await provider.create();
    } catch (e) {
      debugPrint('[lares] 增强降噪处理器创建失败,回落到标准降噪: $e');
      return null;
    }
  }

  Future<void> _configureAudioSession() async {
    // 已核实:SDK 默认就是 communication 预设 + automatic 模式,
    // 即 Android MODE_IN_COMMUNICATION(硬件 AEC/NS)本来就已生效。
    // 这里只把 Apple 的 mode 从 videoChat 调成更贴合纯语音场景的 voiceChat。
    // ⚠️ setAudioSessionOptions 会副作用地切到 manual 模式(LiveKit 不再按房间/轨道生命周期管理会话),
    // 因此必须紧接着恢复 automatic —— 此时自定义 options 会被保留并重新应用。
    // 音频会话相关 API 在 SDK 中全部标注 @experimental,这里逐行豁免告警。
    try {
      // ignore: experimental_member_use
      await AudioManager.instance.setAudioSessionOptions(
        // ignore: experimental_member_use
        const AudioSessionOptions.communication(
          // ignore: experimental_member_use
          apple: AppleAudioSessionConfiguration(
            // ignore: experimental_member_use
            category: AppleAudioCategory.playAndRecord,
            categoryOptions: {
              // ignore: experimental_member_use
              AppleAudioCategoryOption.allowBluetooth,
              // ignore: experimental_member_use
              AppleAudioCategoryOption.allowBluetoothA2DP,
              // ignore: experimental_member_use
              AppleAudioCategoryOption.allowAirPlay,
            },
            // ignore: experimental_member_use
            mode: AppleAudioMode.voiceChat,
          ),
          // ignore: experimental_member_use
          android: AndroidAudioSessionConfiguration.communication,
        ),
      );
      // ignore: experimental_member_use
      await AudioManager.instance.setAudioSessionManagementMode(
        // ignore: experimental_member_use
        AudioSessionManagementMode.automatic,
      );
    } catch (e) {
      // 会话配置失败绝不能挡住进房。
      debugPrint('[lares] 音频会话配置失败(已忽略,继续进房): $e');
    }
  }

  /// 处理器需要在麦克风轨道发布之后才能 onPublish;重复调用无意义。
  Future<void> _publishProcessorIfNeeded(Room room) async {
    final TrackProcessor<AudioProcessorOptions>? processor = _processor;
    if (processor == null || _processorPublished) return;
    try {
      await processor.onPublish(room);
      _processorPublished = true;
    } catch (e) {
      debugPrint('[lares] 增强降噪处理器发布失败: $e');
    }
  }

  @override
  Future<Duration> join({
    required String url,
    required String token,
    required bool startMuted,
    bool highQuality = true,
    AudioTuning tuning = AudioTuning.standard,
  }) async {
    final sw = Stopwatch()..start();

    final AudioPlatformCapabilities caps = await _detectCapabilities();
    ResolvedAudioTuning resolved = resolveAudioTuning(tuning, caps);

    _processor = null;
    _processorPublished = false;
    if (resolved.enhancedProcessorActive) {
      _processor = await _createProcessor();
      if (_processor == null) {
        // 声称支持却造不出实例:如实回落,不要留下"以为开了增强档"的假象。
        resolved = resolveAudioTuning(
          tuning,
          AudioPlatformCapabilities(
            platform: caps.platform,
            supportsAudioSession: caps.supportsAudioSession,
            supportsEnhanced: false,
          ),
        );
      }
    }
    _activeTuning = resolved;

    if (resolved.audioSessionConfigured) {
      await _configureAudioSession();
    }

    final room = Room(
      roomOptions: RoomOptions(
        // 语音房:只需要音频;自适应流与 dynacast 降低挂机带宽
        adaptiveStream: true,
        dynacast: true,
        // 流量透明度(§2.2):高音质 48k / 省流 24k
        defaultAudioPublishOptions: AudioPublishOptions(
          encoding: highQuality
              ? AudioEncoding.presetMusic
              : AudioEncoding.presetSpeech,
        ),
        // 降噪档位 -> 采集约束。软件降噪与 Krisp 互斥由 resolved 保证。
        defaultAudioCaptureOptions: AudioCaptureOptions(
          noiseSuppression: resolved.softwareNoiseSuppression,
          echoCancellation: resolved.echoCancellation,
          autoGainControl: resolved.autoGainControl,
          highPassFilter: resolved.highPassFilter,
          typingNoiseDetection: resolved.typingNoiseDetection,
          // voiceIsolation 保持默认:SDK 的 toMediaConstraintsMap() 实际发出的是
          // {'voiceIsolation': noiseSuppression},读的是 noiseSuppression 字段,
          // 该字段在采集期不起作用,设置它没有意义。
          //
          // 四个 *Mode 字段同样保持 AudioProcessingMode.automatic:它们是实验性 API,
          // 只影响运行期 setAudioProcessingOptions 通路,不参与采集约束的生成。
          processor: resolved.enhancedProcessorActive ? _processor : null,
        ),
      ),
    );
    _room = room;

    _cancelEvents = room.events.listen((event) {
      switch (event) {
        case ActiveSpeakersChangedEvent():
          _speaking.add(event.speakers.map((p) => p.identity).toSet());
        case RoomDisconnectedEvent():
          _speaking.add(const {});
          _disconnected.add(null);
        default:
          break;
      }
    });

    await room.connect(
      url,
      token,
      connectOptions: ConnectOptions(
        autoSubscribe: true,
        rtcConfiguration: hostOnlyIce
            ? const RTCConfiguration(iceServers: [])
            : const RTCConfiguration(),
      ),
    );

    // LiveKit 默认不发布麦克风;只有明确要求开麦时才调用(省一次往返)
    if (!startMuted) {
      await room.localParticipant?.setMicrophoneEnabled(true);
      // 处理器必须在轨道发布之后挂载。
      // 常规路径是进房即静音,此时麦克风尚未发布,
      // 处理器会推迟到 setMuted(false) 首次开麦时再 onPublish。
      await _publishProcessorIfNeeded(room);
    }

    sw.stop();
    return sw.elapsed;
  }

  @override
  Future<void> setMuted(bool muted) async {
    final room = _room;
    await room?.localParticipant?.setMicrophoneEnabled(!muted);
    if (!muted && room != null) {
      // 进房默认静音的常规路径:首次开麦才真正发布麦克风轨道,
      // 增强降噪处理器在这里补挂。
      await _publishProcessorIfNeeded(room);
    }
  }

  @override
  Future<void> leave() async {
    final room = _room;
    _room = null;
    _cancelEvents?.call();
    _cancelEvents = null;
    _activeTuning = null;
    _speaking.add(const {});

    final TrackProcessor<AudioProcessorOptions>? processor = _processor;
    _processor = null;
    _processorPublished = false;
    if (processor != null) {
      try {
        await processor.destroy();
      } catch (e) {
        debugPrint('[lares] 增强降噪处理器释放失败(已忽略): $e');
      }
    }

    await room?.disconnect();
    await room?.dispose();
  }
}
