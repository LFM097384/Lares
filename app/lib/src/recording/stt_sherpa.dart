/// 本地离线语音识别后端(sherpa-onnx / SenseVoice)。
///
/// ## 为什么默认走本地
/// 常驻语音空间意味着麦克风可能一天开十几个小时。云端按秒计费的模型在这种
/// 场景下成本不可控,而且把朋友间的私密闲聊整段上传给第三方,这件事本身
/// 就不该成为默认行为。本地推理是 0 元、离线可用、数据不出机器的。
///
/// ## 本文件的分层(为了可测性,这个分层是刻意的)
/// 文件顶部的**纯函数**([checkSherpaModelDir]、[pcm16ToFloat32] 等)
/// 完全不触碰 `sherpa_onnx` 的任何类型,因此可以在 `flutter test` 的纯 VM 里
/// 直接调用并断言。而真正的识别器构造被藏在 [SherpaSttBackend] 的**惰性初始化**
/// 里 —— `sherpa_onnx` 是 FFI 插件,它的原生 DLL 在 `flutter test` 的 VM 中
/// 根本加载不了(没有 Flutter engine 宿主进程去 dlopen)。
/// 所以单测只覆盖前者,后者只能靠真机/桌面端手工验证。这一点在报告里如实说明,
/// 不要因为"测试全绿"就以为推理路径被验证过了。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'stt_backend.dart';
// SttUnavailableException 定义在选择层:两个后端实现都要抛它,而它们彼此
// 不能互相 import(否则 http 会被拖进本地后端、sherpa 会被拖进云端后端)。
import 'stt_registry.dart';
import 'transcript_store.dart';
import 'utterance.dart';

/// 写进每条 [TranscriptSegment.backend] 的标识。
///
/// 落进每一行是为了将来换引擎后还能分辨历史数据出自谁 —— 同一份转写稿里
/// 混着本地和云端的结果时,质量对比才有依据。
const String kSherpaBackendId = 'sherpa-onnx';

/// 模型权重文件名。int8 量化版本:228 MB,相对 fp32 的精度损失在中文会话
/// 场景下听不出来,但内存占用和首次加载时间都砍掉一大截。
const String kSherpaModelFileName = 'model.int8.onnx';

/// 词表文件名。**没有它模型完全无法工作** —— 解码出来的是 token id,
/// 没有词表就翻不成汉字。半解压的压缩包最典型的症状就是缺这个小文件。
const String kSherpaTokensFileName = 'tokens.txt';

/// 模型下载地址(约 228 MB 的 tar.bz2)。
///
/// **模型刻意不打进安装包**:228 MB 会让 App 体积膨胀到无法接受,而且
/// 相当比例的用户根本不需要转写。做成按需下载,没下载时 App 照常通话录音。
const String kSherpaModelDownloadUrl =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
    'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2';

/// int16 满量程的**绝对值下界**,用作归一化除数。
///
/// 这里有个人人都写错、但几乎没人解释的不对称:int16 的范围是
/// `[-32768, 32767]`,负半轴比正半轴多一格。除以 32768 时,-32768 恰好
/// 映射到 -1.0,而 +32767 只能到 0.99997 —— 正半轴永远差那么一点点够不到 1.0。
/// 除以 32767 则相反:+32767 到 1.0,而 -32768 会溢出到 -1.000031。
///
/// 选 32768 是因为**宁可差一个 LSB 也不要越界**:下游声学特征提取对
/// 超出 [-1, 1] 的输入行为未定义,而 0.99997 与 1.0 的差异在 16 bit 量化
/// 噪声之下,对识别结果毫无影响。这是业界(含 sherpa-onnx 官方示例)的通行做法。
const double kInt16FullScale = 32768.0;

/// int16 小端 PCM 裸字节 → 归一化到 `[-1, 1]` 的 Float32。
///
/// 解码复用 [decodePcm16](统一字节序处理,不在这里重造轮子),
/// 只负责归一化这一步。
Float32List pcm16ToFloat32(Uint8List pcm) =>
    samplesToFloat32(decodePcm16(pcm));

/// int16 采样点 → 归一化到 `[-1, 1]` 的 Float32。
///
/// 结果**保证**落在 `[-1.0, 1.0]` 闭区间内:见 [kInt16FullScale] 的说明,
/// 除以 32768 时最小值 -32768 正好等于 -1.0,不可能越界。
Float32List samplesToFloat32(Int16List samples) {
  final Float32List out = Float32List(samples.length);
  for (int i = 0; i < samples.length; i++) {
    out[i] = samples[i] / kInt16FullScale;
  }
  return out;
}

/// 检查模型目录是否是一份**完整可用**的 SenseVoice 模型。
///
/// 纯函数 + 只用 `dart:io`,不碰 `sherpa_onnx` 任何类型,因此可在纯 VM 测试里
/// 对着临时目录直接跑。
///
/// 刻意检查**两个**文件而不是只看目录在不在:
/// "tar.bz2 解压到一半被用户关掉 / 磁盘写满" 是真实且高频的失败模式,
/// 此时目录存在、`model.int8.onnx`(先解压的大文件)可能也存在,
/// 但 `tokens.txt` 缺席。只查目录会一路走到 FFI 里抛一个英文的
/// `Failed to load model`,用户完全看不懂。在这里拦下来,给中文提示。
///
/// 注意:这里**只做路径校验,不试加载模型**。真正的加载要几秒 + 几百 MB 内存,
/// 不适合放在"进房时查一下"这种高频路径上;损坏的模型只能等到首次识别时
/// 才会暴露,那时返回 [SttUnavailableReason.modelInvalid]。
SttAvailability checkSherpaModelDir(String? dir) {
  if (dir == null || dir.trim().isEmpty) {
    return SttAvailability(
      ready: false,
      reason: SttUnavailableReason.modelMissing,
      message: '未配置本地语音模型目录,转写功能暂不可用(通话与录音不受影响)',
      remedy: sherpaModelRemedy(null),
      modelPath: null,
    );
  }

  final String path = dir.trim();
  if (!Directory(path).existsSync()) {
    return SttAvailability(
      ready: false,
      reason: SttUnavailableReason.modelMissing,
      message: '本地语音模型目录不存在,转写功能暂不可用(通话与录音不受影响)',
      remedy: sherpaModelRemedy(path),
      modelPath: path,
    );
  }

  final List<String> missing = <String>[
    for (final String name in <String>[
      kSherpaModelFileName,
      kSherpaTokensFileName,
    ])
      if (!File('$path${Platform.pathSeparator}$name').existsSync()) name,
  ];

  if (missing.isNotEmpty) {
    return SttAvailability(
      ready: false,
      reason: SttUnavailableReason.modelMissing,
      message:
          '本地语音模型不完整,缺少 ${missing.join("、")}'
          '(压缩包可能没解压完),转写功能暂不可用',
      remedy: sherpaModelRemedy(path),
      modelPath: path,
    );
  }

  return const SttAvailability.ready(backend: '本地离线识别');
}

/// 生成"怎么办"的中文补救文案。
///
/// 单独抽出来而不是内联拼串,是因为四个失败分支要给出**同一份**指引:
/// 分散写必然会写出四个措辞不一致的版本,用户拿到哪一版全看运气。
/// 文案里带上完整下载地址与两个文件名,用户/客服可以照着一步步核对。
String sherpaModelRemedy(String? expectedPath) {
  final StringBuffer buf = StringBuffer()
    ..write('请到「设置 - 语音识别」下载离线模型;')
    ..write('也可手动从 $kSherpaModelDownloadUrl 下载并解压,')
    ..write('解压后目录内需同时存在 $kSherpaModelFileName 与 $kSherpaTokensFileName');
  if (expectedPath != null && expectedPath.isNotEmpty) {
    buf.write('。当前配置的目录为:$expectedPath');
  }
  return buf.toString();
}

/// 本地 sherpa-onnx 识别后端。
///
/// ## 生命周期(这是使用本类最容易踩的地方)
/// [OfflineRecognizer](内部持有)构造一次要加载 228 MB 权重,耗时几秒;
/// 而 `OfflineStream` 是极廉价的每次一用的对象。所以:
/// **识别器全局一个、长期存活;流每段音频新建一个、用完必须 free。**
/// 把这个关系搞反(每段音频重建识别器)会让转写慢到完全不可用。
///
/// 因此本类**持有原生资源**,用完必须调用 [dispose];否则原生侧的
/// 几百 MB 不会随 Dart 对象被 GC 回收(FFI 指针不受 Dart GC 管辖)。
class SherpaSttBackend implements SttBackend {
  /// [modelDir] 来自设置,**绝不硬编码、绝不打包内置**。
  ///
  /// 构造函数刻意什么重活都不干:既不调 `initBindings()` 也不建识别器。
  /// 理由是 App 启动时就会把本后端注册进 [SttBackend] 列表,而绝大多数
  /// 用户根本没下模型 —— 如果构造即加载,那"仅仅注册一下"就要付出几秒
  /// 卡顿加几百 MB 内存,完全是白扔。真正的初始化推迟到第一次 [transcribe]。
  SherpaSttBackend({
    this.modelDir,
    this.language = '',
    this.numThreads = 2,
    this.provider = 'cpu',
  }) : assert(numThreads > 0, '线程数必须为正');

  /// 模型所在目录(需含 [kSherpaModelFileName] 与 [kSherpaTokensFileName])。
  /// null 表示用户还没下载模型 —— 这是**正常状态**,不是错误。
  final String? modelDir;

  /// 识别语言。`''` = 自动判别;也可指定 `'zh'` / `'en'` / `'ja'` / `'ko'` / `'yue'`。
  ///
  /// 默认留空是因为本应用的小圈子里中英夹杂是常态("这个 PR 我 review 一下"),
  /// 锁死单一语言反而会把夹杂的另一种语言识别成同音乱码。
  final String language;

  /// 推理线程数。默认 2 是保守值:本应用是**常驻后台**的,识别不该和
  /// 前台的通话、UI 抢 CPU。调到 8 确实更快,但会让语音通话开始爆音。
  final int numThreads;

  /// 推理后端,`'cpu'`。刻意不默认开 GPU:桌面端 GPU provider 依赖
  /// CUDA/DirectML 运行时,缺库时是原生层直接崩溃而不是优雅回落。
  final String provider;

  /// 惰性构造的识别器。null = 还没初始化过(或已 [dispose])。
  sherpa_onnx.OfflineRecognizer? _recognizer;

  /// 初始化失败的**粘性**结果。
  ///
  /// 记住失败是必要的:模型损坏时每段语音都去重试加载 228 MB,只会让
  /// App 卡死在无谓的重试上。失败一次就记住,直到 [dispose] 重置。
  SttAvailability? _initFailure;

  /// 本进程(严格说是本 isolate)是否已调用过 `initBindings()`。
  ///
  /// ⚠️ **`initBindings()` 是 per-isolate 的**:在主 isolate 调过,
  /// 不等于 worker isolate 里就能用 —— 后者会在第一次 FFI 调用时抛
  /// `Please initialize sherpa-onnx first`。将来如果把识别挪到后台 isolate,
  /// 那个 isolate 里必须**再调一次**。这个静态标志只对当前 isolate 有意义,
  /// 跨 isolate 时它甚至不共享(每个 isolate 有各自的静态变量副本),
  /// 这恰好是我们想要的语义。
  static bool _bindingsReady = false;

  /// 逐轨后端:说话人身份来自 LiveKit 的轨,不来自模型。
  ///
  /// SenseVoice 本身**没有**说话人分离能力,而我们也根本不需要它:
  /// LiveKit 把每个参与者的麦克风放在独立的轨上,谁在说话在音频进入
  /// 识别器之前就是 100% 确定的。任何声纹算法的准确率都比不过这个。
  @override
  bool get supportsDiarization => false;

  /// 用的是 **Offline**(非流式)识别器,只能整段送、整段出。
  ///
  /// 诚实地写 false,而不是"反正上层会整段调用所以填 true 也没差"。
  /// SenseVoice 是非自回归的整段模型,天然没有部分结果可言;
  /// 想要边说边出字得换 OnlineRecognizer + 流式模型,是另一套权重。
  @override
  bool get supportsStreaming => false;

  @override
  Future<SttAvailability> checkAvailability() async {
    // 已经确诊过的初始化失败优先返回 —— 路径检查通过不代表模型能加载。
    final SttAvailability? failure = _initFailure;
    if (failure != null) return failure;
    return checkSherpaModelDir(modelDir);
  }

  @override
  Stream<TranscriptSegment> transcribe(AudioSource src) async* {
    final SttAvailability availability = await checkAvailability();
    if (!availability.ready) {
      // 契约第 4 条:未就绪时也**不允许崩溃**,抛一个带中文说明的错误即可。
      // 上层据此静默跳过转写,通话与录音完全不受影响。
      throw SttUnavailableException(availability);
    }

    if (src.channels != 1) {
      throw SttUnavailableException(
        SttAvailability(
          ready: false,
          reason: SttUnavailableReason.unknown,
          message: '本地识别只支持单声道音频,收到 ${src.channels} 声道',
          remedy: '请在采集端降混为单声道后再送入识别',
        ),
      );
    }

    final sherpa_onnx.OfflineRecognizer recognizer = _ensureRecognizer();
    final Float32List samples = pcm16ToFloat32(src.pcm);

    // 空音频直接收工:喂 0 个采样点给原生层行为未定义,别赌。
    if (samples.isEmpty) return;

    final sherpa_onnx.OfflineStream stream = recognizer.createStream();
    final String text;
    try {
      stream.acceptWaveform(samples: samples, sampleRate: src.sampleRate);
      recognizer.decode(stream);
      text = recognizer.getResult(stream).text.trim();
    } finally {
      // ⚠️ 是 `free()` 不是 `dispose()`,而且**必须**放在 finally 里:
      // 解码中途抛异常时如果漏掉这一句,原生侧的流对象就永久泄漏了
      // (Dart GC 管不到 FFI 指针)。一次通话里这种流有成千上万个。
      stream.free();
    }

    // 静音段/纯噪声会解出空串。这不是错误,只是"没识别出内容",
    // 静默不产出即可 —— 往转写稿里塞空行只会污染导出的 Markdown。
    if (text.isEmpty) return;

    yield TranscriptSegment(
      startedAt: src.startedAt,
      endedAt: src.endedAt,
      // 逐轨后端的核心契约:identity / name 原样回声,一个字都不改。
      speakerIdentity: src.speakerIdentity,
      speakerName: src.speakerName,
      text: text,
      backend: kSherpaBackendId,
      // SenseVoice 不给出整句置信度。**不伪造** `1.0` ——
      // 那会让"不知道"看起来像"很确定",是对下游最恶劣的误导。
      confidence: null,
    );
  }

  /// 惰性构造识别器。首次调用会加载 228 MB 权重,耗时几秒。
  sherpa_onnx.OfflineRecognizer _ensureRecognizer() {
    final sherpa_onnx.OfflineRecognizer? existing = _recognizer;
    if (existing != null) return existing;

    final String dir = modelDir!.trim();
    try {
      if (!_bindingsReady) {
        // per-isolate:见 [_bindingsReady] 的说明。
        sherpa_onnx.initBindings();
        _bindingsReady = true;
      }

      final String sep = Platform.pathSeparator;
      final sherpa_onnx.OfflineModelConfig modelConfig =
          sherpa_onnx.OfflineModelConfig(
            senseVoice: sherpa_onnx.OfflineSenseVoiceModelConfig(
              model: '$dir$sep$kSherpaModelFileName',
              language: language,
              // 逆文本归一化:把"二零二五年"写成"2025 年"、"百分之三十"
              // 写成"30%"。转写稿是给人读的,阿拉伯数字可读性高得多。
              useInverseTextNormalization: true,
            ),
            tokens: '$dir$sep$kSherpaTokensFileName',
            numThreads: numThreads,
            provider: provider,
            // ⚠️ 这个包的 `debug` 默认值是 **true**(不是 false),
            // 不显式关掉的话原生层会往 stdout 刷满配置转储,
            // 在常驻应用里会把日志彻底淹掉。必须显式传 false。
            debug: false,
            // `modelType` 刻意留空:C++ 侧会根据"哪个子配置被填了"
            // 自动判定模型种类。这里**不要**自作聪明填 'sense_voice'
            // 之类的字面量 —— 那个字符串的合法取值由 C++ 侧的
            // 内部映射表决定,跨版本可能变,猜错会直接加载失败。
            // 留空走自动探测才是官方示例的做法。
          );

      final sherpa_onnx.OfflineRecognizer created =
          sherpa_onnx.OfflineRecognizer(
            sherpa_onnx.OfflineRecognizerConfig(model: modelConfig),
          );
      _recognizer = created;
      return created;
    } catch (e) {
      // 加载失败(模型损坏、版本不匹配、原生库缺失)一律转成可展示的
      // 中文可用性状态并**粘住**,避免每段语音都重试一次 228 MB 的加载。
      final SttAvailability failure = SttAvailability(
        ready: false,
        reason: SttUnavailableReason.modelInvalid,
        message: '本地语音模型加载失败,转写功能暂不可用(通话与录音不受影响)',
        remedy: '模型文件可能已损坏或版本不匹配,请到「设置 - 语音识别」重新下载',
        modelPath: dir,
      );
      _initFailure = failure;
      throw SttUnavailableException(failure, cause: e);
    }
  }

  /// 释放原生识别器(228 MB 量级)。
  ///
  /// **必须显式调用**:`_recognizer` 背后是 FFI 指针,Dart GC 回收不了它。
  /// 幂等,重复调用安全。调用后 [_initFailure] 一并清空,下次使用会重新尝试加载 ——
  /// 这正是"用户重新下载完模型后无需重启 App"所依赖的行为。
  void dispose() {
    _recognizer?.free();
    _recognizer = null;
    _initFailure = null;
  }
}
