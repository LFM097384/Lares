// 实时字幕 UI:面板、横幅、按钮(假通道 + 假识别器)。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/captions/caption_controller.dart';
import 'package:lares_app/src/ui/caption_panel.dart';

import 'helpers/caption_fakes.dart';
import 'helpers/localized_app.dart';

void main() {
  late FakeChannel ch;
  late FakeTap tap;
  late CaptionController captions;
  late List<FakeTranscriber> stts;

  setUp(() {
    ch = FakeChannel();
    tap = FakeTap();
    stts = [];
    captions = CaptionController(
      transcriberFactory: ({
        required onPartial,
        required onFinal,
        required onFatal,
      }) {
        final t = FakeTranscriber(onPartial, onFinal, onFatal);
        stts.add(t);
        return t;
      },
      nameOf: (id) => const {'u1': '小明', 'u2': '阿花'}[id] ?? id,
    );
    captions.bindSession(ch, tap);
    captions.updateConditions(const CaptionConditions(
        available: true, inRoom: true, muted: false, provide: true));
  });
  tearDown(() => captions.dispose());

  Widget app() => localizedScaffold(Column(children: [
        CaptionToggleButton(captions: captions, available: true),
        CaptionProvidingBanner(captions: captions),
        CaptionPanel(captions: captions),
      ]));

  void cap(String from, String id, int seq, String text, bool fin) =>
      ch.receive(from, {'t': 'cap', 'id': id, 'seq': seq, 'text': text, 'final': fin});

  testWidgets('按钮切换面板;字幕带名字,partial 淡色原地替换', (tester) async {
    ch.join('u1', mic: true);
    ch.join('u2', mic: true);
    await tester.pumpWidget(app());
    expect(find.byKey(const ValueKey('caption-panel')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('captions-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('caption-panel')), findsOneWidget);
    expect(find.text('有人说话时,文字会出现在这里'), findsOneWidget);
    expect(ch.sentOfType('capreq').last['on'], isTrue);
    // 两人都开着麦但没表态
    expect(find.text('小明、阿花 未开启字幕'), findsOneWidget);

    ch.receive('u1', {'t': 'capack', 'on': true});
    cap('u1', 'a', 1, '今天', false);
    await tester.pump();
    expect(find.text('小明 正在提供字幕'), findsOneWidget);
    expect(find.text('阿花 未开启字幕'), findsOneWidget);
    final key = find.byKey(const ValueKey('cap-u1-a'));
    expect(key, findsOneWidget);
    String textOf() => (tester.widget<Text>(key).textSpan!).toPlainText();
    expect(textOf(), '小明: 今天');
    Color? bodyColor() => ((tester.widget<Text>(key).textSpan! as TextSpan)
            .children![1] as TextSpan)
        .style
        ?.color;
    final partialColor = bodyColor();

    cap('u1', 'a', 2, '今天天气不错。', true);
    await tester.pump();
    expect(find.byKey(const ValueKey('cap-u1-a')), findsOneWidget,
        reason: '原地替换,不新增一行');
    expect(textOf(), '小明: 今天天气不错。');
    expect(bodyColor(), isNot(partialColor), reason: '定稿不再是淡色');

    // 关掉:面板消失,内容清空
    await tester.tap(find.byKey(const ValueKey('captions-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('caption-panel')), findsNothing);
    expect(captions.lines, isEmpty);
  });

  testWidgets('AI 助手不算「正在提供字幕」/「未开启字幕」;它的行带星芒、不用人名的余烬色',
      (tester) async {
    ch.join('u1', mic: true);
    ch.join('u_ai_c1', mic: true);
    await tester.pumpWidget(app());
    await captions.setWantCaptions(true);
    await tester.pump();
    // AI 开着麦、还没发字幕:不提示「未开启字幕」
    expect(find.text('小明 未开启字幕'), findsOneWidget);
    expect(captions.notProvidingNames, ['小明']);

    ch.receive('u1', {'t': 'capack', 'on': true});
    ch.receive('u_ai_c1', {'t': 'capack', 'on': true});
    cap('u1', 'a', 1, '今天', true);
    cap('u_ai_c1', 'x', 1, '我在', true);
    await tester.pump();
    expect(captions.providerNames, ['小明']);
    expect(find.text('小明 正在提供字幕'), findsOneWidget);
    expect(find.textContaining('u_ai_c1 正在提供字幕'), findsNothing);

    // AI 的行:有星芒;名字不是人名那种余烬色
    expect(find.byKey(const ValueKey('cap-ai-x')), findsOneWidget);
    Color? nameColor(String key) =>
        ((tester.widget<Text>(find.byKey(ValueKey(key))).textSpan! as TextSpan)
                .children!
                .whereType<TextSpan>()
                .first)
            .style
            ?.color;
    expect(nameColor('cap-u_ai_c1-x'), isNot(nameColor('cap-u1-a')));
    await captions.setWantCaptions(false);
    await tester.pump();
  });

  testWidgets('自动滚到底;用户往上翻后不再抢滚动', (tester) async {
    await tester.pumpWidget(app());
    await captions.setWantCaptions(true);
    for (var i = 0; i < 25; i++) {
      cap('u1', 'i$i', i + 1, '这是第 $i 句比较长的字幕文字', true);
    }
    await tester.pump();
    await tester.pump();
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).last);
    final pos = scrollable.position;
    expect(pos.pixels, closeTo(pos.maxScrollExtent, 1));

    // 用户往上翻
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();
    final scrolledTo = pos.pixels;
    expect(scrolledTo, lessThan(pos.maxScrollExtent - 24));
    cap('u1', 'new', 99, '新的一句', true);
    await tester.pump();
    await tester.pump();
    expect(pos.pixels, closeTo(scrolledTo, 1), reason: '翻上去看的时候不跳');
    // 自字幕会为我开一个识别会话(含首帧看门狗计时器):关掉字幕收尾
    await captions.setWantCaptions(false);
    await tester.pump();
  });

  testWidgets('正在转写时显示横幅,点击 = 本次不再生成', (tester) async {
    await tester.pumpWidget(app());
    expect(find.byKey(const ValueKey('captions-banner')), findsNothing);
    ch.remotes.add('u1');
    ch.receive('u1', {'t': 'capreq', 'on': true});
    await tester.pump();
    expect(find.text('正在为 小明 生成字幕 · 语音经阿里云识别'), findsOneWidget);
    tap.frame(Uint8List(320).length);

    await tester.tap(find.byKey(const ValueKey('captions-banner')));
    await tester.pump();
    expect(stts.single.stopped, isTrue);
    expect(find.byKey(const ValueKey('captions-banner')), findsNothing);
    expect(find.text('这次不再为别人生成字幕,下次进圈恢复'), findsOneWidget);
  });

  testWidgets('服务器没配字幕 → 没有按钮', (tester) async {
    await pumpLocalized(
        tester, CaptionToggleButton(captions: captions, available: false));
    expect(find.byKey(const ValueKey('captions-toggle')), findsNothing);
  });
}
