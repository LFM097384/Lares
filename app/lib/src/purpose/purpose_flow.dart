/// 用途的公共流程:应用并给回执、一次性凭据、分享码导出 / 导入对话框、
/// 建圈时挑的用途(等登记好再应用)。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/gen/app_localizations.dart';
import '../plugins/plugin_models.dart';
import '../plugins/plugin_owner_section.dart';
import '../plugins/plugin_service.dart';
import '../state/circle_features.dart';
import '../state/room_controller.dart';
import '../theme/tokens.dart';
import 'purpose_code.dart';
import 'purpose_schema.dart';

/// 等宽字体(编辑器、分享码共用)。
const TextStyle kPurposeMonoStyle = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['Consolas', 'Menlo', 'Courier New'],
  fontSize: 13,
  height: 1.4,
);

/// 圈主操作失败原因 → 人话。
String purposeReasonText(AppLocalizations t, String reason, String? detail) {
  final d = detail ?? '';
  return switch (reason) {
    'bad_purpose' => t.purposeReasonBad(d),
    'bad_manifest' => t.purposeReasonManifest(d),
    'manifest_fetch_failed' || 'ssrf_blocked' => t.purposeReasonFetch,
    'too_many' => t.purposeReasonTooMany,
    'feature_off' => t.purposeReasonFeatureOff,
    'unknown_builtin' => t.purposeReasonUnknownBuiltin,
    'not_registered' || 'say_hello_first' => t.purposeReasonNotRegistered,
    'not_owner' || 'no_key' => t.homeOwnerErrNotOwner,
    'timeout' => t.homeOwnerErrTimeout,
    _ => t.homeOwnerErrGeneric,
  };
}

/// 用途名牌的显示名:内置用途走本地化,自定义的用服务器给的名字。
String purposeDisplayName(AppLocalizations t, CirclePurposeInfo p) {
  if (p.builtin) {
    for (final b in builtinPurposes(t)) {
      if (b.id == p.id) return b.name;
    }
  }
  return p.name;
}

/// 用途名牌的图标(内置给默认图标)。
String? purposeDisplayIcon(CirclePurposeInfo p) {
  if (p.icon != null) return p.icon;
  return switch (p.id) {
    'chat' => '💬',
    'study' => '📚',
    'meeting' => '📝',
    _ => null,
  };
}

/// 把 purpose_applied.secrets 一条条弹出来(复用插件安装的一次性凭据对话框)。
Future<void> showPurposeSecrets(
    BuildContext context, List<Map<String, dynamic>> secrets) async {
  for (final s in secrets) {
    if (!context.mounted) return;
    final id = s['pluginId'] is String ? s['pluginId'] as String : '';
    final token = s['token'] is String ? s['token'] as String : null;
    final secret =
        s['webhookSecret'] is String ? s['webhookSecret'] as String : null;
    if (token == null && secret == null) continue;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PluginSecretsDialog(
        result: PluginInstallResult(
          plugin: PluginView(id: id, name: id),
          token: token,
          webhookSecret: secret,
        ),
      ),
    );
  }
}

/// 在 [context] 存活期间接管 [RoomController.onPurposeSecrets],
/// 返回一个「还原」函数。凭据只出现这一次,必须当场给圈主看。
VoidCallback hookPurposeSecrets(BuildContext context, RoomController c) {
  final prev = c.onPurposeSecrets;
  void handler(String id, List<Map<String, dynamic>> secrets) {
    if (context.mounted) {
      unawaited(showPurposeSecrets(context, secrets));
    } else {
      prev?.call(id, secrets);
    }
  }

  c.onPurposeSecrets = handler;
  return () {
    if (identical(c.onPurposeSecrets, handler)) c.onPurposeSecrets = prev;
  };
}

/// 应用用途并弹回执。[purpose] 为内置 id 或完整 JSON。成功返回 true。
Future<bool> applyPurposeWithFeedback(
  BuildContext context,
  RoomController controller,
  String circleId,
  Object purpose,
) async {
  final t = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final restore = hookPurposeSecrets(context, controller);
  final String? err;
  try {
    controller.lastOwnerErrorDetail = null;
    err = await controller.applyCirclePurposeAsOwner(circleId, purpose);
  } finally {
    // purpose_applied 先于 owner_ok 到,等到这里凭据已经交出去了
    restore();
  }
  final name = _purposeName(t, purpose);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(err == null
          ? t.purposeApplied(name)
          : t.purposeApplyFailed(purposeReasonText(
              t, err, controller.lastOwnerErrorDetail))),
    ));
  return err == null;
}

String _purposeName(AppLocalizations t, Object purpose) {
  if (purpose is String) {
    for (final b in builtinPurposes(t)) {
      if (b.id == purpose) return b.name;
    }
    return purpose;
  }
  if (purpose is Map && purpose['name'] is String) {
    return purpose['name'] as String;
  }
  return t.purposeCustom;
}

/// 导出当前配置 → 编成码 → 弹出来。
Future<void> exportPurposeFlow(
    BuildContext context, RoomController controller, String circleId) async {
  final t = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final p = await controller.exportCirclePurposeAsOwner(circleId);
  if (!context.mounted) return;
  if (p == null) {
    messenger?.showSnackBar(SnackBar(content: Text(t.purposeExportFailed)));
    return;
  }
  await showPurposeCodeDialog(context, encodePurposeCode(p));
}

/// 展示一串分享码(可选中、等宽)+ 复制按钮。
Future<void> showPurposeCodeDialog(BuildContext context, String code) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final t = AppLocalizations.of(ctx);
      return AlertDialog(
        title: Text(t.purposeCodeTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.purposeCodeHint,
                  style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: LaresSpacing.sm),
              SelectableText(code,
                  key: const ValueKey('purpose-code-text'),
                  style: kPurposeMonoStyle),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('purpose-code-copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (!ctx.mounted) return;
              ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
                  SnackBar(content: Text(t.purposeCodeCopied)));
            },
            child: Text(t.commonCopy),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.commonDone),
          ),
        ],
      );
    },
  );
}

String purposeCodeErrorText(AppLocalizations t, PurposeCodeException e) =>
    switch (e.kind) {
      PurposeCodeErrorKind.prefix => t.purposeCodeErrPrefix,
      PurposeCodeErrorKind.base64 ||
      PurposeCodeErrorKind.gzip =>
        t.purposeCodeErrBroken,
      PurposeCodeErrorKind.tooLarge => t.purposeCodeErrTooLarge,
      PurposeCodeErrorKind.json ||
      PurposeCodeErrorKind.notObject =>
        t.purposeCodeErrJson,
    };

/// 粘贴分享码的对话框。返回解出来的 JSON(没校验结构)。
///
/// [preview] 为 true 时显示「会改什么」并以「应用」收尾(功能页用);
/// 否则以「填进去」收尾(编辑器用)。[current] 用来算「打开 / 关闭」。
Future<Map<String, dynamic>?> showPurposeImportDialog(
  BuildContext context, {
  bool preview = true,
  CircleFeatures? current,
}) {
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (_) => PurposeImportDialog(preview: preview, current: current),
  );
}

class PurposeImportDialog extends StatefulWidget {
  const PurposeImportDialog({super.key, this.preview = true, this.current});
  final bool preview;
  final CircleFeatures? current;

  @override
  State<PurposeImportDialog> createState() => _PurposeImportDialogState();
}

class _PurposeImportDialogState extends State<PurposeImportDialog> {
  final _field = TextEditingController();
  Map<String, dynamic>? _decoded;
  String? _error;
  List<PurposeIssue> _issues = const [];

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _decode(String text) {
    final t = AppLocalizations.of(context);
    setState(() {
      _decoded = null;
      _error = null;
      _issues = const [];
      if (text.trim().isEmpty) return;
      try {
        _decoded = decodePurposeCode(text);
        _issues = validatePurpose(_decoded);
      } on PurposeCodeException catch (e) {
        _error = purposeCodeErrorText(t, e);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final d = _decoded;
    final canApply = d != null && (!widget.preview || _issues.isEmpty);
    return AlertDialog(
      title: Text(t.purposeImportTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('purpose-import-field'),
              controller: _field,
              autofocus: true,
              maxLines: 4,
              minLines: 2,
              style: kPurposeMonoStyle,
              decoration: InputDecoration(
                hintText: t.purposeImportFieldHint,
                errorText: _error,
                errorMaxLines: 3,
              ),
              onChanged: _decode,
            ),
            if (d != null && widget.preview) ...[
              const SizedBox(height: LaresSpacing.md),
              PurposePreview(purpose: d, current: widget.current),
              for (final i in _issues)
                Padding(
                  padding: const EdgeInsets.only(top: LaresSpacing.xs),
                  child: Text(
                    '${i.path}: ${purposeIssueMessage(t, i)}',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12),
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.commonCancel),
        ),
        FilledButton(
          key: const ValueKey('purpose-import-confirm'),
          onPressed: canApply ? () => Navigator.pop(context, d) : null,
          child: Text(
              widget.preview ? t.purposeImportApply : t.purposeImportFill),
        ),
      ],
    );
  }
}

String featureLabel(AppLocalizations t, CircleFeature f) => switch (f) {
      CircleFeature.captions => t.featureCaptions,
      CircleFeature.transcript => t.featureTranscript,
      CircleFeature.voiceNotes => t.featureVoiceNotes,
      CircleFeature.map => t.featureMap,
      CircleFeature.recording => t.featureRecording,
      CircleFeature.plugins => t.featurePlugins,
      CircleFeature.focus => t.featureFocus,
      CircleFeature.p2p => t.featureP2p,
      CircleFeature.devTools => t.featureDevTools,
    };

/// 一份用途「会改什么」的摘要:名字 + 图标、打开 / 关闭哪些功能、插件、圈设置。
class PurposePreview extends StatelessWidget {
  const PurposePreview({super.key, required this.purpose, this.current});
  final Map<String, dynamic> purpose;
  final CircleFeatures? current;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final sep = t.commonListSeparator;
    final on = <String>[];
    final off = <String>[];
    final f = purpose['features'];
    if (f is Map) {
      for (final feat in CircleFeature.values) {
        final v = f[feat.key];
        if (v is! bool) continue;
        if (current != null && current!.isOn(feat) == v) continue;
        (v ? on : off).add(featureLabel(t, feat));
      }
    }
    final plugins = purpose['plugins'] is List
        ? (purpose['plugins'] as List).length
        : 0;
    final settings = purpose['settings'] is Map
        ? (purpose['settings'] as Map)
            .entries
            .map((e) => '${e.key}=${e.value}')
            .join(sep)
        : '';
    final icon = purpose['icon'] is String ? purpose['icon'] as String : '';
    final name = purpose['name'] is String ? purpose['name'] as String : '?';
    final desc =
        purpose['description'] is String ? purpose['description'] as String : '';
    return Column(
      key: const ValueKey('purpose-preview'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$icon $name'.trim(), style: theme.textTheme.titleMedium),
        if (desc.isNotEmpty)
          Text(desc, style: theme.textTheme.bodySmall),
        const SizedBox(height: LaresSpacing.xs),
        if (on.isEmpty && off.isEmpty) Text(t.purposePreviewNoChange),
        if (on.isNotEmpty) Text(t.purposePreviewTurnsOn(on.join(sep))),
        if (off.isNotEmpty) Text(t.purposePreviewTurnsOff(off.join(sep))),
        if (plugins > 0) Text(t.purposePreviewPlugins(plugins)),
        if (settings.isNotEmpty) Text(t.purposePreviewSettings(settings)),
      ],
    );
  }
}

// ── 建圈时挑的用途 ────────────────────────────────────────────────────

/// 新圈要等下一次握手才登记、圈主钥匙也是那时才被服务器认下,
/// 所以建圈时挑的用途先记在这里,等 `isOwnerOf && isRegisteredCircle`
/// 成立再应用一次。只在内存里:App 重启前没登记上就算了(圈主之后可以在
/// 「功能」里再选)。
class PendingPurposes {
  PendingPurposes._();
  static final PendingPurposes instance = PendingPurposes._();

  /// 最长等多久(在别的房间里时,要等第一次进这个圈才会登记)。
  static Duration timeout = const Duration(minutes: 30);

  final Map<String, _Pending> _pending = {};

  /// 还在等的用途(测试 / 截图用)。
  Object? pendingFor(String circleId) => _pending[circleId]?.purpose;

  /// 记下 [purpose](内置 id 或 JSON),条件满足时应用;[onResult] 收回执
  /// (null = 成功,否则原因码)。
  void schedule(
    RoomController controller,
    String circleId,
    Object purpose, {
    void Function(String? error, String? detail)? onResult,
  }) {
    cancel(circleId);
    late final _Pending p;
    void check() {
      if (p.fired) return;
      if (!controller.isOwnerOf(circleId) ||
          !controller.isRegisteredCircle(circleId)) {
        return;
      }
      p.fired = true;
      _remove(circleId, p);
      unawaited(() async {
        controller.lastOwnerErrorDetail = null;
        final err = await controller.applyCirclePurposeAsOwner(circleId, purpose);
        onResult?.call(err, controller.lastOwnerErrorDetail);
      }());
    }

    p = _Pending(
      purpose: purpose,
      controller: controller,
      listener: check,
      timer: Timer(timeout, () => cancel(circleId)),
    );
    _pending[circleId] = p;
    controller.addListener(check);
    // 也许已经登记好了(空闲时建圈,welcome 来得很快)
    check();
  }

  void cancel(String circleId) {
    final p = _pending[circleId];
    if (p != null) _remove(circleId, p);
  }

  void _remove(String circleId, _Pending p) {
    p.timer.cancel();
    p.controller.removeListener(p.listener);
    if (identical(_pending[circleId], p)) _pending.remove(circleId);
  }
}

class _Pending {
  _Pending({
    required this.purpose,
    required this.controller,
    required this.listener,
    required this.timer,
  });
  final Object purpose;
  final RoomController controller;
  final VoidCallback listener;
  final Timer timer;
  bool fired = false;
}
