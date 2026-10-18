/// 隐名之约(受 Chatham House 规则启发 · 非官方)的客户端状态。
///
/// v2 协议见 server/anonym-agent/AGENT-V2.md:AI 作为**成员**(`u_ai_anon_*`)入房,
/// 信令服务器不碰会话内容。两条通道:
///
/// - **信令 WS**(构造时注入的 [AnonymController.new] `send`;入口 [handle]):只有元数据 ——
///   圈主 `anon_agent_invite` / `anon_agent_dismiss` / `anon_agent_key`,
///   服务器 `anon_agent_state` / `anon_agent_keyreq` / `anon_error`(§3、§2)。
/// - **LiveKit data topic `lares.anon`**(注入的 `sendData`;入口 [handleData]):会话本身(§4)。
///   发:`ack` `ask` `skill` `review` `approve` `mem_list` `mem_retract` `end`,只发给 agent;
///   收:agent 广播的 `state` `answer` `draft` `approvals` `released` `mem` `mem_retracted`
///   `ended` `error`。**只认本圈 agent 身份发来的帧**。E2EE 圈里 data 随房间一起加密。
///
/// 本机只管住只在内存里的东西(会话签名密钥、室内问答、出门稿),到点就销毁:
/// - 收到 `ended`:密钥、问答、出门稿立刻清掉;只留散会卡要用的回执和已放行原文,
///   卡片 [dismissEnded] 后再清;
/// - 离开房间 / 换圈([bindRoom]):全部清掉,散会卡也不留;
/// - `state{active:false}` 或 `anon_agent_state{present:false}`:全部清掉。
///
/// 客户端**不再**把本人字幕喂给任何人(v1 的 `anon_utt` 已删):agent 自己听、自己转写,
/// 且只转写已 ack 的成员。字幕胶水层只经 [AnonymCaptionGate] 知道「此刻别归档」。
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';

import 'anonym_crypto.dart';
import 'anonym_seal.dart';

typedef AnonymSend = void Function(Map<String, dynamic> msg);

/// 经 LiveKit data(topic `lares.anon`,reliable)把 [msg] 只发给 [to] 这个 agent 身份。
typedef AnonymDataSend = void Function(Map<String, dynamic> msg, String to);

/// 本圈 E2EE 媒体密钥 hex(`lares-e2ee-v2` 派生值);本机拿不到为 null。
typedef AnonymMediaKeyFor = Future<String?> Function(String circleId);

/// 把 [plaintext] 密封给 agent 的 X25519 公钥(见 anonym_seal.dart)。
typedef AnonymSealer = Future<String> Function(
    List<int> agentPub, String plaintext, String circleId);

/// LiveKit data topic(AGENT-V2.md §4)。
const String kAnonTopic = 'lares.anon';

/// 隐名 agent 的 LiveKit 身份前缀(区别于语音助手的 `u_ai_`)。
const String kAnonAgentPrefix = 'u_ai_anon_';

/// 本圈隐名 agent 的身份:`u_ai_anon_` + sha256(circleId) 的前 8 个 hex。
String anonAgentIdentityFor(String circleId) =>
    '$kAnonAgentPrefix${sha256.convert(utf8.encode(circleId)).toString().substring(0, 8)}';

/// 字幕胶水层看到的那一面(见 CaptionWiring)。
abstract interface class AnonymCaptionGate implements Listenable {
  /// 本房间正在隐名之约中:转写记录必须停。
  bool get sessionActive;
}

/// 圈主收到的 `anon_agent_keyreq`:agent 要本圈媒体密钥。
@immutable
class AnonymKeyRequest {
  const AnonymKeyRequest({
    required this.circleId,
    required this.x25519PubB64,
    required this.x25519Pub,
  });
  final String circleId;

  /// 原样回显给服务器(`anon_agent_key.x25519Pub`)。
  final String x25519PubB64;
  final List<int> x25519Pub;
}

@immutable
class AnonymMember {
  const AnonymMember({
    required this.id,
    required this.name,
    required this.acked,
  });
  final String id;
  final String name;
  final bool acked;
}

@immutable
class AnonymAnswer {
  const AnonymAnswer({
    required this.askerName,
    required this.question,
    required this.answer,
  });
  final String askerName;
  final String question;
  final String answer;
}

@immutable
class AnonymDraftItem {
  const AnonymDraftItem({
    required this.id,
    required this.text,
    required this.roleRisk,
    this.topic,
    this.reason,
    this.flags = const [],
  });
  final String id;
  final String text;

  /// 小节标题(服务器原样给的;放行文本里是 `## topic`,也在 draftHash 里)。没给为 null。
  final String? topic;

  /// 这一条可能把话指回某位与会者的角色 / 职位。
  final bool roleRisk;
  final String? reason;
  final List<String> flags;
}

@immutable
class AnonymDraft {
  const AnonymDraft({
    required this.draftId,
    required this.draftHash,
    required this.items,
    this.metrics = const {},
  });
  final String draftId;
  final String draftHash;
  final List<AnonymDraftItem> items;

  /// 服务器给什么就显示什么(只收数字 / 字符串 / 布尔);没给就不显示。
  final Map<String, Object> metrics;
}

@immutable
class AnonymReceipt {
  const AnonymReceipt({required this.counts, required this.sha256});

  /// 计数(服务器给什么键就显示什么键)。
  final Map<String, num> counts;
  final String sha256;
}

/// 圈子记忆条目的类型(与 server core/memory.mjs 的 `kind` 字面量一致)。
/// 不认识的类型一律归 [other],照样显示。
enum AnonymMemoryKind {
  idea('idea'),
  decision('decision'),
  todo('todo'),
  fact('fact'),
  other('');

  const AnonymMemoryKind(this.wire);
  final String wire;

  static AnonymMemoryKind parse(Object? v) {
    for (final k in values) {
      if (k != other && k.wire == v) return k;
    }
    return other;
  }
}

/// 圈子记忆(知识面)里的一条:经 k-of-n 放行的去名内容,**永不含说话人**。
///
/// 墓碑([retracted])只有 id,没有正文 —— 服务器不给,本机也不留。
@immutable
class AnonymMemoryItem {
  const AnonymMemoryItem({
    required this.id,
    this.text,
    this.kind = AnonymMemoryKind.other,
    this.sid,
    this.releasedAt,
    this.approvals,
    this.retracted = false,
    this.retractedAt,
    this.canRetract,
  });

  const AnonymMemoryItem.tombstone(this.id, {this.retractedAt})
    : text = null,
      kind = AnonymMemoryKind.other,
      sid = null,
      releasedAt = null,
      approvals = null,
      retracted = true,
      canRetract = false;

  final String id;

  /// 墓碑为 null。
  final String? text;
  final AnonymMemoryKind kind;
  final String? sid;
  final DateTime? releasedAt;

  /// 放行签名数 N。
  final int? approvals;
  final bool retracted;

  /// 撤回时间(只有墓碑才有;服务器给了才有)。
  final DateTime? retractedAt;

  /// 服务器明说我能不能撤回(没说为 null)。
  final bool? canRetract;
}

/// 审阅动作(与 server 的 `action` 字面量一致)。
enum AnonymReviewAction {
  keep('keep'),
  generalise('generalise'),
  cut('cut');

  const AnonymReviewAction(this.wire);
  final String wire;
}

class AnonymController extends ChangeNotifier implements AnonymCaptionGate {
  AnonymController({
    required AnonymSend send,
    AnonymDataSend? sendData,
    AnonymMediaKeyFor? mediaKeyFor,
    AnonymSealer? sealer,
    AnonymKeys Function()? keyFactory,
    String Function()? nonceFactory,
  }) : _send = send,
       _sendData = sendData,
       _mediaKeyFor = mediaKeyFor,
       _sealer = sealer ??
           ((pub, pt, cid) => anonSeal(agentPub: pub, plaintext: pt, circleId: cid)),
       _keyFactory = keyFactory ?? AnonymKeys.generate,
       _nonceFactory = nonceFactory ?? newNonce;

  final AnonymSend _send;
  AnonymDataSend? _sendData;
  AnonymMediaKeyFor? _mediaKeyFor;
  final AnonymSealer _sealer;
  final AnonymKeys Function() _keyFactory;
  final String Function() _nonceFactory;

  /// 晚绑定(main.dart 里 rtc / e2ee 比本控制器晚建好时用)。
  set sendData(AnonymDataSend? v) => _sendData = v;
  set mediaKeyFor(AnonymMediaKeyFor? v) => _mediaKeyFor = v;

  // ── 房间 ──────────────────────────────────────────────────────────────
  String? _circleId;
  bool _inRoom = false;
  String? _myUserId;

  String? get circleId => _circleId;

  // ── agent(信令元数据)───────────────────────────────────────────────────
  bool _agentPresent = false;
  bool _agentActive = false;
  String? _agentIdentity;
  bool _invitePending = false;
  AnonymKeyRequest? _keyRequest;
  bool _keySending = false;

  /// agent 此刻在房里(服务器 `anon_agent_state.present`,或收到过它的 `state`)。
  bool get agentPresent => _agentPresent;

  /// 已发出邀请、agent 还没到。
  bool get invitePending => _invitePending && !_agentPresent;

  /// 本圈 agent 的 LiveKit 身份(没在房里时也给按约定算出的那个)。
  String? get agentIdentity =>
      _agentIdentity ?? (_circleId == null ? null : anonAgentIdentityFor(_circleId!));

  /// 圈主待确认的密钥请求(非 null → 弹确认面板)。
  AnonymKeyRequest? get keyRequest => _keyRequest;
  bool get keySending => _keySending;

  /// [identity] 是不是本圈隐名 agent。
  bool isAgentIdentity(String identity) {
    if (identity.isEmpty) return false;
    if (_agentIdentity != null) return identity == _agentIdentity;
    final String? c = _circleId;
    return c != null && identity == anonAgentIdentityFor(c);
  }

  // ── 会话 ──────────────────────────────────────────────────────────────
  bool _active = false;
  String? _sid;
  int _k = 0;
  List<AnonymMember> _members = const [];
  String? _convenerId;

  /// 本机已发出 anon_ack 的会话 sid。
  String? _ackedSid;

  /// 本机在这场会话里点了「暂不加入」。
  String? _declinedSid;
  AnonymKeys? _keys;

  final List<AnonymAnswer> _answers = [];
  bool _askPending = false;
  AnonymDraft? _draft;
  bool _draftPending = false;
  int _approvals = 0;
  int _approvalsK = 0;

  /// 本机已签过的 draftHash(签过的稿子不能再签;改过的稿子 hash 会变)。
  String? _approvedHash;
  String? _releasedText;
  AnonymReceipt? _receipt;
  String? _lastError;

  // ── 圈子记忆(知识面,服务器持久化)────────────────────────────────────
  // 不是会话状态:anon_ended / anon_state{active:false} 都不清它;只在离房 / 换圈时清。
  String? _memCircleId;
  List<AnonymMemoryItem>? _memItems;
  bool _memLoading = false;
  String? _memError;
  final Set<String> _memRetracting = {};

  /// 记忆列表属于哪个圈(没取过 / 已清为 null)。
  String? get memoryCircleId => _memCircleId;

  /// null = 还没收到过列表。
  List<AnonymMemoryItem>? get memoryItems =>
      _memItems == null ? null : List.unmodifiable(_memItems!);
  bool get memoryLoading => _memLoading;
  String? get memoryError => _memError;

  /// 已发出撤回、还没等到服务器确认的条目。
  bool memoryRetracting(String itemId) => _memRetracting.contains(itemId);

  /// 我能不能撤回这一条:圈主,或服务器说 canRetract。墓碑不能再撤。
  bool mayRetract(AnonymMemoryItem item, {required bool isOwner}) {
    if (item.retracted) return false;
    return isOwner || item.canRetract == true;
  }

  bool get active => _active;
  String? get sid => _sid;
  int get k => _k;
  List<AnonymMember> get members => _members;
  String? get convenerId => _convenerId;
  String? get convenerName {
    for (final m in _members) {
      if (m.id == _convenerId) return m.name;
    }
    return null;
  }

  /// 本机已加入这场会话(发过 ack)。
  bool get acked => _active && _sid != null && _ackedSid == _sid;
  bool get declined => _active && _sid != null && _declinedSid == _sid;

  /// 该弹同意书了:会话进行中,我还没表态。
  bool get needsConsent => _active && _inRoom && !acked && !declined;

  /// 会话公钥(只给测试和自检看;wipe 后为 null)。
  @visibleForTesting
  AnonymKeys? get keys => _keys;

  List<AnonymAnswer> get answers => List.unmodifiable(_answers);
  bool get askPending => _askPending;
  AnonymDraft? get draft => _draft;
  bool get draftPending => _draftPending;
  int get approvals => _approvals;

  /// 放行门槛:服务器 anon_approvals 给的 k 优先,否则用会话的 k。
  int get approvalsK => _approvalsK > 0 ? _approvalsK : _k;
  bool get approvedCurrent =>
      _draft != null && _approvedHash == _draft!.draftHash;
  String? get releasedText => _releasedText;

  /// 非 null = 该显示散会卡。
  AnonymReceipt? get receipt => _receipt;
  String? get lastError => _lastError;

  /// 转写记录要停:agent 报了 active(信令 `anon_agent_state.active` 或 data `state.active`)。
  @override
  bool get sessionActive => _active || (_agentPresent && _agentActive);

  // ── 房间生命周期 ────────────────────────────────────────────────────────

  /// 房间状态变了就调(RoomController 每次 notify)。离房 / 换圈 → 全部销毁。
  void bindRoom({
    required String? circleId,
    required bool inRoom,
    String? myUserId,
  }) {
    _myUserId = myUserId ?? _myUserId;
    final bool left =
        (_inRoom && !inRoom) || (_circleId != null && circleId != _circleId);
    _circleId = circleId;
    final bool changed = _inRoom != inRoom;
    _inRoom = inRoom;
    // 记忆:离房 / 换圈,或刚进了别的圈的房,就清。只看「变化」那一刻,
    // 首页长按打开别的圈的记忆时,房间里平常的 notify 不会把它冲掉。
    final bool memStale =
        _memCircleId != null &&
        (left || (changed && inRoom && circleId != _memCircleId));
    if (memStale) _wipeMemory();
    if (left) {
      _wipeAll(includeEnded: true);
      _wipeAgent();
      notifyListeners();
    } else if (memStale) {
      notifyListeners();
    } else if (changed) {
      notifyListeners();
    }
  }

  /// 本人是不是这场会话的召集人。
  bool get iAmConvener =>
      _convenerId != null && _myUserId != null && _convenerId == _myUserId;

  // ── 收 ────────────────────────────────────────────────────────────────

  /// **信令** 消息入口:只有元数据(`anon_agent_state` / `anon_agent_keyreq` / `anon_error`)。
  /// 会话本身走 [handleData]。断线期间(`_disconnected`)不动状态,重连后服务器会重报。
  void handle(Map<String, dynamic> msg) {
    final Object? t = msg['t'];
    if (t is! String || !t.startsWith('anon_')) return;
    final Object? cid = msg['circleId'];
    switch (t) {
      case 'anon_error':
        _onError(msg, cid);
        return;
      case 'anon_agent_state':
        if (cid is! String || cid != _circleId) return;
        _onAgentState(msg);
        notifyListeners();
        return;
      case 'anon_agent_keyreq':
        if (cid is! String || cid != _circleId || !_inRoom) return;
        final String? raw = _str(msg['x25519Pub']);
        final List<int>? pub = parseX25519Pub(raw);
        if (raw == null || pub == null) return;
        _keyRequest = AnonymKeyRequest(
          circleId: cid,
          x25519PubB64: raw,
          x25519Pub: pub,
        );
        notifyListeners();
        return;
      default:
        return;
    }
  }

  void _onAgentState(Map<String, dynamic> msg) {
    final bool present = msg['present'] == true;
    _agentPresent = present;
    _agentActive = present && msg['active'] == true;
    if (present) {
      _invitePending = false;
      final String? id = _str(msg['identity']) ?? _str(msg['agentId']);
      if (id != null && id.startsWith('u_ai_')) _agentIdentity = id;
    } else {
      _agentIdentity = null;
      _keyRequest = null;
      _keySending = false;
      // agent 走了:会话随之结束(散会卡若已开着,原文留到卡片关掉)
      if (_active) {
        final String? keep = _receipt != null ? _releasedText : null;
        _wipeAll(includeEnded: false);
        _releasedText = keep;
      }
    }
  }

  /// **LiveKit data** 入口(topic `lares.anon`)。[senderIdentity] 必须是本圈 agent,
  /// 否则一律丢弃 —— 别的成员冒充 agent 广播 `state` / `released` 不能生效。
  void handleData(String senderIdentity, List<int> bytes) {
    if (!_inRoom || !isAgentIdentity(senderIdentity)) return;
    final Map<String, dynamic>? msg = decodeFrame(bytes);
    if (msg == null) return;
    // 收到了它的帧,它就在房里(信令的 anon_agent_state 可能还在路上)
    _agentIdentity ??= senderIdentity;
    _agentPresent = true;
    _invitePending = false;
    final String t = msg['t'] as String;
    final String? c = _circleId;
    switch (t) {
      case 'mem':
      case 'mem_retracted':
        if (c == null || c != _memCircleId) return;
        _handleMemory(t, c, msg);
        notifyListeners();
        return;
      case 'error':
        _onError(msg, null);
        return;
      case 'state':
        _onState(msg);
      case 'answer':
        if (!_active) return;
        final String? a = _str(msg['a']) ?? _str(msg['answer']);
        if (a == null) return;
        _answers.add(
          AnonymAnswer(
            askerName: _str(msg['askerName']) ?? '',
            question: _str(msg['q']) ?? _str(msg['question']) ?? '',
            answer: a,
          ),
        );
        _askPending = false;
      case 'draft':
        if (!_active) return;
        final AnonymDraft? d = parseDraft(msg['draft']);
        if (d == null) return;
        if (_draft?.draftId != d.draftId) {
          _approvals = 0;
          _approvalsK = 0;
        }
        _draft = d;
        _draftPending = false;
        _releasedText = null;
      case 'approvals':
        if (!_active) return;
        final String? id = _str(msg['draftId']);
        if (_draft != null && id != null && id != _draft!.draftId) return;
        _approvals = _int(msg['count']) ?? _approvals;
        _approvalsK = _int(msg['k']) ?? _approvalsK;
      case 'released':
        if (!_active) return;
        final String? text = _str(msg['text']);
        if (text == null) return;
        _releasedText = text;
        _draftPending = false;
      case 'ended':
        // 散会卡只给加入过(ack)这场的人;没加入的只看到会话结束
        final bool wasAcked = acked;
        final AnonymReceipt r =
            parseReceipt(msg['receipt']) ??
            const AnonymReceipt(counts: {}, sha256: '');
        final String? released = _releasedText;
        _wipeAll(includeEnded: true);
        if (wasAcked) {
          _receipt = r;
          _releasedText = released;
        }
      default:
        return;
    }
    notifyListeners();
  }

  /// 一帧 data → JSON 对象。不是 UTF-8 JSON 对象、或没有字符串 `t` → null。
  @visibleForTesting
  static Map<String, dynamic>? decodeFrame(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > 256 * 1024) return null;
    try {
      final Object? v = jsonDecode(utf8.decode(bytes));
      if (v is! Map) return null;
      final Map<String, dynamic> m = v.cast<String, dynamic>();
      return m['t'] is String ? m : null;
    } on FormatException {
      return null;
    }
  }

  /// `error` / `anon_error` 按 `op` 分流:`mem_*` 只算记忆页的,其余算室内问答 / 出门稿的。
  /// op 两种写法都认(v2 的 `approve`,以及带 `anon_` 前缀的)。
  void _onError(Map<String, dynamic> msg, Object? cid) {
    final String code = _str(msg['code']) ?? 'unknown';
    final Object? rawOp = msg['op'];
    final String? op = rawOp is String
        ? (rawOp.startsWith('anon_') ? rawOp.substring(5) : rawOp)
        : null;
    if (op != null && op.startsWith('mem_')) {
      if (cid != null && cid != _memCircleId) return;
      _memError = code;
      _memLoading = false;
      _memRetracting.clear();
    } else {
      // 带了 circleId 就必须是当前圈;可能不带
      if (cid != null && cid != _circleId) return;
      // 签名被拒(bad_sig / replay / rate_limited…):放开按钮,允许用新 nonce 再签
      if (op == 'approve') _approvedHash = null;
      if (op == 'agent_invite') _invitePending = false;
      if (op == 'agent_key') _keySending = false;
      _lastError = code;
      _askPending = false;
      _draftPending = false;
    }
    notifyListeners();
  }

  void _handleMemory(String t, String cid, Map<String, dynamic> msg) {
    if (t == 'mem') {
      final Object? raw = msg['items'];
      if (raw is! List) return;
      final List<AnonymMemoryItem> items = parseMemoryItems(raw);
      _memItems = items;
      _memLoading = false;
      _memError = null;
      // 已确认(成了墓碑 / 不在了)的撤回不再算「等确认」
      _memRetracting.removeWhere(
        (id) => !items.any((it) => it.id == id && !it.retracted),
      );
      return;
    }
    // mem_retracted
    final String? id = _id(msg['itemId']);
    if (id == null) return;
    _memRetracting.remove(id);
    final List<AnonymMemoryItem>? items = _memItems;
    if (items == null) return;
    for (int i = 0; i < items.length; i++) {
      if (items[i].id == id) {
        items[i] = AnonymMemoryItem.tombstone(
          id,
          retractedAt: parseReleasedAt(msg['retractedAt']),
        );
      }
    }
  }

  void _onState(Map<String, dynamic> msg) {
    final bool active = msg['active'] == true;
    _agentActive = active;
    if (!active) {
      // 散会卡还开着时(ended 之后 agent 常再报一次 inactive),
      // 已放行原文要留到卡片关掉。
      final String? keep = _receipt != null ? _releasedText : null;
      if (_active) _wipeAll(includeEnded: false);
      _releasedText = keep;
      return;
    }
    final String? sid = _str(msg['sid']);
    if (sid == null) return;
    if (_sid != null && _sid != sid) {
      // 换了一场:上一场的东西不得带进来
      _wipeAll(includeEnded: false);
    }
    _receipt = null;
    _active = true;
    _sid = sid;
    _k = _int(msg['k']) ?? _k;
    _convenerId = _str(msg['convenerId']) ?? _convenerId;
    final Object? raw = msg['members'];
    if (raw is List) {
      _members = [
        for (final m in raw)
          if (m is Map && _str(m['id']) != null)
            AnonymMember(
              id: _str(m['id'])!,
              name: _str(m['name']) ?? _str(m['id'])!,
              acked: m['acked'] == true,
            ),
      ];
    }
    // 断线重连 / agent 重启后把我列成「未加入」,但本机还握着这场的钥匙:
    // 同一把公钥再报一次,不用再签一次同意书。
    if (acked && _keys != null && _myUserId != null) {
      for (final m in _members) {
        if (m.id == _myUserId && !m.acked) {
          resendAck();
          break;
        }
      }
    }
  }

  // ── 发 ────────────────────────────────────────────────────────────────

  /// 经 data 通道发给 agent。agent 不在 / 没接通道 → 不发(返回 false)。
  bool _toAgent(Map<String, dynamic> msg) {
    final AnonymDataSend? send = _sendData;
    final String? to = agentIdentity;
    if (send == null || to == null || !_inRoom) return false;
    send(msg, to);
    return true;
  }

  /// 圈主:请隐名之约 AI 入房(信令 `anon_agent_invite`)。k 由调用方按 2..n 夹好。
  void invite(int k) {
    final String? c = _circleId;
    if (c == null || !_inRoom) return;
    _lastError = null;
    _invitePending = true;
    _send({'t': 'anon_agent_invite', 'circleId': c, 'k': k});
    notifyListeners();
  }

  /// 圈主:请 AI 离开(信令 `anon_agent_dismiss`)。
  void dismiss() {
    final String? c = _circleId;
    if (c == null) return;
    _invitePending = false;
    _keyRequest = null;
    _send({'t': 'anon_agent_dismiss', 'circleId': c});
    notifyListeners();
  }

  /// 圈主拒绝 agent 的密钥请求:不发任何东西,agent 进不了加密房。
  void declineKeyRequest() {
    if (_keyRequest == null) return;
    _keyRequest = null;
    notifyListeners();
  }

  /// 圈主同意:把本圈媒体密钥 hex 密封给 agent 的临时公钥,发 `anon_agent_key`。
  /// 拿不到密钥(本机没口令)→ 报 `no_media_key`,什么都不发。
  Future<void> acceptKeyRequest() async {
    final AnonymKeyRequest? req = _keyRequest;
    final AnonymMediaKeyFor? keyFor = _mediaKeyFor;
    if (req == null || _keySending) return;
    _keySending = true;
    notifyListeners();
    String? sealed;
    try {
      final String? hex = keyFor == null ? null : await keyFor(req.circleId);
      if (hex != null && hex.isNotEmpty) {
        sealed = await _sealer(req.x25519Pub, hex, req.circleId);
      }
    } catch (e) {
      debugPrint('[lares] 隐名之约密钥密封失败: $e');
      sealed = null;
    }
    // 等待期间换了请求 / 离房:作废
    if (!identical(_keyRequest, req) || _circleId != req.circleId || !_inRoom) {
      _keySending = false;
      notifyListeners();
      return;
    }
    _keySending = false;
    _keyRequest = null;
    if (sealed == null) {
      _lastError = 'no_media_key';
    } else {
      _send({
        't': 'anon_agent_key',
        'circleId': req.circleId,
        'sealed': sealed,
        'x25519Pub': req.x25519PubB64,
      });
    }
    notifyListeners();
  }

  /// 圈主散会(data `end`;agent 只认召集人 / 圈主)。
  void end() {
    if (!_active) return;
    _toAgent({'t': 'end'});
  }

  /// 同意并加入:现生成一对只在内存里的会话密钥,把公钥发给 agent。
  void accept() {
    final String? sid = _sid;
    if (_circleId == null || sid == null || !_active) return;
    _keys?.wipe();
    final AnonymKeys keys = _keyFactory();
    _keys = keys;
    _ackedSid = sid;
    _declinedSid = null;
    _toAgent({'t': 'ack', 'pubKey': keys.pubKeyB64});
    notifyListeners();
  }

  void decline() {
    if (!_active || _sid == null) return;
    _declinedSid = _sid;
    notifyListeners();
  }

  /// 断线重连回到同一房间后,把同一把公钥再报一次(agent 会话内钉住同一把钥匙)。
  void resendAck() {
    final AnonymKeys? keys = _keys;
    if (_circleId == null || keys == null || !acked) return;
    _toAgent({'t': 'ack', 'pubKey': keys.pubKeyB64});
  }

  void ask(String question) {
    final String q = question.trim();
    if (_circleId == null || !acked || q.isEmpty) return;
    _askPending = true;
    _toAgent({'t': 'ask', 'q': q});
    notifyListeners();
  }

  /// 跑一个 skill。`minutes`(导出会议纪要)的结果走出门稿 → 审阅 → 放行。
  void runSkill(String name, {Map<String, dynamic>? args}) {
    if (_circleId == null || !acked || name.isEmpty) return;
    if (name == 'minutes') _draftPending = true;
    _lastError = null;
    _toAgent({
      't': 'skill',
      'name': name,
      'args': ?args,
    });
    notifyListeners();
  }

  /// 导出会议纪要(= `skill{name:'minutes'}`)。
  void requestMinutes() => runSkill('minutes');

  void review(String itemId, AnonymReviewAction action) {
    final AnonymDraft? d = _draft;
    if (_circleId == null || d == null || !acked) return;
    _toAgent({
      't': 'review',
      'draftId': d.draftId,
      'itemId': itemId,
      'action': action.wire,
    });
  }

  /// 签名同意放行当前稿(签的是 [approvalMessage],见 anonym_crypto.dart)。
  void approve() {
    final String? sid = _sid;
    final AnonymDraft? d = _draft;
    final AnonymKeys? keys = _keys;
    if (_circleId == null || sid == null || d == null || keys == null || !acked) {
      return;
    }
    if (_approvedHash == d.draftHash) return;
    final String nonce = _nonceFactory();
    final String sig = keys.sign(
      approvalMessage(
        sid: sid,
        draftId: d.draftId,
        draftHash: d.draftHash,
        nonce: nonce,
      ),
    );
    _approvedHash = d.draftHash;
    _toAgent({
      't': 'approve',
      'draftId': d.draftId,
      'draftHash': d.draftHash,
      'nonce': nonce,
      'sig': sig,
    });
    notifyListeners();
  }

  /// 取本圈记忆列表(data `mem_list`,回复 `mem`)。记忆由 agent 维护,
  /// 所以只能在**当前房间、agent 在场**时取;不在 → 报 `agent_absent`。
  void loadMemory({String? circleId}) {
    final String? c = circleId ?? _circleId;
    if (c == null) return;
    if (_memCircleId != c) {
      _memItems = null;
      _memRetracting.clear();
    }
    _memCircleId = c;
    _memError = null;
    if (c != _circleId || !_inRoom || !_agentPresent || !_toAgent({'t': 'mem_list'})) {
      _memLoading = false;
      _memError = 'agent_absent';
    } else {
      _memLoading = true;
    }
    notifyListeners();
  }

  /// 请求撤回一条记忆。**不**先删:等 agent 回 `mem_retracted` 或重发的列表。
  void retractMemory(String itemId) {
    final String? c = _memCircleId;
    final List<AnonymMemoryItem>? items = _memItems;
    if (c == null || items == null || c != _circleId) return;
    if (!items.any((it) => it.id == itemId && !it.retracted)) return;
    if (!_memRetracting.add(itemId)) return;
    _memError = null;
    if (!_toAgent({'t': 'mem_retract', 'itemId': itemId})) {
      _memRetracting.remove(itemId);
      _memError = 'agent_absent';
    }
    notifyListeners();
  }

  void clearMemoryError() {
    if (_memError == null) return;
    _memError = null;
    notifyListeners();
  }

  /// 关掉散会卡:回执和已放行原文也一并清掉。
  void dismissEnded() {
    if (_receipt == null && _releasedText == null) return;
    _receipt = null;
    if (!_active) _releasedText = null;
    notifyListeners();
  }

  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  // ── 销毁 ──────────────────────────────────────────────────────────────

  void _wipeAll({required bool includeEnded}) {
    _keys?.wipe();
    _keys = null;
    _active = false;
    _sid = null;
    _k = 0;
    _members = const [];
    _convenerId = null;
    _ackedSid = null;
    _declinedSid = null;
    _answers.clear();
    _askPending = false;
    _draft = null;
    _draftPending = false;
    _approvals = 0;
    _approvalsK = 0;
    _approvedHash = null;
    _releasedText = null;
    if (includeEnded) _receipt = null;
  }

  void _wipeAgent() {
    _agentPresent = false;
    _agentActive = false;
    _agentIdentity = null;
    _invitePending = false;
    _keyRequest = null;
    _keySending = false;
  }

  void _wipeMemory() {
    _memCircleId = null;
    _memItems = null;
    _memLoading = false;
    _memError = null;
    _memRetracting.clear();
  }

  @override
  void dispose() {
    _wipeAll(includeEnded: true);
    _wipeAgent();
    _wipeMemory();
    super.dispose();
  }

  // ── 纯函数 ────────────────────────────────────────────────────────────

  /// 默认门槛:过半再加一,封顶 n。
  static int defaultK(int n) => clampK((n / 2).ceil() + 1, n);

  /// 夹到 2..n(n<2 时为 2;这时本来就不该让人召集)。
  static int clampK(int k, int n) {
    final int hi = n < 2 ? 2 : n;
    return k < 2 ? 2 : (k > hi ? hi : k);
  }

  @visibleForTesting
  static AnonymDraft? parseDraft(Object? raw) {
    if (raw is! Map) return null;
    final String? id = _str(raw['draftId']);
    final String? hash = _str(raw['draftHash']);
    if (id == null || hash == null) return null;
    final List<AnonymDraftItem> items = [];
    final Object? rawItems = raw['items'];
    if (rawItems is List) {
      for (final it in rawItems) {
        if (it is! Map) continue;
        final String? iid =
            _str(it['id']) ?? (it['id'] is num ? '${it['id']}' : null);
        final String? text = _str(it['text']);
        if (iid == null || text == null) continue;
        final List<String> flags = [
          if (it['flags'] is List)
            for (final f in it['flags'] as List)
              if (f is String) f,
        ];
        items.add(
          AnonymDraftItem(
            id: iid,
            text: text,
            roleRisk:
                _roleRisk(it['roleRisk']) || flags.contains('role-revealing'),
            topic: it['topic'] is String ? it['topic'] as String : null,
            reason: _str(it['reason']),
            flags: flags,
          ),
        );
      }
    }
    final Map<String, Object> metrics = {};
    final Object? rawMetrics = raw['metrics'];
    if (rawMetrics is Map) {
      rawMetrics.forEach((key, value) {
        if (key is String &&
            (value is num || value is String || value is bool)) {
          metrics[key] = value as Object;
        }
      });
    }
    return AnonymDraft(
      draftId: id,
      draftHash: hash,
      items: items,
      metrics: metrics,
    );
  }

  @visibleForTesting
  static AnonymReceipt? parseReceipt(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, num> counts = {};
    final Object? c = raw['counts'];
    if (c is Map) {
      c.forEach((key, value) {
        if (key is String && value is num) counts[key] = value;
      });
    }
    return AnonymReceipt(counts: counts, sha256: _str(raw['sha256']) ?? '');
  }

  /// 解析 `anon_mem.items`。形状不对的条目跳过;墓碑只留 id(就算服务器多给了 text 也丢掉);
  /// 任何说话人字段都不读。
  @visibleForTesting
  static List<AnonymMemoryItem> parseMemoryItems(List<Object?> raw) {
    final List<AnonymMemoryItem> out = [];
    final Set<String> seen = {};
    for (final it in raw) {
      if (it is! Map) continue;
      final String? id = _id(it['id']);
      if (id == null || !seen.add(id)) continue;
      if (it['retracted'] == true) {
        out.add(
          AnonymMemoryItem.tombstone(
            id,
            retractedAt: parseReleasedAt(it['retractedAt']),
          ),
        );
        continue;
      }
      final String? text = _str(it['text']);
      if (text == null) continue;
      out.add(
        AnonymMemoryItem(
          id: id,
          text: text,
          kind: AnonymMemoryKind.parse(it['kind']),
          sid: _str(it['sid']),
          releasedAt: parseReleasedAt(it['releasedAt']),
          approvals: _int(it['approvals']),
          canRetract: it['canRetract'] is bool ? it['canRetract'] as bool : null,
        ),
      );
    }
    return out;
  }

  /// `releasedAt` / `retractedAt`:毫秒时间戳(数字)或 ISO 8601 字符串。太小的数按秒算。返回本地时间。
  @visibleForTesting
  static DateTime? parseReleasedAt(Object? v) {
    if (v is num) {
      if (v <= 0 || !v.isFinite) return null;
      final int ms = v < 1e11 ? (v * 1000).round() : v.round();
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
    }
    if (v is String && v.isNotEmpty) {
      final int? asInt = int.tryParse(v);
      if (asInt != null) return parseReleasedAt(asInt);
      return DateTime.tryParse(v)?.toLocal();
    }
    return null;
  }

  static String? _id(Object? v) =>
      _str(v) ?? (v is num ? (v == v.roundToDouble() ? '${v.toInt()}' : '$v') : null);

  /// roleRisk 可能是布尔,也可能是 0..1 的分数(原型里是 risk 分)。
  static bool _roleRisk(Object? v) => v == true || (v is num && v >= 0.5);

  static String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;
  static int? _int(Object? v) => v is num ? v.toInt() : null;
}
