/// 一段被切分出来的语音(VAD 的输出、STT 的输入)。
///
/// 本文件是**纯值类型**:不碰任何插件/平台通道,可在纯 VM 测试里直接构造。
library;

import 'dart:typed_data';

// 只用 foundation 的 @immutable 注解(纯值语义标记),不引入任何平台通道依赖。
// 未选用 package:meta 是因为它不是本包的直接依赖(depend_on_referenced_packages)。
import 'package:flutter/foundation.dart';

/// 全链路统一的采样率:16 kHz 单声道。
///
/// 选 16k 不是随便定的:主流离线 ASR(sherpa-onnx / whisper / Silero VAD)
/// 的声学模型全部按 16k 训练,喂 48k 反而要在识别前再重采样一次,
/// 平白多一次插值损失。上游 WebRTC 采集到的音频在进入本模块前必须已降采样。
const int kPcmSampleRate = 16000;

/// 每个采样点的字节数(int16 = 2 字节),换算长度/时长时到处要用,提出来避免魔数。
const int kBytesPerSample = 2;

/// 一段连续语音。
///
/// **诚实说明可变性**:本类标了 [immutable],但 [pcm] 是 `Uint8List`,
/// 它的元素在运行期是可写的,Dart 也无法把它变成深度 const。
/// 也就是说这里的"不可变"是**约定而非强制**:构造之后谁都不该再改 [pcm] 的内容。
/// 切分器交出 [Utterance] 后就不再持有那块缓冲区,调用方也请遵守同样的约定;
/// 需要改写时请自己 copy 一份,不要原地改。
/// 为此本类刻意**不参与** `==` 的深比较 —— 见 [operator ==] 的说明。
@immutable
class Utterance {
  const Utterance({
    required this.speakerIdentity,
    required this.speakerName,
    required this.startedAt,
    required this.endedAt,
    required this.pcm,
    this.sampleRate = kPcmSampleRate,
  });

  /// 从 int16 采样点数组构造,内部按**小端**编码成字节。
  ///
  /// 显式按字节写小端,而不是 `Int16List.view(...)` 之类的重解释:
  /// 后者用的是**宿主机字节序**,在大端机器上会静默产出错误的 PCM。
  /// 这条链路要落盘、要跨进程喂给 ASR,字节序必须是我们说了算的。
  factory Utterance.fromSamples({
    required String speakerIdentity,
    required String speakerName,
    required DateTime startedAt,
    required List<int> samples,
    int sampleRate = kPcmSampleRate,
  }) {
    final Uint8List bytes = encodePcm16(samples);
    return Utterance(
      speakerIdentity: speakerIdentity,
      speakerName: speakerName,
      startedAt: startedAt,
      endedAt: startedAt.add(
        Duration(microseconds: samples.length * 1000000 ~/ sampleRate),
      ),
      pcm: bytes,
      sampleRate: sampleRate,
    );
  }

  /// LiveKit participant identity。这是**机器可读**的说话人主键,
  /// 显示名可以随时被用户改掉,identity 不会,所以聚合/去重一律认它。
  final String speakerIdentity;

  /// 显示名(用户可改)。只用于给人看的转写稿,不做任何逻辑判断。
  final String speakerName;

  /// 这段语音第一个采样点对应的绝对时刻(墙钟)。
  final DateTime startedAt;

  /// 这段语音最后一个采样点之后的绝对时刻(左闭右开)。
  ///
  /// 由切分器保证 `endedAt == startedAt + duration` 精确成立 ——
  /// 时刻本身是用"会话起点 + 已处理采样数"推出来的,不是 `DateTime.now()`。
  final DateTime endedAt;

  /// 16 kHz 单声道 int16 **小端** PCM 裸字节(无 WAV 头)。
  final Uint8List pcm;

  final int sampleRate;

  /// 采样点数。字节数是奇数在本模块里不可能出现(切分器只按整帧产出),
  /// 这里的整除只是防御性写法。
  int get sampleCount => pcm.lengthInBytes ~/ kBytesPerSample;

  /// 音频**自身**的长度,由采样点数推出,而不是 `endedAt - startedAt`。
  ///
  /// 两者在本模块里等价,但以采样数为准更可靠:它不受墙钟跳变(NTP 校时、
  /// 用户改系统时间、休眠唤醒)影响。
  Duration get duration =>
      Duration(microseconds: sampleCount * 1000000 ~/ sampleRate);

  /// 解回 int16 采样点(小端)。测试与 ASR 前处理会用到。
  Int16List toSamples() => decodePcm16(pcm);

  Utterance copyWith({
    String? speakerIdentity,
    String? speakerName,
    DateTime? startedAt,
    DateTime? endedAt,
    Uint8List? pcm,
    int? sampleRate,
  }) {
    return Utterance(
      speakerIdentity: speakerIdentity ?? this.speakerIdentity,
      speakerName: speakerName ?? this.speakerName,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      pcm: pcm ?? this.pcm,
      sampleRate: sampleRate ?? this.sampleRate,
    );
  }

  /// 相等性刻意**不比较 PCM 内容**,只比较"是哪一段"(说话人 + 时间区间 +
  /// 长度 + 采样率)。理由:逐字节比几百 KB 的音频在热路径上纯属浪费,
  /// 而在本模块的语义里,同一说话人的同一时间区间本来就唯一确定一段音频。
  /// 需要验证字节内容时请直接比较 [pcm](测试里就是这么做的)。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Utterance &&
          other.speakerIdentity == speakerIdentity &&
          other.speakerName == speakerName &&
          other.startedAt == startedAt &&
          other.endedAt == endedAt &&
          other.sampleRate == sampleRate &&
          other.pcm.lengthInBytes == pcm.lengthInBytes;

  @override
  int get hashCode => Object.hash(
    speakerIdentity,
    speakerName,
    startedAt,
    endedAt,
    sampleRate,
    pcm.lengthInBytes,
  );

  @override
  String toString() =>
      'Utterance(speakerIdentity: $speakerIdentity, '
      'speakerName: $speakerName, startedAt: $startedAt, endedAt: $endedAt, '
      'sampleCount: $sampleCount, duration: $duration, '
      'sampleRate: $sampleRate)';
}

/// int16 采样点 -> 小端字节。
///
/// 超出 int16 范围的输入会被**截断**(clamp)而不是回绕:回绕会把一次轻微
/// 过载变成刺耳的爆音,截断只是削顶。正常链路不会越界,这是防御。
Uint8List encodePcm16(List<int> samples) {
  final Uint8List bytes = Uint8List(samples.length * kBytesPerSample);
  final ByteData view = ByteData.sublistView(bytes);
  for (int i = 0; i < samples.length; i++) {
    final int v = samples[i].clamp(-32768, 32767);
    view.setInt16(i * kBytesPerSample, v, Endian.little);
  }
  return bytes;
}

/// 小端字节 -> int16 采样点。尾部落单的奇数字节直接丢弃(不可能凑成一个采样点)。
Int16List decodePcm16(Uint8List bytes) {
  final int count = bytes.lengthInBytes ~/ kBytesPerSample;
  final Int16List out = Int16List(count);
  final ByteData view = ByteData.sublistView(bytes);
  for (int i = 0; i < count; i++) {
    out[i] = view.getInt16(i * kBytesPerSample, Endian.little);
  }
  return out;
}
