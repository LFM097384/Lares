/// STT 后端的**纯契约**:接口 + 值类型,零实现。
///
/// 本文件刻意不 import `http`、不 import `sherpa_onnx`、不碰任何平台代码。
/// 它是 UI 层与识别实现之间唯一的边界:换引擎(本地 sherpa-onnx → 云端 API →
/// 将来的分离后端)时,调用点一行都不用改。实现放在别处。
library;

// 只用 foundation 的 @immutable 注解(纯值语义标记),不引入任何平台通道依赖。
// 未选用 package:meta 是因为它不是本包的直接依赖(depend_on_referenced_packages)。
import 'package:flutter/foundation.dart';

import 'transcript_store.dart';
import 'utterance.dart';

/// 喂给 STT 的一段音频 + 它的**归属信息**。
///
/// ## 两种后端模式(本类的核心设计)
///
/// **逐轨后端**(当前唯一实现的模式,`supportsDiarization == false`):
/// LiveKit 天然把每个参与者的麦克风放在**各自独立的轨**上。谁在说话这件事
/// 在音频进入识别器之前就已经是确定的 —— 它来自轨的 participant identity,
/// 不需要任何算法去猜。所以 [speakerIdentity] / [speakerName] 由调用方
/// (LiveKit 集成层)填好传进来,后端**原样回声**到它产出的每一条
/// [TranscriptSegment] 里。这种模式的说话人准确率是 100%,任何声纹分离
/// 算法都比不了。
///
/// **分离后端**(未来可能,`supportsDiarization == true`):
/// 如果哪天要处理一路混音(比如会议室里一支麦克风录了五个人),就需要后端
/// 自己做说话人分离。那种后端会**忽略**这里传入的 identity,自行输出
/// `spk_0` / `spk_1` 之类由厂商定义的标识。
///
/// 两种模式共用同一个 [AudioSource] 与同一个 [SttBackend.transcribe] 签名,
/// 差别只体现在 [SttBackend.supportsDiarization] 这个布尔上。因此调用点
/// 永远是同一句 `backend.transcribe(src)`;需要区分时读那个布尔即可 ——
/// 加一个分离后端不需要动任何调用点。
@immutable
class AudioSource {
  const AudioSource({
    required this.pcm,
    required this.startedAt,
    required this.speakerIdentity,
    required this.speakerName,
    this.sampleRate = kPcmSampleRate,
    this.channels = 1,
  }) : assert(sampleRate > 0, '采样率必须为正'),
       assert(channels > 0, '声道数必须为正');

  /// 从 VAD 切好的一段语音构造。这是实际链路上唯一的构造方式。
  factory AudioSource.fromUtterance(Utterance u) => AudioSource(
    pcm: u.pcm,
    startedAt: u.startedAt,
    speakerIdentity: u.speakerIdentity,
    speakerName: u.speakerName,
    sampleRate: u.sampleRate,
  );

  /// int16 **小端** PCM 裸字节(无 WAV 头)。
  final Uint8List pcm;

  final int sampleRate;

  /// 声道数。链路上恒为 1(单声道)——
  /// 字段仍然存在是因为"当前只支持单声道"必须是一个**可检查的断言**,
  /// 而不是一条散落在注释里的口头约定;实现可以据此拒绝它处理不了的输入。
  final int channels;

  /// 这段音频第一个采样点的绝对时刻。后端把识别结果的相对偏移加到它上面,
  /// 就得到可以跨轨对齐的绝对时间戳。
  final DateTime startedAt;

  /// 归属:说话人主键。逐轨后端原样回声,分离后端忽略它。
  final String speakerIdentity;

  /// 归属:显示名。同上。
  final String speakerName;

  int get sampleCount => pcm.lengthInBytes ~/ kBytesPerSample ~/ channels;

  Duration get duration =>
      Duration(microseconds: sampleCount * 1000000 ~/ sampleRate);

  /// 结束时刻,由音频长度推出。
  DateTime get endedAt => startedAt.add(duration);

  AudioSource copyWith({
    Uint8List? pcm,
    int? sampleRate,
    int? channels,
    DateTime? startedAt,
    String? speakerIdentity,
    String? speakerName,
  }) {
    return AudioSource(
      pcm: pcm ?? this.pcm,
      sampleRate: sampleRate ?? this.sampleRate,
      channels: channels ?? this.channels,
      startedAt: startedAt ?? this.startedAt,
      speakerIdentity: speakerIdentity ?? this.speakerIdentity,
      speakerName: speakerName ?? this.speakerName,
    );
  }

  /// 与 [Utterance] 同理:不逐字节比 PCM,只比"是哪一段"。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioSource &&
          other.sampleRate == sampleRate &&
          other.channels == channels &&
          other.startedAt == startedAt &&
          other.speakerIdentity == speakerIdentity &&
          other.speakerName == speakerName &&
          other.pcm.lengthInBytes == pcm.lengthInBytes;

  @override
  int get hashCode => Object.hash(
    sampleRate,
    channels,
    startedAt,
    speakerIdentity,
    speakerName,
    pcm.lengthInBytes,
  );

  @override
  String toString() =>
      'AudioSource(sampleRate: $sampleRate, channels: $channels, '
      'startedAt: $startedAt, speakerIdentity: $speakerIdentity, '
      'speakerName: $speakerName, sampleCount: $sampleCount)';
}

/// 后端为什么不可用。UI 据此决定"引导用户做什么"。
enum SttUnavailableReason {
  /// 可用,没有问题。
  none,

  /// 本地模型文件不存在(最常见:用户装了 App 但没下模型)。
  modelMissing,

  /// 模型文件在,但损坏/版本不匹配,加载失败。
  modelInvalid,

  /// 本平台没有对应的原生库(例如某些架构没有预编译二进制)。
  unsupportedPlatform,

  /// 需要网络的后端当前离线。
  offline,

  /// 后端本身没坏,只是缺少用户必须自己提供的配置(最典型:云端 API Key 没填)。
  ///
  /// 与 [offline] 严格区分:网络可能好得很,问题出在"没配"而不是"连不上"。
  /// 混用会让 UI 给出南辕北辙的引导 —— 用户被告知"检查网络连接",
  /// 而他真正该做的是去设置页填一个 key,查半天网也查不出所以然。
  notConfigured,

  /// 用户在设置里主动关掉了语音识别。
  disabledByUser,

  /// 其他未归类的失败。
  unknown,
}

/// 后端可用性。
///
/// 这是接口的**一等公民**而不是事后补丁:本应用必须在没有本地模型时
/// 照常工作(照常通话、照常录音),只是不出转写。如果可用性只体现为
/// "调用 transcribe 时抛异常",那每个调用点都得自己 try/catch 再自己
/// 编一句中文提示,必然编得五花八门。所以把"能不能用 + 为什么 + 怎么办"
/// 做成一个值对象,UI 直接展示。
@immutable
class SttAvailability {
  const SttAvailability({
    required this.ready,
    required this.reason,
    required this.message,
    this.remedy,
    this.modelPath,
    this.backendLabel = '',
  });

  /// 就绪。[backend] 是给用户看的后端名(如「本地离线识别」)。
  ///
  /// 这里刻意**不**把 [backend] 拼进 [message]:const 初始化列表里不允许对
  /// 参数做条件表达式或字符串插值(invalid_constant,而且报错点会落在调用方的
  /// `const SttAvailability.ready(...)` 上,极难定位)。保住 `const` 更要紧,
  /// 所以后端名单独存进 [backendLabel],由 UI 自己决定怎么拼。
  const SttAvailability.ready({String backend = ''})
    : ready = true,
      reason = SttUnavailableReason.none,
      message = '语音识别已就绪',
      backendLabel = backend,
      remedy = null,
      modelPath = null;

  /// 模型缺失。[expectedPath] 写进提示里,用户/客服能照着去找。
  const SttAvailability.modelMissing({String? expectedPath})
    : ready = false,
      reason = SttUnavailableReason.modelMissing,
      message = '未安装本地语音模型,转写功能暂不可用(通话与录音不受影响)',
      remedy = '到「设置 - 语音识别」下载离线模型后即可自动启用',
      backendLabel = '',
      modelPath = expectedPath;

  /// 缺少用户必须自己提供的配置(最典型:云端识别的 API Key 没填)。
  ///
  /// 与"离线"分开的理由见 [SttUnavailableReason.notConfigured]:这不是故障,
  /// 而是一件用户去设置页填一行字就能解决的事,提示必须直接指向那里。
  ///
  /// [backend] 是给用户看的后端名(如「云端识别」),同样**不**拼进 [message] ——
  /// const 初始化列表里不允许对参数做字符串插值(invalid_constant,且报错点会
  /// 落在调用方那一行,极难定位)。理由与 [SttAvailability.ready] 完全一致。
  const SttAvailability.notConfigured({String backend = ''})
    : ready = false,
      reason = SttUnavailableReason.notConfigured,
      message = '尚未完成配置,转写功能暂不可用(通话与录音不受影响)',
      remedy = '到「设置 - 语音识别」填写所需配置后即可自动启用',
      backendLabel = backend,
      modelPath = null;

  /// 用户主动关闭。
  const SttAvailability.disabledByUser()
    : ready = false,
      reason = SttUnavailableReason.disabledByUser,
      message = '语音识别已被关闭',
      remedy = '到「设置 - 语音识别」重新打开',
      backendLabel = '',
      modelPath = null;

  /// 是否可以调用 [SttBackend.transcribe]。false 时调用方应当**静默跳过**转写,
  /// 而不是弹错误 —— 没有模型是一种正常状态,不是故障。
  final bool ready;

  final SttUnavailableReason reason;

  /// 给用户看的中文说明(一句话,可直接当设置页副标题)。
  final String message;

  /// 给用户看的中文补救办法。没有可行补救时为 null。
  final String? remedy;

  /// 期望的模型路径(仅在与路径相关的失败时有值),便于排查。
  final String? modelPath;

  /// 给用户看的后端名(如「本地离线识别」)。未提供时为空串。
  /// 与 [message] 分开存,理由见 [SttAvailability.ready]。
  final String backendLabel;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SttAvailability &&
          other.ready == ready &&
          other.reason == reason &&
          other.message == message &&
          other.remedy == remedy &&
          other.modelPath == modelPath &&
          other.backendLabel == backendLabel;

  @override
  int get hashCode =>
      Object.hash(ready, reason, message, remedy, modelPath, backendLabel);

  @override
  String toString() =>
      'SttAvailability(ready: $ready, reason: $reason, message: $message, '
      'remedy: $remedy, modelPath: $modelPath, backendLabel: $backendLabel)';
}

/// 后端不可用时从 [SttBackend.transcribe] 抛出的异常。
///
/// **为什么放在这个契约文件里**:它是接口契约的一部分 —— 契约第 2、4 条明确
/// 要求实现方"通过错误通道抛出带说明的错误",那这个错误类型本身就该和
/// [SttAvailability] 并排放在定义契约的地方,而不是放在选择层。
///
/// 放进选择层(`stt_registry.dart`)是行不通的:那会让**具体后端反过来依赖
/// 挑选它们的那一层**,依赖方向整个倒置 —— 本地 / 云端后端只该认识契约,
/// 不该认识注册表。而放进任一后端实现里更糟:两个实现都要抛它,谁放谁那边
/// 都会逼另一边 import 过去,于是 `sherpa_onnx` 被拖进云端后端的依赖图、
/// `http` 被拖进本地后端的依赖图,两边的可测性一起完蛋。
/// 契约文件零平台依赖,是唯一既不倒置方向、也不污染依赖图的位置。
///
/// 携带完整的 [SttAvailability] 而不是一句光秃秃的字符串:调用点拿到它
/// 既能直接展示中文原因,又能读 [SttAvailability.reason] 做分支
/// (比如「模型缺失」引导去下载页,「用户关闭」则干脆什么都不提示)。
class SttUnavailableException implements Exception {
  const SttUnavailableException(this.availability, {this.cause});

  final SttAvailability availability;

  /// 底层原因(如 FFI / HTTP 抛出的原始异常),**仅用于排查日志**,
  /// 不要直接展示给用户 —— 它可能含有英文栈信息之类的噪声。
  final Object? cause;

  /// 给用户看的中文说明,等同于 `availability.message`。
  String get message => availability.message;

  @override
  String toString() => 'SttUnavailableException(${availability.message})';
}

/// 可插拔的语音识别后端。
///
/// 实现方须遵守的契约:
/// 1. [transcribe] 返回的流在识别完成后**必须**正常关闭(否则上层会一直挂着);
/// 2. 识别失败时通过流的 error 通道抛出,不要静默返回空流 ——
///    "没识别出内容"和"识别失败了"对用户是两件事;
/// 3. `supportsDiarization == false` 的实现**必须**把 [AudioSource] 里的
///    identity/name 原样写进每一条 [TranscriptSegment];
/// 4. 即使 [checkAvailability] 返回未就绪,[transcribe] 也不应该崩溃 ——
///    抛一个带说明的错误即可。
abstract class SttBackend {
  /// 后端是否自带说话人分离。逐轨后端一律 false。
  bool get supportsDiarization;

  /// 是否支持边收音边出字(部分结果)。false 表示只能整段送、整段出。
  bool get supportsStreaming;

  /// 识别一段音频。
  ///
  /// 返回流而非 Future:流式后端会在识别过程中吐出多条中间/分句结果;
  /// 非流式后端就在末尾 yield 一条再关流 —— 调用点写法完全一致。
  Stream<TranscriptSegment> transcribe(AudioSource src);

  /// 当前是否可用。UI 在进房时与设置页里各查一次。
  ///
  /// 做成 Future 是因为真实实现要摸文件系统(模型在不在)甚至试加载一次,
  /// 这不该在 UI 线程上同步做。
  Future<SttAvailability> checkAvailability();
}
