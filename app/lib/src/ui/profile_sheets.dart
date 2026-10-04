import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../focus/focus_models.dart' show LeaderboardRow;
import '../focus/focus_service.dart';
import '../focus/focus_widgets.dart' show formatFocusMs;
import '../moderation/block_store.dart';
import '../platform/platform_info.dart'
    if (dart.library.io) '../platform/platform_info_io.dart';
import '../state/identity.dart' show capBio, capNickname, maxBioGraphemes;
import '../state/models.dart';
import '../state/room_controller.dart';
import '../state/settings_store.dart';
import '../text/grapheme_text.dart' show graphemeCount;
import '../theme/tokens.dart';
import 'moderation_menus.dart';
import 'nickname.dart';
import 'push_settings_widgets.dart';
import 'widgets/avatar_orb.dart';

/// 头像 emoji 预设。只给一排,不做完整的 emoji 键盘:
/// 资料是「顺手点一下」的东西,不该变成一个要逛的地方。
const List<String> kProfileEmojiPresets = <String>[
  '🙂', '😎', '🐱', '🐶', '🦊', '🐼', '🌱', '🌙', '☕', '📚', '🎧', '🔥',
];

/// 资料面板顶上的大头像:与座位上的头像球同一个字(emoji 优先,否则首字)。
class _BigAvatar extends StatelessWidget {
  const _BigAvatar({required this.member, this.speaking = false});

  final Member member;
  final bool speaking;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: 72,
      height: 72,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border.all(
          color: speaking ? LaresColors.ember : member.status.color,
          width: 2,
        ),
      ),
      child: Text(
        AvatarOrb.orbGlyph(member),
        style: theme.textTheme.headlineMedium?.copyWith(fontSize: 30),
      ),
    );
  }
}

/// 头像 emoji 的一个格子:等宽的圆,选中时描一圈余烬色。
/// 不用 ChoiceChip —— 它的勾和文字宽度让一排格子长短不齐。
class _EmojiSwatch extends StatelessWidget {
  const _EmojiSwatch({
    super.key,
    required this.selected,
    required this.semanticsLabel,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final String semanticsLabel;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: semanticsLabel,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? LaresColors.emberSoft : cs.surfaceContainerHighest,
            border: Border.all(
              color: selected ? LaresColors.ember : Colors.transparent,
              width: 2,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

String _statusText(AppLocalizations t, MemberStatus s) => switch (s) {
      MemberStatus.free => t.roomStatusFree,
      MemberStatus.busy => t.roomStatusBusy,
      MemberStatus.ears => t.roomStatusEars,
      MemberStatus.away => t.profileStatusAway,
    };

/// 状态三选一(随时聊 / 在忙 / 耳朵在)。「有事先走」是系统态,不给手选。
class ProfileStatusSelector extends StatelessWidget {
  const ProfileStatusSelector({super.key, required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, _) {
        final MemberStatus cur = controller.myStatus == MemberStatus.away
            ? MemberStatus.free
            : controller.myStatus;
        return SegmentedButton<MemberStatus>(
          showSelectedIcon: false,
          segments: <ButtonSegment<MemberStatus>>[
            for (final MemberStatus s in const <MemberStatus>[
              MemberStatus.free,
              MemberStatus.busy,
              MemberStatus.ears,
            ])
              ButtonSegment<MemberStatus>(
                value: s,
                label: Text(_statusText(t, s)),
              ),
          ],
          selected: <MemberStatus>{cur},
          onSelectionChanged: (Set<MemberStatus> v) =>
              controller.setStatus(v.first),
        );
      },
    );
  }
}

/// 点自己的头像:改名字、头像 emoji、一句话签名、状态。
Future<void> showOwnProfileSheet(
  BuildContext context, {
  required RoomController controller,
  SettingsStore? settings,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext ctx) => Padding(
      // 键盘弹起时把面板整体顶上去,别让输入框被盖住
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: _OwnProfileBody(controller: controller, settings: settings),
        ),
      ),
    ),
  );
}

class _OwnProfileBody extends StatefulWidget {
  const _OwnProfileBody({required this.controller, this.settings});

  final RoomController controller;
  final SettingsStore? settings;

  @override
  State<_OwnProfileBody> createState() => _OwnProfileBodyState();
}

class _OwnProfileBodyState extends State<_OwnProfileBody> {
  late final TextEditingController _name =
      TextEditingController(text: widget.controller.userName);
  late final TextEditingController _bio =
      TextEditingController(text: widget.controller.myBio ?? '');
  late String _emoji = widget.controller.myEmoji ?? '';

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final NavigatorState nav = Navigator.of(context);
    final ScaffoldMessengerState? messenger =
        ScaffoldMessenger.maybeOf(context);
    final String savedText = AppLocalizations.of(context).profileSaved;
    await saveMyProfile(
      widget.controller,
      name: _name.text,
      emoji: _emoji,
      bio: _bio.text,
    );
    if (!mounted) return;
    nav.pop();
    messenger?.showSnackBar(SnackBar(content: Text(savedText)));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final RoomController c = widget.controller;
    final SettingsStore? settings = widget.settings;
    final String? cid = c.circleId;
    final Member preview = Member(
      userId: c.userId,
      name: capNickname(_name.text).isEmpty ? c.userName : _name.text,
      status: c.myStatus,
      emoji: _emoji.isEmpty ? null : _emoji,
    );
    return Padding(
      key: const ValueKey('profile-own-sheet'),
      padding: const EdgeInsets.fromLTRB(
        LaresSpacing.lg,
        0,
        LaresSpacing.lg,
        LaresSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Center(child: _BigAvatar(member: preview)),
          const SizedBox(height: LaresSpacing.sm),
          Center(
            child: Text(t.profileOwnTitle, style: theme.textTheme.titleMedium),
          ),
          const SizedBox(height: LaresSpacing.md),
          TextField(
            key: const ValueKey('profile-name-field'),
            controller: _name,
            decoration: InputDecoration(labelText: t.profileNameLabel),
            textInputAction: TextInputAction.next,
            onChanged: (String v) {
              // 输入时就截断,和 saveMyNickname 同一个口径
              final String capped = capNickname(v);
              if (capped != v.trim() && capped.isNotEmpty) {
                _name.value = TextEditingValue(
                  text: capped,
                  selection: TextSelection.collapsed(offset: capped.length),
                );
              }
              setState(() {});
            },
          ),
          const SizedBox(height: LaresSpacing.md),
          Text(t.profileEmojiLabel, style: theme.textTheme.labelLarge),
          const SizedBox(height: LaresSpacing.xs),
          Wrap(
            spacing: LaresSpacing.sm,
            runSpacing: LaresSpacing.sm,
            children: <Widget>[
              _EmojiSwatch(
                key: const ValueKey('profile-emoji-none'),
                selected: _emoji.isEmpty,
                semanticsLabel: t.profileEmojiNone,
                onTap: () => setState(() => _emoji = ''),
                child: Icon(
                  Icons.block_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              for (final String e in kProfileEmojiPresets)
                _EmojiSwatch(
                  key: ValueKey('profile-emoji-$e'),
                  selected: _emoji == e,
                  semanticsLabel: e,
                  onTap: () => setState(() => _emoji = e),
                  child: Text(e, style: const TextStyle(fontSize: 20)),
                ),
            ],
          ),
          const SizedBox(height: LaresSpacing.md),
          TextField(
            key: const ValueKey('profile-bio-field'),
            controller: _bio,
            maxLines: 1,
            decoration: InputDecoration(
              labelText: t.profileBioLabel,
              hintText: t.profileBioHint,
              counterText: t.profileBioCounter(
                graphemeCount(_bio.text),
                maxBioGraphemes,
              ),
            ),
            onChanged: (String v) {
              if (graphemeCount(v) > maxBioGraphemes) {
                final String capped = capBio(v);
                _bio.value = TextEditingValue(
                  text: capped,
                  selection: TextSelection.collapsed(offset: capped.length),
                );
              }
              setState(() {});
            },
          ),
          const SizedBox(height: LaresSpacing.md),
          Text(t.roomStatusPick, style: theme.textTheme.labelLarge),
          const SizedBox(height: LaresSpacing.xs),
          ProfileStatusSelector(controller: c),
          if (settings != null &&
              cid != null &&
              PlatformInfo.current == 'ios' &&
              settings.pushEnabled)
            CirclePushLevelTile(settings: settings, circleId: cid),
          _ProfileErrorLine(controller: c),
          const SizedBox(height: LaresSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t.commonCancel),
              ),
              const SizedBox(width: LaresSpacing.sm),
              FilledButton(
                key: const ValueKey('profile-save'),
                onPressed: _save,
                child: Text(t.commonSave),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 服务器拒了资料时,在面板里安静地说一句(不弹窗)。
class _ProfileErrorLine extends StatelessWidget {
  const _ProfileErrorLine({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return ValueListenableBuilder<({String reason, int? retryMs})?>(
      valueListenable: controller.profileError,
      builder: (BuildContext context, ({String reason, int? retryMs})? e, _) {
        if (e == null) return const SizedBox.shrink();
        final String text = switch (e.reason) {
          'rate_limited' => t.profileErrorRateLimited(
              ((e.retryMs ?? 60000) / 1000).ceil(),
            ),
          'not_allowed' => t.profileErrorNotAllowed,
          'say_hello_first' => t.profileErrorNotConnected,
          _ => t.profileErrorInvalid,
        };
        return Padding(
          padding: const EdgeInsets.only(top: LaresSpacing.sm),
          child: Text(
            text,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        );
      },
    );
  }
}

/// 进房时刻的说法:刚进来 / n 分钟前进来 / HH:mm 进来的。
String profileJoinedText(AppLocalizations t, int joinedAtMs, {DateTime? now}) {
  final DateTime at = DateTime.fromMillisecondsSinceEpoch(joinedAtMs);
  final Duration ago = (now ?? DateTime.now()).difference(at);
  if (ago.inMinutes < 1) return t.profileJoinedJustNow;
  if (ago.inMinutes < 60) return t.profileJoinedMinutes(ago.inMinutes);
  String two(int v) => v.toString().padLeft(2, '0');
  return t.profileJoinedAt('${two(at.hour)}:${two(at.minute)}');
}

/// 点别人的头像:看资料,并在这里做 @Ta / 听不到 Ta / 屏蔽举报 / 移出圈子。
///
/// [onKick] 为 null 就不出「移出圈子」那一行(调用方按 canModerate 判)。
/// [onMention] 为 null(房间没开聊天)就不出 @Ta。
/// [blocks] 为 null 就不出屏蔽 / 举报。
Future<void> showMemberProfileSheet(
  BuildContext context, {
  required RoomController controller,
  required Member member,
  BlockStore? blocks,
  FocusService? focus,
  VoidCallback? onKick,
  VoidCallback? onMention,
  ReportDelivery? delivery,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext ctx) => SafeArea(
      child: SingleChildScrollView(
        child: ListenableBuilder(
          listenable: controller,
          builder: (BuildContext ctx, _) {
            // 面板开着时对方改了资料 / 开口说话,跟着变
            final Member m = controller.members.firstWhere(
              (Member x) => x.userId == member.userId,
              orElse: () => member,
            );
            return _OtherProfileBody(
              hostContext: context,
              sheetContext: ctx,
              controller: controller,
              member: m,
              blocks: blocks,
              focus: focus,
              onKick: onKick,
              onMention: onMention,
              delivery: delivery,
            );
          },
        ),
      ),
    ),
  );
}

class _OtherProfileBody extends StatelessWidget {
  const _OtherProfileBody({
    required this.hostContext,
    required this.sheetContext,
    required this.controller,
    required this.member,
    this.blocks,
    this.focus,
    this.onKick,
    this.onMention,
    this.delivery,
  });

  final BuildContext hostContext;
  final BuildContext sheetContext;
  final RoomController controller;
  final Member member;
  final BlockStore? blocks;
  final FocusService? focus;
  final VoidCallback? onKick;
  final VoidCallback? onMention;
  final ReportDelivery? delivery;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final Member m = member;
    final bool speaking = controller.speakingIds.contains(m.userId);
    final bool localMuted = controller.isLocallyMuted(m.userId);
    final String? bio = m.bio;
    final int? joinedAt = m.joinedAt;
    final FocusService? f = focus;
    final BlockStore? b = blocks;
    final VoidCallback? mention = onMention;
    final VoidCallback? kick = onKick;
    final Color muted = theme.colorScheme.onSurfaceVariant;

    final List<String> focusBits = <String>[];
    if (f != null && f.active) {
      int msIn(List<LeaderboardRow> rows) {
        for (final LeaderboardRow r in rows) {
          if (r.userId == m.userId) return r.ms;
        }
        return 0;
      }

      focusBits.add(t.profileFocusToday(
        formatFocusMs(t, msIn(f.leaderboard.today)),
      ));
      focusBits.add(t.profileFocusWeek(
        formatFocusMs(t, msIn(f.leaderboard.week)),
      ));
      final int streak = f.social.streakOf(m.userId);
      if (streak > 0) focusBits.add(t.profileStreak(streak));
    }

    return Column(
      key: const ValueKey('profile-other-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LaresSpacing.lg,
            0,
            LaresSpacing.lg,
            LaresSpacing.sm,
          ),
          child: Column(
            children: <Widget>[
              _BigAvatar(member: m, speaking: speaking),
              const SizedBox(height: LaresSpacing.sm),
              Text(m.name, style: theme.textTheme.titleMedium),
              // 稳定 id:屏蔽 / 举报认的是它,不是随时能改的昵称
              Text(
                'ID · ${m.userId.length > 6 ? m.userId.substring(m.userId.length - 6) : m.userId}',
                style: theme.textTheme.labelSmall?.copyWith(color: muted),
              ),
              if (bio != null) ...<Widget>[
                const SizedBox(height: LaresSpacing.xs),
                Text(bio, textAlign: TextAlign.center),
              ],
              const SizedBox(height: LaresSpacing.xs),
              Text(
                speaking
                    ? '${_statusText(t, m.status)} · ${t.profileSpeaking}'
                    : _statusText(t, m.status),
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
              if (focusBits.isNotEmpty) ...<Widget>[
                const SizedBox(height: LaresSpacing.xs),
                // 每段整块换行:窄屏上不会把「连续 12 天」拆成两行
                Wrap(
                  alignment: WrapAlignment.center,
                  children: <Widget>[
                    for (int i = 0; i < focusBits.length; i++)
                      Text(
                        i == focusBits.length - 1
                            ? focusBits[i]
                            : '${focusBits[i]} · ',
                        style:
                            theme.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                  ],
                ),
              ],
              if (joinedAt != null) ...<Widget>[
                const SizedBox(height: LaresSpacing.xs),
                Text(
                  profileJoinedText(t, joinedAt),
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            ],
          ),
        ),
        if (mention != null)
          ListTile(
            key: const ValueKey('profile-mention'),
            leading: const Icon(Icons.alternate_email_rounded),
            title: Text(t.profileMention),
            onTap: () {
              Navigator.pop(sheetContext);
              mention();
            },
          ),
        ListTile(
          key: const ValueKey('profile-mute-for-me'),
          leading: Icon(
            localMuted ? Icons.hearing_rounded : Icons.hearing_disabled_rounded,
          ),
          title: Text(localMuted ? t.profileUnmuteForMe : t.profileMuteForMe),
          subtitle: Text(t.profileMuteForMeHint),
          onTap: () => controller.toggleLocalMute(m.userId),
        ),
        if (b != null)
          ...memberSafetyTiles(
            hostContext,
            sheetContext,
            controller: controller,
            blocks: b,
            member: m,
            delivery: delivery,
          ),
        if (kick != null)
          ListTile(
            key: const ValueKey('profile-kick'),
            leading: Icon(Icons.logout_rounded, color: theme.colorScheme.error),
            title: Text(
              t.profileKick,
              style: TextStyle(color: theme.colorScheme.error),
            ),
            onTap: () {
              Navigator.pop(sheetContext);
              kick();
            },
          ),
      ],
    );
  }
}

/// 「移出圈子」的确认框。返回 true 才真的发 kick。
Future<void> confirmProfileKick(
  BuildContext context, {
  required RoomController controller,
  required Member member,
}) async {
  final AppLocalizations t = AppLocalizations.of(context);
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: Text(t.roomKickTitle(member.name)),
      content: Text(t.roomKickBody),
      actions: <Widget>[
        TextButton(
          key: const ValueKey('profile-kick-cancel'),
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(t.commonCancel),
        ),
        FilledButton(
          key: const ValueKey('profile-kick-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(t.roomKickConfirm),
        ),
      ],
    ),
  );
  if (ok == true) controller.kick(member.userId);
}

/// 房间往座位递两样东西:「@Ta」怎么接到聊天框、设置(推送档位那一行要用)。
/// 用 InheritedWidget 而不是一路传参,免得改网格 / 语音条的构造函数。
class ProfileRoomScope extends InheritedWidget {
  const ProfileRoomScope({
    super.key,
    this.onMention,
    this.settings,
    required super.child,
  });

  /// null = 房间没开聊天,资料面板不出 @Ta。
  final void Function(Member member)? onMention;
  final SettingsStore? settings;

  static ProfileRoomScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ProfileRoomScope>();

  @override
  bool updateShouldNotify(ProfileRoomScope old) =>
      old.onMention != onMention || old.settings != settings;
}