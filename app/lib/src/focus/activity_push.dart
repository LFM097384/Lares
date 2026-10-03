/// 活动推送(plugin-focus-contract §9)的客户端一侧:
/// 圈主的触发开关 + 人数阈值,以及房里的「叫大家来」(含 10 分钟冷却)。
///
/// 推送本身由服务器发;这里只读写配置、发 `push_summon`、记住冷却到什么时候。
/// 由 [FocusService] 持有(它本来就挂在全 App 的树上,也有圈主钥匙与服务器时钟),
/// 不另开一层 Scope。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// 触发器 id —— 与 server/src/push_triggers.js 的 TRIGGERS 一致。
const String kTriggerFocus = 'focus';
const String kTriggerCrowd = 'crowd';
const String kTriggerArrive = 'arrive';
const int kCrowdNMin = 2;
const int kCrowdNMax = 12;

/// 通知等级 —— 与服务器 LEVELS 一致。
const List<String> kPushLevels = ['all', 'called', 'off'];

class PushTriggerConfig {
  const PushTriggerConfig({
    required this.focus,
    required this.crowd,
    required this.arrive,
    required this.crowdN,
    this.custom = false,
  });

  final bool focus;
  final bool crowd;
  final bool arrive;
  final int crowdN;

  /// 圈主改过(false = 按用途给的默认)
  final bool custom;

  static const fallback = PushTriggerConfig(
    focus: true,
    crowd: true,
    arrive: false,
    crowdN: 3,
  );

  PushTriggerConfig copyWith({
    bool? focus,
    bool? crowd,
    bool? arrive,
    int? crowdN,
  }) => PushTriggerConfig(
    focus: focus ?? this.focus,
    crowd: crowd ?? this.crowd,
    arrive: arrive ?? this.arrive,
    crowdN: crowdN ?? this.crowdN,
    custom: true,
  );

  Map<String, dynamic> toJson() => {
    'triggers': {
      kTriggerFocus: focus,
      kTriggerCrowd: crowd,
      kTriggerArrive: arrive,
    },
    'crowdN': crowdN,
  };

  static PushTriggerConfig fromJson(Object? raw, {bool custom = false}) {
    if (raw is! Map) return fallback;
    final t = raw['triggers'] is Map ? raw['triggers'] as Map : const <String, Object?>{};
    final n = (raw['crowdN'] as num?)?.toInt() ?? fallback.crowdN;
    return PushTriggerConfig(
      focus: t[kTriggerFocus] != false,
      crowd: t[kTriggerCrowd] != false,
      arrive: t[kTriggerArrive] == true,
      crowdN: n.clamp(kCrowdNMin, kCrowdNMax),
      custom: custom,
    );
  }
}

/// 服务器 `push_cfg` 的一份快照。
class PushCircleView {
  const PushCircleView({
    required this.cfg,
    required this.defaults,
    required this.summonReadyAt,
    required this.cooldownMin,
    required this.dailyCap,
    required this.summonMin,
  });

  final PushTriggerConfig cfg;
  final PushTriggerConfig defaults;

  /// 服务器时间(ms);0 = 现在就能叫
  final int summonReadyAt;
  final int cooldownMin;
  final int dailyCap;
  final int summonMin;
}

/// 「叫大家来」的一次结果。
sealed class SummonResult {
  const SummonResult();
}

class SummonSent extends SummonResult {
  const SummonSent(this.count);
  final int count;
}

class SummonCooldown extends SummonResult {
  const SummonCooldown(this.retryAt);
  final int retryAt;
}

class SummonFailed extends SummonResult {
  const SummonFailed(this.reason);
  final String reason;
}

class ActivityPush extends ChangeNotifier {
  ActivityPush({
    required this.send,
    required this.ownerKeyFor,
    required this.serverNowMs,
  });

  final void Function(Map<String, dynamic> msg) send;
  final String? Function(String circleId) ownerKeyFor;
  final int Function() serverNowMs;

  final Map<String, PushCircleView> _views = {};

  /// 本机发出、还没回执的「叫大家来」
  final Map<String, Completer<SummonResult>> _summons = {};

  /// 本机发出、还没回执的配置保存
  final Map<String, Completer<bool>> _saves = {};

  String? _room;

  PushCircleView? viewOf(String circleId) => _views[circleId];

  bool isOwner(String circleId) => ownerKeyFor(circleId) != null;

  /// 进出房间(由 FocusService.setRoom 转来):圈主进房就拉一次,拿到冷却。
  void setRoom(String? circleId) {
    if (circleId == _room) return;
    _room = circleId;
    if (circleId != null && isOwner(circleId)) refresh(circleId);
  }

  void refresh(String circleId) =>
      send({'t': 'push_cfg_get', 'circleId': circleId});

  /// 「叫大家来」还要等多久(null = 现在能叫)。
  Duration? summonWait(String circleId) {
    final at = _views[circleId]?.summonReadyAt ?? 0;
    final ms = at - serverNowMs();
    return ms > 0 ? Duration(milliseconds: ms) : null;
  }

  Future<SummonResult> summon(String circleId) {
    final key = ownerKeyFor(circleId);
    if (key == null) return Future.value(const SummonFailed('not_owner'));
    final pending = _summons[circleId];
    if (pending != null) return pending.future;
    final c = Completer<SummonResult>();
    _summons[circleId] = c;
    send({'t': 'push_summon', 'circleId': circleId, 'ownerKey': key});
    return c.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _summons.remove(circleId);
        return const SummonFailed('timeout');
      },
    );
  }

  /// 保存圈主配置;[cfg] = null 恢复用途默认。
  Future<bool> save(String circleId, PushTriggerConfig? cfg) {
    final key = ownerKeyFor(circleId);
    if (key == null) return Future.value(false);
    _saves.remove(circleId)?.complete(false);
    final c = Completer<bool>();
    _saves[circleId] = c;
    send({
      't': 'push_cfg_set',
      'circleId': circleId,
      'ownerKey': key,
      'cfg': cfg?.toJson(),
    });
    return c.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _saves.remove(circleId);
        return false;
      },
    );
  }

  /// 返回 true = 这条消息归本类。
  bool onMessage(Map<String, dynamic> msg) {
    final cid = msg['circleId'];
    switch (msg['t']) {
      case 'push_cfg':
        if (cid is! String) return true;
        final lim = msg['limits'] is Map ? msg['limits'] as Map : const <String, Object?>{};
        int n(Object? v, int d) => (v as num?)?.toInt() ?? d;
        _views[cid] = PushCircleView(
          cfg: PushTriggerConfig.fromJson(
            msg['cfg'],
            custom: msg['custom'] == true,
          ),
          defaults: PushTriggerConfig.fromJson(msg['defaults']),
          summonReadyAt: n(msg['summonReadyAt'], 0),
          cooldownMin: n(lim['cooldownMin'], 30),
          dailyCap: n(lim['dailyCap'], 8),
          summonMin: n(lim['summonMin'], 10),
        );
        notifyListeners();
        return true;
      case 'push_summon_ok':
        if (cid is! String) return true;
        _setReady(cid, (msg['nextAt'] as num?)?.toInt() ?? 0);
        _summons.remove(cid)?.complete(
          SummonSent((msg['sent'] as num?)?.toInt() ?? 0),
        );
        return true;
      case 'owner_ok':
        if (msg['op'] == 'push_cfg_set' && cid is String) {
          _saves.remove(cid)?.complete(true);
          return true;
        }
        return false;
      case 'owner_error':
        if (cid is! String) return false;
        final reason = msg['reason'] as String? ?? 'unknown';
        if (msg['op'] == 'push_summon') {
          final retry = (msg['retryAt'] as num?)?.toInt();
          if (retry != null) _setReady(cid, retry);
          _summons.remove(cid)?.complete(
            reason == 'cooldown' && retry != null
                ? SummonCooldown(retry)
                : SummonFailed(reason),
          );
          return true;
        }
        if (msg['op'] == 'push_cfg_set') {
          _saves.remove(cid)?.complete(false);
          return true;
        }
        return false;
    }
    return false;
  }

  void _setReady(String cid, int at) {
    final v = _views[cid];
    _views[cid] = PushCircleView(
      cfg: v?.cfg ?? PushTriggerConfig.fallback,
      defaults: v?.defaults ?? PushTriggerConfig.fallback,
      summonReadyAt: at,
      cooldownMin: v?.cooldownMin ?? 30,
      dailyCap: v?.dailyCap ?? 8,
      summonMin: v?.summonMin ?? 10,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    for (final c in _summons.values) {
      if (!c.isCompleted) c.complete(const SummonFailed('disposed'));
    }
    for (final c in _saves.values) {
      if (!c.isCompleted) c.complete(false);
    }
    super.dispose();
  }
}
