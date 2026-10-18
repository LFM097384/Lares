/// 隐名之约(受 Chatham House 规则启发 · 非官方)的客户端状态。
///
/// 协议见 server/anonym-agent/INTERFACE.md §「Lares 集成协议」。本类只做三件事:
/// 1. 解析服务器的 `anon_*` 消息(全部防御式解析,形状不对就当没收到);
/// 2. 通过构造时注入的 [send] 发 `anon_*` 消息;
/// 3. 管住只在内存里的东西(会话密钥、室内问答、出门稿),到点就销毁。
///
/// **销毁时机**(一律立即、不可恢复):
/// - 收到 `anon_ended`:密钥、问答、出门稿立刻清掉;只留散会卡要用的回执和已放行原文,
///   卡片 [dismissEnded] 后再清;
/// - 离开房间 / 换圈([bindRoom]):全部清掉,散会卡也不留;
/// - `anon_state{active:false}`(包括重连后服务器报告已无会话):全部清掉。
///
/// 它不知道 UI、不知道字幕;字幕经 [AnonymCaptionGate] 这面接进来。
library;

import 'package:flutter/foundation.dart';

import 'anonym_crypto.dart';

typedef AnonymSend = void Function(Map<String, dynamic> msg);

/// 字幕胶水层看到的那一面(见 CaptionWiring)。
abstract interface class AnonymCaptionGate implements Listenable {
  /// 本房间正在隐名之约中:转写记录必须停。
  bool get sessionActive;

  /// 我已同意加入:本人字幕定稿要喂给会话(并因此需要开着识别)。
  bool get feeding;

  /// 本人一句字幕定稿。只在 [feeding] 时才会真的发出去。
  void ownFinal(String text, DateTime startedAt);
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
    AnonymKeys Function()? keyFactory,
    String Function()? nonceFactory,
  }) : _send = send,
       _keyFactory = keyFactory ?? AnonymKeys.generate,
       _nonceFactory = nonceFactory ?? newNonce;

  final AnonymSend _send;
  final AnonymKeys Function() _keyFactory;
  final String Function() _nonceFactory;

  // ── 房间 ──────────────────────────────────────────────────────────────
  String? _circleId;
  bool _inRoom = false;
  String? _myUserId;

  String? get circleId => _circleId;

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

  @override
  bool get sessionActive => _active;

  @override
  bool get feeding => acked && _inRoom && _keys != null;

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

  /// 信令消息入口。不是 anon_* 的一律忽略(`_disconnected` 也不动状态:
  /// 断线期间会话可能还在,重连后由服务器的 anon_state 定夺)。
  void handle(Map<String, dynamic> msg) {
    final Object? t = msg['t'];
    if (t is! String || !t.startsWith('anon_')) return;
    final Object? cid = msg['circleId'];
    // 记忆消息认的是记忆页打开的那个圈(可能是首页长按打开的,不在房里)
    if (t == 'anon_mem' || t == 'anon_mem_retracted') {
      if (cid is! String || cid != _memCircleId) return;
      _handleMemory(t, cid, msg);
      notifyListeners();
      return;
    }
    if (t == 'anon_error') {
      _onError(msg, cid);
      return;
    }
    // 带了 circleId 就必须是当前圈
    if (cid is! String || cid != _circleId) return;
    switch (t) {
      case 'anon_state':
        _onState(msg);
      case 'anon_answer':
        if (!_active) return;
        final String? q = _str(msg['question']);
        final String? a = _str(msg['answer']);
        if (a == null) return;
        _answers.add(
          AnonymAnswer(
            askerName: _str(msg['askerName']) ?? '',
            question: q ?? '',
            answer: a,
          ),
        );
        _askPending = false;
      case 'anon_draft':
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
      case 'anon_approvals':
        if (!_active) return;
        final String? id = _str(msg['draftId']);
        if (_draft != null && id != null && id != _draft!.draftId) return;
        _approvals = _int(msg['count']) ?? _approvals;
        _approvalsK = _int(msg['k']) ?? _approvalsK;
      case 'anon_released':
        if (!_active) return;
        final String? text = _str(msg['text']);
        if (text == null) return;
        _releasedText = text;
      case 'anon_ended':
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

  /// `anon_error` 按 `op` 分流:`anon_mem_*` 只算记忆页的,其余算室内问答 / 出门稿的。
  void _onError(Map<String, dynamic> msg, Object? cid) {
    final String code = _str(msg['code']) ?? 'unknown';
    final Object? op = msg['op'];
    if (op is String && op.startsWith('anon_mem_')) {
      if (cid != null && cid != _memCircleId) return;
      _memError = code;
      _memLoading = false;
      _memRetracting.clear();
    } else {
      // 带了 circleId 就必须是当前圈;可能不带
      if (cid != null && cid != _circleId) return;
      // 签名被拒(bad_sig / replay / rate_limited…):放开按钮,允许用新 nonce 再签
      if (op == 'anon_approve') _approvedHash = null;
      _lastError = code;
      _askPending = false;
      _draftPending = false;
    }
    notifyListeners();
  }

  void _handleMemory(String t, String cid, Map<String, dynamic> msg) {
    if (t == 'anon_mem') {
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
    // anon_mem_retracted
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
    if (!active) {
      // 散会卡还开着时(anon_ended 之后服务器常再报一次 inactive),
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
    // 断线重连后服务器把我列成「未加入」,但本机还握着这场的钥匙:
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

  /// 圈主召集。k 由调用方按 2..n 夹好(见 [defaultK] / [clampK])。
  void start(int k) {
    final String? c = _circleId;
    if (c == null) return;
    _lastError = null;
    _send({'t': 'anon_start', 'circleId': c, 'k': k});
  }

  /// 圈主散会。
  void end() {
    final String? c = _circleId;
    if (c == null || !_active) return;
    _send({'t': 'anon_end', 'circleId': c});
  }

  /// 同意并加入:现生成一对只在内存里的会话密钥,把公钥发出去。
  void accept() {
    final String? c = _circleId;
    final String? sid = _sid;
    if (c == null || sid == null || !_active) return;
    _keys?.wipe();
    final AnonymKeys keys = _keyFactory();
    _keys = keys;
    _ackedSid = sid;
    _declinedSid = null;
    _send({'t': 'anon_ack', 'circleId': c, 'pubKey': keys.pubKeyB64});
    notifyListeners();
  }

  void decline() {
    if (!_active || _sid == null) return;
    _declinedSid = _sid;
    notifyListeners();
  }

  /// 断线重连回到同一房间后,把同一把公钥再报一次(服务器侧按 TOFU 比对同一把钥匙)。
  void resendAck() {
    final String? c = _circleId;
    final AnonymKeys? keys = _keys;
    if (c == null || keys == null || !acked) return;
    _send({'t': 'anon_ack', 'circleId': c, 'pubKey': keys.pubKeyB64});
  }

  @override
  void ownFinal(String text, DateTime startedAt) {
    final String? c = _circleId;
    final String trimmed = text.trim();
    if (!feeding || c == null || trimmed.isEmpty) return;
    _send({
      't': 'anon_utt',
      'circleId': c,
      'text': trimmed,
      'ts': startedAt.millisecondsSinceEpoch,
      'final': true,
    });
  }

  void ask(String question) {
    final String? c = _circleId;
    final String q = question.trim();
    if (c == null || !acked || q.isEmpty) return;
    _askPending = true;
    _send({'t': 'anon_ask', 'circleId': c, 'question': q});
    notifyListeners();
  }

  void requestDraft() {
    final String? c = _circleId;
    if (c == null || !acked) return;
    _draftPending = true;
    _lastError = null;
    _send({'t': 'anon_draft', 'circleId': c});
    notifyListeners();
  }

  void review(String itemId, AnonymReviewAction action) {
    final String? c = _circleId;
    final AnonymDraft? d = _draft;
    if (c == null || d == null || !acked) return;
    _send({
      't': 'anon_review',
      'circleId': c,
      'draftId': d.draftId,
      'itemId': itemId,
      'action': action.wire,
    });
  }

  /// 签名同意放行当前稿(签的是 [approvalMessage],见 anonym_crypto.dart)。
  void approve() {
    final String? c = _circleId;
    final String? sid = _sid;
    final AnonymDraft? d = _draft;
    final AnonymKeys? keys = _keys;
    if (c == null || sid == null || d == null || keys == null || !acked) {
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
    _send({
      't': 'anon_approve',
      'circleId': c,
      'draftId': d.draftId,
      'draftHash': d.draftHash,
      'nonce': nonce,
      'sig': sig,
    });
    notifyListeners();
  }

  /// 取本圈记忆列表(`anon_mem_list`)。回复是 `anon_mem`。
  ///
  /// [circleId] 缺省为当前房间的圈;从首页长按打开时传那个圈。
  void loadMemory({String? circleId}) {
    final String? c = circleId ?? _circleId;
    if (c == null) return;
    if (_memCircleId != c) {
      _memItems = null;
      _memRetracting.clear();
    }
    _memCircleId = c;
    _memLoading = true;
    _memError = null;
    _send({'t': 'anon_mem_list', 'circleId': c});
    notifyListeners();
  }

  /// 请求撤回一条记忆。**不**先删:等服务器回 `anon_mem_retracted` 或重发的列表。
  void retractMemory(String itemId) {
    final String? c = _memCircleId;
    final List<AnonymMemoryItem>? items = _memItems;
    if (c == null || items == null) return;
    if (!items.any((it) => it.id == itemId && !it.retracted)) return;
    if (!_memRetracting.add(itemId)) return;
    _memError = null;
    _send({'t': 'anon_mem_retract', 'circleId': c, 'itemId': itemId});
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
