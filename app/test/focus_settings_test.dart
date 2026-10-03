import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/focus/focus_models.dart';
import 'package:lares_app/src/focus/focus_settings.dart';
import 'package:lares_app/src/theme/theme.dart';

import 'helpers/localized_app.dart';

void main() {
  testWidgets('设置面板:改开关后才能存,存出完整 JSON', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Map<String, dynamic>? saved;
    await tester.pumpWidget(
      localizedApp(
        Scaffold(
          body: SingleChildScrollView(
            child: Builder(
              builder: (context) => buildFocusSettings(
                context,
                circleId: 'c1',
                config: const {'focusMin': 50, 'graceSec': 30},
                onSave: (c) => saved = c,
              ),
            ),
          ),
        ),
        theme: LaresTheme.dark(),
      ),
    );

    expect(find.text('50 分钟'), findsOneWidget);
    expect(find.text('30 秒'), findsOneWidget);
    expect(find.text('4 轮'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final save = find.byKey(const ValueKey('focus-settings-save'));
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('focus-settings-membersCanStart')));
    await tester.pump();
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pump();

    expect(saved, isNotNull);
    expect(FocusConfig.fromJson(saved), isA<FocusConfig>());
    expect(saved!['focusMin'], 50);
    expect(saved!['graceSec'], 30);
    expect(saved!['membersCanStart'], true);
    // chatInBreak 已废弃:设置里没有这个开关,保存时也不再带它
    expect(saved!.containsKey('chatInBreak'), isFalse);
    expect(find.byKey(const ValueKey('focus-settings-chatInBreak')), findsNothing);
    expect(saved!['breakMin'], 5);
  });

  testWidgets('FocusSettingsPanel:越界配置被夹紧显示', (tester) async {
    FocusConfig? saved;
    await tester.pumpWidget(
      localizedApp(
        Scaffold(
          body: SingleChildScrollView(
            child: FocusSettingsPanel(
              config: FocusConfig.fromJson(const {'rounds': 99}),
              onSave: (c) => saved = c,
            ),
          ),
        ),
        theme: LaresTheme.dark(),
      ),
    );
    expect(find.text('12 轮'), findsOneWidget);
    expect(saved, isNull);
  });
}
