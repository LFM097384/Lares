/// 专注社交:每轮出勤卡、连续打卡、每周小结(plugin-focus-contract §10)。
///
/// 由 [FocusService] 持有并转发信令(`focus_round` / `focus_streaks` / `focus_weekly`);
/// 自己只管状态,不碰离开上报那一摊。服务器已排除 `u_ai_*`,这里再兜一道。
library;

import 'package:flutter/foundation.dart';

bool _isHuman(String id) => !id.startsWith('u_ai_') && !id.startsWith('bot:');

class FocusRoundMember {
  const FocusRoundMember({
    required this.userId,
    required this.name,
    required this.awayMs,
    required this.full,
  });

  final String userId;
  final String name;
  final int awayMs;
  final bool full;
}

/// 一轮专注结束时的出勤(服务器 `focus_round`)。
class FocusRound {
  const FocusRound({
    required this.circleId,
    required this.round,
    required this.rounds,
    required this.total,
    required this.full,
    required this.members,
    this.endedAt,
  });

  final String circleId;
  final int round;
  final int rounds;
  final int total;
  final int full;
  final int? endedAt;
  final List<FocusRoundMember> members;

  bool get allIn => total > 0 && full >= total;

  /// 没全勤的人,离开最久的在前。
  List<FocusRoundMember> get missed =>
      members.where((m) => !m.full).toList()
        ..sort((a, b) => b.awayMs.compareTo(a.awayMs));

  static FocusRound? fromJson(Map<String, dynamic> raw) {
    final cid = raw['circleId'];
    if (cid is! String) return null;
    final members = <FocusRoundMember>[];
    final ms = raw['members'];
    if (ms is List) {
      for (final m in ms) {
        if (m is! Map || m['userId'] is! String) continue;
        final id = m['userId'] as String;
        if (!_isHuman(id)) continue;
        members.add(
          FocusRoundMember(
            userId: id,
            name: m['name'] is String ? m['name'] as String : id,
            awayMs: (m['awayMs'] as num?)?.toInt() ?? 0,
            full: m['full'] == true,
          ),
        );
      }
    }
    final full = members.where((m) => m.full).length;
    return FocusRound(
      circleId: cid,
      round: (raw['round'] as num?)?.toInt() ?? 0,
      rounds: (raw['rounds'] as num?)?.toInt() ?? 0,
      endedAt: (raw['endedAt'] as num?)?.toInt(),
      total: members.length,
      full: full,
      members: members,
    );
  }
}

/// 周报卡(服务器 `focus_weekly.card`)。
class FocusWeeklyCard {
  const FocusWeeklyCard({
    required this.circleId,
    required this.week,
    required this.focusMs,
    required this.rank,
    required this.of,
    required this.streak,
    required this.circleTotalMs,
  });

  final String circleId;

  /// 那一周的周一(YYYY-MM-DD)
  final String week;
  final int focusMs;
  final int rank;
  final int of;
  final int streak;
  final int circleTotalMs;

  static FocusWeeklyCard? fromJson(String circleId, Object? raw) {
    if (raw is! Map || raw['week'] is! String) return null;
    int n(String k) => (raw[k] as num?)?.toInt() ?? 0;
    return FocusWeeklyCard(
      circleId: circleId,
      week: raw['week'] as String,
      focusMs: n('focusMs'),
      rank: n('rank'),
      of: n('of'),
      streak: n('streak'),
      circleTotalMs: n('circleTotalMs'),
    );
  }
}

class FocusSocial extends ChangeNotifier {
  FocusSocial({required this.send});

  final void Function(Map<String, dynamic> msg) send;

  String? _room;
  final Map<String, Map<String, int>> _streaks = {};
  FocusRound? _round;
  FocusWeeklyCard? _weekly;

  /// 本房间最近一轮的出勤(收起后为 null)。
  FocusRound? get lastRound => _round;

  /// 本房间待看的周报卡。
  FocusWeeklyCard? get weekly => _weekly;

  /// 某成员在本房间的连续天数(0 = 没有)。
  int streakOf(String userId) {
    if (!_isHuman(userId)) return 0;
    return _streaks[_room]?[userId] ?? 0;
  }

  Map<String, int> streaksIn(String circleId) =>
      Map.unmodifiable(_streaks[circleId] ?? const {});

  /// 进出房间时由 [FocusService.setRoom] 转来;[fetch] = 本圈开着专注插件。
  void setRoom(String? circleId, {bool fetch = false}) {
    if (circleId == _room) return;
    _room = circleId;
    _round = null;
    _weekly = null;
    if (circleId != null && fetch) this.fetch(circleId);
    notifyListeners();
  }

  /// 拉连续打卡 + 待看的周报卡。
  void fetch(String circleId) =>
      send({'t': 'focus_social_get', 'circleId': circleId});

  /// 返回 true = 这条消息归本类。
  bool onMessage(Map<String, dynamic> msg) {
    final cid = msg['circleId'];
    switch (msg['t']) {
      case 'focus_streaks':
        if (cid is! String || msg['streaks'] is! Map) return true;
        final out = <String, int>{};
        (msg['streaks'] as Map).forEach((k, v) {
          if (k is String && _isHuman(k) && v is num && v > 0) {
            out[k] = v.toInt();
          }
        });
        _streaks[cid] = out;
        if (cid == _room) notifyListeners();
        return true;
      case 'focus_round':
        if (cid != _room) return true;
        final r = FocusRound.fromJson(msg);
        if (r == null || r.total == 0) return true;
        _round = r;
        notifyListeners();
        return true;
      case 'focus_weekly':
        if (cid is! String || cid != _room) return true;
        _weekly = FocusWeeklyCard.fromJson(cid, msg['card']);
        notifyListeners();
        return true;
    }
    return false;
  }

  void dismissRound() {
    if (_round == null) return;
    _round = null;
    notifyListeners();
  }

  /// 看过了:告诉服务器(之后不再推这周的周报),本机立刻收起。
  void dismissWeekly() {
    final w = _weekly;
    if (w == null) return;
    send({'t': 'focus_weekly_seen', 'circleId': w.circleId, 'week': w.week});
    _weekly = null;
    notifyListeners();
  }
}
