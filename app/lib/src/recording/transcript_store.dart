/// 转写稿的**追加写 JSONL** 落盘 + 读回 + Markdown 导出。
///
/// 目录由调用方注入(绝不用 path_provider 之类插件去"发现"路径),
/// 因此本文件可在纯 VM 测试里对着临时目录跑。`dart:io` 是可以的,
/// 插件不行 —— 后者在 `flutter test` 环境里根本没有宿主端实现。
library;

import 'dart:convert';
import 'dart:io';

// 只用 foundation 的 @immutable 注解(纯值语义标记),不引入任何平台通道依赖。
// 未选用 package:meta 是因为它不是本包的直接依赖(depend_on_referenced_packages)。
import 'package:flutter/foundation.dart';

/// 转写稿文件扩展名。**JSONL 而不是 JSON 数组**:
/// JSON 数组要求写完最后一个 `]` 才算合法文件,进程被杀就整份报废;
/// JSONL 每行独立自洽,崩溃最多毁掉最后一行。这是 24/7 常驻应用的刚需。
const String kTranscriptExtension = '.jsonl';

/// 一条转写结果。
@immutable
class TranscriptSegment {
  const TranscriptSegment({
    required this.startedAt,
    required this.endedAt,
    required this.speakerIdentity,
    required this.speakerName,
    required this.text,
    required this.backend,
    this.confidence,
  });

  /// 从一行 JSON 还原。任何字段缺失/类型不对都返回 null(不抛)——
  /// 读取方需要"跳过坏行"而不是"炸掉整份转写稿"。
  static TranscriptSegment? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;

    final Object? rawStart = json['startedAt'];
    final Object? rawEnd = json['endedAt'];
    if (rawStart is! String || rawEnd is! String) return null;
    final DateTime? start = DateTime.tryParse(rawStart);
    final DateTime? end = DateTime.tryParse(rawEnd);
    if (start == null || end == null) return null;

    final Object? identity = json['speakerIdentity'];
    final Object? name = json['speakerName'];
    final Object? text = json['text'];
    final Object? backend = json['backend'];
    if (identity is! String || name is! String) return null;
    if (text is! String || backend is! String) return null;

    // confidence 是**真的可选**:很多后端(含 sherpa-onnx 的部分模型)
    // 根本不给置信度。这里区分"没有这个字段"与"字段是 null",
    // 两者都归一成 null,但类型不对(比如字符串)视为坏行整条丢弃。
    final Object? rawConf = json['confidence'];
    double? confidence;
    if (rawConf != null) {
      if (rawConf is! num) return null;
      confidence = rawConf.toDouble();
    }

    return TranscriptSegment(
      startedAt: start,
      endedAt: end,
      speakerIdentity: identity,
      speakerName: name,
      text: text,
      backend: backend,
      confidence: confidence,
    );
  }

  final DateTime startedAt;
  final DateTime endedAt;

  /// 说话人主键(LiveKit identity)。分组、统计一律认它,不认显示名。
  final String speakerIdentity;

  /// 显示名。只给人看。
  final String speakerName;

  final String text;

  /// 置信度,**可空**:很多后端不提供。UI 必须容忍它缺席,
  /// 不要用 `confidence ?? 1.0` 这种伪造 —— 那会让"不知道"看起来像"很确定"。
  final double? confidence;

  /// 产出这条结果的后端标识(如 `sherpa-onnx`)。
  /// 落进每一行是为了将来换引擎后还能分辨历史数据出自谁,便于对比质量。
  final String backend;

  Duration get duration => endedAt.difference(startedAt);

  /// 时刻统一按 **ISO-8601 UTC** 序列化。
  ///
  /// 存本地时区的字符串是个陷阱:用户出差换时区、或者设备夏令时切换后,
  /// 同一份转写稿的时间顺序会错乱。存 UTC、显示时再转本地,顺序永远正确。
  Map<String, Object?> toJson() => <String, Object?>{
    'startedAt': startedAt.toUtc().toIso8601String(),
    'endedAt': endedAt.toUtc().toIso8601String(),
    'speakerIdentity': speakerIdentity,
    'speakerName': speakerName,
    'text': text,
    'confidence': confidence,
    'backend': backend,
  };

  TranscriptSegment copyWith({
    DateTime? startedAt,
    DateTime? endedAt,
    String? speakerIdentity,
    String? speakerName,
    String? text,
    double? confidence,
    String? backend,
  }) {
    return TranscriptSegment(
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      speakerIdentity: speakerIdentity ?? this.speakerIdentity,
      speakerName: speakerName ?? this.speakerName,
      text: text ?? this.text,
      confidence: confidence ?? this.confidence,
      backend: backend ?? this.backend,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TranscriptSegment &&
          other.startedAt == startedAt &&
          other.endedAt == endedAt &&
          other.speakerIdentity == speakerIdentity &&
          other.speakerName == speakerName &&
          other.text == text &&
          other.confidence == confidence &&
          other.backend == backend;

  @override
  int get hashCode => Object.hash(
    startedAt,
    endedAt,
    speakerIdentity,
    speakerName,
    text,
    confidence,
    backend,
  );

  @override
  String toString() =>
      'TranscriptSegment(startedAt: $startedAt, endedAt: $endedAt, '
      'speakerIdentity: $speakerIdentity, speakerName: $speakerName, '
      'text: $text, confidence: $confidence, backend: $backend)';
}

/// 一次读取的结果:解析成功的条目 + 被跳过的坏行数。
@immutable
class TranscriptReadResult {
  const TranscriptReadResult({required this.segments, required this.skipped});

  final List<TranscriptSegment> segments;

  /// 被跳过的畸形行数。
  ///
  /// 这个计数必须暴露出来,因为 **skipped == 1 是完全正常的情况**:
  /// 写到一半被杀进程,文件尾必然留下半行。UI 不该为此报错,
  /// 但运维排查时需要能看到"到底跳了几行" —— 跳了几百行才是真出事了。
  final int skipped;

  bool get isEmpty => segments.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TranscriptReadResult &&
          other.skipped == skipped &&
          listEquals(other.segments, segments);

  @override
  int get hashCode => Object.hash(skipped, Object.hashAll(segments));

  @override
  String toString() =>
      'TranscriptReadResult(segments: ${segments.length}, skipped: $skipped)';
}

/// 追加写的转写稿存储。
///
/// **文件布局**:`<root>/<circleId>/<sessionId>.jsonl`。
/// 按圈子分目录而不是把 circleId 拼进文件名,有两个实际好处:
/// 1. 磁盘清理可以直接以圈子为单位整目录删/整目录统计;
/// 2. 一个圈子几千个会话时,单目录条目数不至于爆炸到影响文件系统枚举。
/// circleId / sessionId 来自用户侧数据,**必须**先过 [sanitizeIdComponent]。
class TranscriptStore {
  TranscriptStore({required this.root});

  /// 根目录,由调用方注入(真实链路传应用支持目录,测试传临时目录)。
  final Directory root;

  /// 某个会话的转写稿文件路径。
  File fileFor({required String circleId, required String sessionId}) {
    final String circle = sanitizeIdComponent(circleId);
    final String session = sanitizeIdComponent(sessionId);
    return File(
      '${root.path}${Platform.pathSeparator}$circle'
      '${Platform.pathSeparator}$session$kTranscriptExtension',
    );
  }

  /// 追加一条,并**逐条 flush**。
  ///
  /// 每条都 flush 看着浪费,但这正是整个设计的目的:进程可能在任何一刻
  /// 被杀(用户强退、系统 OOM、断电)。缓冲区里攒着的十几条转写就这么没了,
  /// 而用户永远不知道自己丢了什么。一条转写几百字节,每秒最多几条,
  /// 这点 IO 相对于"转写稿可信"完全值得。
  Future<void> append(
    TranscriptSegment segment, {
    required String circleId,
    required String sessionId,
  }) async {
    final File f = fileFor(circleId: circleId, sessionId: sessionId);
    await f.parent.create(recursive: true);
    final IOSink sink = f.openWrite(mode: FileMode.writeOnlyAppend);
    try {
      sink.writeln(jsonEncode(segment.toJson()));
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  /// 批量追加(同一次打开里写完再 flush)。
  ///
  /// 仅用于**导入/迁移**这类一次性场景。实时转写请用 [append]:
  /// 批量写意味着这一批要么全在、要么全丢,失去了逐条落盘的抗崩溃性。
  Future<void> appendAll(
    Iterable<TranscriptSegment> segments, {
    required String circleId,
    required String sessionId,
  }) async {
    final File f = fileFor(circleId: circleId, sessionId: sessionId);
    await f.parent.create(recursive: true);
    final IOSink sink = f.openWrite(mode: FileMode.writeOnlyAppend);
    try {
      for (final TranscriptSegment s in segments) {
        sink.writeln(jsonEncode(s.toJson()));
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  /// 读回整份转写稿。
  ///
  /// **坏行不致命**:JSON 解不动、字段类型不对、写到一半被截断 —— 一律
  /// 跳过并计数,继续读后面的行。崩溃场景下文件尾恰好留一行半截 JSON,
  /// 这是**预期情况而非异常**;要是为此抛异常,用户就会因为丢了最后一句话
  /// 而看不到前面几百句完好的转写,那才是真正的数据丢失。
  Future<TranscriptReadResult> read({
    required String circleId,
    required String sessionId,
  }) async {
    final File f = fileFor(circleId: circleId, sessionId: sessionId);
    if (!f.existsSync()) {
      return const TranscriptReadResult(
        segments: <TranscriptSegment>[],
        skipped: 0,
      );
    }
    return parseJsonl(await f.readAsString());
  }

  /// 列出某个圈子下已有的 sessionId(按文件名)。
  Future<List<String>> listSessions(String circleId) async {
    final Directory dir = Directory(
      '${root.path}${Platform.pathSeparator}${sanitizeIdComponent(circleId)}',
    );
    if (!dir.existsSync()) return <String>[];
    final List<String> out = <String>[];
    await for (final FileSystemEntity e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final String name = e.uri.pathSegments.last;
      if (!name.endsWith(kTranscriptExtension)) continue;
      out.add(name.substring(0, name.length - kTranscriptExtension.length));
    }
    out.sort();
    return out;
  }
}

/// 解析 JSONL 文本。纯函数,不碰文件系统,便于直接喂字符串做单测。
TranscriptReadResult parseJsonl(String content) {
  final List<TranscriptSegment> out = <TranscriptSegment>[];
  int skipped = 0;

  for (final String rawLine in const LineSplitter().convert(content)) {
    final String line = rawLine.trim();
    if (line.isEmpty) continue; // 空行不算坏行,纯粹是分隔噪声
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      skipped++;
      continue;
    }
    final TranscriptSegment? seg = TranscriptSegment.fromJson(decoded);
    if (seg == null) {
      skipped++;
      continue;
    }
    out.add(seg);
  }
  return TranscriptReadResult(segments: out, skipped: skipped);
}

/// 把用户侧 id 清洗成安全的路径片段。
///
/// 这些 id 来自圈子名/会话名一类**用户可控**的数据,直接拼进路径就是
/// 目录穿越漏洞(`../../`)外加 Windows 保留名雷区(`CON`、`NUL` 打不开)。
/// 策略是白名单:只放行字母数字和 `-_`,其余一律换成 `_`,再处理保留名与长度。
/// 清洗是**有损**的(两个不同 id 可能撞成同一个文件名),因此调用方应当
/// 保证 id 本身就是机器生成的 uuid/短码,清洗只是最后一道防线。
String sanitizeIdComponent(String raw) {
  final StringBuffer buf = StringBuffer();
  for (final int rune in raw.runes) {
    final bool ok =
        (rune >= 0x30 && rune <= 0x39) || // 0-9
        (rune >= 0x41 && rune <= 0x5A) || // A-Z
        (rune >= 0x61 && rune <= 0x7A) || // a-z
        rune == 0x2D || // -
        rune == 0x5F; // _
    buf.writeCharCode(ok ? rune : 0x5F);
  }
  String s = buf.toString();
  if (s.isEmpty) s = '_';
  // 超长文件名在部分文件系统上直接写失败,截断到一个保守长度。
  if (s.length > 64) s = s.substring(0, 64);
  // Windows 保留设备名:即使带扩展名也打不开,加前缀绕开。
  const Set<String> reserved = <String>{
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };
  if (reserved.contains(s.toUpperCase())) s = '_$s';
  return s;
}

/// 导出为人类可读的 Markdown。
///
/// **连续同一说话人只写一次名字**。逐条重复 "张三:" 在真实对话里极其难读 ——
/// 一个人说三句话就出现三次名字,视觉噪声盖过内容。按说话人分块之后,
/// 转写稿读起来才像剧本而不像日志。分块认 [TranscriptSegment.speakerIdentity]
/// 而不是显示名:同一个人中途改了昵称不该被拆成两个人。
///
/// [toLocal] 控制时间戳是否转成本地时区显示(落盘存的是 UTC)。
String exportTranscriptMarkdown(
  List<TranscriptSegment> segments, {
  String? title,
  bool toLocal = true,
}) {
  final StringBuffer buf = StringBuffer();
  if (title != null && title.isNotEmpty) {
    buf
      ..writeln('# $title')
      ..writeln();
  }
  if (segments.isEmpty) {
    buf.writeln('_(没有转写内容)_');
    return buf.toString();
  }

  String? currentSpeaker;
  for (final TranscriptSegment s in segments) {
    if (s.speakerIdentity != currentSpeaker) {
      if (currentSpeaker != null) buf.writeln();
      buf
        ..writeln('## ${s.speakerName}')
        ..writeln();
      currentSpeaker = s.speakerIdentity;
    }
    final DateTime t = toLocal ? s.startedAt.toLocal() : s.startedAt.toUtc();
    buf.writeln('- `${formatClock(t)}` ${s.text}');
  }
  return buf.toString();
}

/// `HH:MM:SS`。不带日期:转写稿基本都在同一天内,带上日期只会挤占行宽。
String formatClock(DateTime t) {
  final String h = t.hour.toString().padLeft(2, '0');
  final String m = t.minute.toString().padLeft(2, '0');
  final String s = t.second.toString().padLeft(2, '0');
  return '$h:$m:$s';
}
