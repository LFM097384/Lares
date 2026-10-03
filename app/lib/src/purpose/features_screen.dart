/// 圈主的「功能」页:用途 + 9 个功能开关 + 分享码导出 / 导入。
/// 契约 docs/plans/features-purpose-contract.md §1–§3。
library;

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../config.dart';
import '../state/circle_features.dart';
import '../state/room_controller.dart';
import '../theme/tokens.dart';
import 'purpose_editor.dart';
import 'purpose_flow.dart';
import 'purpose_picker.dart';
import 'purpose_schema.dart';

/// 功能的一句话说明。
String featureDescription(AppLocalizations t, CircleFeature f) => switch (f) {
      CircleFeature.captions => t.ownerFeatureCaptionsDesc,
      CircleFeature.transcript => t.ownerFeatureTranscriptDesc,
      CircleFeature.voiceNotes => t.ownerFeatureVoiceNotesDesc,
      CircleFeature.map => t.ownerFeatureMapDesc,
      CircleFeature.recording => t.ownerFeatureRecordingDesc,
      CircleFeature.plugins => t.ownerFeaturePluginsDesc,
      CircleFeature.focus => t.ownerFeatureFocusDesc,
      CircleFeature.p2p => t.ownerFeatureP2pDesc,
      CircleFeature.devTools => t.ownerFeatureDevToolsDesc,
    };

/// 当前用途的显示文字(没设过 → 「还没选」)。
String purposeSummary(AppLocalizations t, CirclePurposeInfo? p) {
  if (p == null) return t.purposeNone;
  final icon = purposeDisplayIcon(p);
  final name = purposeDisplayName(t, p);
  return icon == null ? name : '$icon $name';
}

/// 走完整的「选用途」流程:选 → (自定义则开编辑器)→ 应用 → 回执。
Future<void> pickAndApplyPurpose(
    BuildContext context, RoomController controller, String circleId) async {
  final current = controller.circlePurpose[circleId]?.id;
  // 端到端加密圈里 AI 助手不会工作(服务器不给加密圈起 AI),开关不可拨
  final choice = await showPurposePicker(context,
      current: current,
      aiUnavailable: controller.circleInfo[circleId]?.e2ee == true);
  if (choice == null || !context.mounted) return;
  Object purpose = choice;
  if (choice == kPurposeMeetingAiChoice) {
    purpose = meetingWithAiPurpose();
  } else if (choice == kPurposeCustomId) {
    final t = AppLocalizations.of(context);
    // 先拿当前实际配置做底;拿不到用模板
    final exported = await controller.exportCirclePurposeAsOwner(circleId);
    if (!context.mounted) return;
    final edited =
        await openPurposeEditor(context, initial: exported ?? purposeTemplate(t));
    if (edited == null || !context.mounted) return;
    purpose = edited;
  }
  await applyPurposeWithFeedback(context, controller, circleId, purpose);
}

/// 圈子菜单里的「功能」入口(和「用途」一起)。
class FeaturesOwnerTiles extends StatelessWidget {
  const FeaturesOwnerTiles({
    super.key,
    required this.controller,
    required this.circleId,
    this.onBeforeOpen,
    this.hostContext,
  });

  final RoomController controller;
  final String circleId;

  /// 打开之前关掉菜单
  final VoidCallback? onBeforeOpen;

  /// 菜单关掉后用来继续流程的 context(菜单自己的 context 会随之销毁)
  final BuildContext? hostContext;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          key: const ValueKey('owner-purpose-tile'),
          leading: const Icon(Icons.category_outlined),
          title: Text(t.purposeTitle),
          subtitle: Text(purposeSummary(t, controller.circlePurpose[circleId])),
          onTap: () {
            final host = hostContext ?? context;
            onBeforeOpen?.call();
            pickAndApplyPurpose(host, controller, circleId);
          },
        ),
        ListTile(
          key: const ValueKey('owner-features-tile'),
          leading: const Icon(Icons.tune_rounded),
          title: Text(t.ownerFeaturesTitle),
          subtitle: Text(t.ownerFeaturesEntryDesc),
          onTap: () {
            final nav = Navigator.of(hostContext ?? context);
            onBeforeOpen?.call();
            nav.push(MaterialPageRoute<void>(
              builder: (_) =>
                  FeaturesScreen(controller: controller, circleId: circleId),
            ));
          },
        ),
      ],
    );
  }
}

class FeaturesScreen extends StatefulWidget {
  const FeaturesScreen({
    super.key,
    required this.controller,
    required this.circleId,
    this.recordingAvailable = LaresConfig.recordingEnabled,
  });

  final RoomController controller;
  final String circleId;

  /// 本构建有没有录音(LARES_RECORDING)。没有时开关照样能拨,只是注明。
  final bool recordingAvailable;

  @override
  State<FeaturesScreen> createState() => _FeaturesScreenState();
}

class _FeaturesScreenState extends State<FeaturesScreen> {
  /// 正在等回执的开关 → 乐观值
  final Map<CircleFeature, bool> _pending = {};
  VoidCallback? _restoreSecrets;

  RoomController get _c => widget.controller;
  String get _cid => widget.circleId;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChange);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 页面开着时,凭据(新装 webhook 插件)在这里弹
    _restoreSecrets ??= hookPurposeSecrets(context, _c);
  }

  @override
  void dispose() {
    _c.removeListener(_onChange);
    _restoreSecrets?.call();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _snack(String s) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _toggle(CircleFeature f, bool v) async {
    final t = AppLocalizations.of(context);
    setState(() => _pending[f] = v);
    _c.lastOwnerErrorDetail = null;
    final err = await _c.setCircleFeaturesAsOwner(_cid, {f: v});
    if (!mounted) return;
    // 成功时服务器的 circle_settings 会把真值带回来;失败就回到原值
    setState(() => _pending.remove(f));
    if (err != null) {
      _snack(t.ownerFeatureToggleFailed(
          featureLabel(t, f), purposeReasonText(t, err, _c.lastOwnerErrorDetail)));
    }
  }

  Future<void> _import() async {
    final m = await showPurposeImportDialog(context,
        preview: true, current: _c.featuresOf(_cid));
    if (m == null || !mounted) return;
    await applyPurposeWithFeedback(context, _c, _cid, m);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final feats = _c.featuresOf(_cid);
    final purpose = _c.circlePurpose[_cid];
    return Scaffold(
      appBar: AppBar(title: Text(t.ownerFeaturesTitle)),
      body: ListView(
        children: [
          ListTile(
            key: const ValueKey('features-purpose-tile'),
            leading: const Icon(Icons.category_outlined),
            title: Text(t.purposeTitle),
            subtitle: Text(purposeSummary(t, purpose)),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => pickAndApplyPurpose(context, _c, _cid),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                LaresSpacing.md, 0, LaresSpacing.md, LaresSpacing.sm),
            child: Wrap(
              spacing: LaresSpacing.sm,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('features-export'),
                  icon: const Icon(Icons.ios_share_rounded, size: 18),
                  label: Text(t.purposeExport),
                  onPressed: () => exportPurposeFlow(context, _c, _cid),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('features-import'),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: Text(t.purposeImport),
                  onPressed: _import,
                ),
              ],
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                LaresSpacing.md, LaresSpacing.sm, LaresSpacing.md, 0),
            child: Text(t.ownerFeaturesHint, style: theme.textTheme.bodySmall),
          ),
          for (final f in CircleFeature.values)
            SwitchListTile(
              key: ValueKey('feature-switch-${f.key}'),
              title: Text(featureLabel(t, f)),
              subtitle: Text(
                f == CircleFeature.recording && !widget.recordingAvailable
                    ? '${featureDescription(t, f)}\n${t.ownerFeatureRecordingUnavailable}'
                    : featureDescription(t, f),
              ),
              value: _pending[f] ?? feats.isOn(f),
              onChanged: _pending.containsKey(f) ? null : (v) => _toggle(f, v),
            ),
          const SizedBox(height: LaresSpacing.lg),
        ],
      ),
    );
  }
}
