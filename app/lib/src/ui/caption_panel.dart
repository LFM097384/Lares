/// 实时字幕的房内界面:顶栏按钮、「正在为 X 生成字幕」横幅、字幕面板。
library;

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../captions/caption_controller.dart';
import '../theme/tokens.dart';

/// 顶栏的「字幕」开关。服务器没配字幕时整个不出现。
class CaptionToggleButton extends StatelessWidget {
  const CaptionToggleButton({
    super.key,
    required this.captions,
    required this.available,
  });

  final CaptionController captions;
  final bool available;

  @override
  Widget build(BuildContext context) {
    if (!available) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: captions,
      builder: (context, _) {
        final on = captions.wantCaptions;
        return IconButton(
          key: const ValueKey('captions-toggle'),
          tooltip: on ? t.captionsToggleOn : t.captionsToggleOff,
          isSelected: on,
          onPressed: captions.toggleWantCaptions,
          icon: Icon(
            on ? Icons.closed_caption_rounded : Icons.closed_caption_off_outlined,
            color: on ? LaresColors.ember : null,
            semanticLabel: t.captionsToggle,
          ),
        );
      },
    );
  }
}

/// 常驻横幅:本机正把自己的语音送云端识别。点它 = 本次在房期间不再生成。
///
/// 语音出本机必须看得见 —— 与录音指示器同一原则:可以安静,不能藏。
class CaptionProvidingBanner extends StatelessWidget {
  const CaptionProvidingBanner({super.key, required this.captions});

  final CaptionController captions;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: captions,
      builder: (context, _) {
        if (!captions.transcribing) return const SizedBox.shrink();
        final t = AppLocalizations.of(context);
        final names = captions.requesterNames.join(t.captionsNameSeparator);
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.fromLTRB(
              LaresSpacing.lg, LaresSpacing.sm, LaresSpacing.lg, 0),
          child: Material(
            color: LaresColors.emberSoft,
            borderRadius: BorderRadius.circular(LaresRadii.sm),
            child: InkWell(
              key: const ValueKey('captions-banner'),
              borderRadius: BorderRadius.circular(LaresRadii.sm),
              onTap: () {
                captions.stopForSession();
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  SnackBar(content: Text(t.captionsStoppedSnack)),
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: LaresSpacing.md, vertical: LaresSpacing.sm),
                child: Row(
                  children: [
                    const Icon(Icons.closed_caption_rounded,
                        size: 18, color: LaresColors.ember),
                    const SizedBox(width: LaresSpacing.sm),
                    Expanded(
                      child: Text(
                        t.captionsBanner(names),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(width: LaresSpacing.sm),
                    Text(
                      t.captionsBannerStop,
                      style: theme.textTheme.labelLarge
                          ?.copyWith(color: LaresColors.ember),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 字幕面板:最近 ~30 行,「名字:文字」,partial 淡色原地替换;
/// 自动滚到底,除非用户自己往上翻了。
class CaptionPanel extends StatefulWidget {
  const CaptionPanel({super.key, required this.captions});

  final CaptionController captions;

  @override
  State<CaptionPanel> createState() => _CaptionPanelState();
}

class _CaptionPanelState extends State<CaptionPanel> {
  final ScrollController _scroll = ScrollController();

  /// 用户是否停在底部附近(是 → 新字幕来了跟着滚)。
  bool _pinned = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    widget.captions.addListener(_onCaptions);
  }

  @override
  void didUpdateWidget(CaptionPanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.captions, widget.captions)) {
      old.captions.removeListener(_onCaptions);
      widget.captions.addListener(_onCaptions);
    }
  }

  @override
  void dispose() {
    widget.captions.removeListener(_onCaptions);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    _pinned = p.maxScrollExtent - p.pixels < 24;
  }

  void _onCaptions() {
    if (!_pinned) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final c = widget.captions;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (!c.wantCaptions) return const SizedBox.shrink();
        final lines = c.lines;
        final providers = c.providerNames;
        final missing = c.notProvidingNames;
        final sep = t.captionsNameSeparator;
        final baseStyle = theme.textTheme.titleMedium?.copyWith(
          fontSize: 20,
          height: 1.4,
        );
        // partial:同色降透明度 —— 一眼看出「还没说完、可能会改」
        final dim = (baseStyle?.color ?? theme.colorScheme.onSurface)
            .withValues(alpha: 0.55);
        return Container(
          key: const ValueKey('caption-panel'),
          margin: const EdgeInsets.fromLTRB(
              LaresSpacing.md, LaresSpacing.sm, LaresSpacing.md, 0),
          padding: const EdgeInsets.all(LaresSpacing.md),
          constraints: const BoxConstraints(maxHeight: 240),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(LaresRadii.md),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (providers.isNotEmpty)
                Text(
                  t.captionsProviders(providers.join(sep)),
                  style: theme.textTheme.bodySmall,
                ),
              if (missing.isNotEmpty)
                Text(
                  t.captionsNotProviding(missing.join(sep)),
                  key: const ValueKey('captions-not-providing'),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: LaresColors.statusBusy),
                ),
              if (providers.isNotEmpty || missing.isNotEmpty)
                const SizedBox(height: LaresSpacing.xs),
              Flexible(
                child: lines.isEmpty
                    ? Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: LaresSpacing.sm),
                        child: Text(t.captionsPanelEmpty,
                            style: theme.textTheme.bodyMedium),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        shrinkWrap: true,
                        itemCount: lines.length,
                        itemBuilder: (context, i) {
                          final l = lines[i];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text.rich(
                              TextSpan(children: [
                                TextSpan(
                                  text: '${l.name}: ',
                                  style: baseStyle?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: LaresColors.ember,
                                  ),
                                ),
                                TextSpan(
                                  text: l.text,
                                  style: l.isFinal
                                      ? baseStyle
                                      : baseStyle?.copyWith(color: dim),
                                ),
                              ]),
                              key: ValueKey('cap-${l.identity}-${l.itemId}'),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
