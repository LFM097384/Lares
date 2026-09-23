import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../chat/chat_service.dart';
import '../config.dart';
import '../e2ee/e2ee_controller.dart';
import '../e2ee/e2ee_status.dart';
import '../moderation/block_store.dart';
import '../recording/recording_consent.dart';
import '../recording/recording_indicator.dart';
import '../state/location_share_stub.dart'
    if (dart.library.io) '../state/location_share.dart';
import '../state/mic_notice.dart';
import '../state/models.dart';
import '../state/room_controller.dart';
import '../state/settings_store.dart';
import '../state/voice_notes.dart';
import '../theme/tokens.dart';
import 'chat_panel.dart';
import 'map_panel.dart';
import 'moderation_menus.dart';
import 'widgets/avatar_orb.dart';
import 'widgets/e2ee_badge.dart';

// ── 就地常量 ──
// tokens.dart 没有「图标尺寸」这一档,被屏蔽标记的两个尺寸就地定义。

/// 被屏蔽成员的头像压到多暗。压到四成是「一眼看出不一样」又「还认得出是谁」
/// 的平衡点 —— 全糊掉反而让人不知道自己屏蔽了谁。
const double _blockedAvatarOpacity = 0.4;

/// 被屏蔽角标的图标尺寸,与 AvatarOrb 里的静音标记同量级。
const double _blockedBadgeIconSize = 16;

/// 房间内界面(设计.md §3.2-2):极简 —— 头像网格 + 波纹 + 底部两个主按钮。
/// 文字/图片是安静的副通道(§2.3 已由 owner 显式放开):默认折叠,
/// 不抢成员网格与主麦克风按钮的位置,语音仍是一等公民。
/// 地图视图:位置共享(Snapchat 式)。
class RoomScreen extends StatefulWidget {
  const RoomScreen({
    super.key,
    required this.controller,
    required this.circleName,
    this.voiceNotes,
    this.settings,
    this.locationShare,
    this.chat,
    this.recordingConsent,
    this.blocks,
    this.e2ee,
  });

  final RoomController controller;
  final String circleName;
  final VoiceNotesController? voiceNotes;
  final SettingsStore? settings;
  final LocationShareService? locationShare;

  /// 文字/图片副通道。为 null 时整块不渲染(与 _KnockBanner 同样的降级方式)
  final ChatService? chat;

  /// 录音同意控制器。为 null 时不渲染指示器(同上的降级方式)
  final RecordingConsentController? recordingConsent;

  /// 屏蔽名单(App Store 审核指南 1.2)。为 null 时长按头像退回「直接踢人」的
  /// 老行为,既不崩也不少任何既有功能 —— 可选协作者一律优雅降级(同上)。
  final BlockStore? blocks;

  /// 按圈端到端加密。为 null 时不显示任何加密字样 ——
  /// 宁可什么都不说,也不能显示一个可能说错的状态。
  final E2EEController? e2ee;

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  bool _showMap = false;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      body: Stack(
        children: [
          // 地图铺满时这层完全被盖住 —— 停掉,别白烧 60fps。
          _BreathingBackground(
            visible: !(_showMap && widget.locationShare != null),
          ),
          SafeArea(
            child: Column(
              children: [
                _RoomHeader(
                  controller: controller,
                  circleName: widget.circleName,
                  showMap: _showMap,
                  onToggleMap: widget.locationShare == null
                      ? null
                      : () => setState(() => _showMap = !_showMap),
                  e2ee: widget.e2ee,
                ),
                // 「你以为加密了但其实没有」值得一整条横幅,不是一个小角标。
                if (widget.e2ee != null)
                  _E2EERoomBanner(
                    controller: controller,
                    e2ee: widget.e2ee!,
                  ),
                // 「这个圈子要口令」—— 当场补填,不必跑去设置页。
                // 放在敲门横幅之前:它是一条**挡路**的错误,
                // 而敲门是别人的请求,此刻还轮不到。
                _PasscodeRetryBanner(
                  controller: controller,
                  settings: widget.settings,
                ),
                _KnockBanner(controller: controller, settings: widget.settings),
                // 录音指示器:房间里有人在录音时对**所有人**常驻显示。
                // 这是本 App 唯一刻意「吵」的组件 —— 安静的设计 ≠ 藏起来。
                // 没人录音时它自己退化成 SizedBox.shrink(),不占位。
                //
                // 注:录音功能当前整体未开放(LaresConfig.recordingEnabled),
                // 故指示器一并隐藏。二者必须同开同关 —— 只要功能可用,
                // 指示器就必须在,否则就成了「偷录」。
                if (LaresConfig.recordingEnabled &&
                    widget.recordingConsent != null)
                  RecordingIndicatorBanner(
                    controller: widget.recordingConsent!,
                  ),
                Expanded(
                  child: _showMap && widget.locationShare != null
                      ? MapPanel(
                          controller: controller,
                          locationShare: widget.locationShare!,
                        )
                      : _MemberGrid(
                          controller: controller,
                          blocks: widget.blocks,
                        ),
                ),
                // 副通道置于主按钮之上:默认折叠成一条细条,不挤压上方网格
                if (widget.chat != null)
                  ChatPanel(chat: widget.chat!, blocks: widget.blocks)
                else
                  const SizedBox.shrink(),
                _ControlBar(
                    controller: controller, voiceNotes: widget.voiceNotes),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 房间「呼吸感」氛围背景:极慢明灭的暖色光晕,让「有人在」可感知。
///
/// ## 省电:App 退到后台就**停表**,不是降频
///
/// 这是常驻挂机类应用的准入条件,不是优化项 —— 核心场景是一天挂十几小时。
///
/// 原型实测(见 `app/tool/hearth/REPORT.md`)给出过一条反直觉的数据:
/// **节流重绘救不了耗电**。把重绘从 60fps 降到 12fps 之后,
/// 提交帧率仍是 60fps、CPU 仍占 27% —— 因为只要 Ticker 还在跑,
/// 引擎每个 vsync 都要走完整的帧调度,节流只省掉 paint 里画渐变那一点。
///
/// 只有彻底 `stop()` 才是真的零:**27.2% → 0.31%,降到 1/88**。
class _BreathingBackground extends StatefulWidget {
  const _BreathingBackground({this.visible = true});

  /// 这层背景此刻是否真的看得见。
  ///
  /// 地图页打开时,背景仍在 `Stack` 底层、只是被盖住 —— 那种情况下
  /// 继续烧 60fps 是纯浪费,用户一帧都看不到。
  final bool visible;

  @override
  State<_BreathingBackground> createState() => _BreathingBackgroundState();
}

class _BreathingBackgroundState extends State<_BreathingBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath;
  AppLifecycleListener? _lifecycle;

  /// App 是否在前台。与 [_BreathingBackground.visible] 是**两个独立条件**,
  /// 必须都成立才转表。
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 7),
    );
    // 用 onStateChange 而不是 onHide/onShow:后者在部分平台上不触发,
    // 而 paused/inactive 是所有平台都会报的。
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    _sync();
  }

  @override
  void didUpdateWidget(_BreathingBackground old) {
    super.didUpdateWidget(old);
    if (old.visible != widget.visible) _sync();
  }

  void _onLifecycle(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  /// 把「该不该转」这件事收在一个地方算,避免两个条件各改各的而打架。
  void _sync() {
    final shouldRun = _foreground && widget.visible;
    if (shouldRun) {
      // 只在真的停了的时候才重启 —— 重复调 repeat() 会把动画拽回起点,
      // 表现为光晕突然一跳。
      if (!_breath.isAnimating) _breath.repeat(reverse: true);
    } else {
      // stop() 保留当前值,下次恢复从原处继续,视觉上不跳。
      _breath.stop();
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).scaffoldBackgroundColor;
    return AnimatedBuilder(
      animation: _breath,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_breath.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0, -0.7),
              radius: 1.2,
              colors: [
                LaresColors.ember.withValues(alpha: 0.05 + 0.05 * t),
                base,
              ],
            ),
          ),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

/// 进房被拒于「差一个口令」时,当场补填的横幅。
///
/// ## 为什么值得一个常驻输入框,而不是一句「去设置里填」
///
/// 邀请链接**刻意不带口令** —— 口令经 Argon2id 派生出 E2EE 密钥,写进链接
/// 等于把密钥一起发出去,而链接会经微信/短信/剪贴板流转。代价是:通过链接
/// 加进来的圈子,本地必然没有口令,第一次进房必然被 4401 拒。
///
/// 那是新用户遇到的**第一个**障碍。让他去翻设置页、找到服务器档案、
/// 看懂「按圈口令」是什么意思,才能填一个朋友刚发给他的四位数 —— 太远了。
///
/// ## 只在「确实是口令问题」时出现
///
/// 判据是 [RoomController.needsPasscode],它读的是结构化的错误种类,
/// 不是去匹配错误文案的文字。网络不好、服务器没配 LiveKit 的时候弹口令框
/// 是误导 —— 用户会反复输入一个本来就没错的口令。
class _PasscodeRetryBanner extends StatefulWidget {
  const _PasscodeRetryBanner({required this.controller, this.settings});

  final RoomController controller;
  final SettingsStore? settings;

  @override
  State<_PasscodeRetryBanner> createState() => _PasscodeRetryBannerState();
}

class _PasscodeRetryBannerState extends State<_PasscodeRetryBanner> {
  final _field = TextEditingController();

  /// 正在保存/重连中:按钮置灰,防止连点。
  /// 连点的代价是实打实的:服务端 5 分钟 10 次失败就封 IP(4429)。
  bool _busy = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final settings = widget.settings;
    final circleId = widget.controller.circleId;
    final pass = _field.text;
    if (settings == null || circleId == null || pass.isEmpty || _busy) return;

    setState(() => _busy = true);
    // 存口令。返回 false 表示「存下了,但这台服务器当前用的是共享令牌,
    // 不会立刻生效」—— 那种情况必须如实说,不能假装重试会成功。
    final effective = await settings.setCirclePasscode(circleId, pass);
    if (!mounted) return;

    if (!effective) {
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).roomPasscodeSavedElsewhere),
        ),
      );
      return;
    }

    // 输入框在重试之前就清空:口令已经存进 SecretVault 了,
    // 没有任何理由让它继续留在一个 widget 的内存里。
    _field.clear();
    await widget.controller.retryJoin(circleId);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        // settings 为 null 时不渲染:没有它就无处存口令,
        // 给一个按了没反应的按钮比不给更糟(可选协作者一律优雅降级)。
        if (!widget.controller.needsPasscode || widget.settings == null) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            LaresSpacing.lg,
            LaresSpacing.sm,
            LaresSpacing.lg,
            0,
          ),
          child: Card(
            color: Theme.of(context).colorScheme.surface,
            child: Padding(
              padding: const EdgeInsets.all(LaresSpacing.md),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _field,
                      // 不回显:这个场景就是「旁边可能有人」。
                      obscureText: true,
                      enabled: !_busy,
                      decoration: InputDecoration(
                        labelText: t.roomPasscodeHint,
                        isDense: true,
                      ),
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                  const SizedBox(width: LaresSpacing.sm),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(t.roomPasscodeRetry),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 敲门横幅:有人想进来时,轻提示 + 放行按钮(§2.2「轻敲门」非强提醒)
class _KnockBanner extends StatelessWidget {
  const _KnockBanner({required this.controller, this.settings});

  final RoomController controller;
  final SettingsStore? settings;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.knockRequests.isEmpty) {
          return const SizedBox.shrink();
        }
        // 免打扰时段:不弹敲门横幅(§2.2 防打扰)
        if (settings?.inDndNow == true) {
          return const SizedBox.shrink();
        }
        final knock = controller.knockRequests.first;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            LaresSpacing.lg,
            LaresSpacing.sm,
            LaresSpacing.lg,
            0,
          ),
          child: Card(
            color: Theme.of(context).colorScheme.surface,
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.door_front_door_outlined),
              title: Text(t.roomKnockWants(knock.name)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () => controller.dismissKnock(knock.userId),
                    child: Text(t.roomKnockDeny),
                  ),
                  FilledButton.tonal(
                    onPressed: () => controller.allowKnock(knock.userId),
                    child: Text(t.roomKnockAllow),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RoomHeader extends StatelessWidget {
  const _RoomHeader({
    required this.controller,
    required this.circleName,
    this.showMap = false,
    this.onToggleMap,
    this.e2ee,
  });

  final RoomController controller;
  final String circleName;
  final bool showMap;
  final VoidCallback? onToggleMap;
  final E2EEController? e2ee;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([controller, e2ee]),
      builder: (context, _) {
        final count = controller.members.length;
        // 只认「本次通话」的权威结论,且必须与当前圈子匹配 ——
        // 圈子对不上一律返回 null,绝不把上一个圈的状态显示给这一个圈。
        // 注册圈的加密由圈主统一定:进房后照样以本次通话的权威结论为准;
        // 还没连上媒体时(joining)用预测值,让人一进门就看到这把锁的真实情况。
        final cid = controller.circleId;
        final E2EEStatus? status = e2ee?.statusForActiveCircle(cid) ??
            (cid != null && e2ee != null && e2ee!.isCircleManaged(cid)
                ? e2ee!.previewStatusFor(cid)
                : null);
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            LaresSpacing.lg,
            LaresSpacing.md,
            LaresSpacing.lg,
            0,
          ),
          child: Row(
            children: [
              // ⚠️ 必须 Flexible。Row 对非 flex 子节点给的是**无界**横向约束,
              // 而下面那行副标题在 error 态是异常文本 —— 长度不可控。
              // 漏掉它的后果实测过:单行铺开到 2000+ px,
              // 屏幕右上角出现黄黑警示条「RIGHT OVERFLOWED BY 2014 PIXELS」。
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            circleName,
                            style: theme.textTheme.titleLarge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (status != null &&
                            status != E2EEStatus.disabled) ...[
                          const SizedBox(width: LaresSpacing.sm),
                          E2EEBadge(status: status, compact: true),
                        ],
                      ],
                    ),
                    Text(
                      switch (controller.phase) {
                        RoomPhase.joining => controller.knocking
                            ? t.roomKnocking
                            : t.roomJoining,
                        RoomPhase.inRoom =>
                          count <= 1 ? t.roomAloneHere : t.roomPeopleHere(count),
                        // 只显示人话。原始异常留给日志,不甩给用户。
                        // 注:errorMessage 本身由 room_controller.dart 产出,
                        // 仍是中文硬编码 —— 那个文件不在本批范围内,待后续批次。
                        RoomPhase.error =>
                          controller.errorMessage ?? t.roomErrorGeneric,
                        RoomPhase.idle => '',
                      },
                      style: theme.textTheme.bodyMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const Spacer(),
              if (onToggleMap != null)
                IconButton(
                  tooltip: showMap ? t.roomBackToRoom : t.roomLocationMap,
                  onPressed: onToggleMap,
                  icon: Icon(
                    showMap ? Icons.groups_rounded : Icons.map_outlined,
                    color: showMap ? LaresColors.ember : null,
                  ),
                ),
              if (controller.lastJoinLatency != null)
                Tooltip(
                  message: t.roomJoinLatencyTooltip,
                  child: Text(
                    '${controller.lastJoinLatency!.inMilliseconds}ms',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 「开了加密但这次通话其实没加密」的房内横幅。
///
/// 只在 [E2EEStatus.isBrokenPromise] 时出现 —— 真加密了不喊(头部那把锁足够),
/// 没开加密也不喊(那是用户的选择,天天提醒只会变成背景噪音)。
/// 唯一要打断用户的,是「你以为加密了」这一种情况。
class _E2EERoomBanner extends StatelessWidget {
  const _E2EERoomBanner({required this.controller, required this.e2ee});

  final RoomController controller;
  final E2EEController e2ee;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, e2ee]),
      builder: (context, _) {
        final status = e2ee.statusForActiveCircle(controller.circleId);
        if (status == null || !status.isBrokenPromise) {
          return const SizedBox.shrink();
        }
        return E2EEWarningBanner(status: status);
      },
    );
  }
}

/// 语音便签按钮:红点=有待听;长按录音时变色提示
class _VoiceNoteButton extends StatelessWidget {
  const _VoiceNoteButton({this.voiceNotes});

  final VoiceNotesController? voiceNotes;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final vn = voiceNotes;
    if (vn == null) {
      return const IconButton.filledTonal(
        onPressed: null,
        icon: Icon(Icons.voicemail_rounded),
      );
    }
    return ListenableBuilder(
      listenable: vn,
      builder: (context, _) {
        final count = vn.pendingCount;
        return GestureDetector(
          onLongPressStart: (_) => vn.startRecording(),
          onLongPressEnd: (_) => vn.stopAndSend(),
          child: Badge(
            isLabelVisible: count > 0,
            label: Text('$count'),
            child: IconButton.filledTonal(
              tooltip: count > 0 ? t.noteListen(count) : t.noteRecordHint,
              style: vn.recording
                  ? IconButton.styleFrom(
                      backgroundColor: LaresColors.ember,
                      foregroundColor: const Color(0xFF1A120C),
                    )
                  : null,
              onPressed: count > 0 ? vn.playAll : null,
              icon: Icon(
                vn.recording
                    ? Icons.mic_rounded
                    : vn.playing
                        ? Icons.volume_up_rounded
                        : Icons.voicemail_rounded,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 踢人确认
Future<void> _confirmKick(
    BuildContext context, RoomController controller, Member m) async {
  final t = AppLocalizations.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.roomKickTitle(m.name)),
      content: Text(t.roomKickBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(t.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(t.roomKickConfirm),
        ),
      ],
    ),
  );
  if (ok == true) controller.kick(m.userId);
}

class _MemberGrid extends StatelessWidget {
  const _MemberGrid({required this.controller, this.blocks});

  final RoomController controller;

  /// 为 null 时整块退回「长按=踢人」的老行为,且不画屏蔽标记
  final BlockStore? blocks;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final BlockStore? blocks = this.blocks;
    return ListenableBuilder(
      // 必须把 blocks 一起并进来:屏蔽是在 BlockStore 上发生的,
      // controller 根本不会为此 notify,不合并就「屏蔽了但画面没变」。
      listenable: Listenable.merge(<Listenable?>[controller, blocks]),
      builder: (context, _) {
        final members = controller.members;
        if (members.isEmpty) {
          return Center(
            child: Text(t.roomEmpty,
                style: Theme.of(context).textTheme.bodyMedium),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(LaresSpacing.lg),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 140,
            mainAxisSpacing: LaresSpacing.lg,
            crossAxisSpacing: LaresSpacing.sm,
            childAspectRatio: 0.72,
          ),
          itemCount: members.length,
          itemBuilder: (context, i) {
            final m = members[i];
            final isMe = m.userId == controller.userId;
            final bool blocked = blocks?.isBlocked(m.userId) ?? false;
            // 注册圈里只有圈主能踢:非圈主连这一行都看不到(服务器反正会拒)。
            // env 圈维持老行为,人人可踢。屏蔽是个人行为,不受影响。
            final cid = controller.circleId;
            final canKick = cid == null || controller.canModerate(cid);

            // 接了屏蔽名单就走处置菜单(踢人作为其中一行保留);
            // 没接就还是老样子:长按直接踢。
            VoidCallback? openMenu;
            if (!isMe && blocks != null) {
              openMenu = () => showMemberModerationSheet(
                    context,
                    controller: controller,
                    blocks: blocks,
                    member: m,
                    onKick: canKick
                        ? () => _confirmKick(context, controller, m)
                        : null,
                  );
            }

            final Widget orb = AvatarOrb(
              member: m,
              speaking: controller.speakingIds.contains(m.userId),
              muted: isMe && controller.muted,
            );

            return GestureDetector(
              // 点一下也能打开处置菜单。只留长按太隐蔽了 ——
              // AvatarOrb 自己 excludeSemantics: true,读屏用户更摸不到,
              // 而「能屏蔽」这件事必须让人找得到(审核指南 1.2)。
              onTap: openMenu,
              onLongPress: openMenu ??
                  (isMe || !canKick
                      ? null
                      : () => _confirmKick(context, controller, m)),
              child: blocked ? _BlockedOverlay(child: orb) : orb,
            );
          },
        );
      },
    );
  }
}

/// 被屏蔽成员的视觉标记:头像压暗 + 右上角一枚禁止图标。
///
/// 为什么一定要有:屏蔽的效果(听不到、看不到消息)全都发生在别处,
/// 网格里若毫无变化,用户点完那一下根本不知道生效了没有 ——
/// 审核员也是。名字已经在 AvatarOrb 里了,这里只加「暗」和「角标」两件事。
class _BlockedOverlay extends StatelessWidget {
  const _BlockedOverlay({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      // 无障碍标签同样要翻译 —— 读屏用户也是用户,而且这是审核指南 1.2
      // 「屏蔽能力必须找得到」的一部分。
      label: AppLocalizations.of(context).roomBlockedSemantics,
      // container: true 是必须的:AvatarOrb 自己已经建了一个语义节点
      // (还带 excludeSemantics),外层若不独立成节点,这个标签就会被吞掉,
      // 读屏用户根本听不到「已屏蔽」三个字。
      container: true,
      child: Stack(
        children: <Widget>[
          Opacity(opacity: _blockedAvatarOpacity, child: child),
          Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(LaresSpacing.xs),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.surface,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(LaresSpacing.xs),
                  child: Icon(
                    Icons.block_rounded,
                    size: _blockedBadgeIconSize,
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({required this.controller, this.voiceNotes});

  final RoomController controller;
  final VoiceNotesController? voiceNotes;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        // 麦克风没开成 / 没关成:弹一次即清。
        // 放在控制条这里,是因为它就是那个按钮的回音 —— 按了没反应的时候,
        // 用户的眼睛正停在这一块。权限被拒要说清「去系统设置」,
        // App 里再按多少次都没用。
        final notice = controller.micNotice;
        if (notice != null) {
          controller.micNotice = null;
          final text = switch (notice) {
            MicNotice.permissionDenied => t.roomMicPermissionDenied,
            MicNotice.unmuteFailed => t.roomMicUnmuteFailed,
            MicNotice.muteFailed => t.roomMicMuteFailed,
          };
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(text)));
          });
        }
        return Padding(
          padding: const EdgeInsets.all(LaresSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 轻状态选择(§2.2:降低「现在方不方便进」的顾虑)
              SegmentedButton<MemberStatus>(
                showSelectedIcon: false,
                // ⚠️ const 必须去掉:本地化字符串不是编译期常量。
                segments: [
                  ButtonSegment(
                      value: MemberStatus.free, label: Text(t.roomStatusFree)),
                  ButtonSegment(
                      value: MemberStatus.busy, label: Text(t.roomStatusBusy)),
                  ButtonSegment(
                      value: MemberStatus.ears, label: Text(t.roomStatusEars)),
                ],
                selected: {controller.myStatus},
                onSelectionChanged: (s) => controller.setStatus(s.first),
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStatePropertyAll(
                    theme.textTheme.bodyMedium,
                  ),
                ),
              ),
              const SizedBox(height: LaresSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 离开:低调,无仪式感
                  IconButton.filledTonal(
                    tooltip: t.roomLeave,
                    onPressed: controller.leave,
                    icon: const Icon(Icons.call_end_rounded),
                  ),
                  const SizedBox(width: LaresSpacing.lg),
                  // 静音/说话:绝对主角
                  SizedBox(
                    width: 76,
                    height: 76,
                    child: IconButton.filled(
                      tooltip: controller.muted ? t.roomUnmute : t.roomMute,
                      style: IconButton.styleFrom(
                        backgroundColor: controller.muted
                            ? theme.colorScheme.surface
                            : LaresColors.ember,
                        foregroundColor: controller.muted
                            ? theme.colorScheme.onSurface
                            : const Color(0xFF1A120C),
                      ),
                      onPressed: controller.toggleMute,
                      icon: Icon(
                        controller.muted
                            ? Icons.mic_off_rounded
                            : Icons.mic_rounded,
                        size: 34,
                      ),
                    ),
                  ),
                  const SizedBox(width: LaresSpacing.lg),
                  // 语音便签:点=听留言,长按=留一条(≤15s)
                  _VoiceNoteButton(voiceNotes: voiceNotes),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
