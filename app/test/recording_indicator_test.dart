import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/recording/recording_consent.dart';
import 'package:lares_app/src/recording/recording_indicator.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/theme/tokens.dart';

const String kMe = 'u_me';
const String kCircle = 'c';

/// 固定的录音起始时刻(epoch 毫秒)。测试里的「现在」一律由它加偏移得来,
/// 这样已录时长的断言是逐字确定的,不会随真实时钟漂移而红。
const int kSinceMs = 1700000000000;
final DateTime kSince = DateTime.fromMillisecondsSinceEpoch(kSinceMs);

/// 把横幅塞进和真实房间同样的主题环境里(暗色为一等公民)。
///
/// **不要在这里 pumpAndSettle**:横幅带 repeat(reverse: true) 的脉动,
/// 永远不会静止,pumpAndSettle 必然超时。全部用显式 pump。
Widget wrap(
  RecordingConsentController controller, {
  DateTime Function()? now,
  bool disableAnimations = false,
}) {
  final Widget banner = RecordingIndicatorBanner(
    controller: controller,
    now: now ?? () => kSince,
  );
  return MaterialApp(
    theme: LaresTheme.dark(),
    home: Scaffold(
      body: disableAnimations
          ? MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: banner,
            )
          : banner,
    ),
  );
}

/// 让某个人在服务器眼里开始/停止录音。
void memberRec(
  RecordingConsentController c, {
  required String userId,
  required bool active,
  String name = '小明',
  String circleId = kCircle,
  int sinceMs = kSinceMs,
}) {
  c.handleMessage(<String, dynamic>{
    't': 'member_rec',
    'circleId': circleId,
    'userId': userId,
    'name': name,
    'active': active,
    'since': sinceMs,
  });
}

/// 走完「请求 -> 自己的回显」这条唯一能进入 recording 的路径。
///
/// requestStart 返回的 Future 只在回显/超时时兑现,**绝不能先 await**,
/// 否则测试会在这里死等。
Future<void> becomeRecorder(
  WidgetTester tester,
  RecordingConsentController c, {
  String name = '我',
}) async {
  c.requestStart(kCircle);
  await tester.pump();
  memberRec(c, userId: kMe, active: true, name: name);
  await tester.pump();
}

/// 构造控制器并**立刻**注册 teardown。
///
/// 顺序要紧:进入 recording 会起 15 秒心跳定时器,测试结束时若还挂着,
/// flutter_test 会直接判失败("A Timer is still pending")。
/// dispose() 内部会 _cancelTimers(),所以先注册再驱动。
RecordingConsentController makeController(List<Map<String, dynamic>> sent) {
  final RecordingConsentController c = RecordingConsentController(
    userId: kMe,
    send: (Map<String, dynamic> m) => sent.add(m),
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('横幅渲染', () {
    testWidgets('没人录音时横幅不渲染', (WidgetTester tester) async {
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final RecordingConsentController c = makeController(sent);

      await tester.pumpWidget(wrap(c));
      await tester.pump();

      // 「没有指示器」必须严格等价于「没有人在录音」
      expect(find.byType(RecordingStopButton), findsNothing);
      expect(find.textContaining('正在录音'), findsNothing);
      expect(
        tester.getSize(find.byType(RecordingIndicatorBanner)),
        Size.zero,
        reason: 'anyoneRecording 为 false 时应退化成 SizedBox.shrink()',
      );
    });

    testWidgets('有远端录音者时横幅出现并点名是谁', (WidgetTester tester) async {
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final RecordingConsentController c = makeController(sent);

      await tester.pumpWidget(wrap(c));
      memberRec(c, userId: 'u2', active: true, name: '小明');
      await tester.pump();

      expect(find.text('「小明」正在录音'), findsOneWidget);
      // 别人在录时不该出现我的停止按钮 —— 我停不了别人的录音
      expect(find.byType(RecordingStopButton), findsNothing);
    });

    testWidgets('多人录音时显示「等 N 人」形式', (WidgetTester tester) async {
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final RecordingConsentController c = makeController(sent);

      await tester.pumpWidget(wrap(c));
      memberRec(c, userId: 'u2', active: true, name: '小明', sinceMs: kSinceMs);
      memberRec(
        c,
        userId: 'u3',
        active: true,
        name: '小林',
        sinceMs: kSinceMs + 5000,
      );
      await tester.pump();

      // 最早开始的那位做主语,顺序由控制器的稳定排序保证
      expect(find.text('小明 等 2 人正在录音'), findsOneWidget);
    });

    testWidgets('我是录音者时用第一人称文案,并给出可见的停止操作', (WidgetTester tester) async {
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final RecordingConsentController c = makeController(sent);

      await tester.pumpWidget(wrap(c));
      await becomeRecorder(tester, c);

      expect(c.room.localRecording, isTrue);
      // 录音者绝不能把自己的录音误读成别人的
      expect(find.text('你正在录音'), findsOneWidget);
      expect(find.byType(RecordingStopButton), findsOneWidget);
      expect(find.text('停止录音'), findsOneWidget);

      c.stop();
    });

    testWidgets('我在录且别人也在录时,补出「房间里还有 N 人在录音」', (WidgetTester tester) async {
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final RecordingConsentController c = makeController(sent);

      await tester.pumpWidget(wrap(c));
      await becomeRecorder(tester, c);
      memberRec(
        c,
        userId: 'u2',
        active: true,
        name: '小明',
        sinceMs: kSinceMs + 1000,
      );
      await tester.pump();

      expect(find.text('你正在录音'), findsOneWidget);
      expect(find.text('房间里还有 1 人在录音'), findsOneWidget);

      c.stop();
    });

    testWidgets('横幅是持久的:没有任何关闭/驳回按钮', (WidgetTester tester) async {
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final RecordingConsentController c = makeController(sent);

      await tester.pumpWidget(wrap(c));
      memberRec(c, userId: 'u2', active: true, name: '小明');
      await tester.pump();

      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.byType(Dismissible), findsNothing);

      // 动画跑很久也不会自动消失
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('「小明」正在录音'), findsOneWidget);
    });
  });

  group('停止录音', () {
    testWidgets('点「停止录音」后控制器真的停了采集', (WidgetTester tester) async {
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final RecordingConsentController c = makeController(sent);

      await tester.pumpWidget(wrap(c));
      await becomeRecorder(tester, c);
      expect(c.captureAllowed, isTrue);

      await tester.tap(find.text('停止录音'));
      await tester.pump();

      expect(c.captureAllowed, isFalse);
      expect(c.state, RecordingConsentState.idle);
      expect(
        sent.any((Map<String, dynamic> m) => m['t'] == 'rec_stop'),
        isTrue,
        reason: '停录必须同时向房间广播,否则别人的指示器还亮着',
      );
      // 本机不再是录音者,横幅随之熄灭
      expect(find.byType(RecordingStopButton), findsNothing);
    });

    testWidgets('停止按钮永不置灰:onPressed 始终非空', (WidgetTester tester) async {
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final RecordingConsentController c = makeController(sent);

      await tester.pumpWidget(wrap(c));
      await becomeRecorder(tester, c);

      final FilledButton button = tester.widget<FilledButton>(
        find.descendant(
          of: find.byType(RecordingStopButton),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNotNull);

      c.stop();
    });
  });

  group('宽限期', () {
    testWidgets('失去确认时切成醒目的警告态文案', (WidgetTester tester) async {
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final RecordingConsentController c = makeController(sent);

      await tester.pumpWidget(wrap(c));
      await becomeRecorder(tester, c);

      // 宽限期只能从 recording 进入
      c.handleMessage(<String, dynamic>{'t': '_disconnected'});
      await tester.pump();
      expect(c.inGracePeriod, isTrue);

      // 标题换成「状态未确认」,「谁在录」降级成副行(仍在,但不再是主句)
      expect(find.text('录音状态未确认'), findsOneWidget);
      expect(find.text('你正在录音'), findsOneWidget);
      final RecordingIndicatorDisplay display =
          RecordingIndicatorDisplay.derive(
        room: c.room,
        inGracePeriod: c.inGracePeriod,
        message: c.message,
        now: kSince,
      );
      expect(display.headline, '录音状态未确认');
      expect(display.detail, '你正在录音');
      // 控制器的中文说明被原样透出
      expect(find.textContaining('信令连接已断开'), findsOneWidget);
      // 采集还开着,所以停止按钮必须还在
      expect(find.byType(RecordingStopButton), findsOneWidget);

      c.stop();
    });

    testWidgets('警告态使用 statusBusy 而非暖橙', (WidgetTester tester) async {
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final RecordingConsentController c = makeController(sent);

      await tester.pumpWidget(wrap(c));
      await becomeRecorder(tester, c);
      c.handleMessage(<String, dynamic>{'t': '_disconnected'});
      await tester.pump();

      final Icon icon = tester.widget<Icon>(
        find.byIcon(Icons.warning_amber_rounded),
      );
      expect(icon.color, LaresColors.statusBusy);

      c.stop();
    });
  });

  group('无障碍', () {
    testWidgets('横幅带有包含「录音」的 Semantics 标签', (WidgetTester tester) async {
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final RecordingConsentController c = makeController(sent);
      // 句柄必须在测试体内 dispose:flutter_test 在 teardown 之前就会
      // 断言「没有残留的 SemanticsHandle」,放进 addTearDown 已经太晚。
      final SemanticsHandle handle = tester.ensureSemantics();

      await tester.pumpWidget(wrap(c));
      memberRec(c, userId: 'u2', active: true, name: '小明');
      await tester.pump();

      expect(find.bySemanticsLabel(RegExp('录音')), findsWidgets);

      final SemanticsNode node = tester.getSemantics(
        find.bySemanticsLabel(RegExp('录音提示')).first,
      );
      expect(node.label, contains('录音'));
      expect(node.label, contains('小明'));
      // liveRegion:状态一变就主动播报,不能等用户自己去摸这块区域
      expect(node, isSemantics(isLiveRegion: true));

      handle.dispose();
    });

    testWidgets('停止按钮在语义树里仍然可达可点', (WidgetTester tester) async {
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final RecordingConsentController c = makeController(sent);
      final SemanticsHandle handle = tester.ensureSemantics();

      await tester.pumpWidget(wrap(c));
      await becomeRecorder(tester, c);

      final SemanticsNode node = tester.getSemantics(find.text('停止录音'));
      expect(node.label, contains('停止录音'));
      // 横幅其余文字被 ExcludeSemantics 排除,但停录必须始终可被点到
      expect(node, isSemantics(hasTapAction: true, isEnabled: true));

      c.stop();
      handle.dispose();
    });

    testWidgets('系统减弱动态效果时横幅依然完整可见,只是不再脉动', (WidgetTester tester) async {
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final RecordingConsentController c = makeController(sent);

      await tester.pumpWidget(wrap(c, disableAnimations: true));
      memberRec(c, userId: 'u2', active: true, name: '小明');
      await tester.pump();

      // 无障碍设置绝不能变成隐藏录音提示的后门
      expect(find.text('「小明」正在录音'), findsOneWidget);
      // 没有待处理的动画帧:说明脉动确实停住了
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  group('已录时长文案', () {
    test('不足一分钟按秒显示,时钟偏移被钳到 0 秒', () {
      expect(
        RecordingIndicatorDisplay.formatElapsed(
          kSince,
          kSince.add(const Duration(seconds: 42)),
        ),
        '已录 42 秒',
      );
      // since 在未来(服务器/本机时钟不同步)时绝不显示负数
      expect(
        RecordingIndicatorDisplay.formatElapsed(
          kSince,
          kSince.subtract(const Duration(seconds: 30)),
        ),
        '已录 0 秒',
      );
    });

    test('一分钟到一小时按分钟显示', () {
      expect(
        RecordingIndicatorDisplay.formatElapsed(
          kSince,
          kSince.add(const Duration(minutes: 3, seconds: 20)),
        ),
        '已录 3 分钟',
      );
      expect(
        RecordingIndicatorDisplay.formatElapsed(
          kSince,
          kSince.add(const Duration(seconds: 60)),
        ),
        '已录 1 分钟',
      );
    });

    test('超过一小时按小时+分钟显示,整点省掉 0 分钟', () {
      expect(
        RecordingIndicatorDisplay.formatElapsed(
          kSince,
          kSince.add(const Duration(hours: 2, minutes: 7)),
        ),
        '已录 2 小时 7 分钟',
      );
      expect(
        RecordingIndicatorDisplay.formatElapsed(
          kSince,
          kSince.add(const Duration(hours: 2)),
        ),
        '已录 2 小时',
      );
    });

    testWidgets('横幅里渲染出注入时钟算得的时长', (WidgetTester tester) async {
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final RecordingConsentController c = makeController(sent);

      await tester.pumpWidget(
        wrap(c, now: () => kSince.add(const Duration(minutes: 3))),
      );
      memberRec(c, userId: 'u2', active: true, name: '小明');
      await tester.pump();

      expect(find.text('已录 3 分钟'), findsOneWidget);
    });
  });

  group('显示内容派生', () {
    RoomRecordingState roomOf(List<RemoteRecorder> rs) =>
        RoomRecordingState(recorders: rs, localUserId: kMe);

    test('单个远端录音者:normal 语气、无停止操作', () {
      final RecordingIndicatorDisplay d = RecordingIndicatorDisplay.derive(
        room: roomOf(<RemoteRecorder>[
          RemoteRecorder(userId: 'u2', name: '小明', since: kSince),
        ]),
        inGracePeriod: false,
        message: null,
        now: kSince.add(const Duration(minutes: 3)),
      );

      expect(d.tone, RecordingIndicatorTone.normal);
      expect(d.headline, '「小明」正在录音');
      expect(d.elapsedLabel, '已录 3 分钟');
      expect(d.showStopAction, isFalse);
      expect(d.semanticsLabel, '录音提示:「小明」正在录音,已录 3 分钟');
    });

    test('我在录:selfRecording 语气、第一人称、带停止操作', () {
      final RecordingIndicatorDisplay d = RecordingIndicatorDisplay.derive(
        room: roomOf(<RemoteRecorder>[
          RemoteRecorder(userId: kMe, name: '我', since: kSince),
        ]),
        inGracePeriod: false,
        message: null,
        now: kSince.add(const Duration(minutes: 3)),
      );

      expect(d.tone, RecordingIndicatorTone.selfRecording);
      expect(d.headline, '你正在录音');
      expect(d.showStopAction, isTrue);
      expect(d.semanticsLabel, '录音提示:你正在录音,已录 3 分钟');
    });

    test('宽限期压过一切:语气转 warning,谁在录降级为副行', () {
      final RecordingIndicatorDisplay d = RecordingIndicatorDisplay.derive(
        room: roomOf(<RemoteRecorder>[
          RemoteRecorder(userId: kMe, name: '我', since: kSince),
        ]),
        inGracePeriod: true,
        message: '信令连接已断开',
        now: kSince.add(const Duration(minutes: 3)),
      );

      expect(d.tone, RecordingIndicatorTone.warning);
      expect(d.headline, '录音状态未确认');
      expect(d.detail, '你正在录音');
      expect(d.message, '信令连接已断开');
      // 采集还开着,所以仍然必须能停
      expect(d.showStopAction, isTrue);
      expect(d.semanticsLabel, contains('录音'));
    });

    test('值语义:同内容相等,不同内容不等', () {
      final RecordingIndicatorDisplay a = RecordingIndicatorDisplay.derive(
        room: roomOf(<RemoteRecorder>[
          RemoteRecorder(userId: 'u2', name: '小明', since: kSince),
        ]),
        inGracePeriod: false,
        message: null,
        now: kSince,
      );
      final RecordingIndicatorDisplay b = RecordingIndicatorDisplay.derive(
        room: roomOf(<RemoteRecorder>[
          RemoteRecorder(userId: 'u2', name: '小明', since: kSince),
        ]),
        inGracePeriod: false,
        message: null,
        now: kSince,
      );
      final RecordingIndicatorDisplay c = RecordingIndicatorDisplay.derive(
        room: roomOf(<RemoteRecorder>[
          RemoteRecorder(userId: kMe, name: '我', since: kSince),
        ]),
        inGracePeriod: false,
        message: null,
        now: kSince,
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a.toString(), contains('小明'));
    });
  });

  group('知情同意对话框', () {
    /// 打开对话框并把返回值记下来。
    /// **不用 pumpAndSettle**:改用两次显式 pump 走完路由转场。
    Future<void> openDialog(
      WidgetTester tester,
      void Function(bool) onResult, {
      int memberCount = 6,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: LaresTheme.dark(),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => TextButton(
                onPressed: () async {
                  final bool ok = await showRecordingConsentDialog(
                    ctx,
                    memberCount: memberCount,
                  );
                  onResult(ok);
                },
                child: const Text('开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('开'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('确认返回 true,正文说清「每个人都会」被告知', (WidgetTester tester) async {
      bool? result;
      await openDialog(tester, (bool v) => result = v, memberCount: 6);

      expect(find.text('开始录音?'), findsOneWidget);
      // 这是伦理契约里最关键的一句,必须出现
      expect(find.textContaining('每个人都会'), findsOneWidget);
      // 本地存储、常驻提示、在场人数,一条都不能少
      expect(find.textContaining('本地'), findsOneWidget);
      expect(find.textContaining('关不掉'), findsOneWidget);
      expect(find.textContaining('6 个人'), findsOneWidget);
      expect(find.text('再想想'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '开始录音'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(result, isTrue);
    });

    testWidgets('点「再想想」返回 false', (WidgetTester tester) async {
      bool? result;
      await openDialog(tester, (bool v) => result = v);

      await tester.tap(find.text('再想想'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(result, isFalse);
    });

    testWidgets('点遮罩关掉也算不同意(null 折成 false)', (WidgetTester tester) async {
      bool? result;
      await openDialog(tester, (bool v) => result = v);

      // 点对话框之外的区域:barrier dismiss
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(result, isFalse);
      expect(find.text('开始录音?'), findsNothing);
    });

    testWidgets('确认按钮显式不自动聚焦,防止一记回车误确认', (WidgetTester tester) async {
      bool? result;
      await openDialog(tester, (bool v) => result = v);

      final FilledButton affirmative = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '开始录音'),
      );
      expect(affirmative.autofocus, isFalse);

      await tester.tap(find.text('再想想'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(result, isFalse);
    });
  });
}
