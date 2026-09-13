/// 录音指示器(设计.md §9 录音与转写的 UI 侧)。
///
/// 本文件是 Lares 全局「平静设计」里**刻意的例外**,原因只有一条:
/// **平静的设计 ≠ 隐蔽的设计**。
///
/// 炉灵是一个常开的语音房,朋友之间说话时没人会时刻盯着屏幕。
/// 在这种场景里录音的伦理分量是真实的:一个人可能整晚都在被录,
/// 却因为提示「太克制、太优雅」而从未注意到。所以这里的红线是 ——
/// **不可能身处一个正在被录音的房间而没有察觉**。
///
/// 但「不可忽视」不等于「吓人」。它不是浏览器那条冷冰冰的权限条,
/// 也不是红色告警框;它仍然属于这个产品:暖橙、圆角、有呼吸感、
/// 用第一人称说人话。庄重,而不是惊悚。
///
/// 由此推出的几条不可协商的实现约束:
/// * **持久**:没有关闭按钮、不可滑走、不自动隐藏。只要房间里有人在录,
///   它就一直在。能被用户关掉的知情提示等于没有。
/// * **脉动**:用一个约 1.8 秒周期的呼吸点,明显快于房间背景
///   `_BreathingBackground` 那 7 秒的氛围光晕 —— 那是「有人在」的暖意,
///   这是**录音指示灯**,必须读起来像一盏正在工作的 tally light。
/// * **降级不降可见性**:系统开启「减弱动态效果」时只停掉动画,
///   指示本身反而钉死在高可见度上。无障碍设置绝不能被用来变相隐藏录音提示。
/// * **第一人称**:我自己在录时,文案必须是「你正在录音」并配一个永远可点的
///   停止按钮。录音者把自己的录音误认成别人的录音,是最坏的一种失败。
///
/// 本文件全部是**控制器之上的纯 UI**:不含业务逻辑、不发网络包、
/// 除动画控制器外不持有任何定时器。是否允许采集永远只由
/// [RecordingConsentController.captureAllowed] 说了算。
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'recording_consent.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 视觉语气
// ─────────────────────────────────────────────────────────────────────────────

/// 指示器的视觉语气。
///
/// 刻意只有三档:再细分会让「谁在录」这件事变成需要辨色的猜谜游戏。
enum RecordingIndicatorTone {
  /// 房间里有人在录,但不是我。暖橙,克制。
  normal,

  /// **我自己**在录。同为暖橙但更实、更亮,并带停止按钮 ——
  /// 录音者必须一眼看出「是我在录」,不能和别人在录混为一谈。
  selfRecording,

  /// 录音状态失去确认(宽限期)。改用 [LaresColors.statusBusy],
  /// 因为此刻的事实是「房间可能已经不知道了」,这比「有人在录」更需要注意。
  warning,
}

// ─────────────────────────────────────────────────────────────────────────────
// 值对象:该渲染成什么
// ─────────────────────────────────────────────────────────────────────────────

/// 指示器当前该显示的全部内容(纯派生值,不含任何 Widget)。
///
/// 把「显示什么」从「怎么画」里摘出来,是为了让文案规则可以被单元测试
/// 逐条钉死 —— 录音提示的文案属于伦理契约的一部分,不该只能靠截图review。
/// Widget 因此退化成一个哑渲染器:拿到本对象,照着画。
@immutable
class RecordingIndicatorDisplay {
  /// 直接构造一份显示内容。一般请用 [RecordingIndicatorDisplay.derive]。
  const RecordingIndicatorDisplay({
    required this.tone,
    required this.headline,
    required this.semanticsLabel,
    this.elapsedLabel,
    this.detail,
    this.message,
    this.showStopAction = false,
  });

  /// 从房间全景派生显示内容。
  ///
  /// 注入 [now] 而不是内部调 `DateTime.now()`:已录时长是要被测试逐字断言的
  /// 文案,时钟必须可控。调用方应在 [RoomRecordingState.anyoneRecording]
  /// 为 false 时根本不渲染指示器;真传进来了也不会崩,会退化成一句
  /// 「房间里没有人在录音」,而不是拼出一句没有主语的病句。
  factory RecordingIndicatorDisplay.derive({
    required RoomRecordingState room,
    required bool inGracePeriod,
    required String? message,
    required DateTime now,
  }) {
    final List<RemoteRecorder> recorders = room.recorders;
    final int count = room.recorderCount;
    final bool mine = room.localRecording;

    // 「谁在录」这一句。它在正常态是标题,在宽限期会被降级成副行 ——
    // 因为那时更重要的事实是「状态未确认」。
    final String who;
    if (count == 0) {
      who = '房间里没有人在录音';
    } else if (mine) {
      // 第一人称,不用名字。别人的名字读起来是「有人在录」,
      // 只有「你」才会让录音者意识到责任在自己身上。
      who = '你正在录音';
    } else if (count >= 2) {
      // recorders 由控制器按开始时间升序排好,取第一个即最早那位,
      // 顺序稳定 => 文案不会随消息到达次序抖动。
      who = '${recorders.first.name} 等 $count 人正在录音';
    } else {
      // 加书名号是为了把名字和句子切开:名字里带「正在」之类的字也不会歧义。
      who = '「${recorders.first.name}」正在录音';
    }

    // 我在录、同时别人也在录。这条必须补上:否则录音者会以为
    // 房间里只有自己这一路录音,从而误判在场者的知情范围。
    final int otherCount = room.others.length;
    final String? othersLine = mine && otherCount > 0
        ? '房间里还有 $otherCount 人在录音'
        : null;

    // 已录时长取「标题主语那一位」的 since:标题说的是谁,时长就是谁的,
    // 否则会出现「你正在录音 / 已录 2 小时」而那 2 小时其实是别人的。
    final RemoteRecorder? subject = count == 0
        ? null
        : mine
            ? room.recorderOf(room.localUserId) ?? recorders.first
            : recorders.first;
    final String? elapsed =
        subject == null ? null : formatElapsed(subject.since, now);

    if (inGracePeriod) {
      // 宽限期:采集其实还开着(抖动不该毁录音),但房间**可能**已经
      // 看不到我的指示灯了。这种不确定性必须原样传达,不能粉饰成正常录音。
      return RecordingIndicatorDisplay(
        tone: RecordingIndicatorTone.warning,
        headline: '录音状态未确认',
        elapsedLabel: elapsed,
        detail: othersLine == null ? who : '$who,$othersLine',
        message: message,
        showStopAction: mine,
        semanticsLabel: _composeSemantics(
          headline: '录音状态未确认',
          detail: othersLine == null ? who : '$who,$othersLine',
          elapsed: elapsed,
          message: message,
        ),
      );
    }

    return RecordingIndicatorDisplay(
      tone: mine
          ? RecordingIndicatorTone.selfRecording
          : RecordingIndicatorTone.normal,
      headline: who,
      elapsedLabel: elapsed,
      detail: othersLine,
      message: message,
      showStopAction: mine,
      semanticsLabel: _composeSemantics(
        headline: who,
        detail: othersLine,
        elapsed: elapsed,
        message: message,
      ),
    );
  }

  /// 当前语气。
  final RecordingIndicatorTone tone;

  /// 主句:「你正在录音」/「「小明」正在录音」/「录音状态未确认」。
  final String headline;

  /// 无障碍朗读用的整句。必定包含「录音」二字 —— 屏幕阅读器用户
  /// 只靠这一句判断自己是否身处录音房间,不能指望他去逐行扫描。
  final String semanticsLabel;

  /// 已录时长,如「已录 3 分钟」。无人在录时为 null。
  final String? elapsedLabel;

  /// 副行:宽限期里放「谁在录」,正常态里放「房间里还有 N 人在录音」。
  final String? detail;

  /// 控制器给出的中文警告/说明([RecordingConsentController.message])。
  final String? message;

  /// 是否显示「停止录音」。仅当我自己是录音者时为 true。
  final bool showStopAction;

  /// 把 [since] 到 [now] 的间隔格式化成中文时长。
  ///
  /// 时钟偏移(服务器 since 在未来)会得到负数;这里**钳到 0** 而不是
  /// 显示「已录 -3 秒」—— 指示器一旦说过一次胡话,它说的所有话都会被打折。
  static String formatElapsed(DateTime since, DateTime now) {
    final Duration raw = now.difference(since);
    final Duration d = raw.isNegative ? Duration.zero : raw;
    if (d.inSeconds < 60) return '已录 ${d.inSeconds} 秒';
    if (d.inMinutes < 60) return '已录 ${d.inMinutes} 分钟';
    final int hours = d.inHours;
    final int minutes = d.inMinutes - hours * 60;
    // 整点时省掉「0 分钟」:「已录 2 小时 0 分钟」读起来像机器报时。
    return minutes == 0 ? '已录 $hours 小时' : '已录 $hours 小时 $minutes 分钟';
  }

  static String _composeSemantics({
    required String headline,
    required String? detail,
    required String? elapsed,
    required String? message,
  }) {
    final List<String> parts = <String>[
      headline,
      ?detail,
      ?elapsed,
      ?message,
    ];
    // 固定前缀「录音提示」:朗读常常是从半句开始被听到的,
    // 把最关键的词放在最前面,听到第一个词就知道是怎么回事。
    return '录音提示:${parts.join(',')}';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RecordingIndicatorDisplay &&
          other.tone == tone &&
          other.headline == headline &&
          other.semanticsLabel == semanticsLabel &&
          other.elapsedLabel == elapsedLabel &&
          other.detail == detail &&
          other.message == message &&
          other.showStopAction == showStopAction;

  @override
  int get hashCode => Object.hash(
        tone,
        headline,
        semanticsLabel,
        elapsedLabel,
        detail,
        message,
        showStopAction,
      );

  @override
  String toString() =>
      'RecordingIndicatorDisplay(tone: $tone, headline: $headline, '
      'elapsedLabel: $elapsedLabel, detail: $detail, message: $message, '
      'showStopAction: $showStopAction)';
}

// ─────────────────────────────────────────────────────────────────────────────
// 横幅
// ─────────────────────────────────────────────────────────────────────────────

/// 房间级的常驻录音指示横幅。
///
/// 放在 `_KnockBanner` 旁边,占用同样的横向留白,所以两者同时出现时
/// 读起来是同一套版式,而不是一条突兀的外来告警条。
///
/// ## 已录时长是怎么刷新的(这是个刻意的取舍)
///
/// 这里**没有** `Timer.periodic`。理由:一个 Widget 不该为了刷新一行文字
/// 而自己养一只挂钟 —— 周期定时器要跟着 `dispose` 精确拆除,漏一次就是
/// 一个泄漏;在移动端它还会周期性唤醒 UI 线程,和「常开挂机」这个场景
/// 直接冲突(炉灵的房间可能一挂就是一整晚)。
///
/// 而脉动动画本来就在以每帧的节奏重建这棵子树,时长文案完全可以**搭车**:
/// 每帧重算一个几十字节的短字符串,相对于脉动本身已经强制发生的重绘,
/// 成本可以忽略。时钟从 [now] 注入,于是这行文案在测试里是确定性的。
///
/// **代价要说清楚**:系统开启「减弱动态效果」后脉动停摆,时长就只在
/// 控制器 notify 时才刷新,可能停在某个旧值上。这个取舍是可以接受的,
/// 因为伦理上要紧的是「有人在录音」这个**事实**,它由控制器通知驱动,
/// 永远准确;已录了几分几秒只是附带信息,略微陈旧不改变任何人的判断。
class RecordingIndicatorBanner extends StatefulWidget {
  /// 构造横幅。[controller] 是唯一数据源;[now] 可注入时钟供测试使用。
  const RecordingIndicatorBanner({
    super.key,
    required this.controller,
    this.now = DateTime.now,
  });

  /// 录音同意控制器。横幅只读它,绝不写它(停止按钮除外,那是显式动作)。
  final RecordingConsentController controller;

  /// 当前时刻的来源。默认 [DateTime.now];测试里注入固定时钟。
  final DateTime Function() now;

  @override
  State<RecordingIndicatorBanner> createState() =>
      _RecordingIndicatorBannerState();
}

class _RecordingIndicatorBannerState extends State<RecordingIndicatorBanner>
    with SingleTickerProviderStateMixin {
  /// 脉动周期。1.8 秒 ≈ 静息心率的一半,读起来是「活的」而不是「急的」;
  /// 同时明显快于背景呼吸光晕的 7 秒 —— 两者必须一眼可分,
  /// 否则录音指示会被误读成房间氛围的一部分。
  static const Duration _pulsePeriod = Duration(milliseconds: 1800);

  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    // 这里只创建,不启动:是否该动要看 MediaQuery,而 initState 里还读不到它。
    _pulse = AnimationController(vsync: this, duration: _pulsePeriod);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  /// 跟随系统「减弱动态效果」开关启停脉动。
  ///
  /// 关键:停的只是**动**,不是**显**。停摆时把相位钉在 1.0(最亮那一端),
  /// 于是无障碍设置反而让指示器变得更稳定可见。把它做成淡出会是一个
  /// 用无障碍选项变相隐藏录音提示的后门,绝不接受。
  void _syncMotion() {
    final bool reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      if (_pulse.isAnimating) _pulse.stop();
      _pulse.value = 1;
      return;
    }
    if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? _) {
        final RoomRecordingState room = widget.controller.room;
        // 没人在录音就整块不渲染 —— 与 _KnockBanner 相同的降级方式,
        // 保证「没有指示器」严格等价于「没有人在录音」。
        if (!room.anyoneRecording) return const SizedBox.shrink();

        return AnimatedBuilder(
          animation: _pulse,
          builder: (BuildContext context, Widget? child) {
            // 已录时长搭这趟车重算(见类文档的取舍说明)。
            final RecordingIndicatorDisplay display =
                RecordingIndicatorDisplay.derive(
              room: room,
              inGracePeriod: widget.controller.inGracePeriod,
              message: widget.controller.message,
              now: widget.now(),
            );
            return _buildBanner(context, display);
          },
        );
      },
    );
  }

  Widget _buildBanner(
    BuildContext context,
    RecordingIndicatorDisplay display,
  ) {
    final ThemeData theme = Theme.of(context);
    final bool reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // 减弱动态时直接取相位 1.0:与 _syncMotion 的钉死值一致,
    // 即使某一帧的启停时序错开也不会闪成暗态。
    final double t =
        reduceMotion ? 1 : Curves.easeInOut.transform(_pulse.value);

    final Color tone = _toneColor(display.tone);

    // ── 透明度全部锚在 token 上 ──
    // LaresColors.emberSoft 的 alpha 是 0x33 ≈ 0.20,是设计系统认可的
    // 「一层暖色薄纱」。底色取 0.14→0.20 的摆动:峰值正好落在该 token 上,
    // 谷值略低,于是脉动始终在设计系统允许的范围内起伏,不会超纲变亮。
    const double kVeilPeak = 0.20;
    const double kVeilTrough = 0.14;
    // 描边必须任何相位下都看得见,所以谷值取到 0.45;峰值 0.75 而非 1.0,
    // 是为了保留一点柔光感,不让它变成硬边告警框。
    const double kBorderTrough = 0.45;
    const double kBorderPeak = 0.75;

    final double veil = kVeilTrough + (kVeilPeak - kVeilTrough) * t;
    final double borderAlpha =
        kBorderTrough + (kBorderPeak - kBorderTrough) * t;

    // normal 态(别人在录)用中性高亮面,只靠描边和呼吸点着色;
    // selfRecording / warning 则整块蒙上语气色 —— 这是「是我在录」
    // 与「是别人在录」最快的区分方式,不依赖读字。
    final Color background = display.tone == RecordingIndicatorTone.normal
        ? LaresColors.surfaceHighDark
        : tone.withValues(alpha: veil);

    return Semantics(
      // liveRegion:状态一变就主动播报,而不是等用户自己摸到这块区域。
      liveRegion: true,
      container: true,
      label: display.semanticsLabel,
      child: Padding(
        // 与 _KnockBanner 完全相同的外边距,两条横幅并排时版式对齐。
        padding: const EdgeInsets.fromLTRB(
          LaresSpacing.lg,
          LaresSpacing.sm,
          LaresSpacing.lg,
          0,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            borderRadius: LaresRadii.cardRadius,
            border: Border.all(
              color: tone.withValues(alpha: borderAlpha),
              // 1 逻辑像素:比 dividerTheme 的 1 更细就会在低密度屏上消失。
              width: 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(LaresSpacing.md),
            child: Row(
              children: <Widget>[
                _PulseDot(tone: tone, phase: t),
                const SizedBox(width: LaresSpacing.sm),
                Icon(_toneIcon(display.tone), color: tone, size: 20),
                const SizedBox(width: LaresSpacing.sm),
                Expanded(
                  // 文字整体排除在语义树外:上面的 Semantics 已经把同样的
                  // 内容组织成一句完整的播报,再让每行各报一次只会变成噪音。
                  child: ExcludeSemantics(
                    child: _BannerText(display: display, theme: theme),
                  ),
                ),
                if (display.showStopAction) ...<Widget>[
                  const SizedBox(width: LaresSpacing.sm),
                  // **不**放进 ExcludeSemantics:停止录音必须始终是一个
                  // 可被辅助技术找到并点击的动作。
                  RecordingStopButton(onStop: widget.controller.stop),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Color _toneColor(RecordingIndicatorTone tone) => switch (tone) {
        RecordingIndicatorTone.normal => LaresColors.ember,
        RecordingIndicatorTone.selfRecording => LaresColors.ember,
        // 「状态未确认」比「有人在录」更需要被处理,借用 presence 的「在忙」色:
        // 它在本设计系统里已经承担「需要留意」的语义,无需新增颜色。
        RecordingIndicatorTone.warning => LaresColors.statusBusy,
      };

  static IconData _toneIcon(RecordingIndicatorTone tone) => switch (tone) {
        // 别人在录:声波,描述的是「房间里有声音被收走」。
        RecordingIndicatorTone.normal => Icons.graphic_eq_rounded,
        // 我在录:麦克风,指向持麦的那个人 —— 就是你。
        RecordingIndicatorTone.selfRecording => Icons.mic_rounded,
        RecordingIndicatorTone.warning => Icons.warning_amber_rounded,
      };
}

/// 横幅的文字栏。拆出来只是为了让 [_RecordingIndicatorBannerState] 的
/// 布局代码保持可读,本身没有任何状态。
class _BannerText extends StatelessWidget {
  const _BannerText({required this.display, required this.theme});

  final RecordingIndicatorDisplay display;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    // 警告态的主句本身也着色:此时用户可能只来得及扫一眼标题。
    final Color headlineColor = display.tone == RecordingIndicatorTone.warning
        ? LaresColors.statusBusy
        : LaresColors.textPrimaryDark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          display.headline,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: headlineColor,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (display.elapsedLabel != null)
          Text(display.elapsedLabel!, style: theme.textTheme.bodyMedium),
        if (display.detail != null)
          Text(display.detail!, style: theme.textTheme.bodyMedium),
        if (display.message != null)
          // 控制器的警告文案走同一套次级样式:它是补充说明,
          // 不该和「谁在录音」这句主句争夺注意力。
          Text(display.message!, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

/// 脉动的录音点(tally light)。
class _PulseDot extends StatelessWidget {
  const _PulseDot({required this.tone, required this.phase});

  final Color tone;

  /// 已经过缓动的相位,0..1。
  final double phase;

  /// 点的直径。取 [LaresSpacing.sm] + [LaresSpacing.xs]:不新造尺寸常数,
  /// 同时保证在 16px 图标旁边仍然是可辨认的一个「灯」而不是一粒灰。
  static const double _size = LaresSpacing.sm + LaresSpacing.xs;

  @override
  Widget build(BuildContext context) {
    // 0.60→1.00:谷值仍然接近实心。录音指示灯在任何一帧都不许淡到暧昧,
    // 「一闪一闪」的目的是引起注意,而不是制造它可能不在的错觉。
    const double kDotTrough = 0.60;
    final double alpha = kDotTrough + (1 - kDotTrough) * phase;
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: tone.withValues(alpha: alpha),
        boxShadow: <BoxShadow>[
          BoxShadow(
            // 外发光的 alpha 取薄纱档(emberSoft ≈ 0.20)的量级,
            // 只做「暖」,不做「亮」——它不该在暗色背景上糊成一团光斑。
            color: tone.withValues(alpha: 0.20 * phase),
            blurRadius: LaresSpacing.sm + LaresSpacing.xs * phase,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 停止按钮
// ─────────────────────────────────────────────────────────────────────────────

/// 「停止录音」按钮。
///
/// 三条硬规矩,都是从「停录永远不许失败」这条控制器不变量延伸出来的:
/// **一次点击**(不加二次确认对话框)、**永不收进菜单**、**永不置灰**。
/// 开始录音应该有摩擦,停止录音不该有 —— 任何一道额外的门,
/// 都会变成某个人被继续录下去的理由。
class RecordingStopButton extends StatelessWidget {
  /// 构造停止按钮。[onStop] 一般直接接 [RecordingConsentController.stop]。
  const RecordingStopButton({super.key, required this.onStop});

  /// 点击回调。**不允许传 null**:没有「不能停」这种状态。
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: onStop,
      icon: const Icon(Icons.stop_rounded),
      label: const Text('停止录音'),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 开始录音的知情同意对话框
// ─────────────────────────────────────────────────────────────────────────────

/// 弹出「开始录音」确认对话框,返回用户是否确认。
///
/// 取消、点遮罩关闭、系统返回都算**不同意**(`null` 一律折成 false):
/// 录音默认关闭这件事,不允许因为任何一种「没表态」而被绕过。
///
/// 摩擦力是刻意调到中间档的。这是一个五到二十人的熟人房间,不是取证工具:
/// 要求打字确认那种仪式感属于表演,只会训练用户机械照抄;
/// 而一个一键开关又太容易被误触 —— 录音不该是能被手滑打开的东西。
/// 一个说清后果的确认框,正好落在「不会误开、也不至于让人烦」之间。
Future<bool> showRecordingConsentDialog(
  BuildContext context, {
  required int memberCount,
}) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) {
      final ColorScheme scheme = Theme.of(ctx).colorScheme;
      return AlertDialog(
        shape: const RoundedRectangleBorder(
          borderRadius: LaresRadii.cardRadius,
        ),
        title: const Text('开始录音?'),
        // 正文只讲**后果**,不讲功能。用户需要判断的不是「这个按钮做什么」,
        // 而是「我按下去之后,这个房间里会发生什么」。
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('房间里每个人都会立刻收到通知,知道是你在录。'),
            const SizedBox(height: LaresSpacing.sm),
            const Text('录音期间,所有人的界面上都会一直显示录音提示,关不掉。'),
            const SizedBox(height: LaresSpacing.sm),
            const Text('声音会被转写成文字,只保存在本地设备,不会上传。'),
            const SizedBox(height: LaresSpacing.sm),
            Text('现在房间里有 $memberCount 个人。'),
          ],
        ),
        actions: <Widget>[
          // 取消在前:默认视线落点是「不做这件事」。
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('再想想'),
          ),
          FilledButton(
            // 显式关掉自动聚焦:否则一次无意的回车就能把确认按掉,
            // 那等于把刚刚建立起来的那点摩擦力又还回去了。
            autofocus: false,
            style: FilledButton.styleFrom(
              backgroundColor: LaresColors.ember,
              foregroundColor: scheme.onPrimary,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始录音'),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}
