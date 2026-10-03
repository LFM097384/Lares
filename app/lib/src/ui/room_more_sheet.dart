/// 房间「更多」:语音 + 文字聊天以外的可选功能都收在这一个入口后面
/// (features-purpose-contract §1)。
///
/// 只列「本圈开着 且 本机用得上」的功能 —— 关掉的功能整格不出现,不画灰格子。
/// 常驻的东西(专注计时卡、正在出本机的字幕横幅、录音指示器、转写提示)
/// 不收进来:能安静,不能藏。
library;

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../captions/caption_controller.dart';
import '../chat/chat_service.dart';
import '../focus/focus_service.dart';
import '../plugins/ai_voice_settings.dart' show showAiVoiceInfoSheet;
import '../plugins/plugin_models.dart';
import '../plugins/plugin_panel.dart';
import '../plugins/plugin_service.dart';
import '../state/circle_features.dart';
import '../state/location_share_stub.dart'
    if (dart.library.io) '../state/location_share.dart';
import '../state/room_controller.dart';
import '../state/voice_notes.dart';
import '../theme/tokens.dart';
import '../transcript/transcript_scope.dart';
import '../transcript/transcript_service.dart';

/// 「更多」面板的输入:房间页每次 build 新建一份(便宜,只是一组引用)。
class RoomMoreModel {
  RoomMoreModel({
    required this.controller,
    required this.circleName,
    this.captions,
    this.voiceNotes,
    this.locationShare,
    this.plugins,
    this.chat,
    this.transcripts,
    this.focus,
    this.showMap = false,
    this.onToggleMap,
  });

  final RoomController controller;
  final String circleName;
  final CaptionController? captions;
  final VoiceNotesController? voiceNotes;
  final LocationShareService? locationShare;
  final PluginService? plugins;
  final ChatService? chat;
  final TranscriptService? transcripts;
  final FocusService? focus;

  /// 地图此刻是否铺着(格子据此显示「回到房间」)。
  final bool showMap;
  final VoidCallback? onToggleMap;

  /// 任何一个变了,格子的有无 / 状态都可能变。
  Listenable get listenable => Listenable.merge(<Listenable?>[
    controller,
    captions,
    voiceNotes,
    plugins,
    focus,
  ]);

  CircleFeatures get _features {
    final cid = controller.circleId;
    return cid == null ? CircleFeatures.legacy : controller.featuresOf(cid);
  }

  /// 番茄钟专注段:地图、便签、小程序这些分心入口收起(与过去一致)。
  bool get _focusing => focus?.focusing ?? false;

  /// 插件列表还没拉过就拉一次(与过去顶栏插件键的做法相同)。
  void ensureLoaded() {
    final p = plugins;
    final cid = controller.circleId;
    if (p == null || cid == null || p.hasListFor(cid)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => p.ensureList(cid));
  }

  List<PluginView> _entryPlugins() {
    final p = plugins;
    final cid = controller.circleId;
    if (p == null || cid == null) return const [];
    return roomEntryPlugins(p, cid, thirdParty: _features.plugins);
  }

  /// 此刻该出现的格子,按固定顺序。
  List<CircleFeature> items() {
    final f = _features;
    final cid = controller.circleId;
    return [
      if (captions != null && controller.captionsAvailable && f.captions)
        CircleFeature.captions,
      if (cid != null &&
          transcripts != null &&
          f.transcript &&
          controller.isTranscriptOn(cid))
        CircleFeature.transcript,
      if (voiceNotes != null && f.voiceNotes && !_focusing)
        CircleFeature.voiceNotes,
      if (locationShare != null && onToggleMap != null && f.map && !_focusing)
        CircleFeature.map,
      if (!_focusing && _entryPlugins().isNotEmpty) CircleFeature.plugins,
    ];
  }

  /// 本圈装着且启用的 AI 语音助手(内置插件,不受「插件」功能开关影响)。
  PluginView? get aiPlugin {
    final p = plugins;
    final cid = controller.circleId;
    if (p == null || cid == null) return null;
    final v = p.plugin(cid, aiVoicePluginId);
    return v != null && v.enabled ? v : null;
  }

  /// 「更多」里至少有一格(功能格或 AI 助手格)。
  bool get hasAnything => aiPlugin != null || items().isNotEmpty;
}

/// 控件排里的「更多」键。有没有它由调用方按 [RoomMoreModel.items] 决定 ——
/// 这样控件排数得清两侧各几颗键,麦克风才钉得住正中。
class RoomMoreButton extends StatelessWidget {
  const RoomMoreButton({super.key, required this.model});

  final RoomMoreModel model;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return IconButton.filledTonal(
      key: const ValueKey('room-more'),
      tooltip: t.roomMore,
      onPressed: () => showRoomMoreSheet(context, model),
      icon: const Icon(Icons.grid_view_rounded),
    );
  }
}

/// 打开「更多」面板。[context] 必须是房间页的(插件 / 转写页从这里 push)。
Future<void> showRoomMoreSheet(BuildContext context, RoomMoreModel model) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => _RoomMoreSheet(model: model, host: context),
  );
}

class _RoomMoreSheet extends StatelessWidget {
  const _RoomMoreSheet({required this.model, required this.host});

  final RoomMoreModel model;

  /// 房间页的 context:关掉面板后用它继续导航。
  final BuildContext host;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: ListenableBuilder(
        listenable: model.listenable,
        builder: (context, _) {
          final items = model.items();
          final ai = model.aiPlugin;
          return Padding(
            padding: const EdgeInsets.fromLTRB(
              LaresSpacing.lg,
              0,
              LaresSpacing.lg,
              LaresSpacing.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.roomMore, style: theme.textTheme.titleMedium),
                const SizedBox(height: LaresSpacing.md),
                LayoutBuilder(
                  builder: (context, box) {
                    // 一排四格;窄到放不下就三格
                    final int cols = box.maxWidth < 300 ? 3 : 4;
                    final double w =
                        (box.maxWidth - LaresSpacing.sm * (cols - 1)) / cols;
                    return Wrap(
                      spacing: LaresSpacing.sm,
                      runSpacing: LaresSpacing.md,
                      children: [
                        for (final f in items)
                          SizedBox(
                            key: ValueKey('more-${f.key}'),
                            width: w,
                            child: _tile(context, f),
                          ),
                        if (ai != null)
                          SizedBox(
                            key: const ValueKey('more-ai'),
                            width: w,
                            child: _MoreTile(
                              innerKey: const ValueKey('room-ai'),
                              icon: Icons.smart_toy_outlined,
                              label: t.roomMoreAi,
                              onTap: () {
                                Navigator.of(context).pop();
                                if (!host.mounted) return;
                                showAiVoiceInfoSheet(host, ai.config);
                              },
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _tile(BuildContext context, CircleFeature f) {
    final t = AppLocalizations.of(context);
    final controller = model.controller;
    final cid = controller.circleId;
    switch (f) {
      case CircleFeature.captions:
        final captions = model.captions!;
        final bool on = captions.wantCaptions;
        return _MoreTile(
          innerKey: const ValueKey('captions-toggle'),
          icon: on
              ? Icons.closed_caption_rounded
              : Icons.closed_caption_off_outlined,
          label: t.featureCaptions,
          status: on ? t.roomMoreOn : t.roomMoreOff,
          active: on,
          tooltip: on ? t.captionsToggleOn : t.captionsToggleOff,
          onTap: captions.toggleWantCaptions,
        );
      case CircleFeature.transcript:
        return _MoreTile(
          innerKey: const ValueKey('room-transcript-history'),
          icon: Icons.subject_rounded,
          label: t.featureTranscript,
          onTap: () {
            Navigator.of(context).pop();
            if (!host.mounted || cid == null) return;
            openTranscriptHistory(
              host,
              service: model.transcripts!,
              circleId: cid,
              circleName: model.circleName,
              isOwner: controller.isOwnerOf(cid),
            );
          },
        );
      case CircleFeature.voiceNotes:
        return _VoiceNoteTile(voiceNotes: model.voiceNotes!);
      case CircleFeature.map:
        return _MoreTile(
          icon: model.showMap ? Icons.groups_rounded : Icons.map_outlined,
          label: model.showMap ? t.roomBackToRoom : t.featureMap,
          active: model.showMap,
          tooltip: model.showMap ? t.roomBackToRoom : t.roomLocationMap,
          onTap: () {
            Navigator.of(context).pop();
            model.onToggleMap?.call();
          },
        );
      case CircleFeature.plugins:
        return _MoreTile(
          innerKey: const ValueKey('room-plugins'),
          icon: Icons.extension_outlined,
          label: t.featurePlugins,
          onTap: () {
            final items = model._entryPlugins();
            Navigator.of(context).pop();
            if (!host.mounted || cid == null) return;
            pickAndOpenRoomPlugin(
              host,
              items: items,
              service: model.plugins!,
              controller: controller,
              circleId: cid,
              circleName: model.circleName,
              chat: model.chat,
              captions: model.captions,
              transcripts: model.transcripts,
            );
          },
        );
      case CircleFeature.recording:
      case CircleFeature.focus:
      case CircleFeature.p2p:
      case CircleFeature.devTools:
        // 不是格子:录音控件尚未开放;专注是常驻模式(计时卡 + 排行键);
        // 直连与开发者读数不在房间里操作。
        return const SizedBox.shrink();
    }
  }
}

/// 一格:圆形 tonal 图标 + 名字 +(可选)一行状态小字。开着时余烬色。
class _MoreTile extends StatelessWidget {
  const _MoreTile({
    required this.icon,
    required this.label,
    this.status,
    this.active = false,
    this.tooltip,
    this.onTap,
    this.innerKey,
    this.badge,
  });

  final IconData icon;
  final String label;
  final String? status;
  final bool active;
  final String? tooltip;
  final VoidCallback? onTap;
  final Key? innerKey;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final Widget circle = Container(
      width: _tileIconBox,
      height: _tileIconBox,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? LaresColors.emberSoft : scheme.secondaryContainer,
      ),
      child: Icon(
        icon,
        color: active ? LaresColors.ember : scheme.onSecondaryContainer,
      ),
    );
    final Widget body = InkWell(
      key: innerKey,
      borderRadius: BorderRadius.circular(LaresRadii.sm),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: LaresSpacing.xs),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Badge(
              isLabelVisible: (badge ?? 0) > 0,
              label: Text('${badge ?? 0}'),
              child: circle,
            ),
            const SizedBox(height: LaresSpacing.xs + 2),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium,
            ),
            if (status != null)
              Text(
                status!,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: active ? LaresColors.ember : scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
    return Semantics(
      button: true,
      toggled: status == null ? null : active,
      child: tooltip == null ? body : Tooltip(message: tooltip, child: body),
    );
  }
}

/// 语音便签格:点 = 听待听的(角标是条数),长按 = 录一条(≤15s),松手发送。
class _VoiceNoteTile extends StatelessWidget {
  const _VoiceNoteTile({required this.voiceNotes});

  final VoiceNotesController voiceNotes;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final vn = voiceNotes;
    final count = vn.pendingCount;
    return GestureDetector(
      onLongPressStart: (_) => vn.startRecording(),
      onLongPressEnd: (_) => vn.stopAndSend(),
      child: _MoreTile(
        icon: vn.recording
            ? Icons.mic_rounded
            : vn.playing
            ? Icons.volume_up_rounded
            : Icons.voicemail_rounded,
        label: t.featureVoiceNotes,
        status: vn.recording
            ? t.roomMoreVoiceNotesRecording
            : count > 0
            ? t.roomMoreVoiceNotesPending(count)
            : t.roomMoreVoiceNotesHint,
        active: vn.recording,
        badge: count,
        tooltip: count > 0 ? t.noteListen(count) : t.noteRecordHint,
        onTap: count > 0 ? vn.playAll : null,
      ),
    );
  }
}

/// 房间里常驻的一行小字:本圈开着转写记录。点一下看记录。
///
/// 本机正在出字幕 / 转写时 [CaptionProvidingBanner] 已经在喊这件事,
/// 那时这行就不重复。
class RoomTranscriptNotice extends StatelessWidget {
  const RoomTranscriptNotice({
    super.key,
    required this.controller,
    required this.circleName,
    this.captions,
    this.transcripts,
  });

  final RoomController controller;
  final String circleName;
  final CaptionController? captions;
  final TranscriptService? transcripts;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable?>[controller, captions]),
      builder: (context, _) {
        final cid = controller.circleId;
        if (cid == null ||
            !controller.isTranscriptOn(cid) ||
            !controller.isFeatureOn(cid, CircleFeature.transcript) ||
            (captions?.archiveOn ?? false)) {
          return const SizedBox.shrink();
        }
        final t = AppLocalizations.of(context);
        final theme = Theme.of(context);
        final muted = theme.colorScheme.onSurfaceVariant;
        final service = transcripts;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            LaresSpacing.md,
            LaresSpacing.xs,
            LaresSpacing.md,
            0,
          ),
          child: Tooltip(
            message: service == null ? '' : t.roomTranscriptNoticeOpen,
            child: InkWell(
              key: const ValueKey('room-transcript-notice'),
              borderRadius: BorderRadius.circular(LaresRadii.sm),
              onTap: service == null
                  ? null
                  : () => openTranscriptHistory(
                      context,
                      service: service,
                      circleId: cid,
                      circleName: circleName,
                      isOwner: controller.isOwnerOf(cid),
                    ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LaresSpacing.sm,
                  vertical: LaresSpacing.xs,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.subject_rounded, size: 16, color: muted),
                    const SizedBox(width: LaresSpacing.xs + 2),
                    Flexible(
                      child: Text(
                        t.roomTranscriptNotice,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
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

/// 格子里圆形图标底的直径。
const double _tileIconBox = 52;
