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
            on
                ? Icons.closed_caption_rounded
                : Icons.closed_caption_off_outlined,
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
        final bool archive = captions.archiveOn;
        if (!captions.transcribing && !archive) return const SizedBox.shrink();
        final t = AppLocalizations.of(context);
        final sep = t.captionsNameSeparator;
        final names = captions.requesterNames.join(sep);
        final theme = Theme.of(context);
        // 转写记录开着:全员常驻提示;能停的只有「我的话」
        final bool canStop = captions.transcribing ||
            (archive && captions.willingNow);
        final declined = archive ? captions.declinedNames : const <String>[];
        final String message = archive
            ? t.captionsArchiveBanner
            : (names.isEmpty ? t.captionsBannerSelf : t.captionsBanner(names));
        final String? detail = archive
            ? [
                if (!captions.willingNow) t.captionsArchiveSelfOff,
                if (declined.isNotEmpty)
                  t.captionsNotTranscribed(declined.join(sep)),
              ].join(' · ')
            : null;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            LaresSpacing.md,
            LaresSpacing.sm,
            LaresSpacing.md,
            0,
          ),
          child: Material(
            color: LaresColors.emberSoft,
            borderRadius: BorderRadius.circular(LaresRadii.sm),
            child: InkWell(
              key: ValueKey(archive ? 'captions-archive-banner' : 'captions-banner'),
              borderRadius: BorderRadius.circular(LaresRadii.sm),
              onTap: !canStop
                  ? null
                  : () {
                      captions.stopForSession();
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        SnackBar(
                          content: Text(archive
                              ? t.captionsArchiveStoppedSnack
                              : t.captionsStoppedSnack),
                        ),
                      );
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LaresSpacing.md,
                  vertical: LaresSpacing.sm,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.closed_caption_rounded,
                      size: 18,
                      color: LaresColors.ember,
                    ),
                    const SizedBox(width: LaresSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(message, style: theme.textTheme.bodyMedium),
                          if (detail != null && detail.isNotEmpty)
                            Text(
                              detail,
                              key: const ValueKey('captions-not-transcribed'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: LaresColors.statusBusy,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (canStop) ...[
                      const SizedBox(width: LaresSpacing.sm),
                      Text(
                        t.captionsBannerStop,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: LaresColors.ember,
                        ),
                      ),
                    ],
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
  const CaptionPanel({super.key, required this.captions, this.band = false});

  final CaptionController captions;

  /// 字幕带形态:嵌进房间底座、紧贴输入框上方的一条半透明带,
  /// 最多露出最近三四行 —— 而不是在语音与聊天之间再塞一只独立的盒子。
  ///
  /// 与聊天的区分靠三件事:左侧一道余烬色竖线 + CC 标记(「这是正在说的话」)、
  /// 更大的字号、没有时间戳也没有气泡(字幕是流过去的,不是留下来的)。
  final bool band;

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
          fontSize: widget.band ? _bandFontSize : 20,
          height: widget.band ? 1.35 : 1.4,
        );
        if (widget.band) {
          return _buildBand(
            context,
            t,
            theme,
            lines,
            providers,
            missing,
            sep,
            baseStyle,
          );
        }
        // partial:同色降透明度 —— 一眼看出「还没说完、可能会改」
        final dim = (baseStyle?.color ?? theme.colorScheme.onSurface)
            .withValues(alpha: 0.55);
        return Container(
          key: const ValueKey('caption-panel'),
          margin: const EdgeInsets.fromLTRB(
            LaresSpacing.md,
            LaresSpacing.sm,
            LaresSpacing.md,
            0,
          ),
          padding: const EdgeInsets.all(LaresSpacing.md),
          constraints: const BoxConstraints(maxHeight: 240),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.85,
            ),
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
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: LaresColors.statusBusy,
                  ),
                ),
              if (providers.isNotEmpty || missing.isNotEmpty)
                const SizedBox(height: LaresSpacing.xs),
              Flexible(
                child: lines.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: LaresSpacing.sm,
                        ),
                        child: Text(
                          t.captionsPanelEmpty,
                          style: theme.textTheme.bodyMedium,
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        shrinkWrap: true,
                        itemCount: lines.length,
                        itemBuilder: (context, i) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: _line(t, lines[i], baseStyle, dim),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 一行字幕:「名字: 文字」。名字余烬色加粗,partial 同色降透明度。
  /// 面板与字幕带共用,保证 key 与 TextSpan 结构只有一份定义。
  Widget _line(AppLocalizations t, CaptionLine l, TextStyle? baseStyle,
          Color dim) =>
      Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: '${_speaker(t, l)}: ',
          style: baseStyle?.copyWith(
            fontWeight: FontWeight.w600,
            color: LaresColors.ember,
          ),
        ),
        TextSpan(
          text: l.text,
          style: l.isFinal ? baseStyle : baseStyle?.copyWith(color: dim),
        ),
      ],
    ),
    key: ValueKey('cap-${l.identity}-${l.itemId}'),
  );

  /// 说话人:自己 →「我」;机器人 → 名字 +「机器人」。
  static String _speaker(AppLocalizations t, CaptionLine l) => l.isSelf
      ? t.captionsYou
      : (l.isBot ? t.captionsBotName(l.name) : l.name);

  Widget _buildBand(
    BuildContext context,
    AppLocalizations t,
    ThemeData theme,
    List<CaptionLine> lines,
    List<String> providers,
    List<String> missing,
    String sep,
    TextStyle? baseStyle,
  ) {
    final dim = (baseStyle?.color ?? theme.colorScheme.onSurface).withValues(
      alpha: 0.55,
    );
    final meta = theme.textTheme.bodySmall;
    return Padding(
      key: const ValueKey('caption-panel'),
      padding: const EdgeInsets.fromLTRB(
        LaresSpacing.sm,
        LaresSpacing.xs,
        LaresSpacing.sm,
        0,
      ),
      // 圆角交给 ClipRRect:Flutter 不允许「只有左边线的 Border」再带 borderRadius
      child: ClipRRect(
        borderRadius: BorderRadius.circular(LaresRadii.sm),
        child: Container(
          constraints: const BoxConstraints(maxHeight: _bandMaxHeight),
          decoration: BoxDecoration(
            // 余烬色极淡一层:与聊天区(无底色)分开,又不像一只新盒子
            color: LaresColors.ember.withValues(alpha: _bandTintAlpha),
            border: const Border(
              left: BorderSide(
                color: LaresColors.ember,
                width: _bandAccentWidth,
              ),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(
            LaresSpacing.md,
            LaresSpacing.sm,
            LaresSpacing.md,
            LaresSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 一行小字:CC 标记 + 谁在提供 / 谁没开。不另起一只盒子。
              Row(
                children: [
                  const Icon(
                    Icons.closed_caption_rounded,
                    size: _bandIconSize,
                    color: LaresColors.ember,
                  ),
                  const SizedBox(width: LaresSpacing.xs),
                  if (providers.isNotEmpty)
                    Flexible(
                      child: Text(
                        t.captionsProviders(providers.join(sep)),
                        style: meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (providers.isNotEmpty && missing.isNotEmpty)
                    Text(' · ', style: meta),
                  if (missing.isNotEmpty)
                    Flexible(
                      child: Text(
                        t.captionsNotProviding(missing.join(sep)),
                        key: const ValueKey('captions-not-providing'),
                        style: meta?.copyWith(color: LaresColors.statusBusy),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (providers.isEmpty && missing.isEmpty)
                    Flexible(
                      child: Text(t.captionsToggle, style: meta, maxLines: 1),
                    ),
                ],
              ),
              const SizedBox(height: LaresSpacing.xs),
              Flexible(
                child: lines.isEmpty
                    ? Text(
                        t.captionsPanelEmpty,
                        style: theme.textTheme.bodyMedium,
                      )
                    : ListView.builder(
                        controller: _scroll,
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: lines.length,
                        itemBuilder: (context, i) => Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: _line(t, lines[i], baseStyle, dim),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 字幕带:字号(比聊天正文 16 大一档,一眼区分「正在说」与「写下的」)。
const double _bandFontSize = 18;

/// 字幕带最高高度:状态行 + 约三行字幕。再多就在带内滚动,不挤语音区。
const double _bandMaxHeight = 128;

/// 字幕带底色的余烬浓度、左侧强调线宽度、CC 小图标尺寸。
const double _bandTintAlpha = 0.08;
const double _bandAccentWidth = 3;
const double _bandIconSize = 14;
