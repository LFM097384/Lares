// 概念稿的假数据:一个六人圈,周四夜谈,以隐名之约讨论社区图书角的预算。
import 'chatham_kit.dart';

class Seat {
  const Seat(this.glyph, this.name, {this.officer = false, this.me = false, this.verified = true});
  final String glyph;

  /// 已核验身份(放行只计已核验成员)。
  final bool verified;
  final String name;
  final bool officer;
  final bool me;
}

const List<Seat> kSeats = <Seat>[
  Seat('我', '我', me: true),
  Seat('鹿', '小鹿'),
  Seat('橘', '大橘'),
  Seat('禾', '青禾', verified: false),
  Seat('周', '老周'),
  Seat('蛮', '阿蛮', officer: true),
];

/// 参与放行表决的五人(安全员不投票)。
List<Seat> get kVoters => kSeats.where((Seat s) => !s.officer).toList();

const String kRuleEn =
    'When a meeting, or part thereof, is held under the Chatham House Rule, '
    'participants are free to use the information received, but neither the '
    'identity nor the affiliation of the speaker(s), nor that of any other '
    'participant, may be revealed.';

/// 官方中文译文(chathamhouse.org),逐字引用,不得改写。
const String kRuleZh =
    '如果一个会议，或会议的一部分，是按照Chatham House规则进行的，'
    '则与会者可自由使用在会议中获得的信息，但不得透露演讲者及其他与会者的身份与所属机构。';

class CaptionLine {
  const CaptionLine(this.who, this.text);
  final String who;
  final String text;
}

const List<CaptionLine> kCaptions = <CaptionLine>[
  CaptionLine('大橘', '我还是觉得三千块全买新书太冒险了。'),
  CaptionLine('青禾', '可以先拿一千试三个月，看借阅量再说。'),
  CaptionLine('小鹿', '书架那部分街道办说过能报销一半。'),
  CaptionLine('老周', '那剩下的钱留给周末的读书会？'),
];

/// 守门人审阅里的一段:原文被拆成片段,带删改理由的片段会高亮。
class Span {
  const Span(this.text, [this.reason]);
  final String text;
  final Redaction? reason;
}

const List<List<Span>> kRawLines = <List<Span>>[
  <Span>[
    Span('大橘', Redaction.identity),
    Span('：'),
    Span('我在', null),
    Span('区图书馆', Redaction.org),
    Span('干了'),
    Span('十一年', Redaction.detail),
    Span('，'),
    Span('“三千块全买新书就是打水漂”', Redaction.quote),
    Span('。'),
  ],
  <Span>[
    Span('小鹿', Redaction.identity),
    Span('：'),
    Span('街道办王主任', Redaction.org),
    Span('答应书架能报一半。'),
  ],
  <Span>[
    Span('青禾', Redaction.identity),
    Span('：先拿一千试三个月，看借阅量。'),
  ],
];

/// 隐名稿的主体(可放心出门的观点)。
const String kDigestMain =
    '有与会者认为一次性把预算全部用于购书风险较高，'
    '建议先以约三分之一的预算试行三个月，再依借阅数据决定后续投入；';

/// 被守门人标为「暴露角色」的一条:只有对接街道的人才会知道。
const String kDigestRoleClaim = '书架费用有望获得部分公共补贴。';

const String kDigest = '$kDigestMain$kDigestRoleClaim';
