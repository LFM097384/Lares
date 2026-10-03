/// 进圈隐私告知的单屏面板(契约 features-purpose-contract §4)。
///
/// 一行一件事,关着的不说(端到端加密例外:永远说清是否加密)。
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/gen/app_localizations.dart';
import '../plugins/plugin_models.dart' show pluginPermissionLabel;
import '../theme/tokens.dart';
import 'privacy_summary.dart';

export 'privacy_summary.dart' show CirclePrivacySummary, PrivacyPlugin;

/// 完整隐私政策(docs/privacy.md 发布在 docs.laresapp.org)。
const String kPrivacyPolicyUrl = 'https://docs.laresapp.org/privacy';

/// 弹出告知面板;用户点「知道了」或划掉都算看过(返回后由调用方记 ack)。
Future<void> showCirclePrivacySheet(
  BuildContext context, {
  required CirclePrivacySummary summary,
  required String circleName,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // 与房间「更多」面板一致:有拖拽把手,标题紧贴把手下方
    showDragHandle: true,
    builder: (_) => CirclePrivacySheet(
      summary: summary,
      circleName: circleName,
      underHandle: true,
    ),
  );
}

class CirclePrivacySheet extends StatelessWidget {
  const CirclePrivacySheet({
    super.key,
    required this.summary,
    required this.circleName,
    this.underHandle = false,
  });

  final CirclePrivacySummary summary;
  final String circleName;

  /// 面板自带拖拽把手时为 true:顶部留白交给把手,不再叠一层大边距。
  final bool underHandle;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final s = summary;
    final lines = <Widget>[
      if (s.ai)
        _Line(
          key: const ValueKey('privacy-ai'),
          icon: Icons.smart_toy_outlined,
          text: t.privacySheetAi,
        ),
      if (s.transcript)
        _Line(
          key: const ValueKey('privacy-transcript'),
          icon: Icons.subtitles_outlined,
          text: s.e2ee == true
              ? t.privacySheetTranscriptE2ee
              : t.privacySheetTranscript,
        ),
      if (s.captions)
        _Line(
          key: const ValueKey('privacy-captions'),
          icon: Icons.closed_caption_outlined,
          text: t.privacySheetCaptions,
        ),
      if (s.plugins.isNotEmpty) ...[
        _Line(
          key: const ValueKey('privacy-plugins'),
          icon: Icons.extension_outlined,
          text: t.privacySheetPlugins(
            s.plugins.length,
            s.plugins.map((p) => p.displayName).join(t.privacySheetSeparator),
          ),
        ),
        for (final p in s.plugins)
          _SubLine(
            key: ValueKey('privacy-plugin-${p.id}'),
            text: _pluginDetail(t, p),
            warn: p.hasWebhook,
          ),
      ],
      if (s.focus)
        _Line(
          key: const ValueKey('privacy-focus'),
          icon: Icons.timer_outlined,
          text: t.privacySheetFocus,
        ),
      if (s.map)
        _Line(
          key: const ValueKey('privacy-map'),
          icon: Icons.place_outlined,
          text: t.privacySheetMap,
        ),
      if (s.recording && s.showRecording)
        _Line(
          key: const ValueKey('privacy-recording'),
          icon: Icons.fiber_manual_record_outlined,
          text: t.privacySheetRecording,
        ),
      if (!s.hasNotable)
        _Line(
          key: const ValueKey('privacy-nothing'),
          icon: Icons.check_circle_outline,
          text: t.privacySheetNothing,
        ),
      _Line(
        key: const ValueKey('privacy-e2ee'),
        icon: s.e2ee == true ? Icons.lock_outline : Icons.lock_open_outlined,
        text: switch (s.e2ee) {
          true => t.privacySheetE2eeOn,
          false => t.privacySheetE2eeOff,
          null => t.privacySheetE2eeUnset,
        },
      ),
    ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          LaresSpacing.lg,
          underHandle ? 0 : LaresSpacing.lg,
          LaresSpacing.lg,
          LaresSpacing.lg,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.privacySheetTitle, style: theme.textTheme.titleMedium),
              if (circleName.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    circleName,
                    key: const ValueKey('privacy-circle-name'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: LaresSpacing.md),
              ...lines,
              const SizedBox(height: LaresSpacing.md),
              // 窄屏 / 大字号放不下一行时自动折成两行,不溢出。
              OverflowBar(
                alignment: MainAxisAlignment.spaceBetween,
                overflowAlignment: OverflowBarAlignment.end,
                spacing: LaresSpacing.sm,
                children: [
                  TextButton(
                    key: const ValueKey('privacy-full-policy'),
                    onPressed: () => launchUrl(
                      Uri.parse(kPrivacyPolicyUrl),
                      mode: LaunchMode.externalApplication,
                    ),
                    child: Text(t.privacySheetFullPolicy),
                  ),
                  FilledButton(
                    key: const ValueKey('privacy-got-it'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(t.commonGotIt),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _pluginDetail(AppLocalizations t, PrivacyPlugin p) {
    final perms = p.permissions.isEmpty
        ? t.privacySheetPluginNoPerms
        : p.permissions
              .map((x) => pluginPermissionLabel(t, x))
              .join(t.privacySheetSeparator);
    final base = t.privacySheetPluginDetail(p.displayName, perms);
    return p.hasWebhook ? '$base${t.privacySheetPluginThirdParty}' : base;
  }
}

class _Line extends StatelessWidget {
  const _Line({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: LaresSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 图标略下移,与首行文字的视觉中线对齐(行高 1.5)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              icon,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: LaresSpacing.sm + 4),
          // 主行用正文色;下面的插件明细用淡色小字 —— 主次分明
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SubLine extends StatelessWidget {
  const _SubLine({super.key, required this.text, this.warn = false});

  final String text;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        left: 20 + LaresSpacing.sm + 4,
        bottom: LaresSpacing.xs,
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          height: 1.45,
          color: warn
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
