/// 云端语音识别后端(Groq / Whisper large-v3-turbo)。
///
/// ## 定位:兜底,不是默认
/// 本应用默认走本地 sherpa-onnx(0 元、离线、隐私)。云端只在两种情况下用:
/// 用户没装本地模型但又想要转写,或者他明确觉得云端质量值得那点钱。
/// 因此本后端的每一处默认值都倾向**保守**:没填 key 就报不可用,
/// 短音频默认拒绝(见 [kGroqMinBillableChunk] 的计费陷阱),绝不擅自发请求。
///
/// ## 可测性
/// [http.Client] 由构造函数注入,测试传 `package:http/testing.dart` 的
/// `MockClient` 即可在纯 VM 里跑完整条路径(含错误分支),一个字节都不上网。
/// 那个包随 `http` 一起发布,不需要新增依赖。
/// WAV 封装 [buildWavFile] 是纯函数,单独可测。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

// SttAvailability 与 SttUnavailableException 都来自这份纯契约:本后端只依赖
// 契约,**不**依赖挑选后端的 stt_registry.dart —— 否则依赖方向就倒过来了。
import 'stt_backend.dart';
import 'transcript_store.dart';
import 'utterance.dart';

/// 写进每条 [TranscriptSegment.backend] 的标识。
const String kGroqBackendId = 'groq-whisper';

/// Groq 的 OpenAI 兼容转写端点。
const String kGroqTranscriptionUrl =
    'https://api.groq.com/openai/v1/audio/transcriptions';

/// 默认模型。turbo 版在中文上质量与 large-v3 接近,但快好几倍、便宜不少。
const String kGroqDefaultModel = 'whisper-large-v3-turbo';

/// ⚠️ **计费陷阱:Groq 每次请求按 10 秒起步计费。**
///
/// 这条不是性能优化,是真金白银:VAD 切出来的句子中位数大约 3 秒,
/// 而 3 秒的请求和 10 秒的请求**收一样的钱**。逐句上传等于把账单乘以
/// 10/3 ≈ 3.3 倍,而且用户完全看不见这笔浪费 —— 他只会在月底发现
/// 账单比预期多了两倍多,还找不到原因。
///
/// 所以本后端的默认策略是:**短于本阈值的音频直接拒绝**
/// ([GroqShortChunkPolicy.reject]),由上层把多个短句攒够 10 秒再送。
/// 想要低延迟、不在乎钱的用户可以显式切到
/// [GroqShortChunkPolicy.sendAnyway] —— 但那必须是他**主动**选的,
/// 而不是我们替他默认好的。
const Duration kGroqMinBillableChunk = Duration(seconds: 10);

/// 默认请求超时。
///
/// 30 秒是给"10 秒音频 + 上传 + 推理"留的宽裕余量。不设超时是绝对不行的:
/// 移动网络下 TCP 连接可以挂死好几分钟,而本应用是常驻的,挂死的请求会
/// 一个个堆积起来,最后把 socket 和内存一起吃干净。
const Duration kGroqDefaultTimeout = Duration(seconds: 30);

/// 不足 [kGroqMinBillableChunk] 的音频怎么处理。
enum GroqShortChunkPolicy {
  /// **默认**:拒绝,抛出带中文说明的 [SttUnavailableException]。
  ///
  /// 选"拒绝"而不是"在后端内部缓冲攒够再发",是因为缓冲会破坏
  /// [AudioSource] 的归属语义 —— 攒起来的几段可能来自**不同说话人**
  /// (逐轨模式下每条轨各自 VAD),硬拼成一个请求就把说话人搞混了,
  /// 而说话人准确正是本架构最核心的卖点。真要合并,必须由上层
  /// 按说话人分别攒,那是上层才有的信息,后端里做不了。
  reject,

  /// 照发不误,接受 3.3 倍的计费溢价。只应由用户显式选择。
  sendAnyway,
}

/// 手写一个最小 WAV 文件(44 字节头 + PCM 数据)。
///
/// **为什么必须包 WAV**:Whisper 系列端点要求上传的是可识别的音频**文件**,
/// 裸 PCM 传上去会被判为无法解码的格式直接 400。我们手里的是无头 PCM,
/// 所以得自己补头。
///
/// **为什么手写而不是拉个库**:44 字节的固定结构而已,为它引入一个依赖
/// 不划算;而且 canonical WAV 头的每个字段偏移都是死的,写一次测一次就永久正确。
///
/// 头部布局(全部**小端**,唯独四个 ASCII magic 是按字节原样写的):
/// ```
/// 偏移 0  'RIFF'                     4 字节 ASCII
/// 偏移 4  chunkSize = 36 + dataLen   uint32  ← 整个文件大小减去前 8 字节
/// 偏移 8  'WAVE'                     4 字节 ASCII
/// 偏移 12 'fmt '                     4 字节 ASCII(注意末尾那个**空格**)
/// 偏移 16 subchunk1Size = 16         uint32  ← PCM 固定 16
/// 偏移 20 audioFormat = 1            uint16  ← 1 = 无压缩 PCM
/// 偏移 22 numChannels                uint16
/// 偏移 24 sampleRate                 uint32
/// 偏移 28 byteRate                   uint32  ← sampleRate*channels*bits/8
/// 偏移 32 blockAlign                 uint16  ← channels*bits/8
/// 偏移 34 bitsPerSample              uint16
/// 偏移 36 'data'                     4 字节 ASCII
/// 偏移 40 dataLen                    uint32  ← 纯样本字节数,**不含**这 44 字节
/// 偏移 44 <PCM 数据>
/// ```
/// 最容易写错的两处:`chunkSize` 写成了整个文件长度(应当再减 8),
/// 以及 `'fmt '` 漏掉末尾空格(变成 3 字节,后面所有偏移全体错位)。
Uint8List buildWavFile(
  Uint8List pcm, {
  int sampleRate = kPcmSampleRate,
  int channels = 1,
  int bitsPerSample = 16,
}) {
  final int dataLen = pcm.lengthInBytes;
  final Uint8List out = Uint8List(kWavHeaderSize + dataLen);
  final ByteData view = ByteData.sublistView(out);

  void writeAscii(int offset, String tag) {
    for (int i = 0; i < tag.length; i++) {
      view.setUint8(offset + i, tag.codeUnitAt(i));
    }
  }

  writeAscii(0, 'RIFF');
  // 减 8:'RIFF' 这 4 字节和它自己这 4 字节不计入 chunkSize。
  view.setUint32(4, kWavHeaderSize - 8 + dataLen, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt '); // ← 末尾空格是规范的一部分,不是笔误
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little); // 1 = PCM,无压缩
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(
    28,
    sampleRate * channels * bitsPerSample ~/ 8,
    Endian.little,
  );
  view.setUint16(32, channels * bitsPerSample ~/ 8, Endian.little);
  view.setUint16(34, bitsPerSample, Endian.little);
  writeAscii(36, 'data');
  view.setUint32(40, dataLen, Endian.little);

  out.setRange(kWavHeaderSize, kWavHeaderSize + dataLen, pcm);
  return out;
}

/// canonical PCM WAV 的头长度。非 PCM 或带额外 chunk 的 WAV 会更长,
/// 但我们只生产这一种,所以是个确定的常量。
const int kWavHeaderSize = 44;

/// Groq 云端识别后端。
///
/// ## API Key 处理原则(安全要求,不是建议)
/// key 从设置注入,**绝不硬编码、绝不写日志、绝不进任何错误消息**。
/// 本类里唯一读 [apiKey] 的地方是构造 `Authorization` 请求头那一行;
/// 所有 catch 分支只使用状态码和响应体片段,**从不回显请求头** ——
/// 把 headers 塞进异常消息是泄漏 key 最常见的方式,而错误消息往往会被
/// 原样写进崩溃日志甚至上报给第三方。
class GroqSttBackend implements SttBackend {
  GroqSttBackend({
    required this.apiKey,
    http.Client? client,
    this.model = kGroqDefaultModel,
    this.language,
    this.timeout = kGroqDefaultTimeout,
    this.shortChunkPolicy = GroqShortChunkPolicy.reject,
    this.minChunk = kGroqMinBillableChunk,
    this.endpoint = kGroqTranscriptionUrl,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  /// Groq API Key,来自设置。空串表示用户没配置 —— 这是**正常状态**,
  /// [checkAvailability] 会给出中文引导,而不是当成故障。
  final String apiKey;

  final String model;

  /// 提示模型音频是什么语言(ISO-639-1,如 `'zh'`)。null = 让模型自己判。
  /// 中英夹杂的场景下留 null 通常更好,锁死语言反而会把夹杂词识别成同音乱码。
  final String? language;

  final Duration timeout;

  /// 短音频策略,见 [kGroqMinBillableChunk] 的计费说明。
  final GroqShortChunkPolicy shortChunkPolicy;

  /// 计费起步时长,暴露成字段是为了 Groq 改价时不用改代码。
  final Duration minChunk;

  final String endpoint;

  final http.Client _client;

  /// 是不是我们自己 new 的 client。
  ///
  /// 这个标志决定 [dispose] 该不该真的关掉它:注入进来的 client 归调用方
  /// 所有,可能还被别的模块共用,我们擅自 close 会让人家后续请求全部报
  /// "Client is already closed",而且这种 bug 极难定位。
  final bool _ownsClient;

  /// 云端模型也不做说话人分离 —— 说话人来自 LiveKit 的轨,不来自模型。
  /// Whisper 端点压根没有 diarization 这个能力,填 false 既是契约也是事实。
  @override
  bool get supportsDiarization => false;

  /// 这是个**批量**端点:整个文件传上去,一次性拿回全文,
  /// 没有任何中间结果可言。诚实填 false。
  @override
  bool get supportsStreaming => false;

  @override
  Future<SttAvailability> checkAvailability() async {
    if (apiKey.trim().isEmpty) {
      // ⚠️ 归因为 [SttUnavailableReason.notConfigured] 而**不是** `offline`:
      // 没填 key 跟网络状况毫无关系,网可能好得很。报成 `offline` 会让
      // 按 reason 分支的 UI 去劝用户"检查网络连接",而他查到天亮也查不出
      // 问题 —— 真正该做的只是去设置页填一行字。
      return const SttAvailability(
        ready: false,
        reason: SttUnavailableReason.notConfigured,
        message: '未配置云端识别的 API Key,转写功能暂不可用(通话与录音不受影响)',
        remedy: '请到「设置 - 语音识别」填入 Groq API Key',
      );
    }
    // 刻意**不**发探测请求来验证 key 真伪:那要花钱(哪怕探测请求也按
    // 10 秒起步计费)、要等网络,而 checkAvailability 是进房时就会调的高频路径。
    // key 是否有效等到真正转写时由 401 分支去处理。
    return const SttAvailability.ready(backend: '云端识别');
  }

  @override
  Stream<TranscriptSegment> transcribe(AudioSource src) async* {
    final SttAvailability availability = await checkAvailability();
    if (!availability.ready) {
      throw SttUnavailableException(availability);
    }

    if (src.pcm.isEmpty) return;

    // 计费闸门:必须在发请求**之前**拦截,拦晚了钱已经花出去了。
    if (shortChunkPolicy == GroqShortChunkPolicy.reject &&
        src.duration < minChunk) {
      throw SttUnavailableException(
        SttAvailability(
          ready: false,
          reason: SttUnavailableReason.unknown,
          message:
              '音频仅 ${src.duration.inMilliseconds} 毫秒,短于云端计费起步的 '
              '${minChunk.inSeconds} 秒,已跳过以免产生额外费用',
          remedy:
              'Groq 每次请求按 ${minChunk.inSeconds} 秒起步计费,'
              '过短的片段会按整 ${minChunk.inSeconds} 秒收费;'
              '请由上层合并到 ${minChunk.inSeconds} 秒以上再送,'
              '或在设置中改为「不合并直接上传」',
        ),
      );
    }

    final Uint8List wav = buildWavFile(
      src.pcm,
      sampleRate: src.sampleRate,
      channels: src.channels,
    );

    final http.MultipartRequest req =
        http.MultipartRequest('POST', Uri.parse(endpoint))
          // 唯一使用 apiKey 的地方。下面任何错误分支都不会碰 req.headers。
          ..headers['Authorization'] = 'Bearer $apiKey'
          ..fields['model'] = model
          // 只要纯文本:verbose_json 会多回一堆我们用不上的分段信息,
          // 白白增加解析面和出错机会。时间戳我们自己有(来自 VAD 的绝对时刻),
          // 比模型估的准得多。
          ..fields['response_format'] = 'json'
          ..files.add(
            http.MultipartFile.fromBytes(
              'file',
              wav,
              // 文件名必须带 .wav:服务端会据此判断格式,
              // 不带扩展名的话即使字节正确也可能被拒。
              filename: 'audio.wav',
            ),
          );
    final String? lang = language;
    if (lang != null && lang.isNotEmpty) {
      req.fields['language'] = lang;
    }

    final String text;
    try {
      final http.StreamedResponse streamed = await _client
          .send(req)
          .timeout(timeout);
      final http.Response resp = await http.Response.fromStream(streamed);

      // ⚠️ 刻意**不用** `resp.body`:那个 getter 按响应头里的 charset 解码,
      // 而 charset 缺失时 `http` 包会退回 **latin-1**,于是每个汉字都会碎成
      // 两三个乱码字符。JSON 按 RFC 8259 规定就是 UTF-8,和服务端有没有
      // 老老实实写 charset 无关,所以这里直接按 UTF-8 解字节。
      // `allowMalformed: true` 是为了让半截多字节序列退化成替换字符,
      // 而不是抛异常把整段转写废掉。
      final String body = utf8.decode(resp.bodyBytes, allowMalformed: true);

      if (resp.statusCode != 200) {
        throw SttUnavailableException(_failureFor(resp.statusCode, body));
      }
      text = _extractText(body).trim();
    } on SttUnavailableException {
      rethrow; // 已经是我们自己的、带中文说明的错误,原样上抛
    } on TimeoutException {
      throw SttUnavailableException(
        SttAvailability(
          ready: false,
          reason: SttUnavailableReason.offline,
          message: '云端识别请求超时(超过 ${timeout.inSeconds} 秒),本段未能转写',
          remedy: '请检查网络连接;网络不稳定时建议改用本地离线识别',
        ),
      );
    } catch (e) {
      // 网络异常(DNS 失败、连接被拒、TLS 错误……)。
      // ⚠️ 这里把 `$e` 拼进 message 是安全的:异常来自 socket/HTTP 层,
      // 不含请求头。但**绝不能**改成打印 req.headers 或 req 本身。
      throw SttUnavailableException(
        SttAvailability(
          ready: false,
          reason: SttUnavailableReason.offline,
          message: '云端识别请求失败:$e',
          remedy: '请检查网络连接;离线时建议改用本地离线识别',
        ),
        cause: e,
      );
    }

    if (text.isEmpty) return; // 静音段,不是错误

    yield TranscriptSegment(
      startedAt: src.startedAt,
      endedAt: src.endedAt,
      // 逐轨契约:identity / name 原样回声。
      speakerIdentity: src.speakerIdentity,
      speakerName: src.speakerName,
      text: text,
      backend: kGroqBackendId,
      // Whisper 的 json 格式不返回置信度。不伪造。
      confidence: null,
    );
  }

  /// 从响应体里取出 `text` 字段。
  ///
  /// ⚠️ `strict-casts` 下 `jsonDecode` 返回的是 `Object?`,**不是** `dynamic`,
  /// 所以不能直接 `decoded['text']` —— 必须先逐层 `is` 收窄类型。
  /// 这也正好顺手挡住了畸形响应:类型不对就当解析失败,而不是在运行期
  /// 抛一个看不懂的 `NoSuchMethodError`。
  String _extractText(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (e) {
      throw SttUnavailableException(
        const SttAvailability(
          ready: false,
          reason: SttUnavailableReason.unknown,
          message: '云端识别返回了无法解析的内容,本段未能转写',
          remedy: '通常是服务端临时故障,稍后会自动恢复;持续出现请改用本地离线识别',
        ),
        cause: e,
      );
    }

    if (decoded is! Map<String, Object?>) {
      throw const SttUnavailableException(
        SttAvailability(
          ready: false,
          reason: SttUnavailableReason.unknown,
          message: '云端识别返回的数据格式不符合预期,本段未能转写',
          remedy: '通常是服务端临时故障,稍后会自动恢复;持续出现请改用本地离线识别',
        ),
      );
    }

    final Object? text = decoded['text'];
    if (text is! String) {
      throw const SttUnavailableException(
        SttAvailability(
          ready: false,
          reason: SttUnavailableReason.unknown,
          message: '云端识别返回的数据缺少转写文本,本段未能转写',
          remedy: '通常是服务端临时故障,稍后会自动恢复;持续出现请改用本地离线识别',
        ),
      );
    }
    return text;
  }

  /// 把 HTTP 状态码翻译成用户看得懂的中文。
  ///
  /// 按状态码分流而不是统一回一句"请求失败:401",是因为这几种失败
  /// 需要用户做的事完全不同:401 要去改 key,429 要等一会儿,5xx 只能干等。
  /// 一句笼统的提示等于什么都没说。
  ///
  /// ⚠️ [body] 只用于 5xx/未知分支的诊断片段,且**截断到 200 字符**。
  /// 响应体是服务端产的,不含我们的 key;但仍然截断,免得把一整页
  /// HTML 错误页灌进 UI。
  SttAvailability _failureFor(int status, String body) {
    switch (status) {
      case 401:
      case 403:
        return const SttAvailability(
          ready: false,
          reason: SttUnavailableReason.unknown,
          // 注意这里**没有**回显 key 的任何字符(包括所谓"前 4 位")——
          // 前缀同样是密钥材料,日志里出现就是泄漏。
          message: '云端识别鉴权失败,API Key 可能无效或已过期',
          remedy: '请到「设置 - 语音识别」重新填写 Groq API Key',
        );
      case 413:
        return const SttAvailability(
          ready: false,
          reason: SttUnavailableReason.unknown,
          message: '音频片段过大,超出云端识别的单次上传上限,本段未能转写',
          remedy: '请缩短单次送识别的音频长度',
        );
      case 429:
        return const SttAvailability(
          ready: false,
          reason: SttUnavailableReason.unknown,
          message: '云端识别请求过于频繁或已超出配额,本段未能转写',
          remedy: '请稍后再试,或到 Groq 控制台查看用量配额',
        );
      default:
        final String snippet = body.length > 200
            ? '${body.substring(0, 200)}…'
            : body;
        return SttAvailability(
          ready: false,
          reason: status >= 500
              ? SttUnavailableReason.offline
              : SttUnavailableReason.unknown,
          message: '云端识别返回错误(HTTP $status),本段未能转写',
          remedy: snippet.isEmpty ? null : '服务端说明:$snippet',
        );
    }
  }

  /// 关闭内部 HTTP client。
  ///
  /// 只关**我们自己创建**的那个;注入进来的归调用方管,见 [_ownsClient]。
  void dispose() {
    if (_ownsClient) _client.close();
  }
}
