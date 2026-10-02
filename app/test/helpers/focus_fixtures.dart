/// 专注学习的测试夹具:一个吃假信令流的 [FocusService] + 常用推送消息。
library;

import 'dart:async';

import 'package:lares_app/src/focus/focus_models.dart';
import 'package:lares_app/src/focus/focus_service.dart';

/// 固定的「此刻」(本机 = 服务器,偏移 0)。
const int kFocusNow = 1790000000000;

class FocusHarness {
  FocusHarness({
    String? ownerKey,
    FocusHostKind host = FocusHostKind.mobile,
    DateTime Function()? now,
    String myUserId = 'u_me',
  }) {
    service = FocusService(
      send: sent.add,
      messages: _ctrl.stream,
      ownerKeyFor: (_) => ownerKey,
      myUserId: () => myUserId,
      clockOffsetMs: () => 0,
      now: now ?? () => DateTime.fromMillisecondsSinceEpoch(kFocusNow),
      host: host,
    );
  }

  final _ctrl = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final List<Map<String, dynamic>> sent = [];
  late final FocusService service;

  void inject(Map<String, dynamic> msg) => service.debugInject(msg);

  /// 本圈装了且启用专注插件。
  void enable(String circleId, {Map<String, dynamic>? config}) => inject({
    't': 'plugins',
    'circleId': circleId,
    'items': [
      {
        'id': kFocusPluginId,
        'name': '专注学习',
        'enabled': true,
        'config': config ?? const <String, dynamic>{},
      },
    ],
  });

  void status(
    String circleId, {
    String phase = 'idle',
    int? endsAt,
    int round = 0,
    int rounds = 4,
    List<Map<String, dynamic>> members = const [],
    Map<String, dynamic>? config,
    bool enabled = true,
  }) => inject({
    't': 'focus_status',
    'circleId': circleId,
    'now': kFocusNow,
    'enabled': enabled,
    'config': config ?? const <String, dynamic>{},
    'pomodoro': {
      'phase': phase,
      'endsAt': endsAt,
      'round': round,
      'rounds': rounds,
    },
    'members': members,
  });

  Future<void> dispose() async {
    service.dispose();
    await _ctrl.close();
  }
}

Map<String, dynamic> focusMember(
  String userId,
  String name,
  String state, {
  int? awaySince,
  int focusMs = 0,
  int awayMs = 0,
}) => {
  'userId': userId,
  'name': name,
  'state': state,
  'awaySince': awaySince,
  'focusMs': focusMs,
  'awayMs': awayMs,
};
