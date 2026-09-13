import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/audio/audio_tuning.dart';

/// 构造一个平台能力桩,避免每个用例都写全参数
AudioPlatformCapabilities caps({
  required String platform,
  bool audioSession = false,
  bool enhanced = false,
}) => AudioPlatformCapabilities(
  platform: platform,
  supportsAudioSession: audioSession,
  supportsEnhanced: enhanced,
);

void main() {
  group('AudioTuning 默认值', () {
    test('标准档默认开启高通滤波(刻意区别于 SDK 的 false 默认值)', () {
      const t = AudioTuning.standard;
      expect(t.mode, NoiseSuppressionMode.standard);
      expect(t.highPassFilter, isTrue);
      expect(t.echoCancellation, isTrue);
      expect(t.autoGainControl, isTrue);
      expect(t.typingNoiseDetection, isTrue);
    });

    test('全关档把四项 DSP 全部关掉', () {
      const t = AudioTuning.off;
      expect(t.mode, NoiseSuppressionMode.off);
      expect(t.echoCancellation, isFalse);
      expect(t.autoGainControl, isFalse);
      expect(t.highPassFilter, isFalse);
      expect(t.typingNoiseDetection, isFalse);
    });

    test('增强档只改档位,其余 DSP 保持默认开启', () {
      const t = AudioTuning.enhanced;
      expect(t.mode, NoiseSuppressionMode.enhanced);
      expect(t.echoCancellation, isTrue);
      expect(t.highPassFilter, isTrue);
    });
  });

  group('降噪档位解析', () {
    test('平台不支持增强降噪时回落到标准档,并在说明里点名平台', () {
      final r = resolveAudioTuning(
        AudioTuning.enhanced,
        caps(platform: 'windows'),
      );

      expect(r.requested, NoiseSuppressionMode.enhanced);
      expect(r.effective, NoiseSuppressionMode.standard);
      expect(r.didFallBack, isTrue);
      expect(r.enhancedProcessorActive, isFalse);
      expect(r.softwareNoiseSuppression, isTrue);
      expect(r.reason, contains('windows'));
    });

    test('平台支持增强降噪时启用 Krisp,并关闭软件降噪(不叠加两套模型)', () {
      final r = resolveAudioTuning(
        AudioTuning.enhanced,
        caps(platform: 'android', audioSession: true, enhanced: true),
      );

      expect(r.effective, NoiseSuppressionMode.enhanced);
      expect(r.didFallBack, isFalse);
      expect(r.enhancedProcessorActive, isTrue);
      expect(r.softwareNoiseSuppression, isFalse);
      expect(r.reason, contains('Krisp'));
    });

    test('标准档启用 WebRTC 软件降噪', () {
      final r = resolveAudioTuning(
        AudioTuning.standard,
        caps(platform: 'macos'),
      );

      expect(r.effective, NoiseSuppressionMode.standard);
      expect(r.softwareNoiseSuppression, isTrue);
      expect(r.enhancedProcessorActive, isFalse);
      expect(r.highPassFilter, isTrue);
    });

    test('全关档:两路降噪与四项 DSP 全部为 false', () {
      final r = resolveAudioTuning(AudioTuning.off, caps(platform: 'windows'));

      expect(r.effective, NoiseSuppressionMode.off);
      expect(r.softwareNoiseSuppression, isFalse);
      expect(r.enhancedProcessorActive, isFalse);
      expect(r.echoCancellation, isFalse);
      expect(r.autoGainControl, isFalse);
      expect(r.highPassFilter, isFalse);
      expect(r.typingNoiseDetection, isFalse);
    });

    test('全关档即使用户单独开着某项 DSP,也会被强制关闭', () {
      const t = AudioTuning(
        mode: NoiseSuppressionMode.off,
        echoCancellation: true,
        autoGainControl: true,
        highPassFilter: true,
        typingNoiseDetection: true,
      );
      final r = resolveAudioTuning(t, caps(platform: 'ios', audioSession: true));

      expect(r.echoCancellation, isFalse);
      expect(r.autoGainControl, isFalse);
      expect(r.highPassFilter, isFalse);
      expect(r.typingNoiseDetection, isFalse);
    });

    test('互斥不变量:全矩阵下软件降噪与增强降噪永不同时为真', () {
      const platforms = <String>[
        'windows',
        'macos',
        'linux',
        'ios',
        'android',
        'web',
      ];

      for (final mode in NoiseSuppressionMode.values) {
        for (final supportsEnhanced in <bool>[true, false]) {
          for (final platform in platforms) {
            final r = resolveAudioTuning(
              AudioTuning(mode: mode),
              caps(platform: platform, enhanced: supportsEnhanced),
            );

            expect(
              r.softwareNoiseSuppression && r.enhancedProcessorActive,
              isFalse,
              reason: '$platform / $mode / enhanced=$supportsEnhanced 破坏了互斥',
            );
            // 生效档位与两个布尔必须严格对应
            expect(
              r.softwareNoiseSuppression,
              r.effective == NoiseSuppressionMode.standard,
            );
            expect(
              r.enhancedProcessorActive,
              r.effective == NoiseSuppressionMode.enhanced,
            );
          }
        }
      }
    });

    test('音频会话仅在 iOS / Android 上被标记为已配置', () {
      expect(
        resolveAudioTuning(
          AudioTuning.standard,
          caps(platform: 'ios', audioSession: true),
        ).audioSessionConfigured,
        isTrue,
      );
      expect(
        resolveAudioTuning(
          AudioTuning.standard,
          caps(platform: 'android', audioSession: true),
        ).audioSessionConfigured,
        isTrue,
      );
      expect(
        resolveAudioTuning(
          AudioTuning.standard,
          caps(platform: 'windows'),
        ).audioSessionConfigured,
        isFalse,
      );
    });
  });

  group('Krisp 平台白名单', () {
    test('只含 android / ios / macos,保守地不含 web', () {
      expect(kKrispCapablePlatforms, containsAll(<String>['android', 'ios', 'macos']));
      expect(kKrispCapablePlatforms.contains('web'), isFalse);
      expect(kKrispCapablePlatforms.contains('windows'), isFalse);
      expect(kKrispCapablePlatforms.contains('linux'), isFalse);
    });
  });

  group('值类型语义', () {
    test('AudioTuning 相等性与 hashCode 按字段比较', () {
      const a = AudioTuning();
      const b = AudioTuning();
      const c = AudioTuning(highPassFilter: false);

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('copyWith 只改指定字段', () {
      const base = AudioTuning.standard;
      final changed = base.copyWith(
        mode: NoiseSuppressionMode.enhanced,
        autoGainControl: false,
      );

      expect(changed.mode, NoiseSuppressionMode.enhanced);
      expect(changed.autoGainControl, isFalse);
      expect(changed.echoCancellation, base.echoCancellation);
      expect(changed.highPassFilter, base.highPassFilter);
      expect(changed.typingNoiseDetection, base.typingNoiseDetection);
      expect(base.copyWith(), equals(base));
    });

    test('AudioPlatformCapabilities 与 ResolvedAudioTuning 也是值类型', () {
      expect(caps(platform: 'ios'), equals(caps(platform: 'ios')));

      final r1 = resolveAudioTuning(AudioTuning.standard, caps(platform: 'ios'));
      final r2 = resolveAudioTuning(AudioTuning.standard, caps(platform: 'ios'));
      expect(r1, equals(r2));
      expect(r1.hashCode, equals(r2.hashCode));
      expect(r1.toString(), contains('ios'));
    });
  });
}
