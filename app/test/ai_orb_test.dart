// AI 座位光球:四种状态的 key / 状态字 / 读屏;降低动效下停帧、pumpAndSettle 不挂;
// 紧凑 / 小号尺寸、深浅两套主题都不溢出。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/state/ai_state.dart';
import 'package:lares_app/src/state/models.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/ui/widgets/ai_orb.dart';
import 'package:lares_app/src/ui/widgets/avatar_orb.dart';

import 'helpers/localized_app.dart';

const _ai = Member(userId: 'u_ai_1', name: '小助手', status: MemberStatus.free);

Widget _seat(
  AiActivity? a, {
  bool reduce = false,
  ThemeData? theme,
  double size = 88,
  bool compact = false,
  bool speaking = false,
}) =>
    localizedApp(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
          child: Scaffold(
            body: Center(
              child: AvatarOrb(
                member: _ai,
                speaking: speaking,
                muted: false,
                size: size,
                compact: compact,
                aiActivity: a,
              ),
            ),
          ),
        ),
      ),
      theme: theme,
    );

void main() {
  const labels = {
    AiActivity.idle: '等你叫它',
    AiActivity.listening: '在听',
    AiActivity.thinking: '在想…',
    AiActivity.speaking: '在说话',
  };

  for (final a in AiActivity.values) {
    testWidgets('${a.name}:key、状态字、读屏', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_seat(a));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(ValueKey('ai-orb-${a.name}')), findsOneWidget);
      for (final other in AiActivity.values.where((o) => o != a)) {
        expect(find.byKey(ValueKey('ai-orb-${other.name}')), findsNothing);
      }
      expect(find.byKey(ValueKey('ai-orb-status-${a.name}')), findsOneWidget);
      expect(find.text(labels[a]!), findsOneWidget);
      expect(find.byKey(const ValueKey('seat-ai-badge')), findsOneWidget);
      expect(find.bySemanticsLabel('小助手,AI 助手,${labels[a]}'), findsOneWidget);
      // 没有首字母:AI 座位是一团光,不是「小」字
      expect(find.text('小'), findsNothing);
      handle.dispose();
    });
  }

  testWidgets('没传状态:按 speaking 推断', (tester) async {
    await tester.pumpWidget(_seat(null, speaking: true));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('ai-orb-speaking')), findsOneWidget);
    await tester.pumpWidget(_seat(null));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('ai-orb-listening')), findsOneWidget);
  });

  testWidgets('降低动效:四种状态都能 pumpAndSettle', (tester) async {
    for (final a in AiActivity.values) {
      await tester.pumpWidget(_seat(a, reduce: true));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('ai-orb-${a.name}')), findsOneWidget);
    }
  });

  testWidgets('idle 静止:不降低动效也能 pumpAndSettle', (tester) async {
    await tester.pumpWidget(_seat(AiActivity.idle));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-orb-idle')), findsOneWidget);
  });

  testWidgets('状态切换:动画跟着换,不留旧 key', (tester) async {
    await tester.pumpWidget(_seat(AiActivity.listening));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(_seat(AiActivity.thinking));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('ai-orb-thinking')), findsOneWidget);
    await tester.pumpWidget(_seat(AiActivity.idle));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-orb-idle')), findsOneWidget);
  });

  for (final (name, theme) in [
    ('深色', LaresTheme.dark()),
    ('浅色', LaresTheme.light()),
  ]) {
    testWidgets('$name主题 + 紧凑 / 小号:不溢出', (tester) async {
      tester.view
        ..physicalSize = const Size(360, 640)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final a in AiActivity.values) {
        for (final (size, compact) in [(88.0, false), (56.0, true), (40.0, true)]) {
          await tester.pumpWidget(
              _seat(a, theme: theme, size: size, compact: compact, reduce: true));
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
      }
    });
  }

  testWidgets('AiOrbMini:静态,有星芒', (tester) async {
    await tester.pumpWidget(localizedScaffold(
        const Row(children: [AiOrbMini(size: 28), AiOrbMini(size: 28, dim: true)])));
    await tester.pumpAndSettle();
    expect(find.byIcon(kAiGlyph), findsNWidgets(2));
  });
}
