/// 炉灵助理的底部面板:圈主邀请 AI([AnonymConveneSheet])、成员同意书
/// ([AnonymConsentSheet])、E2EE 圈的密钥请求确认([AnonymKeyRequestSheet]),
/// 以及共用的规则卡 / 诚实声明。
///
/// 定性:受 Chatham House 规则启发,非官方;与 Chatham House 无隶属。
/// 任何文案都不得写成「依规则」/「under the Rule」。
library;

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../theme/tokens.dart';
import 'anonym_controller.dart';
import 'anonym_kit.dart';

/// 规则原文卡:英文 + 官方中文译文(逐字,不进 l10n)。
class AnonymRuleCard extends StatelessWidget {
  const AnonymRuleCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      key: const ValueKey('anon-rule-card'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      decoration: BoxDecoration(
        color: theme.isDark
            ? Color.alphaBlend(
                LaresColors.ember.withValues(alpha: 0.05),
                cs.surface,
              )
            : const Color(0xFFFFFBF6),
        borderRadius: BorderRadius.circular(LaresRadii.md + 4),
        border: Border.all(
          color: LaresColors.ember.withValues(
            alpha: theme.isDark ? 0.16 : 0.22,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Overline(
            'THE CHATHAM HOUSE RULE',
            color: LaresColors.ember.withValues(alpha: 0.85),
          ),
          const SizedBox(height: 8),
          Text(
            kRuleEn,
            style: TextStyle(
              fontFamily: ChathamType.serifLatin,
              fontStyle: FontStyle.italic,
              fontSize: 12,
              height: 1.4,
              color: cs.onSurface.withValues(alpha: 0.86),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: 24,
            height: 1,
            color: LaresColors.ember.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 8),
          Text(
            kRuleZh,
            style: TextStyle(
              fontFamily: ChathamType.serifCjk,
              fontSize: 12.5,
              height: 1.6,
              color: cs.onSurface.withValues(alpha: 0.78),
            ),
          ),
        ],
      ),
    );
  }
}

/// 诚实声明:原话会经过哪里,以及什么会被记住。召集面板和同意书里一字不差。
class AnonymDisclosure extends StatelessWidget {
  const AnonymDisclosure({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('anon-disclosure'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LaresRadii.md),
        border: Border.all(color: theme.hairline),
      ),
      child: Column(
        children: [
          _DisclosureLine(icon: Icons.shield_outlined, text: t.anonDisclosure),
          const SizedBox(height: 8),
          _DisclosureLine(
            key: const ValueKey('anon-memory-disclosure'),
            icon: Icons.bookmark_border_rounded,
            text: t.anonMemoryDisclosure,
          ),
        ],
      ),
    );
  }
}

class _DisclosureLine extends StatelessWidget {
  const _DisclosureLine({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final Color c = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 16, color: c),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12.5, height: 1.55, color: c),
          ),
        ),
      ],
    );
  }
}

/// 面板头:约印 + 标题。
class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        const RuleSeal(size: 44, years: false),
        const SizedBox(width: LaresSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleMedium),
            ],
          ),
        ),
      ],
    );
  }
}

/// 邀请面板底部唯一的一行出处脚注:受 Chatham House 规则启发 · 非官方 · 无隶属。
/// 其他页面一律不挂这类标签。
class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Center(
      child: Text(
        t.anonNotAffiliated,
        key: const ValueKey('anon-not-affiliated'),
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, color: Theme.of(context).faint),
      ),
    );
  }
}

Widget _sheetFrame(BuildContext context, List<Widget> children) {
  return SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        LaresSpacing.lg,
        0,
        LaresSpacing.lg,
        LaresSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}

// ─────────────────────────── 召集 ───────────────────────────

/// 圈主邀请炉灵助理入房(选好放行门槛 k)。[presentCount] 是此刻在房的真人数(不含 AI 助手)。
Future<void> showAnonymConveneSheet(
  BuildContext context, {
  required AnonymController anonym,
  required int presentCount,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) =>
        AnonymConveneSheet(anonym: anonym, presentCount: presentCount),
  );
}

class AnonymConveneSheet extends StatefulWidget {
  const AnonymConveneSheet({
    super.key,
    required this.anonym,
    required this.presentCount,
  });

  final AnonymController anonym;
  final int presentCount;

  @override
  State<AnonymConveneSheet> createState() => _AnonymConveneSheetState();
}

class _AnonymConveneSheetState extends State<AnonymConveneSheet> {
  late int _k = AnonymController.defaultK(widget.presentCount);

  int get _n => widget.presentCount;
  bool get _enough => _n >= 2;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return _sheetFrame(context, [
      _SheetHeader(title: t.anonConveneTitle),
      const SizedBox(height: LaresSpacing.md),
      Text(t.anonKLabel, style: theme.textTheme.titleSmall),
      const SizedBox(height: 4),
      if (_enough)
        Row(
          children: [
            IconButton(
              key: const ValueKey('anon-k-minus'),
              onPressed: _k > 2 ? () => setState(() => _k--) : null,
              icon: const Icon(Icons.remove_rounded),
            ),
            Expanded(
              child: Text(
                t.anonKValue(_k, _n),
                key: const ValueKey('anon-k-value'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('anon-k-plus'),
              onPressed: _k < _n ? () => setState(() => _k++) : null,
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        )
      else
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            t.anonConveneNeedTwo,
            key: const ValueKey('anon-need-two'),
            style: TextStyle(color: cs.error),
          ),
        ),
      Text(
        t.anonKHint,
        style: TextStyle(fontSize: 12, height: 1.5, color: cs.onSurfaceVariant),
      ),
      const SizedBox(height: LaresSpacing.md),
      const AnonymDisclosure(),
      const SizedBox(height: LaresSpacing.md),
      SizedBox(
        height: 48,
        child: FilledButton(
          key: const ValueKey('anon-convene-start'),
          onPressed: _enough
              ? () {
                  widget.anonym.invite(AnonymController.clampK(_k, _n));
                  Navigator.of(context).pop();
                }
              : null,
          child: Text(t.anonConveneStart),
        ),
      ),
      const SizedBox(height: LaresSpacing.sm),
      const _Footer(),
    ]);
  }
}

// ─────────────────────────── 同意书 ───────────────────────────

/// 同意书。返回 true = 同意并加入;false / null = 暂不加入(下滑关掉也算)。
Future<void> showAnonymConsentSheet(
  BuildContext context, {
  required AnonymController anonym,
}) async {
  final bool? yes = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => AnonymConsentSheet(convenerName: anonym.convenerName),
  );
  // 等面板关掉的工夫会话可能已经散了 / 换了一场:那就什么都不做
  if (!anonym.needsConsent) return;
  if (yes == true) {
    anonym.accept();
  } else {
    anonym.decline();
  }
}

class AnonymConsentSheet extends StatelessWidget {
  const AnonymConsentSheet({super.key, this.convenerName});

  final String? convenerName;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final String? name = convenerName;
    return _sheetFrame(context, [
      _SheetHeader(
        title: name == null || name.isEmpty
            ? t.anonConsentTitleOwner
            : t.anonConsentTitle(name),
      ),
      const SizedBox(height: LaresSpacing.md),
      Text(
        t.anonConsentBody,
        style: TextStyle(fontSize: 13.5, height: 1.6, color: cs.onSurface),
      ),
      const SizedBox(height: LaresSpacing.md),
      const AnonymDisclosure(),
      const SizedBox(height: LaresSpacing.md),
      Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 48,
              child: OutlinedButton(
                key: const ValueKey('anon-consent-decline'),
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(t.anonConsentDecline),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 48,
              child: FilledButton(
                key: const ValueKey('anon-consent-accept'),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(t.anonConsentAccept),
              ),
            ),
          ),
        ],
      ),
    ]);
  }
}

/// 圈主散会前的确认。
Future<void> confirmAnonymEnd(
  BuildContext context,
  AnonymController anonym,
) async {
  final t = AppLocalizations.of(context);
  final bool? yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.anonEndConfirmTitle),
      content: Text(t.anonEndConfirmBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(t.commonCancel),
        ),
        FilledButton(
          key: const ValueKey('anon-end-confirm'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(t.anonEndConfirm),
        ),
      ],
    ),
  );
  if (yes == true) anonym.end();
}

/// 圈主请 AI 离开前的确认。
Future<void> confirmAnonymDismiss(
  BuildContext context,
  AnonymController anonym,
) async {
  final t = AppLocalizations.of(context);
  final bool? yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.anonDismissConfirmTitle),
      content: Text(t.anonDismissConfirmBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(t.commonCancel),
        ),
        FilledButton(
          key: const ValueKey('anon-dismiss-confirm'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(t.anonDismissAi),
        ),
      ],
    ),
  );
  if (yes == true) anonym.dismiss();
}

// ─────────────────────────── 密钥请求(E2EE 圈)───────────────────────────

/// 托管 agent 要本圈媒体密钥(`anon_agent_keyreq`)。同意 → 密封后发 `anon_agent_key`;
/// 拒绝 / 下滑关掉 → 什么都不发,agent 进不了加密房。
Future<void> showAnonymKeyRequestSheet(
  BuildContext context, {
  required AnonymController anonym,
}) async {
  final AnonymKeyRequest? req = anonym.keyRequest;
  if (req == null) return;
  final bool? yes = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const AnonymKeyRequestSheet(),
  );
  // 等面板关掉的工夫请求可能已作废(agent 走了 / 换了一个请求)
  if (!identical(anonym.keyRequest, req)) return;
  if (yes == true) {
    await anonym.acceptKeyRequest();
  } else {
    anonym.declineKeyRequest();
  }
}

class AnonymKeyRequestSheet extends StatelessWidget {
  const AnonymKeyRequestSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return _sheetFrame(context, [
      _SheetHeader(title: t.anonKeyReqTitle),
      const SizedBox(height: LaresSpacing.md),
      Text(
        t.anonKeyReqBody,
        style: TextStyle(fontSize: 13.5, height: 1.6, color: cs.onSurface),
      ),
      const SizedBox(height: LaresSpacing.md),
      Container(
        key: const ValueKey('anon-keyreq-note'),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(LaresRadii.md),
          border: Border.all(color: theme.hairline),
        ),
        child: _DisclosureLine(
          icon: Icons.key_outlined,
          text: t.anonKeyReqNote,
        ),
      ),
      const SizedBox(height: LaresSpacing.md),
      Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 48,
              child: OutlinedButton(
                key: const ValueKey('anon-keyreq-decline'),
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(t.anonKeyReqDecline),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 48,
              child: FilledButton(
                key: const ValueKey('anon-keyreq-accept'),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(t.anonKeyReqAccept),
              ),
            ),
          ),
        ],
      ),
    ]);
  }
}