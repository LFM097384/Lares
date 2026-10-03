/// 进圈隐私告知的触发(契约 features-purpose-contract §4)。
///
/// 盯着 [RoomController]:正在进 / 已在某圈,且本机已拿到该圈完整的隐私配置时,
/// 若本机存的 ack ≠ 当前哈希,就弹一次 [showCirclePrivacySheet]。
/// - 同一 (圈, 哈希) 本次运行最多弹一次;点「知道了」或划掉都记 ack。
/// - 哈希变了(圈主开了转写等)→ 下一次通知(含房内的 circle_settings)再弹。
/// - 圈主本人不弹(配置是自己定的),静默记 ack。
/// - ack 只存本机,从不上传。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../plugins/plugin_scope.dart';
import '../state/models.dart' show RoomPhase;
import '../state/room_controller.dart';
import '../state/settings_store.dart';
import 'privacy_sheet.dart';
import 'privacy_summary.dart';

class CirclePrivacyGate extends StatefulWidget {
  const CirclePrivacyGate({
    super.key,
    required this.controller,
    required this.child,
    this.settings,
    this.circleNameOf,
    this.pluginNamesOf,
  });

  final RoomController controller;

  /// ack 存储;null(测试)时只记在内存里。
  final SettingsStore? settings;

  /// 圈子显示名(来自 CircleStore);null 或返回 null 时不显示圈名。
  final String? Function(String circleId)? circleNameOf;

  /// 插件 id → 名字;不传就从树上的 [PluginScope] 取。
  final Map<String, String> Function(String circleId)? pluginNamesOf;

  final Widget child;

  @override
  State<CirclePrivacyGate> createState() => _CirclePrivacyGateState();
}

class _CirclePrivacyGateState extends State<CirclePrivacyGate> {
  /// 本次运行里已弹过的 "圈|哈希"。
  final Set<String> _shown = <String>{};

  /// 没有 settings 时的内存 ack。
  final Map<String, String> _memAcks = <String, String>{};

  bool _showing = false;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onChange());
  }

  @override
  void didUpdateWidget(CirclePrivacyGate old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  String? _ackFor(String cid) =>
      widget.settings?.privacyAckFor(cid) ?? _memAcks[cid];

  Future<void> _storeAck(String cid, String hash) async {
    _memAcks[cid] = hash;
    final s = widget.settings;
    if (s == null) return;
    try {
      await s.setPrivacyAck(cid, hash);
    } catch (e) {
      debugPrint('[lares] 隐私告知 ack 存不进去($cid): $e');
    }
  }

  Map<String, String> _pluginNames(String cid) {
    final f = widget.pluginNamesOf;
    if (f != null) return f(cid);
    final svc = PluginScope.maybeOf(context);
    if (svc == null) return const {};
    return {for (final p in svc.pluginsFor(cid)) p.id: p.name};
  }

  void _onChange() {
    if (!mounted || _showing || _scheduled) return;
    final c = widget.controller;
    final cid = c.circleId;
    if (cid == null) return;
    if (c.phase != RoomPhase.joining && c.phase != RoomPhase.inRoom) return;
    if (!privacyInfoKnown(c, cid)) return;
    final summary =
        buildCirclePrivacySummary(c, cid, pluginNames: _pluginNames(cid));
    final hash = summary.privacyHash();
    if (_ackFor(cid) == hash) return;
    if (c.isOwnerOf(cid)) {
      unawaited(_storeAck(cid, hash));
      return;
    }
    if (!_shown.add('$cid|$hash')) return;
    // 通知可能发生在 build 期间:挪到帧后再弹。
    _scheduled = true;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _show(cid, hash))
      ..ensureVisualUpdate(); // 后帧回调本身不排帧
  }

  Future<void> _show(String cid, String hash) async {
    _scheduled = false;
    if (!mounted) return;
    final c = widget.controller;
    // 帧后重新取一次(名字可能刚到);哈希变了就交给下一次通知。
    final summary =
        buildCirclePrivacySummary(c, cid, pluginNames: _pluginNames(cid));
    if (summary.privacyHash() != hash) {
      _shown.remove('$cid|$hash');
      _onChange();
      return;
    }
    _showing = true;
    try {
      await showCirclePrivacySheet(
        context,
        summary: summary,
        circleName: widget.circleNameOf?.call(cid) ?? '',
      );
    } finally {
      _showing = false;
    }
    await _storeAck(cid, hash);
    // 弹着的时候配置可能又变了
    _onChange();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
