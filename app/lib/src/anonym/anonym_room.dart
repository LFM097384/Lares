/// 房间里的隐名之约:约带 + 成员加入状态 + 问 AI / 出门稿入口([AnonymRoomBand]),
/// 室内问答面板([AnonymAskSheet]),以及自动弹同意书 / 散会卡的宿主([AnonymRoomHost])。
library;

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../state/settings_store.dart';
import '../theme/tokens.dart';
import 'anonym_controller.dart';
import 'anonym_gate.dart';
import 'anonym_kit.dart';
import 'anonym_sheets.dart';

/// 约带:会话不在时自己缩成 [SizedBox.shrink]。
class AnonymRoomBand extends StatelessWidget {
  const AnonymRoomBand({super.key, required this.anonym, this.settings});

  final AnonymController anonym;

  /// v2 起不再用(AI 自己听,不靠本机字幕);留着只为不改调用方。
  final SettingsStore? settings;

  @override
  Widget build(BuildContext context) {
    final Listenable l = settings == null
        ? anonym
        : Listenable.merge([anonym, settings!]);
    return ListenableBuilder(
      listenable: l,
      builder: (context, _) {
        if (!anonym.active) return const SizedBox.shrink();
        return _Band(anonym: anonym, settings: settings);
      },
    );
  }
}

class _Band extends StatelessWidget {
  const _Band({required this.anonym, this.settings});
  final AnonymController anonym;
  final SettingsStore? settings;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final members = anonym.members;
    final int ackedCount = members.where((m) => m.acked).length;
    final AnonymAnswer? latest = anonym.answers.isEmpty
        ? null
        : anonym.answers.last;
    return Padding(
      key: const ValueKey('anon-band'),
      padding: const EdgeInsets.fromLTRB(
        LaresSpacing.md,
        6,
        LaresSpacing.md,
        6,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RuleBand(latin: t.anonBandLatin, zh: t.anonBandZh),
          const SizedBox(height: 6),
          // 成员加入状态:一行可横滑的小胶囊
          SizedBox(
            height: 24,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                Pill(
                  key: const ValueKey('anon-joined-count'),
                  label: t.anonJoinedCount(ackedCount, members.length),
                  icon: Icons.how_to_reg_outlined,
                  color: LaresColors.ember,
                  filled: true,
                  dense: true,
                ),
                for (final m in members) ...[
                  const SizedBox(width: 6),
                  _MemberPill(member: m),
                ],
              ],
            ),
          ),
          if (anonym.declined) ...[
            const SizedBox(height: 6),
            _Note(
              key: const ValueKey('anon-declined-note'),
              icon: Icons.do_not_disturb_on_outlined,
              text: t.anonDeclinedNote,
              action: t.anonJoinNow,
              onAction: () =>
                  showAnonymConsentSheet(context, anonym: anonym).ignore(),
            ),
          ],
          if (anonym.acked) ...[
            const SizedBox(height: 6),
            if (latest != null || anonym.askPending)
              _LatestAnswer(
                answer: latest,
                pending: anonym.askPending,
                onTap: () => showAnonymAskSheet(context, anonym: anonym),
              ),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: OutlinedButton.icon(
                      key: const ValueKey('anon-ask'),
                      style: _bandButton(OutlinedButton.styleFrom()),
                      onPressed: () =>
                          showAnonymAskSheet(context, anonym: anonym),
                      icon: const Icon(Icons.auto_awesome_outlined, size: 16),
                      label: Text(t.anonAskAi, style: _bandLabel),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('anon-minutes'),
                      style: _bandButton(FilledButton.styleFrom()),
                      onPressed: anonym.draftPending
                          ? null
                          : () {
                              if (anonym.draft == null) anonym.requestMinutes();
                              openAnonymGate(context, anonym);
                            },
                      icon: const Icon(
                        Icons.summarize_outlined,
                        size: 16,
                      ),
                      label: Text(
                        anonym.draftPending
                            ? t.anonDraftPending
                            : anonym.draft == null
                            ? t.anonExportMinutes
                            : t.anonOpenDraft,
                        style: _bandLabel,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (anonym.lastError case final code?) ...[
            const SizedBox(height: 4),
            Text(
              t.anonError(code),
              key: const ValueKey('anon-error'),
              style: TextStyle(fontSize: 12, color: cs.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _MemberPill extends StatelessWidget {
  const _MemberPill({required this.member});
  final AnonymMember member;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Pill(
      key: ValueKey('anon-member-${member.id}'),
      label:
          '${member.name} · ${member.acked ? t.anonMemberAcked : t.anonMemberNotJoined}',
      icon: member.acked ? Icons.check_rounded : Icons.remove_rounded,
      color: member.acked
          ? cs.onSurface
          : cs.onSurfaceVariant.withValues(alpha: 0.7),
      dense: true,
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({
    super.key,
    required this.icon,
    required this.text,
    required this.action,
    required this.onAction,
  });
  final IconData icon;
  final String text;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LaresRadii.sm),
        border: Border.all(color: theme.hairline),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: Text(
              action,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _LatestAnswer extends StatelessWidget {
  const _LatestAnswer({
    required this.answer,
    required this.pending,
    required this.onTap,
  });
  final AnonymAnswer? answer;
  final bool pending;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(LaresRadii.sm),
        child: InkWell(
          key: const ValueKey('anon-latest-answer'),
          borderRadius: BorderRadius.circular(LaresRadii.sm),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Row(
              children: [
                const _AiDot(size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    pending ? t.anonThinking : answer!.answer,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _NoTraceTag(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NoTraceTag extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Pill(
      key: const ValueKey('anon-no-trace'),
      label: t.anonNoTrace,
      icon: Icons.visibility_off_outlined,
      color: LaresColors.ember,
      dense: true,
    );
  }
}

/// 简化的 AI 光球(静态)。
class _AiDot extends StatelessWidget {
  const _AiDot({this.size = 28});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: Alignment(-0.35, -0.4),
          colors: [
            Color(0xFFFFE3D1),
            LaresColors.aiGlow,
            LaresColors.ember,
            LaresColors.aiPlum,
          ],
          stops: [0, 0.3, 0.7, 1],
        ),
      ),
    );
  }
}

// ─────────────────────────── 问 AI ───────────────────────────

Future<void> showAnonymAskSheet(
  BuildContext context, {
  required AnonymController anonym,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => AnonymAskSheet(anonym: anonym),
  );
}

/// 室内问答:只在屋里,不存档、不出门(不留痕)。会话散了自己关掉。
class AnonymAskSheet extends StatefulWidget {
  const AnonymAskSheet({super.key, required this.anonym});
  final AnonymController anonym;

  @override
  State<AnonymAskSheet> createState() => _AnonymAskSheetState();
}

class _AnonymAskSheetState extends State<AnonymAskSheet> {
  final TextEditingController _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.anonym.addListener(_onChange);
  }

  void _onChange() {
    if (!widget.anonym.acked && mounted) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    widget.anonym.removeListener(_onChange);
    _text.dispose();
    super.dispose();
  }

  void _send() {
    final String q = _text.text.trim();
    if (q.isEmpty) return;
    widget.anonym.ask(q);
    _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: ListenableBuilder(
            listenable: widget.anonym,
            builder: (context, _) {
              final answers = widget.anonym.answers;
              return Padding(
                padding: const EdgeInsets.fromLTRB(
                  LaresSpacing.lg,
                  0,
                  LaresSpacing.lg,
                  LaresSpacing.md,
                ),
                child: Column(
                  key: const ValueKey('anon-ask-sheet'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const _AiDot(size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            t.anonAnswersTitle,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        _NoTraceTag(),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      t.anonAskSubtitle,
                      key: const ValueKey('anon-ask-subtitle'),
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: theme.faint,
                      ),
                    ),
                    const SizedBox(height: LaresSpacing.sm),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final a in answers)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    a.askerName.isEmpty
                                        ? a.question
                                        : '${t.anonAnswerAsker(a.askerName)}:${a.question}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: theme.faint,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    a.answer,
                                    style: TextStyle(
                                      fontSize: 14,
                                      height: 1.55,
                                      color: cs.onSurface,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (widget.anonym.askPending)
                            Text(
                              t.anonThinking,
                              key: const ValueKey('anon-thinking'),
                              style: TextStyle(color: cs.onSurfaceVariant),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: LaresSpacing.sm),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('anon-ask-field'),
                            controller: _text,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _send(),
                            decoration: InputDecoration(
                              hintText: t.anonAskHint,
                              isDense: true,
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          key: const ValueKey('anon-ask-send'),
                          onPressed: widget.anonym.askPending ? null : _send,
                          child: Text(t.anonAskSend),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────── 宿主 ───────────────────────────

/// 套在房间页外面:会话一开、我还没表态 → 弹同意书(每场一次);
/// 散会 → 弹散会卡;圈主收到 agent 的密钥请求 → 弹确认。自身不画任何东西。
class AnonymRoomHost extends StatefulWidget {
  const AnonymRoomHost({super.key, required this.anonym, required this.child});

  final AnonymController anonym;
  final Widget child;

  @override
  State<AnonymRoomHost> createState() => _AnonymRoomHostState();
}

class _AnonymRoomHostState extends State<AnonymRoomHost> {
  String? _promptedSid;
  AnonymReceipt? _shownReceipt;
  AnonymKeyRequest? _promptedKey;

  @override
  void initState() {
    super.initState();
    widget.anonym.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onChange());
  }

  @override
  void didUpdateWidget(AnonymRoomHost old) {
    super.didUpdateWidget(old);
    if (old.anonym != widget.anonym) {
      old.anonym.removeListener(_onChange);
      widget.anonym.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    widget.anonym.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    final a = widget.anonym;
    if (a.needsConsent && a.sid != _promptedSid) {
      _promptedSid = a.sid;
      showAnonymConsentSheet(context, anonym: a).ignore();
    }
    final AnonymKeyRequest? kr = a.keyRequest;
    if (kr != null && !identical(kr, _promptedKey)) {
      _promptedKey = kr;
      showAnonymKeyRequestSheet(context, anonym: a).ignore();
    }
    final AnonymReceipt? r = a.receipt;
    if (r != null && !identical(r, _shownReceipt)) {
      _shownReceipt = r;
      showAnonymEndCard(context, anonym: a).ignore();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 带内两颗按钮同高(主题里 FilledButton 字号偏大,会被 44 高裁掉)。
ButtonStyle _bandButton(ButtonStyle base) => base.copyWith(
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
  minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
);

/// 只调字号,不覆盖主题字族。
const TextStyle _bandLabel = TextStyle(fontSize: 14, height: 1.2);
