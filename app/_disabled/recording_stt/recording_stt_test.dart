/// STT 三件套的纯 VM 单测:WAV 封装、PCM 归一化、可用性判定、
/// 云端错误处理、注册表降级。
///
/// ## 这份测试**覆盖不到**什么(请勿因为全绿就以为万事大吉)
/// 1. **sherpa-onnx 的真实推理完全没有被测。** 它是 FFI 插件,原生 DLL
///    在 `flutter test` 的 VM 里加载不了(没有 Flutter engine 去 dlopen)。
///    这里只测了不碰 FFI 的那一半:路径校验、int16→float32 归一化。
///    识别质量、模型加载、`stream.free()` 是否真的没泄漏,只能在
///    Windows/macOS 真机跑起来手工验证。
/// 2. **Groq 的真实网络请求完全没有被测。** 全部走 `MockClient`,
///    验的是"我们怎么发、怎么解析、怎么处理错误",不是"Groq 真的会这么回"。
///    请求体格式是否被服务端接受、真实的 401 长什么样,得实打实调一次才知道。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lares_app/src/recording/stt_backend.dart';
import 'package:lares_app/src/recording/stt_cloud.dart';
import 'package:lares_app/src/recording/stt_registry.dart';
import 'package:lares_app/src/recording/stt_sherpa.dart';
import 'package:lares_app/src/recording/transcript_store.dart';
import 'package:lares_app/src/recording/utterance.dart';

/// 测试里反复用到的说话人,集中定义,避免各处写不一样的字面量后
/// "回声"断言变得似是而非。
const String kIdentity = 'user-42';
const String kName = '阿柴';

/// 构造一段指定时长的静音 AudioSource。内容不重要,测的是长度与归属。
AudioSource sourceOf({
  Duration duration = const Duration(seconds: 12),
  int sampleRate = kPcmSampleRate,
  String identity = kIdentity,
  String name = kName,
}) {
  final int sampleCount = duration.inMicroseconds * sampleRate ~/ 1000000;
  return AudioSource(
    pcm: Uint8List(sampleCount * kBytesPerSample),
    startedAt: DateTime.utc(2026, 3, 1, 10),
    speakerIdentity: identity,
    speakerName: name,
    sampleRate: sampleRate,
  );
}

/// 把 WAV 头解析回来,用于往返验证。
/// 刻意**独立于** [buildWavFile] 重新实现一遍读取:如果读写共用同一份
/// 偏移常量,两边一起写错时测试反而会通过。
({
  String riff,
  int chunkSize,
  String wave,
  String fmt,
  int subchunk1Size,
  int audioFormat,
  int channels,
  int sampleRate,
  int byteRate,
  int blockAlign,
  int bitsPerSample,
  String data,
  int dataLen,
})
parseWavHeader(Uint8List wav) {
  final ByteData v = ByteData.sublistView(wav);
  String ascii(int off) =>
      String.fromCharCodes(wav.sublist(off, off + 4));
  return (
    riff: ascii(0),
    chunkSize: v.getUint32(4, Endian.little),
    wave: ascii(8),
    fmt: ascii(12),
    subchunk1Size: v.getUint32(16, Endian.little),
    audioFormat: v.getUint16(20, Endian.little),
    channels: v.getUint16(22, Endian.little),
    sampleRate: v.getUint32(24, Endian.little),
    byteRate: v.getUint32(28, Endian.little),
    blockAlign: v.getUint16(32, Endian.little),
    bitsPerSample: v.getUint16(34, Endian.little),
    data: ascii(36),
    dataLen: v.getUint32(40, Endian.little),
  );
}

/// 可控的假后端,用来把注册表的降级分支逐条走一遍。
class FakeBackend implements SttBackend {
  FakeBackend(this.availability, {this.id = 'fake'});

  final SttAvailability availability;
  final String id;
  int checkCount = 0;

  @override
  bool get supportsDiarization => false;

  @override
  bool get supportsStreaming => false;

  @override
  Future<SttAvailability> checkAvailability() async {
    checkCount++;
    return availability;
  }

  @override
  Stream<TranscriptSegment> transcribe(AudioSource src) async* {}
}

/// checkAvailability 直接抛异常的后端 —— 测注册表是否兜得住。
class ThrowingBackend implements SttBackend {
  @override
  bool get supportsDiarization => false;

  @override
  bool get supportsStreaming => false;

  @override
  Future<SttAvailability> checkAvailability() async =>
      throw StateError('后端内部炸了');

  @override
  Stream<TranscriptSegment> transcribe(AudioSource src) async* {}
}

void main() {
  group('WAV 头封装', () {
    test('头部恰好 44 字节,四个 magic 与数据长度全部正确', () {
      final Uint8List pcm = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
      final Uint8List wav = buildWavFile(pcm);

      expect(wav.length, kWavHeaderSize + 8);
      expect(kWavHeaderSize, 44);

      final h = parseWavHeader(wav);
      expect(h.riff, 'RIFF');
      expect(h.wave, 'WAVE');
      // 'fmt ' 末尾那个空格是规范的一部分,漏掉会让后面所有偏移错位。
      expect(h.fmt, 'fmt ');
      expect(h.data, 'data');
    });

    test('两个长度字段分别是 36+dataLen 与 dataLen', () {
      const int dataLen = 640;
      final Uint8List wav = buildWavFile(Uint8List(dataLen));
      final h = parseWavHeader(wav);

      // chunkSize 不是整个文件长度:'RIFF' 与它自己这 8 字节不计入。
      expect(h.chunkSize, 36 + dataLen);
      expect(h.chunkSize, wav.length - 8);
      // dataLen 是纯样本字节数,不含 44 字节头。
      expect(h.dataLen, dataLen);
    });

    test('16 位单声道 PCM:格式字段与派生字段正确', () {
      final Uint8List wav = buildWavFile(Uint8List(16));
      final h = parseWavHeader(wav);

      expect(h.subchunk1Size, 16); // PCM 固定 16
      expect(h.audioFormat, 1); // 1 = 无压缩 PCM
      expect(h.channels, 1);
      expect(h.bitsPerSample, 16);
      expect(h.sampleRate, kPcmSampleRate);
      // byteRate = sampleRate * channels * bitsPerSample / 8
      expect(h.byteRate, 16000 * 1 * 16 ~/ 8);
      expect(h.byteRate, 32000);
      // blockAlign = channels * bitsPerSample / 8
      expect(h.blockAlign, 1 * 16 ~/ 8);
      expect(h.blockAlign, 2);
    });

    test('长度字段按小端写入(逐字节核对,不信任读取函数)', () {
      // dataLen = 260 = 0x0104。小端应当是 04 01 00 00;
      // 写成大端会变成 00 00 01 04,这是最典型的字节序 bug。
      final Uint8List wav = buildWavFile(Uint8List(260));
      expect(wav[40], 0x04);
      expect(wav[41], 0x01);
      expect(wav[42], 0x00);
      expect(wav[43], 0x00);

      // sampleRate 16000 = 0x3E80 → 小端 80 3E 00 00
      expect(wav[24], 0x80);
      expect(wav[25], 0x3E);
      expect(wav[26], 0x00);
      expect(wav[27], 0x00);
    });

    test('采样率与声道数可覆盖,派生字段随之变化', () {
      final Uint8List wav = buildWavFile(
        Uint8List(100),
        sampleRate: 48000,
        channels: 2,
      );
      final h = parseWavHeader(wav);

      expect(h.sampleRate, 48000);
      expect(h.channels, 2);
      expect(h.byteRate, 48000 * 2 * 16 ~/ 8);
      expect(h.blockAlign, 2 * 16 ~/ 8);
    });

    test('PCM 数据原样附在头之后,一个字节都不改', () {
      final Uint8List pcm = Uint8List.fromList(
        List<int>.generate(64, (int i) => i * 3 % 256),
      );
      final Uint8List wav = buildWavFile(pcm);
      expect(wav.sublist(kWavHeaderSize), pcm);
    });

    test('空 PCM 也产出结构合法的 44 字节文件(不崩)', () {
      final Uint8List wav = buildWavFile(Uint8List(0));
      final h = parseWavHeader(wav);

      expect(wav.length, 44);
      expect(h.dataLen, 0);
      expect(h.chunkSize, 36);
      expect(h.riff, 'RIFF');
    });
  });

  group('int16 → float32 归一化', () {
    test('静音映射到 0.0', () {
      final Float32List f = samplesToFloat32(Int16List.fromList(<int>[0, 0]));
      expect(f[0], 0.0);
      expect(f[1], 0.0);
    });

    test('最大负值 -32768 恰好等于 -1.0(除数选 32768 的直接后果)', () {
      final Float32List f = samplesToFloat32(Int16List.fromList(<int>[-32768]));
      expect(f[0], -1.0);
    });

    test('最大正值 +32767 略小于 1.0 —— 诚实承认这一格的不对称', () {
      final Float32List f = samplesToFloat32(Int16List.fromList(<int>[32767]));
      expect(f[0], lessThan(1.0));
      // 差距只有 1/32768 ≈ 0.00003,在 16 bit 量化噪声之下,对识别无影响。
      expect(f[0], closeTo(1.0, 0.0001));
    });

    test('全量程扫描后输出恒落在 [-1.0, 1.0] 内(绝不越界)', () {
      final Int16List samples = Int16List.fromList(<int>[
        -32768, -32767, -20000, -1, 0, 1, 20000, 32766, 32767,
      ]);
      final Float32List f = samplesToFloat32(samples);
      for (final double v in f) {
        expect(v, greaterThanOrEqualTo(-1.0));
        expect(v, lessThanOrEqualTo(1.0));
      }
    });

    test('半量程线性:16384 → 0.5', () {
      final Float32List f = samplesToFloat32(
        Int16List.fromList(<int>[16384, -16384]),
      );
      expect(f[0], 0.5);
      expect(f[1], -0.5);
    });

    test('从裸 PCM 字节入口走一遍,小端解码与归一化串接正确', () {
      // encodePcm16 是 utterance.dart 的既有实现,这里复用它构造输入,
      // 顺便验证两个模块在字节序上的约定是一致的。
      final Uint8List pcm = encodePcm16(<int>[0, 16384, -32768]);
      final Float32List f = pcm16ToFloat32(pcm);

      expect(f.length, 3);
      expect(f[0], 0.0);
      expect(f[1], 0.5);
      expect(f[2], -1.0);
    });

    test('空输入产出空数组,不抛', () {
      expect(pcm16ToFloat32(Uint8List(0)).length, 0);
    });
  });

  group('契约层的可用性值对象与异常', () {
    test('SttAvailability.notConfigured 归因为「未配置」并把用户指向设置页', () {
      const SttAvailability a = SttAvailability.notConfigured(backend: '云端识别');

      expect(a.ready, isFalse);
      expect(a.reason, SttUnavailableReason.notConfigured);
      expect(a.message, isNotEmpty);
      // 补救办法必须指向「设置」,否则用户知道"没配"也不知道去哪配。
      expect(a.remedy, contains('设置'));
      // 后端名单独存字段、不拼进 message:const 初始化列表里不能对参数
      // 做字符串插值(invalid_constant,且报错点会落在调用方那一行)。
      expect(a.backendLabel, '云端识别');
      expect(a.modelPath, isNull);
    });

    test('notConfigured 与 offline 是两个不同的原因,不可混用', () {
      expect(
        SttUnavailableReason.notConfigured,
        isNot(SttUnavailableReason.offline),
      );
      expect(
        SttUnavailableReason.values,
        contains(SttUnavailableReason.notConfigured),
      );
    });

    test('SttUnavailableException 直接回声 availability 的中文说明', () {
      const SttUnavailableException e = SttUnavailableException(
        SttAvailability.notConfigured(),
      );

      expect(e.message, e.availability.message);
      expect(e.cause, isNull);
      expect(e.toString(), contains(e.availability.message));
    });
  });

  group('本地模型可用性判定', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('lares_stt_test_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('路径为 null 时不可用,且提示里带下载地址与两个文件名', () {
      final SttAvailability a = checkSherpaModelDir(null);

      expect(a.ready, isFalse);
      expect(a.reason, SttUnavailableReason.modelMissing);
      expect(a.message, contains('未配置'));
      // 提示必须能让用户/客服照着一步步操作,所以三要素缺一不可。
      expect(a.remedy, contains(kSherpaModelDownloadUrl));
      expect(a.remedy, contains('model.int8.onnx'));
      expect(a.remedy, contains('tokens.txt'));
      expect(a.remedy, contains('设置'));
    });

    test('空白路径等同于未配置(避免设置里存了个空格就去摸文件系统)', () {
      final SttAvailability a = checkSherpaModelDir('   ');
      expect(a.ready, isFalse);
      expect(a.reason, SttUnavailableReason.modelMissing);
    });

    test('目录不存在时不可用,并在结果里回带该路径便于排查', () {
      final String missing =
          '${tmp.path}${Platform.pathSeparator}not_there';
      final SttAvailability a = checkSherpaModelDir(missing);

      expect(a.ready, isFalse);
      expect(a.reason, SttUnavailableReason.modelMissing);
      expect(a.message, contains('不存在'));
      expect(a.modelPath, missing);
    });

    test('只有 model.int8.onnx、缺 tokens.txt(压缩包解压到一半)时不可用', () {
      File('${tmp.path}${Platform.pathSeparator}$kSherpaModelFileName')
          .writeAsBytesSync(<int>[0, 1, 2]);

      final SttAvailability a = checkSherpaModelDir(tmp.path);

      expect(a.ready, isFalse);
      expect(a.reason, SttUnavailableReason.modelMissing);
      // 必须点名到底缺哪个文件 —— 只说"不完整"用户无从下手。
      expect(a.message, contains('tokens.txt'));
      expect(a.message, isNot(contains('model.int8.onnx')));
      expect(a.message, contains('解压'));
    });

    test('只有 tokens.txt、缺权重文件时同样不可用,并点名缺的是权重', () {
      File('${tmp.path}${Platform.pathSeparator}$kSherpaTokensFileName')
          .writeAsStringSync('a\nb\n');

      final SttAvailability a = checkSherpaModelDir(tmp.path);

      expect(a.ready, isFalse);
      expect(a.message, contains('model.int8.onnx'));
    });

    test('两个文件都在时报告可用(仅校验路径,不加载模型)', () {
      File('${tmp.path}${Platform.pathSeparator}$kSherpaModelFileName')
          .writeAsBytesSync(<int>[0, 1, 2]);
      File('${tmp.path}${Platform.pathSeparator}$kSherpaTokensFileName')
          .writeAsStringSync('a\nb\n');

      final SttAvailability a = checkSherpaModelDir(tmp.path);

      expect(a.ready, isTrue);
      expect(a.reason, SttUnavailableReason.none);
      expect(a.message, contains('已就绪'));
    });

    test('后端构造本身不触碰 FFI:没有模型时构造与查询都不崩', () async {
      // 惰性初始化的核心断言:仅仅"注册一个后端"必须零成本。
      // 如果构造函数里调了 initBindings(),这个用例会当场炸掉。
      final SherpaSttBackend backend = SherpaSttBackend();
      final SttAvailability a = await backend.checkAvailability();

      expect(a.ready, isFalse);
      expect(a.reason, SttUnavailableReason.modelMissing);
      backend.dispose(); // 从未初始化过也要能安全释放
    });

    test('不可用时 transcribe 抛出带中文说明的异常,而不是崩溃', () async {
      final SherpaSttBackend backend = SherpaSttBackend();

      await expectLater(
        backend.transcribe(sourceOf()).toList(),
        throwsA(
          isA<SttUnavailableException>().having(
            (SttUnavailableException e) => e.availability.reason,
            'reason',
            SttUnavailableReason.modelMissing,
          ),
        ),
      );
    });

    test('本地后端是逐轨的:不做说话人分离,也不支持流式', () {
      final SherpaSttBackend backend = SherpaSttBackend();
      // 说话人来自 LiveKit 的轨,不来自模型 —— 这是整套架构的核心主张。
      expect(backend.supportsDiarization, isFalse);
      // 用的是 Offline 识别器,只能整段送整段出,诚实填 false。
      expect(backend.supportsStreaming, isFalse);
    });
  });

  group('云端后端(MockClient,不联网)', () {
    const String kKey = 'gsk_super_secret_key_value_1234567890';

    /// 造一个固定返回的假 client。
    ///
    /// 用 `Response.bytes` 而不是 `Response(String, ...)`,并且**刻意不带**
    /// charset:真实服务端经常就是这样回的,而 `http` 包在缺 charset 时
    /// 会按 latin-1 解码,汉字会碎成乱码。这里复现那个环境,正是为了确保
    /// 被测代码自己按 UTF-8 解字节(见 stt_cloud.dart 里的说明)。
    MockClient respondWith(int status, String body) =>
        MockClient((http.Request req) async => http.Response.bytes(
              utf8.encode(body),
              status,
              headers: <String, String>{'content-type': 'application/json'},
            ));

    test('成功响应产出 TranscriptSegment,文本与后端标识正确', () async {
      final GroqSttBackend backend = GroqSttBackend(
        apiKey: kKey,
        client: respondWith(200, jsonEncode(<String, Object?>{
          'text': '今晚七点老地方见',
        })),
      );

      final List<TranscriptSegment> out =
          await backend.transcribe(sourceOf()).toList();

      expect(out, hasLength(1));
      expect(out.single.text, '今晚七点老地方见');
      expect(out.single.backend, kGroqBackendId);
      // 云端也不给置信度,不允许伪造成 1.0。
      expect(out.single.confidence, isNull);
    });

    test('响应头不带 charset 时汉字仍然正确(不能退回 latin-1)', () async {
      // 回归测试:`http.Response.body` 在缺 charset 时按 latin-1 解码,
      // 汉字会碎成"ä»Šæ™"这样的乱码。被测代码必须自己按 UTF-8 解 bodyBytes。
      const String chinese = '这是一段很长的中文,包含标点、数字 2026 和 emoji 🎧';
      final GroqSttBackend backend = GroqSttBackend(
        apiKey: kKey,
        client: respondWith(
          200,
          jsonEncode(<String, Object?>{'text': chinese}),
        ),
      );

      final List<TranscriptSegment> out =
          await backend.transcribe(sourceOf()).toList();

      expect(out.single.text, chinese);
    });

    test('轨的说话人身份被原样回声进结果(逐轨归属的核心断言)', () async {
      final GroqSttBackend backend = GroqSttBackend(
        apiKey: kKey,
        client: respondWith(200, jsonEncode(<String, Object?>{'text': '好'})),
      );

      final AudioSource src = sourceOf(
        identity: 'lk-participant-7',
        name: '小满',
      );
      final List<TranscriptSegment> out =
          await backend.transcribe(src).toList();

      // 模型压根不知道说话人是谁,这两个字段只能是我们传进去的那两个。
      expect(out.single.speakerIdentity, 'lk-participant-7');
      expect(out.single.speakerName, '小满');
      // 时间戳同样来自 VAD 的绝对时刻,不是模型估的。
      expect(out.single.startedAt, src.startedAt);
      expect(out.single.endedAt, src.endedAt);
    });

    test('响应文本为空(静音段)时不产出任何条目,也不报错', () async {
      final GroqSttBackend backend = GroqSttBackend(
        apiKey: kKey,
        client: respondWith(200, jsonEncode(<String, Object?>{'text': '   '})),
      );

      expect(await backend.transcribe(sourceOf()).toList(), isEmpty);
    });

    test('401 转成中文鉴权提示,不抛未捕获异常', () async {
      final GroqSttBackend backend = GroqSttBackend(
        apiKey: kKey,
        client: respondWith(401, '{"error":{"message":"Invalid API Key"}}'),
      );

      await expectLater(
        backend.transcribe(sourceOf()).toList(),
        throwsA(
          isA<SttUnavailableException>().having(
            (SttUnavailableException e) => e.availability.message,
            'message',
            contains('鉴权失败'),
          ),
        ),
      );
    });

    test('500 转成中文服务端错误,归因为网络侧问题', () async {
      final GroqSttBackend backend = GroqSttBackend(
        apiKey: kKey,
        client: respondWith(500, 'internal error'),
      );

      await expectLater(
        backend.transcribe(sourceOf()).toList(),
        throwsA(
          isA<SttUnavailableException>()
              .having(
                (SttUnavailableException e) => e.availability.message,
                'message',
                contains('HTTP 500'),
              )
              .having(
                (SttUnavailableException e) => e.availability.reason,
                'reason',
                SttUnavailableReason.offline,
              ),
        ),
      );
    });

    test('429 单独成一类提示(要等,而不是去改 key)', () async {
      final GroqSttBackend backend = GroqSttBackend(
        apiKey: kKey,
        client: respondWith(429, '{}'),
      );

      await expectLater(
        backend.transcribe(sourceOf()).toList(),
        throwsA(
          isA<SttUnavailableException>().having(
            (SttUnavailableException e) => e.availability.message,
            'message',
            contains('频繁'),
          ),
        ),
      );
    });

    test('响应不是合法 JSON 时优雅报错', () async {
      final GroqSttBackend backend = GroqSttBackend(
        apiKey: kKey,
        client: respondWith(200, '<html>502 Bad Gateway</html>'),
      );

      await expectLater(
        backend.transcribe(sourceOf()).toList(),
        throwsA(
          isA<SttUnavailableException>().having(
            (SttUnavailableException e) => e.availability.message,
            'message',
            contains('无法解析'),
          ),
        ),
      );
    });

    test('JSON 合法但缺 text 字段时优雅报错(strict-casts 下不会炸成类型错误)', () async {
      final GroqSttBackend backend = GroqSttBackend(
        apiKey: kKey,
        client: respondWith(200, jsonEncode(<String, Object?>{'foo': 1})),
      );

      await expectLater(
        backend.transcribe(sourceOf()).toList(),
        throwsA(
          isA<SttUnavailableException>().having(
            (SttUnavailableException e) => e.availability.message,
            'message',
            contains('缺少转写文本'),
          ),
        ),
      );
    });

    test('JSON 顶层不是对象(比如数组)时优雅报错', () async {
      final GroqSttBackend backend = GroqSttBackend(
        apiKey: kKey,
        client: respondWith(200, '[1,2,3]'),
      );

      await expectLater(
        backend.transcribe(sourceOf()).toList(),
        throwsA(isA<SttUnavailableException>()),
      );
    });

    test('网络异常(连不上)转成中文提示,不抛原始 SocketException', () async {
      final GroqSttBackend backend = GroqSttBackend(
        apiKey: kKey,
        client: MockClient(
          (http.Request req) async =>
              throw const SocketException('Connection refused'),
        ),
      );

      await expectLater(
        backend.transcribe(sourceOf()).toList(),
        throwsA(
          isA<SttUnavailableException>().having(
            (SttUnavailableException e) => e.availability.reason,
            'reason',
            SttUnavailableReason.offline,
          ),
        ),
      );
    });

    test('API Key 绝不出现在任何一条错误消息里(安全底线)', () async {
      // 逐个错误分支跑一遍,挨条检查 key 没有泄漏。
      // 这是最容易在重构中被破坏的不变量:某天有人为了"方便排查"
      // 把 request headers 拼进 message,key 就随日志跑出去了。
      final List<MockClient> clients = <MockClient>[
        respondWith(401, '{"error":"bad key"}'),
        respondWith(403, '{}'),
        respondWith(429, '{}'),
        respondWith(500, 'server exploded'),
        respondWith(418, 'teapot'),
        respondWith(200, 'not json at all'),
        respondWith(200, '{"no_text":true}'),
        MockClient(
          (http.Request req) async => throw const SocketException('boom'),
        ),
      ];

      for (final MockClient c in clients) {
        final GroqSttBackend backend = GroqSttBackend(apiKey: kKey, client: c);
        Object? caught;
        try {
          await backend.transcribe(sourceOf()).toList();
        } catch (e) {
          caught = e;
        }
        expect(caught, isA<SttUnavailableException>());
        final SttUnavailableException e = caught! as SttUnavailableException;

        // message / remedy / toString() 三条对外通路全部检查。
        expect(e.availability.message, isNot(contains(kKey)));
        expect(e.availability.remedy ?? '', isNot(contains(kKey)));
        expect(e.toString(), isNot(contains(kKey)));
        // 连 key 的前缀片段也不允许出现 —— 前缀同样是密钥材料。
        expect(e.availability.message, isNot(contains('gsk_')));
        expect(e.toString(), isNot(contains('gsk_')));
      }
    });

    test('未填 key 时报告不可用,并引导去设置页填写', () async {
      final GroqSttBackend backend = GroqSttBackend(apiKey: '');
      final SttAvailability a = await backend.checkAvailability();

      expect(a.ready, isFalse);
      expect(a.message, contains('API Key'));
      expect(a.remedy, contains('设置'));
      backend.dispose();
    });

    test('未填 key 归因为「未配置」而不是「离线」(网好得很,问题在没配)', () async {
      final GroqSttBackend backend = GroqSttBackend(apiKey: '');
      final SttAvailability a = await backend.checkAvailability();

      // 这条是语义底线:报成 offline 会让按 reason 分支的 UI 去劝用户
      // 「检查网络连接」,而他查到天亮也查不出问题 —— 真正该做的只是
      // 去设置页填一行 key。
      expect(a.reason, SttUnavailableReason.notConfigured);
      expect(a.reason, isNot(SttUnavailableReason.offline));
      backend.dispose();
    });

    test('key 只有空白字符时同样归因为「未配置」', () async {
      final GroqSttBackend backend = GroqSttBackend(apiKey: '  \t ');
      final SttAvailability a = await backend.checkAvailability();

      expect(a.reason, SttUnavailableReason.notConfigured);
      backend.dispose();
    });

    test('未填 key 时 transcribe 抛出的异常也带着「未配置」这个原因', () async {
      final GroqSttBackend backend = GroqSttBackend(apiKey: '');

      await expectLater(
        backend.transcribe(sourceOf()).toList(),
        throwsA(
          isA<SttUnavailableException>().having(
            (SttUnavailableException e) => e.availability.reason,
            'reason',
            SttUnavailableReason.notConfigured,
          ),
        ),
      );
      backend.dispose();
    });

    test('key 只有空白字符时同样视为未填', () async {
      final GroqSttBackend backend = GroqSttBackend(apiKey: '  \t ');
      expect((await backend.checkAvailability()).ready, isFalse);
      backend.dispose();
    });

    test('未填 key 时 transcribe 抛中文异常而不是崩溃', () async {
      final GroqSttBackend backend = GroqSttBackend(apiKey: '');

      await expectLater(
        backend.transcribe(sourceOf()).toList(),
        throwsA(isA<SttUnavailableException>()),
      );
      backend.dispose();
    });

    test('云端后端同样不做说话人分离,也不是流式', () {
      final GroqSttBackend backend = GroqSttBackend(apiKey: kKey);
      expect(backend.supportsDiarization, isFalse);
      expect(backend.supportsStreaming, isFalse);
      backend.dispose();
    });
  });

  group('云端最短分片计费策略', () {
    const String kKey = 'gsk_test_key';

    test('默认策略下,短于 10 秒的分片被直接拒绝,且根本不发请求', () async {
      bool sent = false;
      final GroqSttBackend backend = GroqSttBackend(
        apiKey: kKey,
        client: MockClient((http.Request req) async {
          sent = true;
          return http.Response('{"text":"x"}', 200);
        }),
      );

      await expectLater(
        backend.transcribe(sourceOf(duration: const Duration(seconds: 3)))
            .toList(),
        throwsA(isA<SttUnavailableException>()),
      );
      // 关键断言:拦截必须发生在发请求**之前**。拦晚了钱已经花出去了。
      expect(sent, isFalse);
    });

    test('拒绝时的中文说明点明「按 10 秒起步计费」这个原因', () async {
      final GroqSttBackend backend = GroqSttBackend(
        apiKey: kKey,
        client: respondOk(),
      );

      Object? caught;
      try {
        await backend
            .transcribe(sourceOf(duration: const Duration(seconds: 3)))
            .toList();
      } catch (e) {
        caught = e;
      }

      final SttUnavailableException e = caught! as SttUnavailableException;
      expect(e.availability.message, contains('10 秒'));
      expect(e.availability.message, contains('费用'));
      expect(e.availability.remedy, contains('计费'));
    });

    test('恰好 10 秒(等于阈值)放行', () async {
      final GroqSttBackend backend = GroqSttBackend(
        apiKey: kKey,
        client: respondOk(text: '正好十秒'),
      );

      final List<TranscriptSegment> out = await backend
          .transcribe(sourceOf(duration: kGroqMinBillableChunk))
          .toList();

      expect(out.single.text, '正好十秒');
    });

    test('显式选 sendAnyway 时短分片照发(用户自己认了这笔溢价)', () async {
      final GroqSttBackend backend = GroqSttBackend(
        apiKey: kKey,
        client: respondOk(text: '三秒也发'),
        shortChunkPolicy: GroqShortChunkPolicy.sendAnyway,
      );

      final List<TranscriptSegment> out = await backend
          .transcribe(sourceOf(duration: const Duration(seconds: 3)))
          .toList();

      expect(out.single.text, '三秒也发');
    });

    test('阈值可注入(Groq 改价时不用改代码)', () async {
      final GroqSttBackend backend = GroqSttBackend(
        apiKey: kKey,
        client: respondOk(text: '短阈值'),
        minChunk: const Duration(seconds: 2),
      );

      final List<TranscriptSegment> out = await backend
          .transcribe(sourceOf(duration: const Duration(seconds: 3)))
          .toList();

      expect(out.single.text, '短阈值');
    });

    test('常量本身就是 10 秒 —— 这个数字来自 Groq 的计费规则,别随手改', () {
      expect(kGroqMinBillableChunk, const Duration(seconds: 10));
    });
  });

  group('后端注册表与降级', () {
    SttAvailability ok() => const SttAvailability.ready(backend: 't');
    SttAvailability missing() =>
        const SttAvailability.modelMissing(expectedPath: r'C:\models\sv');

    test('默认选本地(项目决策:免费、离线、隐私优先)', () async {
      final FakeBackend local = FakeBackend(ok());
      final FakeBackend cloud = FakeBackend(ok());
      final SttSelection sel =
          await SttRegistry(local: local, cloud: cloud).select();

      expect(sel.requested, SttBackendChoice.local);
      expect(sel.effective, SttBackendChoice.local);
      expect(identical(sel.backend, local), isTrue);
      expect(sel.ready, isTrue);
      expect(sel.didFallBack, isFalse);
      // 本地可用时压根不该去问云端(免得白白发探测请求)。
      expect(cloud.checkCount, 0);
    });

    test('降级顺序里本地排在云端前面(云端要花钱,只能兜底)', () {
      expect(SttRegistry.kFallbackOrder.first, SttBackendChoice.local);
      expect(SttRegistry.kFallbackOrder, contains(SttBackendChoice.cloud));
    });

    test('本地模型没装时自动降级到云端,并标记发生了降级', () async {
      final FakeBackend local = FakeBackend(missing());
      final FakeBackend cloud = FakeBackend(ok());
      final SttSelection sel =
          await SttRegistry(local: local, cloud: cloud).select();

      expect(sel.effective, SttBackendChoice.cloud);
      expect(identical(sel.backend, cloud), isTrue);
      expect(sel.ready, isTrue);
      // UI 必须能知道"用户要的不是这个",否则就是背着用户花钱。
      expect(sel.didFallBack, isTrue);
    });

    test('用户选云端、云端没 key 时反向降级回本地', () async {
      final FakeBackend local = FakeBackend(ok());
      final FakeBackend cloud = FakeBackend(
        // 没填 key 的归因是「未配置」而非「离线」,与真实云端后端保持一致。
        const SttAvailability(
          ready: false,
          reason: SttUnavailableReason.notConfigured,
          message: '未配置 API Key',
        ),
      );
      final SttSelection sel = await SttRegistry(local: local, cloud: cloud)
          .select(requested: SttBackendChoice.cloud);

      expect(sel.effective, SttBackendChoice.local);
      expect(sel.ready, isTrue);
      expect(sel.didFallBack, isTrue);
    });

    test('全都不可用时返回不可用状态,而不是抛异常', () async {
      final SttRegistry reg = SttRegistry(
        local: FakeBackend(missing()),
        cloud: FakeBackend(
          const SttAvailability(
            ready: false,
            reason: SttUnavailableReason.notConfigured,
            message: '未配置 API Key',
          ),
        ),
      );

      // 不抛是硬性要求:录音链路不能被"模型没装"拖垮。
      final SttSelection sel = await reg.select();

      expect(sel.ready, isFalse);
      expect(sel.backend, isNull);
      expect(sel.effective, SttBackendChoice.off);
    });

    test('全军覆没时展示的是「用户首选」的失败原因,不是链条末端的', () async {
      final SttRegistry reg = SttRegistry(
        local: FakeBackend(missing()),
        cloud: FakeBackend(
          const SttAvailability(
            ready: false,
            reason: SttUnavailableReason.notConfigured,
            message: '未配置 API Key',
          ),
        ),
      );
      final SttSelection sel = await reg.select();

      // 用户选的是本地,就该看到"模型没装",而不是一句他压根没选过的
      // "请填 API Key" —— 后者只会让人一头雾水。
      expect(sel.availability.reason, SttUnavailableReason.modelMissing);
      expect(sel.availability.message, contains('未安装本地语音模型'));
      expect(sel.availability.remedy, contains('设置'));
      expect(sel.availability.modelPath, r'C:\models\sv');
    });

    test('一个后端都没装配时给出可读的「STT 不可用」中文说明', () async {
      final SttSelection sel = await const SttRegistry().select();

      expect(sel.ready, isFalse);
      expect(sel.backend, isNull);
      expect(sel.availability.message, contains('STT 不可用'));
      // 必须说明录音不受影响,否则用户会以为整个功能坏了。
      expect(sel.availability.message, contains('录音不受影响'));
    });

    test('后端的 checkAvailability 抛异常时注册表兜住,继续尝试下一个', () async {
      final FakeBackend cloud = FakeBackend(ok());
      final SttSelection sel =
          await SttRegistry(local: ThrowingBackend(), cloud: cloud).select();

      // 一个后端炸了不该让整条降级链断掉。
      expect(sel.effective, SttBackendChoice.cloud);
      expect(sel.ready, isTrue);
    });

    test('全炸时也不外抛,只返回不可用', () async {
      final SttSelection sel = await SttRegistry(
        local: ThrowingBackend(),
        cloud: ThrowingBackend(),
      ).select();

      expect(sel.ready, isFalse);
      expect(sel.availability.message, contains('失败'));
    });

    test('用户主动选「关闭」时不做任何降级,尊重明确意愿', () async {
      final FakeBackend local = FakeBackend(ok());
      final SttSelection sel = await SttRegistry(local: local)
          .select(requested: SttBackendChoice.off);

      expect(sel.effective, SttBackendChoice.off);
      expect(sel.backend, isNull);
      expect(sel.didFallBack, isFalse);
      expect(sel.availability.reason, SttUnavailableReason.disabledByUser);
      // "用户不想要"和"用不了"是两回事,前者绝不该去查后端。
      expect(local.checkCount, 0);
    });

    test('首选后端只被查询一次(去重,避免多余的文件系统 IO)', () async {
      final FakeBackend local = FakeBackend(missing());
      await SttRegistry(local: local).select();
      expect(local.checkCount, 1);
    });

    test('设置下拉框的三个选项都有中文标签与代价说明', () {
      expect(SttBackendChoice.local.label, '本地离线识别');
      expect(SttBackendChoice.cloud.label, '云端识别');
      expect(SttBackendChoice.off.label, '关闭转写');

      // 云端要花钱、要上传音频,这两件事必须写在用户能看见的地方。
      expect(SttBackendChoice.cloud.description, contains('计费'));
      expect(SttBackendChoice.cloud.description, contains('上传'));
      expect(SttBackendChoice.local.description, contains('免费'));
    });
  });

  group('两个后端的逐轨归属契约', () {
    test('两个后端都声明不做说话人分离', () {
      final SherpaSttBackend local = SherpaSttBackend();
      final GroqSttBackend cloud = GroqSttBackend(apiKey: 'k');

      // 说话人来自 LiveKit 的轨,不来自任何模型 —— 这是本架构的核心主张,
      // 哪天有人把某个后端改成 true,这条会立刻失败并逼他重新审视这个决定。
      expect(local.supportsDiarization, isFalse);
      expect(cloud.supportsDiarization, isFalse);

      local.dispose();
      cloud.dispose();
    });

    test('AudioSource.fromUtterance 把归属信息一路带到 TranscriptSegment', () async {
      final Utterance u = Utterance.fromSamples(
        speakerIdentity: 'lk-9',
        speakerName: '老周',
        startedAt: DateTime.utc(2026, 5, 1, 20, 30),
        samples: List<int>.filled(kPcmSampleRate * 12, 0),
      );
      final AudioSource src = AudioSource.fromUtterance(u);

      final GroqSttBackend backend = GroqSttBackend(
        apiKey: 'k',
        client: respondOk(text: '带着身份走完全程'),
      );
      final List<TranscriptSegment> out =
          await backend.transcribe(src).toList();

      expect(out.single.speakerIdentity, 'lk-9');
      expect(out.single.speakerName, '老周');
      expect(out.single.text, '带着身份走完全程');
    });
  });
}

/// 200 + 合法 JSON 的假 client,给不关心响应内容的用例复用。
///
/// 同样走 UTF-8 字节且不声明 charset —— 理由见上面 `respondWith` 的说明。
MockClient respondOk({String text = 'ok'}) => MockClient(
  (http.Request req) async => http.Response.bytes(
    utf8.encode(jsonEncode(<String, Object?>{'text': text})),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  ),
);
