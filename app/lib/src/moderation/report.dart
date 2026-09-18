import 'package:flutter/foundation.dart' show immutable;

/// 举报支持邮箱。以后要改地址,只改这一处。
const String kSupportEmail = 'support@laresapp.org';

/// 举报分类。审核员会实测这个列表,分类要覆盖 1.2 常见滥用类型。
enum ReportReason {
  harassment('骚扰或人身攻击'),
  hateSpeech('仇恨或歧视言论'),
  sexualContent('色情或性暗示内容'),
  violence('暴力或血腥内容'),
  illegal('违法或危险行为'),
  spam('垃圾信息或刷屏'),
  other('其他');

  const ReportReason(this.label);

  /// 给人看的中文名(选项列表、邮件正文里都用它)
  final String label;

  /// 给机器看的稳定标识。以后接服务端上报时用它,别用中文 label。
  String get wire => name;
}

/// 一次举报的全部内容。构造出来就不再改,直接交给 [buildReportBody] 渲染。
@immutable
class ReportDraft {
  const ReportDraft({
    required this.targetUserId,
    required this.targetName,
    required this.circleId,
    required this.timestamp,
    required this.reason,
    required this.note,
    required this.reporterUserId,
    this.messageId,
    this.messageExcerpt,
  });

  /// 被举报者的稳定身份(userId,昵称随时会改,追责只能认这个)
  final String targetUserId;

  /// 举报当时对方的昵称,只是给人看的上下文
  final String targetName;

  final String circleId;

  final DateTime timestamp;

  final ReportReason reason;

  /// 举报人补充的自由文本,可以为空
  final String note;

  /// 举报具体某条消息时才有;举报「这个人」时为 null
  final String? messageId;

  /// 违规文本的短摘录,用 [excerptForReport] 生成
  final String? messageExcerpt;

  final String reporterUserId;
}

/// 邮件主题
String buildReportSubject(ReportDraft d) =>
    '[Lares 举报] ${d.reason.label} · ${d.targetUserId}';

/// 邮件正文(纯文本,中文)。
///
/// 每项单独一行、带中文标签,方便人工快速核对;
/// 没有消息上下文时,消息相关的两行整行省掉,不留空标签。
String buildReportBody(ReportDraft d) {
  final lines = <String>[
    '以下内容由 Lares 自动生成,请勿删改。',
    '',
    '被举报者 ID: ${d.targetUserId}',
    '被举报者昵称: ${d.targetName}',
    '圈子 ID: ${d.circleId}',
    '举报时间: ${d.timestamp.toUtc().toIso8601String()}',
    '举报理由分类: ${d.reason.label}',
  ];
  final messageId = d.messageId;
  if (messageId != null && messageId.isNotEmpty) {
    lines.add('消息 ID: $messageId');
  }
  final excerpt = d.messageExcerpt;
  if (excerpt != null && excerpt.trim().isNotEmpty) {
    lines.add('消息摘录: $excerpt');
  }
  lines.addAll([
    '补充说明: ${d.note.trim().isEmpty ? '(无)' : d.note.trim()}',
    '举报人 ID: ${d.reporterUserId}',
    '',
    '我们会在 24 小时内处理完这条举报,并把结果回复到这个邮箱。',
  ]);
  return lines.join('\n');
}

/// 截取一小段违规文本放进举报里。
///
/// 按 **runes** 截而不是按 code unit:中文和 emoji 在 UTF-16 里占两个 code unit,
/// 按 code unit 切会把代理对劈成两半,邮件里就是一串乱码。
/// (ZWJ 组合 emoji 如「👨‍👩‍👧」仍可能从中间断开,但至少每个码点都是完整的,
/// 不会产生非法字符 —— 举报摘录只求可读,不值得为此引依赖。)
///
/// null 或纯空白返回 `''`。
String excerptForReport(String? text, {int maxChars = 200}) {
  if (text == null) return '';
  final trimmed = text.trim();
  if (trimmed.isEmpty) return '';
  final runes = trimmed.runes.toList();
  if (runes.length <= maxChars) return trimmed;
  return '${String.fromCharCodes(runes.take(maxChars))}…';
}

/// 组一个 mailto: 链接。编码交给 SDK 处理,别自己拼 %XX。
Uri buildReportMailtoUri(ReportDraft d) => Uri(
      scheme: 'mailto',
      path: kSupportEmail,
      queryParameters: <String, String>{
        'subject': buildReportSubject(d),
        'body': buildReportBody(d),
      },
    );
