// 只用 foundation 的 @immutable 注解(纯值语义标记),不引入任何平台通道依赖,
// 本文件可在无插件的纯 VM 测试环境中直接使用。
// 未选用 package:meta 是因为它不是本包的直接依赖(depend_on_referenced_packages)。
import 'package:flutter/foundation.dart';

/// 降噪档位。
///
/// - [off]:关闭全部 APM 处理(合奏/放音乐/排查问题时用,不吃掉乐器泛音)。
/// - [standard]:WebRTC APM 软件降噪 + 回声消除 + 自动增益 + 高通滤波。
/// - [enhanced]:Krisp 轨道处理器;此档下软件降噪必须关闭
///   (厂商明确要求不要叠加两套降噪模型)。
enum NoiseSuppressionMode { off, standard, enhanced }

/// 用户可调的降噪偏好(纯值对象,不含任何平台/插件依赖)。
@immutable
class AudioTuning {
  const AudioTuning({
    this.mode = NoiseSuppressionMode.standard,
    this.echoCancellation = true,
    this.autoGainControl = true,
    // 注意:这里刻意与 SDK 默认值(false)不同。
    // 高通滤波几乎零成本地滤掉空调/桌面低频嗡鸣,是白捡的收益。
    this.highPassFilter = true,
    this.typingNoiseDetection = true,
  });

  final NoiseSuppressionMode mode;
  final bool echoCancellation;
  final bool autoGainControl;
  final bool highPassFilter;
  final bool typingNoiseDetection;

  /// 默认档:标准降噪 + 全部 DSP 开启。
  static const AudioTuning standard = AudioTuning();

  /// 全关档:合奏/乐器分享场景。
  static const AudioTuning off = AudioTuning(
    mode: NoiseSuppressionMode.off,
    echoCancellation: false,
    autoGainControl: false,
    highPassFilter: false,
    typingNoiseDetection: false,
  );

  /// 增强档:Krisp;平台不支持时会在解析阶段自动回落到标准档。
  static const AudioTuning enhanced = AudioTuning(
    mode: NoiseSuppressionMode.enhanced,
  );

  AudioTuning copyWith({
    NoiseSuppressionMode? mode,
    bool? echoCancellation,
    bool? autoGainControl,
    bool? highPassFilter,
    bool? typingNoiseDetection,
  }) {
    return AudioTuning(
      mode: mode ?? this.mode,
      echoCancellation: echoCancellation ?? this.echoCancellation,
      autoGainControl: autoGainControl ?? this.autoGainControl,
      highPassFilter: highPassFilter ?? this.highPassFilter,
      typingNoiseDetection: typingNoiseDetection ?? this.typingNoiseDetection,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioTuning &&
          other.mode == mode &&
          other.echoCancellation == echoCancellation &&
          other.autoGainControl == autoGainControl &&
          other.highPassFilter == highPassFilter &&
          other.typingNoiseDetection == typingNoiseDetection;

  @override
  int get hashCode => Object.hash(
    mode,
    echoCancellation,
    autoGainControl,
    highPassFilter,
    typingNoiseDetection,
  );

  @override
  String toString() =>
      'AudioTuning(mode: $mode, echoCancellation: $echoCancellation, '
      'autoGainControl: $autoGainControl, highPassFilter: $highPassFilter, '
      'typingNoiseDetection: $typingNoiseDetection)';
}

/// 平台能力(可注入,便于纯 VM 测试)。
@immutable
class AudioPlatformCapabilities {
  const AudioPlatformCapabilities({
    required this.platform,
    required this.supportsAudioSession,
    required this.supportsEnhanced,
  });

  /// 'windows' | 'macos' | 'linux' | 'ios' | 'android' | 'web'
  /// (io 端兜底可能返回 'unknown')
  final String platform;

  /// 是否有原生音频会话可配置(仅 iOS / Android)。
  final bool supportsAudioSession;

  /// 增强降噪是否真的可用:平台在 Krisp 支持列表内 **且** 已注册处理器实现。
  final bool supportsEnhanced;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioPlatformCapabilities &&
          other.platform == platform &&
          other.supportsAudioSession == supportsAudioSession &&
          other.supportsEnhanced == supportsEnhanced;

  @override
  int get hashCode => Object.hash(platform, supportsAudioSession, supportsEnhanced);

  @override
  String toString() =>
      'AudioPlatformCapabilities(platform: $platform, '
      'supportsAudioSession: $supportsAudioSession, '
      'supportsEnhanced: $supportsEnhanced)';
}

/// Krisp 声明支持的平台(pub.dev 标签: Android/iOS/macOS)。
///
/// 刻意 **不含** 'web':changelog 声称 0.2.0 加了 Web 支持,但与 pub.dev
/// 平台标签互相矛盾。取保守口径 —— 宁可回落到标准降噪,也不对用户
/// 承诺一个可能不存在的能力。Windows/Linux 明确不支持。
const Set<String> kKrispCapablePlatforms = <String>{'android', 'ios', 'macos'};

/// 解析后的最终生效状态。UI 直接读它显示"实际发生了什么",而不是"用户要什么"。
@immutable
class ResolvedAudioTuning {
  const ResolvedAudioTuning({
    required this.requested,
    required this.effective,
    required this.softwareNoiseSuppression,
    required this.enhancedProcessorActive,
    required this.echoCancellation,
    required this.autoGainControl,
    required this.highPassFilter,
    required this.typingNoiseDetection,
    required this.audioSessionConfigured,
    required this.platform,
    required this.reason,
  }) : assert(
         !(softwareNoiseSuppression && enhancedProcessorActive),
         '软件降噪与增强降噪互斥,不能同时开启',
       );

  /// 用户请求的档位。
  final NoiseSuppressionMode requested;

  /// 本平台上实际生效的档位(可能因能力不足而回落)。
  final NoiseSuppressionMode effective;

  /// WebRTC APM 软件降噪是否开启。
  final bool softwareNoiseSuppression;

  /// Krisp 增强降噪处理器是否挂载。
  final bool enhancedProcessorActive;

  final bool echoCancellation;
  final bool autoGainControl;
  final bool highPassFilter;
  final bool typingNoiseDetection;

  /// 是否配置了原生音频会话(仅 iOS / Android 为 true)。
  final bool audioSessionConfigured;

  final String platform;

  /// 简短的中文说明,可直接作为设置页副标题。
  final String reason;

  /// 是否发生了回落(请求档位 ≠ 生效档位)。
  bool get didFallBack => requested != effective;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResolvedAudioTuning &&
          other.requested == requested &&
          other.effective == effective &&
          other.softwareNoiseSuppression == softwareNoiseSuppression &&
          other.enhancedProcessorActive == enhancedProcessorActive &&
          other.echoCancellation == echoCancellation &&
          other.autoGainControl == autoGainControl &&
          other.highPassFilter == highPassFilter &&
          other.typingNoiseDetection == typingNoiseDetection &&
          other.audioSessionConfigured == audioSessionConfigured &&
          other.platform == platform &&
          other.reason == reason;

  @override
  int get hashCode => Object.hash(
    requested,
    effective,
    softwareNoiseSuppression,
    enhancedProcessorActive,
    echoCancellation,
    autoGainControl,
    highPassFilter,
    typingNoiseDetection,
    audioSessionConfigured,
    platform,
    reason,
  );

  @override
  String toString() =>
      'ResolvedAudioTuning(requested: $requested, effective: $effective, '
      'softwareNoiseSuppression: $softwareNoiseSuppression, '
      'enhancedProcessorActive: $enhancedProcessorActive, '
      'echoCancellation: $echoCancellation, autoGainControl: $autoGainControl, '
      'highPassFilter: $highPassFilter, '
      'typingNoiseDetection: $typingNoiseDetection, '
      'audioSessionConfigured: $audioSessionConfigured, '
      'platform: $platform, reason: $reason)';
}

/// 纯函数解析器:把"用户想要什么"+"平台能做到什么"合成"实际会发生什么"。
///
/// 不碰任何平台通道,可在纯 VM 测试中直接调用。
ResolvedAudioTuning resolveAudioTuning(
  AudioTuning tuning,
  AudioPlatformCapabilities caps,
) {
  final NoiseSuppressionMode requested = tuning.mode;
  NoiseSuppressionMode effective = requested;

  if (requested == NoiseSuppressionMode.enhanced && !caps.supportsEnhanced) {
    effective = NoiseSuppressionMode.standard;
  }

  // 互斥不变量:两个布尔都由同一个枚举派生,结构上不可能同时为 true。
  final bool software = effective == NoiseSuppressionMode.standard;
  final bool enhanced = effective == NoiseSuppressionMode.enhanced;
  final bool isOff = effective == NoiseSuppressionMode.off;

  final String reason;
  if (requested == NoiseSuppressionMode.enhanced && !caps.supportsEnhanced) {
    reason = '本平台(${caps.platform})不支持增强降噪,已回落到标准降噪';
  } else if (enhanced) {
    reason = 'Krisp 增强降噪';
  } else if (isOff) {
    reason = '已关闭所有降噪处理';
  } else if (tuning.highPassFilter) {
    reason = '系统级降噪(WebRTC APM)+ 高通滤波';
  } else {
    reason = '系统级降噪(WebRTC APM)';
  }

  return ResolvedAudioTuning(
    requested: requested,
    effective: effective,
    softwareNoiseSuppression: software,
    enhancedProcessorActive: enhanced,
    // off 档强制关掉全部 DSP,不让任何一项漏网。
    echoCancellation: isOff ? false : tuning.echoCancellation,
    autoGainControl: isOff ? false : tuning.autoGainControl,
    highPassFilter: isOff ? false : tuning.highPassFilter,
    typingNoiseDetection: isOff ? false : tuning.typingNoiseDetection,
    audioSessionConfigured: caps.supportsAudioSession,
    platform: caps.platform,
    reason: reason,
  );
}
