import 'package:livekit_client/livekit_client.dart';

/// Krisp 等增强降噪处理器的接线位。
///
/// 默认无实现 -> 增强档不可用,自动回落到标准档(见 [resolveAudioTuning])。
/// 将来接入 livekit_noise_filter 时,只需在 main.dart 注册一个实现,
/// 本层与 RTC 层都无需改动。
abstract class AudioProcessorProvider {
  /// 处理器名(诊断用)。
  String get name;

  /// 本平台 + 本实现是否真的可用。
  /// 允许异步 —— Krisp 的 isSupported 可能需要查询原生侧。
  Future<bool> isSupported();

  /// 创建一个处理器实例;不可用时返回 null。
  Future<TrackProcessor<AudioProcessorOptions>?> create();
}

/// 全局注册表。
///
/// 刻意用全局单例而非构造注入:main.dart 由其他人维护,
/// 默认路径必须在完全不改 main.dart 的前提下正确工作;
/// 将来接 Krisp 时也只是往 main.dart 粘一行注册语句。
class AudioProcessorRegistry {
  AudioProcessorRegistry._();

  static final AudioProcessorRegistry instance = AudioProcessorRegistry._();

  AudioProcessorProvider? _provider;

  AudioProcessorProvider? get provider => _provider;

  bool get hasProvider => _provider != null;

  void register(AudioProcessorProvider provider) {
    _provider = provider;
  }

  /// 供测试复位使用。
  void clear() {
    _provider = null;
  }
}

// ---------------------------------------------------------------------------
// 【预置但未启用】Krisp 接线参考实现
//
// 下面整块是"依赖到位后可直接粘贴启用"的样板。当前仓库 **没有**
// livekit_noise_filter 依赖(本次改动零新增依赖),所以它以注释形式静置在这里,
// 不参与编译、不产生任何运行时行为。
//
// 启用步骤(需要 pubspec 的所有者配合):
//   1. pubspec.yaml 增加 livekit_noise_filter 依赖并 pub get;
//   2. 取消下面注释,补上 import 'package:livekit_noise_filter/livekit_noise_filter.dart';
//   3. 在 main.dart 里加一行:
//        AudioProcessorRegistry.instance.register(KrispAudioProcessorProvider());
//   4. RTC 层零改动 —— 增强档会自动从"回落"变成"真正生效"。
//
// class KrispAudioProcessorProvider implements AudioProcessorProvider {
//   @override
//   String get name => 'krisp-noise-filter';
//
//   @override
//   Future<bool> isSupported() async {
//     // LiveKitNoiseFilter 只在 Android / iOS / macOS 上有原生实现,
//     // 与 kKrispCapablePlatforms 保持一致;调用方还会再做一次平台白名单校验。
//     return true;
//   }
//
//   @override
//   Future<TrackProcessor<AudioProcessorOptions>?> create() async {
//     // LiveKitNoiseFilter 实现了 TrackProcessor<AudioProcessorOptions>,
//     // 生命周期(init / onPublish / onUnpublish / destroy)由 SDK 与本层共同驱动。
//     return LiveKitNoiseFilter();
//   }
// }
// ---------------------------------------------------------------------------
