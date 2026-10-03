/// 专注学习(`lares.focus`)的数据模型。
///
/// 字段名逐字对齐 `docs/plans/plugin-focus-contract.md` §6 —— 改格式先改契约。
library;

/// 内置专注插件的 id。
const String kFocusPluginId = 'lares.focus';

int _int(Object? v, int fallback) => v is num ? v.toInt() : fallback;
int? _intOrNull(Object? v) => v is num ? v.toInt() : null;

/// §6.1 配置。服务器严格校验并补默认;客户端这里只做同样的夹紧,
/// 好让「老服务器 / 缺字段」时界面不出现 0 分钟这种怪值。
class FocusConfig {
  const FocusConfig({
    this.focusMin = 25,
    this.breakMin = 5,
    this.rounds = 4,
    this.graceSec = 10,
    this.membersCanStart = false,
  });

  final int focusMin; // 1..180
  final int breakMin; // 1..60
  final int rounds; // 1..12
  final int graceSec; // 0..300
  final bool membersCanStart;

  static const FocusConfig defaults = FocusConfig();

  factory FocusConfig.fromJson(Object? raw) {
    if (raw is! Map) return defaults;
    return FocusConfig(
      focusMin: _int(raw['focusMin'], 25).clamp(1, 180),
      breakMin: _int(raw['breakMin'], 5).clamp(1, 60),
      rounds: _int(raw['rounds'], 4).clamp(1, 12),
      graceSec: _int(raw['graceSec'], 10).clamp(0, 300),
      membersCanStart: raw['membersCanStart'] == true,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'focusMin': focusMin,
    'breakMin': breakMin,
    'rounds': rounds,
    'graceSec': graceSec,
    'membersCanStart': membersCanStart,
  };

  FocusConfig copyWith({
    int? focusMin,
    int? breakMin,
    int? rounds,
    int? graceSec,
    bool? membersCanStart,
  }) => FocusConfig(
    focusMin: focusMin ?? this.focusMin,
    breakMin: breakMin ?? this.breakMin,
    rounds: rounds ?? this.rounds,
    graceSec: graceSec ?? this.graceSec,
    membersCanStart: membersCanStart ?? this.membersCanStart,
  );

  @override
  bool operator ==(Object other) =>
      other is FocusConfig &&
      other.focusMin == focusMin &&
      other.breakMin == breakMin &&
      other.rounds == rounds &&
      other.graceSec == graceSec &&
      other.membersCanStart == membersCanStart;

  @override
  int get hashCode => Object.hash(
    focusMin,
    breakMin,
    rounds,
    graceSec,
    membersCanStart,
  );
}

enum PomodoroPhase { idle, focus, breakTime }

PomodoroPhase _phase(Object? v) => switch (v) {
  'focus' => PomodoroPhase.focus,
  'break' => PomodoroPhase.breakTime,
  _ => PomodoroPhase.idle,
};

/// §6.3 `pomodoro`。`endsAt` 是**服务器时间**毫秒。
class Pomodoro {
  const Pomodoro({
    this.phase = PomodoroPhase.idle,
    this.endsAt,
    this.round = 0,
    this.rounds = 0,
    this.startedBy,
  });

  final PomodoroPhase phase;
  final int? endsAt;
  final int round;
  final int rounds;
  final String? startedBy;

  static const Pomodoro idle = Pomodoro();

  bool get running => phase != PomodoroPhase.idle;

  factory Pomodoro.fromJson(Object? raw) {
    if (raw is! Map) return idle;
    return Pomodoro(
      phase: _phase(raw['phase']),
      endsAt: _intOrNull(raw['endsAt']),
      round: _int(raw['round'], 0),
      rounds: _int(raw['rounds'], 0),
      startedBy: raw['startedBy'] as String?,
    );
  }
}

enum FocusMemberMode { focus, away, breakTime, idle }

/// §6.3 `members[]` 的一项。focusMs/awayMs = 本次进房以来累计(服务器结算值)。
class FocusMemberState {
  const FocusMemberState({
    required this.userId,
    required this.name,
    required this.state,
    this.awaySince,
    this.focusMs = 0,
    this.awayMs = 0,
  });

  final String userId;
  final String name;
  final FocusMemberMode state;
  final int? awaySince;
  final int focusMs;
  final int awayMs;

  static FocusMemberState? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['userId'];
    if (id is! String || id.isEmpty) return null;
    return FocusMemberState(
      userId: id,
      name: raw['name'] as String? ?? '',
      state: switch (raw['state']) {
        'away' => FocusMemberMode.away,
        'break' => FocusMemberMode.breakTime,
        'idle' => FocusMemberMode.idle,
        _ => FocusMemberMode.focus,
      },
      awaySince: _intOrNull(raw['awaySince']),
      focusMs: _int(raw['focusMs'], 0),
      awayMs: _int(raw['awayMs'], 0),
    );
  }
}

/// 排行榜一行:`Row={userId,name,ms}`,服务器已降序。
class LeaderboardRow {
  const LeaderboardRow({
    required this.userId,
    required this.name,
    required this.ms,
  });

  final String userId;
  final String name;
  final int ms;

  static List<LeaderboardRow> listFromJson(Object? raw) {
    if (raw is! List) return const <LeaderboardRow>[];
    final out = <LeaderboardRow>[];
    for (final r in raw) {
      if (r is! Map) continue;
      final id = r['userId'];
      if (id is! String) continue;
      out.add(
        LeaderboardRow(
          userId: id,
          name: r['name'] as String? ?? '',
          ms: _int(r['ms'], 0),
        ),
      );
    }
    return out;
  }
}

class FocusLeaderboard {
  const FocusLeaderboard({
    this.today = const <LeaderboardRow>[],
    this.week = const <LeaderboardRow>[],
    this.all = const <LeaderboardRow>[],
  });

  final List<LeaderboardRow> today;
  final List<LeaderboardRow> week;
  final List<LeaderboardRow> all;

  static const FocusLeaderboard empty = FocusLeaderboard();

  factory FocusLeaderboard.fromJson(Map raw) => FocusLeaderboard(
    today: LeaderboardRow.listFromJson(raw['today']),
    week: LeaderboardRow.listFromJson(raw['week']),
    all: LeaderboardRow.listFromJson(raw['all']),
  );
}

/// §6.3 `focus_status`。
class FocusStatus {
  const FocusStatus({
    required this.circleId,
    required this.now,
    required this.enabled,
    required this.config,
    required this.pomodoro,
    required this.members,
  });

  final String circleId;

  /// 服务器发出时刻(服务器毫秒)。没有 pong 校时样本时用它粗校。
  final int? now;
  final bool enabled;
  final FocusConfig config;
  final Pomodoro pomodoro;
  final List<FocusMemberState> members;

  static FocusStatus? fromJson(Map raw) {
    final cid = raw['circleId'];
    if (cid is! String || cid.isEmpty) return null;
    return FocusStatus(
      circleId: cid,
      now: _intOrNull(raw['now']),
      enabled: raw['enabled'] == true,
      config: FocusConfig.fromJson(raw['config']),
      pomodoro: Pomodoro.fromJson(raw['pomodoro']),
      members: [
        for (final m in (raw['members'] as List? ?? const []))
          ?FocusMemberState.fromJson(m),
      ],
    );
  }
}

enum FocusNoticeKind {
  away,
  back,
  leftEarly,
  phase,
  started,
  stopped,
  endedByOwner,
  error,
}

/// `focus_notice`(以及本地化后要弹 snackbar 的 `focus_error`)。
class FocusNotice {
  const FocusNotice({
    required this.kind,
    this.userId,
    this.name,
    this.awayMs,
    this.phase,
    this.round,
    this.reason,
  });

  final FocusNoticeKind kind;
  final String? userId;
  final String? name;
  final int? awayMs;
  final PomodoroPhase? phase;
  final int? round;

  /// 仅 [FocusNoticeKind.error]:服务器 reason。
  final String? reason;

  static FocusNotice? fromJson(Map raw) {
    final kind = switch (raw['kind']) {
      'away' => FocusNoticeKind.away,
      'back' => FocusNoticeKind.back,
      'left_early' => FocusNoticeKind.leftEarly,
      'phase' => FocusNoticeKind.phase,
      'started' => FocusNoticeKind.started,
      'stopped' => FocusNoticeKind.stopped,
      'ended_by_owner' => FocusNoticeKind.endedByOwner,
      _ => null,
    };
    if (kind == null) return null;
    return FocusNotice(
      kind: kind,
      userId: raw['userId'] as String?,
      name: raw['name'] as String?,
      awayMs: _intOrNull(raw['awayMs']),
      phase: raw['phase'] == null ? null : _phase(raw['phase']),
      round: _intOrNull(raw['round']),
    );
  }
}
