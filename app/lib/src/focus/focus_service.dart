import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;

import 'focus_models.dart';

/// 本机跑在哪类平台上 —— 只决定「哪些生命周期信号算离开」。
enum FocusHostKind { mobile, desktop, web }

/// 专注学习(`lares.focus`)客户端:吃信令消息维护专注状态,并上报本机离开/回来。
///
/// 契约:`docs/plans/plugin-focus-contract.md` §6、§7。只依赖 `send` + `messages`,
/// 测试用假信令直接驱动;时钟与计时器都可注入(fake_async)。
///
/// ## 什么算「离开」
///
/// - **移动端**:只认 `paused` / `hidden`(以及 `detached`)。`inactive` 单独出现时
///   **不算** —— Android 拉下通知栏、iOS 下拉控制中心都只会到 inactive,
///   人其实还盯着这块屏幕。
/// - iOS 锁屏、来电接听也会走到 paused —— 生命周期分不清「锁屏发呆」和
///   「去刷别的 App」,一律算离开。这是有意的:锁屏也是离开了专注画面。
/// - **桌面**:窗口失焦(window_manager `onWindowBlur`)就算,最小化走 hidden 同样算。
/// - **Web**:`inactive`(标签页失焦)与 `hidden`(切走标签)都算。
///
/// 离开后先等宽限期(`config.graceSec`),仍未回来才发 `focus_away`,
/// 且 `since` 是**真正离开的那一刻**(换算成服务器时间);回来时若发过 away 就补 `focus_back`。
/// 只在「专注模式开着 + 在房 + 番茄钟不在休息期」时上报。
class FocusService extends ChangeNotifier {
  FocusService({
    required this.send,
    required Stream<Map<String, dynamic>> messages,
    this.ownerKeyFor,
    this.myUserId,
    int? Function()? clockOffsetMs,
    DateTime Function()? now,
    Timer Function(Duration, void Function())? timerFactory,
    this.host = FocusHostKind.mobile,
  }) : _pongOffset = clockOffsetMs,
       _now = now ?? DateTime.now,
       _timer = timerFactory ?? Timer.new {
    _sub = messages.listen(_onMessage);
  }

  final void Function(Map<String, dynamic> msg) send;
  final String? Function(String circleId)? ownerKeyFor;
  final String? Function()? myUserId;
  final FocusHostKind host;
  final int? Function()? _pongOffset;
  final DateTime Function() _now;
  final Timer Function(Duration, void Function()) _timer;
  late final StreamSubscription<Map<String, dynamic>> _sub;

  final _notices = StreamController<FocusNotice>.broadcast();

  /// 要弹 snackbar 的事件(离开 / 回来 / 提前离开 / 阶段切换 / 圈主结束…)。
  Stream<FocusNotice> get notices => _notices.stream;

  // ── 圈级状态 ──
  final Map<String, bool> _enabled = {};
  final Map<String, FocusConfig> _configs = {};

  String? _room;
  FocusStatus? _status;
  Pomodoro _pomodoro = Pomodoro.idle;
  FocusLeaderboard _board = FocusLeaderboard.empty;

  /// 由 focus_status.now 粗估的偏移;pong 校时(更准)缺席时兜底。
  int? _statusOffset;

  // ── 本机离开状态 ──
  bool _lifecycleAway = false;
  bool _windowAway = false;
  DateTime? _leftAt;
  Timer? _graceTimer;
  bool _awaySent = false;

  /// 当前所在房间的圈子(不在房为 null)。
  String? get roomCircleId => _room;

  /// 某个圈是否装了且启用了专注插件。
  bool isEnabledIn(String circleId) => _enabled[circleId] ?? false;

  /// 本房间是否处于专注模式。
  bool get active => _room != null && isEnabledIn(_room!);

  FocusConfig get config =>
      (_room == null ? null : _configs[_room!]) ?? FocusConfig.defaults;

  FocusConfig configFor(String circleId) =>
      _configs[circleId] ?? FocusConfig.defaults;

  Pomodoro get pomodoro => active ? _pomodoro : Pomodoro.idle;

  /// 是否在休息期。
  bool get inBreak => active && _pomodoro.phase == PomodoroPhase.breakTime;

  /// 文字聊天与发图是否收起。
  ///
  /// 契约 §6.2:只在番茄钟的**专注段**收起。没开钟(idle)时房间照常,聊天开着;
  /// 休息段看 `chatInBreak`(默认开)。
  bool get chatLocked =>
      active &&
      (_pomodoro.phase == PomodoroPhase.focus ||
          (inBreak && !config.chatInBreak));

  /// 是否处于「该收起分心入口」的专注段(番茄钟 focus 阶段)。
  bool get focusing => active && _pomodoro.phase == PomodoroPhase.focus;

  /// 本机是否会上报离开(专注期且在房)。
  bool get _reportable => focusing;

  /// 本机此刻是否处于离开(本地判断,未必已上报)。
  bool get locallyAway => _lifecycleAway || _windowAway;

  List<FocusMemberState> get members =>
      active ? (_status?.members ?? const []) : const [];

  FocusMemberState? memberState(String userId) {
    if (!active) return null;
    for (final m in members) {
      if (m.userId == userId) return m;
    }
    return null;
  }

  FocusLeaderboard get leaderboard => _board;

  /// 服务器时钟 − 本机时钟(毫秒)。pong 校时优先,其次 focus_status.now,最后 0。
  int get clockOffsetMs => _pongOffset?.call() ?? _statusOffset ?? 0;

  /// 此刻的服务器时间(毫秒)。
  int serverNowMs() => _now().millisecondsSinceEpoch + clockOffsetMs;

  /// 番茄钟本阶段剩余时间(idle / 无 endsAt 为 null)。
  Duration? get remaining {
    final p = pomodoro;
    if (!p.running || p.endsAt == null) return null;
    final ms = p.endsAt! - serverNowMs();
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  /// 某成员已离开多久(不在离开状态为 null)。
  Duration? awayFor(String userId) {
    final m = memberState(userId);
    if (m == null || m.state != FocusMemberMode.away) return null;
    final since = m.awaySince;
    if (since == null) return Duration.zero;
    final ms = serverNowMs() - since;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  bool isOwner(String circleId) => ownerKeyFor?.call(circleId) != null;

  /// 本机能不能开 / 停番茄钟。
  bool get canControl =>
      active && (isOwner(_room!) || config.membersCanStart);

  // ── 房间 ──

  /// 进出房间时由外部调用(main.dart 接到 RoomController 上)。
  void setRoom(String? circleId) {
    if (circleId == _room) return;
    _resetAway(sendBack: false);
    _room = circleId;
    _status = null;
    _pomodoro = Pomodoro.idle;
    _board = FocusLeaderboard.empty;
    if (circleId != null && isEnabledIn(circleId)) {
      send({'t': 'focus_get', 'circleId': circleId});
    }
    notifyListeners();
  }

  // ── 动作 ──

  void startPomodoro() => _control('focus_start');
  void stopPomodoro() => _control('focus_stop');

  void _control(String t) {
    final id = _room;
    if (id == null) return;
    final key = ownerKeyFor?.call(id);
    send({'t': t, 'circleId': id, 'ownerKey': ?key});
  }

  /// 拉一次状态 + 排行榜(回 focus_status + focus_board)。
  void requestBoard() {
    final id = _room;
    if (id == null) return;
    send({'t': 'focus_get', 'circleId': id});
  }

  // ── 生命周期上报 ──

  void onAppLifecycle(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _lifecycleAway = false;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _lifecycleAway = true;
      case AppLifecycleState.inactive:
        // 只有 Web 把 inactive(标签页失焦)当离开;移动端的 inactive
        // 是通知栏 / 控制中心,桌面的失焦交给 onWindowFocus。
        if (host == FocusHostKind.web) _lifecycleAway = true;
    }
    _syncAway();
  }

  /// 桌面 / Web 窗口焦点(window_manager onWindowBlur/onWindowFocus)。
  void onWindowFocus(bool focused) {
    if (host == FocusHostKind.mobile) return;
    _windowAway = !focused;
    _syncAway();
  }

  void _syncAway() {
    if (locallyAway) {
      if (_leftAt != null) return; // 已经在离开中
      _leftAt = _now();
      _armGrace();
    } else {
      _resetAway(sendBack: true);
    }
  }

  void _armGrace() {
    _graceTimer?.cancel();
    _graceTimer = null;
    if (_leftAt == null || _awaySent || !_reportable) return;
    final grace = Duration(seconds: config.graceSec);
    final elapsed = _now().difference(_leftAt!);
    final wait = grace - elapsed;
    if (wait <= Duration.zero) {
      _fireAway();
    } else {
      _graceTimer = _timer(wait, _fireAway);
    }
  }

  void _fireAway() {
    _graceTimer = null;
    final id = _room;
    final left = _leftAt;
    if (id == null || left == null || _awaySent || !_reportable) return;
    _awaySent = true;
    send({
      't': 'focus_away',
      'circleId': id,
      'since': left.millisecondsSinceEpoch + clockOffsetMs,
    });
  }

  void _resetAway({required bool sendBack}) {
    _graceTimer?.cancel();
    _graceTimer = null;
    if (sendBack && _awaySent && _room != null) {
      send({'t': 'focus_back', 'circleId': _room});
    }
    _awaySent = false;
    _leftAt = null;
    if (!sendBack) {
      _lifecycleAway = false;
      _windowAway = false;
    }
  }

  // ── 消息 ──

  void _onMessage(Map<String, dynamic> msg) {
    switch (msg['t']) {
      case 'welcome':
      case 'circle_settings':
        final c = msg['circle'];
        if (c is Map && c['id'] is String && c['plugins'] is List) {
          _applyPluginViews(c['id'] as String, c['plugins'] as List);
        }
      case 'plugins':
        final id = msg['circleId'];
        if (id is String && msg['items'] is List) {
          _applyPluginViews(id, msg['items'] as List);
        }
      case 'circle_summary':
        final id = msg['circleId'];
        final ps = msg['plugins'];
        if (id is String && ps is List) {
          var found = false;
          for (final p in ps) {
            if (p is Map && p['id'] == kFocusPluginId) {
              found = true;
              _setEnabled(id, p['enabled'] == true);
            }
          }
          if (!found) _setEnabled(id, false);
        }
      case 'plugin_state':
        if (msg['pluginId'] == kFocusPluginId &&
            msg['circleId'] == _room &&
            msg['state'] is Map) {
          final p = (msg['state'] as Map)['pomodoro'];
          if (p is Map) {
            _pomodoro = Pomodoro.fromJson(p);
            _afterPhaseChange();
            notifyListeners();
          }
        }
      case 'focus_status':
        final s = FocusStatus.fromJson(msg);
        if (s == null) return;
        _configs[s.circleId] = s.config;
        final wasEnabled = isEnabledIn(s.circleId);
        _enabled[s.circleId] = s.enabled;
        if (s.circleId != _room) {
          if (wasEnabled != s.enabled) notifyListeners();
          return;
        }
        if (s.now != null) {
          _statusOffset = s.now! - _now().millisecondsSinceEpoch;
        }
        _status = s;
        _pomodoro = s.pomodoro;
        if (!s.enabled) _resetAway(sendBack: false);
        _afterPhaseChange();
        notifyListeners();
      case 'focus_notice':
        if (msg['circleId'] != _room) return;
        final n = FocusNotice.fromJson(msg);
        if (n == null) return;
        if (n.kind == FocusNoticeKind.endedByOwner) {
          _setEnabled(_room!, false);
        }
        _notices.add(n);
      case 'focus_board':
        if (msg['circleId'] != _room) return;
        _board = FocusLeaderboard.fromJson(msg);
        notifyListeners();
      case 'focus_error':
        if (msg['circleId'] != null && msg['circleId'] != _room) return;
        _notices.add(
          FocusNotice(
            kind: FocusNoticeKind.error,
            reason: msg['reason'] as String? ?? 'unknown',
          ),
        );
    }
  }

  void _applyPluginViews(String circleId, List items) {
    var found = false;
    for (final p in items) {
      if (p is Map && p['id'] == kFocusPluginId) {
        found = true;
        _configs[circleId] = FocusConfig.fromJson(p['config']);
        _setEnabled(circleId, p['enabled'] == true, force: true);
      }
    }
    if (!found) _setEnabled(circleId, false);
  }

  void _setEnabled(String circleId, bool on, {bool force = false}) {
    final was = isEnabledIn(circleId);
    _enabled[circleId] = on;
    if (was == on && !force) return;
    if (circleId == _room) {
      if (on && !was) {
        send({'t': 'focus_get', 'circleId': circleId});
      }
      if (!on) {
        _resetAway(sendBack: false);
        _status = null;
        _pomodoro = Pomodoro.idle;
      }
    }
    notifyListeners();
  }

  /// 阶段变化后:进休息期不再上报(已发出的 away 服务器自会处理),
  /// 回到专注期而本机仍在离开 → 重新起宽限。
  void _afterPhaseChange() {
    if (!_reportable) {
      _graceTimer?.cancel();
      _graceTimer = null;
    } else if (locallyAway && _leftAt != null && !_awaySent &&
        _graceTimer == null) {
      // 休息期里离开的不算;从回到专注期这一刻起重新计宽限
      _leftAt = _now();
      _armGrace();
    }
  }

  /// 测试 / 截图用:直接注入一条信令消息。
  @visibleForTesting
  void debugInject(Map<String, dynamic> msg) => _onMessage(msg);

  @override
  void dispose() {
    _graceTimer?.cancel();
    unawaited(_sub.cancel());
    unawaited(_notices.close());
    super.dispose();
  }
}
