import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/moderation/block_store.dart';
import 'package:lares_app/src/moderation/consent_store.dart';
import 'package:lares_app/src/moderation/content_policy_text.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/ui/blocked_users_section.dart';
import 'package:lares_app/src/ui/content_policy_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 门后面那一屏,用一句独一无二的话标记,免得跟规范正文撞车
const String kChildMarker = '这里是主界面';

Widget _app(Widget home) => MaterialApp(
      theme: LaresTheme.dark(),
      home: home,
    );

/// 同意按钮当前是不是可点的。`onPressed == null` 就是禁用。
bool _agreeEnabled(WidgetTester tester) {
  final button = tester.widget<FilledButton>(
    find.widgetWithText(FilledButton, kContentPolicyAgreeLabel),
  );
  return button.onPressed != null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('内容规范同意门', () {
    testWidgets('没同意过时,只看得到规范页,看不到主界面', (tester) async {
      final consent = await ConsentStore.load();
      expect(consent.accepted, isFalse);

      await tester.pumpWidget(_app(ContentPolicyGate(
        consent: consent,
        child: const Scaffold(body: Text(kChildMarker)),
      )));

      expect(find.text(kContentPolicyTitle), findsOneWidget);
      expect(find.text(kContentPolicySummary), findsOneWidget);
      expect(find.text(kChildMarker), findsNothing);
    });

    testWidgets('勾上「读完了」之前,同意按钮是禁用的', (tester) async {
      final consent = await ConsentStore.load();
      await tester.pumpWidget(_app(ContentPolicyGate(
        consent: consent,
        child: const Scaffold(body: Text(kChildMarker)),
      )));

      // 勾选框默认不勾 —— 预勾选的同意等于没有同意
      final checkbox = find.byType(CheckboxListTile);
      await tester.ensureVisible(checkbox);
      await tester.pump();
      expect(
        tester.widget<CheckboxListTile>(checkbox).value,
        isFalse,
        reason: '「我已经读完」必须默认不勾选',
      );
      expect(_agreeEnabled(tester), isFalse, reason: '没勾就不该能同意');

      await tester.tap(checkbox);
      await tester.pump();

      expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
      expect(_agreeEnabled(tester), isTrue, reason: '勾上之后才放开同意按钮');
    });

    testWidgets('勾选并同意之后,记下同意状态并放行到主界面', (tester) async {
      final consent = await ConsentStore.load();
      await tester.pumpWidget(_app(ContentPolicyGate(
        consent: consent,
        child: const Scaffold(body: Text(kChildMarker)),
      )));

      final checkbox = find.byType(CheckboxListTile);
      await tester.ensureVisible(checkbox);
      await tester.pump();
      await tester.tap(checkbox);
      await tester.pump();

      final agree = find.widgetWithText(FilledButton, kContentPolicyAgreeLabel);
      await tester.ensureVisible(agree);
      await tester.pump();
      await tester.tap(agree);
      await tester.pumpAndSettle();

      expect(consent.accepted, isTrue);
      expect(find.text(kChildMarker), findsOneWidget);
      expect(find.text(kContentPolicyTitle), findsNothing);
    });

    testWidgets('规范正文写明了零容忍与 24 小时处理承诺', (tester) async {
      final consent = await ConsentStore.load();
      await tester.pumpWidget(_app(ContentPolicyGate(
        consent: consent,
        child: const Scaffold(body: Text(kChildMarker)),
      )));

      // 直接拿常量去找,文案改了这里也不会失灵 —— 但条款必须真的渲染出来
      for (final point in kContentPolicyPoints) {
        expect(find.text(point.title), findsOneWidget,
            reason: '条目标题「${point.title}」没有渲染出来');
        expect(find.text(point.body), findsOneWidget,
            reason: '条目正文「${point.title}」没有渲染出来');
      }

      final zeroTolerance = kContentPolicyPoints
          .firstWhere((p) => p.body.contains('零容忍') || p.title.contains('零容忍'));
      expect(find.text(zeroTolerance.body), findsOneWidget);

      final within24h =
          kContentPolicyPoints.firstWhere((p) => p.body.contains('24 小时'));
      expect(find.text(within24h.body), findsOneWidget);
    });

    test('同意会落盘:重新 load 之后仍然算已同意', () async {
      final store = await ConsentStore.load();
      expect(store.accepted, isFalse);
      await store.accept();
      expect(store.acceptedVersion, ConsentStore.currentPolicyVersion);

      final reloaded = await ConsentStore.load();
      expect(reloaded.accepted, isTrue);
      expect(reloaded.acceptedVersion, ConsentStore.currentPolicyVersion);
    });

    test('撤回同意之后,门会重新拦住', () async {
      final store = await ConsentStore.load();
      await store.accept();
      await store.revoke();
      expect(store.accepted, isFalse);

      final reloaded = await ConsentStore.load();
      expect(reloaded.accepted, isFalse);
    });
  });

  group('已屏蔽的人', () {
    /// 屏蔽名单会变,入口 tile 要跟着变 —— 用 ListenableBuilder 包一层,
    /// 和 settings_sheet.dart 里的用法一致。
    Widget host(BlockStore blocks) => _app(
          Scaffold(
            body: ListenableBuilder(
              listenable: blocks,
              builder: (context, _) => BlockedUsersSection(blocks: blocks),
            ),
          ),
        );

    /// 只在弹出的面板内部查找。
    ///
    /// 入口 tile 和面板同时挂在树上,且两边的文案刻意有重合(标题都是
    /// 「已屏蔽的人」,副标题与空状态都以「还没有屏蔽任何人」开头)——
    /// 不限定范围的 finder 会同时命中两处。
    Finder inSheet(Finder matching) => find.descendant(
          of: find.byType(BottomSheet),
          matching: matching,
        );

    /// 打开面板。入口 tile 的标题与面板表头同名,故按类型点 ListTile。
    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.byType(BlockedUsersSection));
      await tester.pumpAndSettle();
    }

    testWidgets('一个人都没屏蔽时,显示空状态', (tester) async {
      final blocks = await BlockStore.load();
      await tester.pumpWidget(host(blocks));

      // 入口 tile 自己的样子
      expect(find.text('已屏蔽的人'), findsOneWidget);
      expect(find.text('还没有屏蔽任何人'), findsOneWidget);

      await openSheet(tester);

      // 面板里要说清楚怎么屏蔽一个人;整句精确匹配,不用子串
      expect(inSheet(find.text(kBlockedUsersEmptyHint)), findsOneWidget);
      // 空名单时不该出现任何「解除」入口
      expect(inSheet(find.text('解除')), findsNothing);
      expect(inSheet(find.text('全部解除')), findsNothing);
    });

    testWidgets('屏蔽之后,名单里出现对方的 ID', (tester) async {
      final blocks = await BlockStore.load();
      await tester.pumpWidget(host(blocks));

      await blocks.block('u_x');
      await tester.pumpAndSettle();

      expect(find.text('共 1 人'), findsOneWidget);

      await openSheet(tester);

      // 存的是稳定 id 而不是昵称,列表里也如实显示 id
      expect(inSheet(find.text('u_x')), findsOneWidget);
      // 空状态该让位了
      expect(inSheet(find.text(kBlockedUsersEmptyHint)), findsNothing);
    });

    testWidgets('点「解除」把人从名单里拿掉', (tester) async {
      final blocks = await BlockStore.load();
      await blocks.block('u_x');
      await tester.pumpWidget(host(blocks));

      await openSheet(tester);
      expect(inSheet(find.text('u_x')), findsOneWidget);

      await tester.tap(inSheet(find.widgetWithText(TextButton, '解除')));
      await tester.pumpAndSettle();

      // 落到 store 上
      expect(blocks.isBlocked('u_x'), isFalse);
      expect(blocks.count, 0);
      // 面板里那一行真的没了,并且换成了空状态整句
      expect(inSheet(find.text('u_x')), findsNothing);
      expect(inSheet(find.text(kBlockedUsersEmptyHint)), findsOneWidget);
      // 入口 tile 的副标题也跟着回到零
      expect(find.text('还没有屏蔽任何人'), findsOneWidget);
    });
  });
}
