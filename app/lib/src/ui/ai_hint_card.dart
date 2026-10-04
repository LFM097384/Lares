/// 点房间里的 AI 座位弹出的说明卡:怎么叫它、现在是哪种触发方式、语音去哪儿。
///
/// 内容全从 `lares.ai-voice` 插件配置里来(名字 + 别的叫法 + 触发方式),
/// 配置还没到(插件列表没收到)时按默认值(「小助手」/ 叫名字)说。
library;

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../plugins/ai_voice_settings.dart';
import '../theme/tokens.dart';
import 'widgets/ai_orb.dart';

/// 说明卡里图标的尺寸。
const double _rowIconSize = 20;
const double _headerOrbSize = 36;

/// 只有说明卡的底部面板:房间没接屏蔽名单(没有处置菜单)时点 AI 座位用。
Future<void> showAiHintSheet(
  BuildContext context, {
  required Map<String, dynamic> config,
  String? displayName,
}) {
  final t = AppLocalizations.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AiHintCard(config: config, displayName: displayName),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  LaresSpacing.lg, 0, LaresSpacing.lg, LaresSpacing.sm),
              child: Text(
                t.aiVoiceModerationHint,
                key: const ValueKey('moderation-ai-hint'),
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: LaresSpacing.md),
                child: TextButton(
                  key: const ValueKey('ai-hint-close'),
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(t.commonGotIt),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class AiHintCard extends StatelessWidget {
  const AiHintCard({
    super.key,
    required this.config,
    this.displayName,
    this.askKey,
    this.privacyKey,
  });

  /// 插件配置;空表 = 用默认。
  final Map<String, dynamic> config;

  /// 座位上显示的名字(服务器改名有延迟时,标题仍以配置里的名字为准)。
  final String? displayName;

  /// 外层面板想给「怎么问它」/ 隐私那一行另挂的 key(房间「更多」里的说明面板用
  /// i-info-how / i-info-privacy)。行内文字自己的 i-hint-* key 不变。
  final Key? askKey;
  final Key? privacyKey;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final String name = aiVoiceName(config);
    final String trigger = aiVoiceTrigger(config);
    final bool ptt = trigger == 'ptt';
    final List<String> extras = aiVoiceExtraWakeWords(config);
    final String sep = t.aiHintListSep;

    final String ask = switch (trigger) {
      'always' => t.aiHintAskAlways,
      'ptt' => t.aiHintAskPtt,
      _ => t.aiHintAskWake(name),
    };
    final String? also = ptt
        ? t.aiHintAlsoAt(['@$name', for (final w in extras) '@$w'].join(sep))
        : (extras.isEmpty ? null : t.aiHintAlsoCall(extras.join(sep)));
    final String modeName = switch (trigger) {
      'always' => t.aiVoiceTriggerAlways,
      'ptt' => t.aiVoiceTriggerPtt,
      _ => t.aiVoiceTriggerWake,
    };
    final String modeDesc = switch (trigger) {
      'always' => t.aiVoiceTriggerAlwaysDesc,
      'ptt' => t.aiVoiceTriggerPttDesc(name),
      _ => t.aiVoiceTriggerWakeDesc,
    };

    final TextStyle? muted =
        theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);

    Widget row(IconData icon, Widget text, {Color? iconColor}) => Padding(
          padding: const EdgeInsets.only(top: LaresSpacing.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon,
                  size: _rowIconSize,
                  color: iconColor ?? scheme.onSurfaceVariant),
              const SizedBox(width: LaresSpacing.sm),
              Expanded(child: text),
            ],
          ),
        );

    return Padding(
      key: const ValueKey('ai-hint-card'),
      padding: const EdgeInsets.fromLTRB(
          LaresSpacing.lg, LaresSpacing.sm, LaresSpacing.lg, LaresSpacing.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AiOrbMini(size: _headerOrbSize),
              const SizedBox(width: LaresSpacing.md),
              Expanded(
                child: Text(
                  t.roomMoreAiTitle(name),
                  key: const ValueKey('ai-hint-title'),
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: LaresSpacing.sm),
          // 最要紧的一句:怎么问它。放大、用正文色
          row(
            ptt ? Icons.alternate_email_rounded : Icons.record_voice_over_outlined,
            KeyedSubtree(
              key: askKey,
              child: Text(ask,
                  key: const ValueKey('ai-hint-ask'),
                  style: theme.textTheme.bodyLarge),
            ),
            iconColor: scheme.tertiary,
          ),
          if (also != null)
            Padding(
              padding: const EdgeInsets.only(
                  left: _rowIconSize + LaresSpacing.sm, top: LaresSpacing.xs),
              child: Text(also, key: const ValueKey('ai-hint-also'), style: muted),
            ),
          if (!ptt)
            row(
              Icons.chat_bubble_outline_rounded,
              Text(t.aiHintChatToo,
                  key: const ValueKey('ai-hint-chat'), style: muted),
            ),
          row(
            Icons.tune_rounded,
            Text(t.aiHintMode(modeName, modeDesc),
                key: const ValueKey('ai-hint-mode'), style: muted),
          ),
          row(
            ptt ? Icons.lock_outline_rounded : Icons.cloud_outlined,
            KeyedSubtree(
              key: privacyKey,
              child: Text(
                ptt ? t.aiHintPrivacyPtt : t.aiHintPrivacy,
                key: const ValueKey('ai-hint-privacy'),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
