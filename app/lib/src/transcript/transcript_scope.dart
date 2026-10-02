/// 把 [TranscriptService] 挂在树上:房间页 / 圈子菜单按需取,
/// 不必沿 LaresApp → HomeScreen → RoomScreen 一路加构造参数。
/// 没挂(测试 / 老入口)时 [maybeOf] 返回 null,入口整块不显示。
library;

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import 'transcript_history_screen.dart';
import 'transcript_owner_section.dart';
import 'transcript_service.dart';

class TranscriptScope extends InheritedWidget {
  const TranscriptScope({
    super.key,
    required this.service,
    required super.child,
  });

  final TranscriptService service;

  static TranscriptService? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<TranscriptScope>()
      ?.service;

  @override
  bool updateShouldNotify(TranscriptScope old) => old.service != service;
}

/// 打开某圈的「转写记录」页。[isOwner] → 带「清空记录」。
Future<void> openTranscriptHistory(
  BuildContext context, {
  required TranscriptService service,
  required String circleId,
  required String circleName,
  required bool isOwner,
}) {
  final history = service.historyFor(circleId);
  final encrypted = service.isE2EE(circleId);
  return Navigator.of(context)
      .push(MaterialPageRoute<void>(
        builder: (_) => TranscriptHistoryScreen(
          history: history,
          circleName: circleName,
          encrypted: encrypted,
          onClear: isOwner ? () => service.clearAsOwner(circleId) : null,
        ),
      ))
      .whenComplete(() => (history as ChangeNotifier).dispose());
}

/// 圈子菜单里的「转写记录」入口(所有成员)。
class TranscriptHistoryTile extends StatelessWidget {
  const TranscriptHistoryTile({
    super.key,
    required this.service,
    required this.circleId,
    required this.circleName,
    required this.isOwner,
    this.onBeforeOpen,
  });

  final TranscriptService service;
  final String circleId;
  final String circleName;
  final bool isOwner;

  /// 先关掉底部菜单等。
  final VoidCallback? onBeforeOpen;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final nav = Navigator.of(context);
    return ListTile(
      key: const ValueKey('transcript-history-tile'),
      leading: const Icon(Icons.subject_rounded),
      title: Text(t.transcriptTitle),
      subtitle: Text(service.isE2EE(circleId)
          ? t.transcriptEntryDescE2ee
          : t.transcriptEntryDesc),
      onTap: () {
        onBeforeOpen?.call();
        openTranscriptHistory(nav.context,
            service: service,
            circleId: circleId,
            circleName: circleName,
            isOwner: isOwner);
      },
    );
  }
}

/// 圈主菜单项:转写记录开关 + 机器人入口。
class TranscriptOwnerTiles extends StatelessWidget {
  const TranscriptOwnerTiles({
    super.key,
    required this.service,
    required this.circleId,
    required this.on,
    this.onBeforeOpen,
  });

  final TranscriptService service;
  final String circleId;
  final bool on;
  final VoidCallback? onBeforeOpen;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final nav = Navigator.of(context);
    final e2ee = service.isE2EE(circleId);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TranscriptOwnerSwitch(
          on: on,
          e2ee: e2ee,
          onSet: (v) => service.setTranscriptOn(circleId, v),
        ),
        ListTile(
          key: const ValueKey('bot-tokens-tile'),
          leading: const Icon(Icons.smart_toy_outlined),
          title: Text(t.botTokensTitle),
          subtitle: Text(t.botTokensEntryDesc),
          onTap: () {
            onBeforeOpen?.call();
            nav.push(MaterialPageRoute<void>(
              builder: (_) => BotTokensScreen(
                api: ServiceBotTokenApi(service, circleId),
                e2ee: e2ee,
              ),
            ));
          },
        ),
      ],
    );
  }
}
