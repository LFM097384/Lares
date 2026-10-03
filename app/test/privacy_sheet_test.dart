import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/net/secret_vault.dart';
import 'package:lares_app/src/privacy/privacy_gate.dart';
import 'package:lares_app/src/privacy/privacy_sheet.dart';
import 'package:lares_app/src/privacy/privacy_summary.dart';
import 'package:lares_app/src/state/models.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/state/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/localized_app.dart';
import 'support/fake_room.dart';

const _cid = 'c_aaaaaaaaaaaaaaaaaaaaaaaaaa';

Map<String, dynamic> _circle({
  bool transcript = false,
  bool? e2ee = false,
  bool focus = false,
  bool captions = true,
  List<Map<String, dynamic>> plugins = const [],
}) =>
    {
      't': 'circle_settings',
      'circle': {
        'id': _cid,
        'registered': true,
        'e2ee': e2ee,
        'transcript': transcript,
        'features': {
          'captions': captions,
          'transcript': transcript,
          'voiceNotes': true,
          'map': false,
          'recording': false,
          'plugins': true,
          'focus': focus,
          'p2p': false,
          'devTools': false,
        },
        'plugins': plugins,
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  debugUseInMemoryVault = true;
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('privacyHash', () {
    const base = CirclePrivacySummary(
      circleId: 'c',
      plugins: [
        PrivacyPlugin(id: 'b', name: 'B', permissions: ['y', 'x']),
        PrivacyPlugin(id: 'a', name: 'A', permissions: ['z']),
      ],
    );

    test('稳定:16 位 hex,插件顺序 / 权限顺序 / 插件名不影响', () {
      final h = base.privacyHash();
      expect(h, matches(RegExp(r'^[0-9a-f]{16}$')));
      const reordered = CirclePrivacySummary(
        circleId: 'other', // circleId 不进哈希
        plugins: [
          PrivacyPlugin(id: 'a', name: '改了名', permissions: ['z']),
          PrivacyPlugin(id: 'b', permissions: ['x', 'y']),
        ],
      );
      expect(reordered.privacyHash(), h);
      expect(base.privacyHash(), h);
    });

    test('每个输入都改变哈希', () {
      final h = base.privacyHash();
      CirclePrivacySummary w({
        bool transcript = false,
        bool? e2ee,
        bool captions = false,
        bool focus = false,
        bool recording = false,
        bool map = false,
        List<PrivacyPlugin>? plugins,
      }) =>
          CirclePrivacySummary(
            circleId: 'c',
            transcript: transcript,
            e2ee: e2ee,
            captions: captions,
            focus: focus,
            recording: recording,
            map: map,
            plugins: plugins ?? base.plugins,
          );
      final variants = [
        w(transcript: true),
        w(e2ee: true),
        w(e2ee: false),
        w(captions: true),
        w(focus: true),
        w(recording: true),
        w(map: true),
        w(plugins: const [PrivacyPlugin(id: 'a', permissions: ['z'])]),
        w(plugins: const [
          PrivacyPlugin(id: 'a', permissions: ['z', 'q']),
          PrivacyPlugin(id: 'b', permissions: ['x', 'y']),
        ]),
        w(plugins: const [
          PrivacyPlugin(id: 'a', permissions: ['z'], hasWebhook: true),
          PrivacyPlugin(id: 'b', permissions: ['x', 'y']),
        ]),
      ];
      expect(w().privacyHash(), h);
      final hashes = {for (final v in variants) v.privacyHash()};
      expect(hashes, hasLength(variants.length));
      expect(hashes, isNot(contains(h)));
    });
  });

  group('面板', () {
    testWidgets('示例摘要:各行齐全', (tester) async {
      await pumpLocalized(
        tester,
        CirclePrivacySheet(
          summary: CirclePrivacySummary.sample(),
          circleName: '自习室',
        ),
      );
      expect(find.text('本圈的隐私设置'), findsOneWidget);
      expect(find.text('自习室'), findsOneWidget);
      expect(find.byKey(const ValueKey('privacy-transcript')), findsOneWidget);
      expect(find.byKey(const ValueKey('privacy-captions')), findsOneWidget);
      expect(find.text('插件 2 个(专注学习、会议纪要)'), findsOneWidget);
      expect(find.textContaining('第三方'), findsOneWidget);
      expect(find.byKey(const ValueKey('privacy-focus')), findsOneWidget);
      expect(find.text('端到端加密:否'), findsOneWidget);
      expect(find.byKey(const ValueKey('privacy-nothing')), findsNothing);
      expect(find.text('知道了'), findsOneWidget);
      expect(find.text('完整隐私说明'), findsOneWidget);
    });

    testWidgets('什么都没开:一句安心话 + 加密行', (tester) async {
      await pumpLocalized(
        tester,
        const CirclePrivacySheet(
          summary: CirclePrivacySummary(circleId: 'c', e2ee: true),
          circleName: '',
        ),
      );
      expect(find.byKey(const ValueKey('privacy-nothing')), findsOneWidget);
      expect(find.text('端到端加密:是'), findsOneWidget);
      expect(find.byKey(const ValueKey('privacy-transcript')), findsNothing);
    });

    testWidgets('360×640 下放得下(英文)', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(localizedApp(
        Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => showCirclePrivacySheet(ctx,
                  summary: CirclePrivacySummary.sample(), circleName: 'Study'),
              child: const Text('open'),
            ),
          ),
        ),
        locale: const Locale('en'),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Privacy in this circle'), findsOneWidget);
      expect(find.textContaining('2 plugins'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('触发', () {
    late FakeSignalingClient signaling;
    late RoomController controller;
    late SettingsStore settings;

    Future<void> setUpGate(WidgetTester tester) async {
      settings = await SettingsStore.load(vault: InMemorySecretVault());
      signaling = FakeSignalingClient();
      controller = RoomController(
        signaling: signaling,
        rtc: FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
        settings: settings,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(localizedApp(
        CirclePrivacyGate(
          controller: controller,
          settings: settings,
          circleNameOf: (id) => id == _cid ? '自习室' : null,
          child: const Scaffold(body: SizedBox()),
        ),
      ));
    }

    Future<void> inject(WidgetTester tester, Map<String, dynamic> m) async {
      signaling.testInject(m);
      await tester.pump();
      await tester.pumpAndSettle();
    }

    void enterRoom() {
      controller.circleId = _cid;
      controller.phase = RoomPhase.inRoom;
    }

    testWidgets('首次进圈弹;知道了记 ack;再进同圈不弹;哈希变了再弹', (tester) async {
      await setUpGate(tester);
      // 没在任何圈里:有 info 也不弹
      await inject(tester, _circle());
      expect(find.text('本圈的隐私设置'), findsNothing);

      enterRoom();
      await inject(tester, _circle());
      expect(find.text('本圈的隐私设置'), findsOneWidget);
      expect(find.text('自习室'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.text('本圈的隐私设置'), findsNothing);
      final ack = settings.privacyAckFor(_cid);
      expect(ack, isNotNull);
      expect(
          (await SharedPreferences.getInstance())
              .getString('lares.privacyAck.$_cid'),
          ack);

      // 出房再进:同哈希不弹
      controller.phase = RoomPhase.idle;
      await inject(tester, _circle());
      enterRoom();
      await inject(tester, _circle());
      expect(find.text('本圈的隐私设置'), findsNothing);

      // 圈主开了转写(房内的 circle_settings):再弹
      await inject(tester, _circle(transcript: true));
      expect(find.text('本圈的隐私设置'), findsOneWidget);
      expect(find.byKey(const ValueKey('privacy-transcript')), findsOneWidget);
      // 划掉也算看过
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('本圈的隐私设置'), findsNothing);
      expect(settings.privacyAckFor(_cid), isNot(ack));
      await inject(tester, _circle(transcript: true));
      expect(find.text('本圈的隐私设置'), findsNothing);
    });

    testWidgets('新服务器:插件权限视图没到之前不弹', (tester) async {
      await setUpGate(tester);
      enterRoom();
      // circle_summary 带 features 但不带插件权限
      await inject(tester, {
        't': 'circle_summary',
        'circleId': _cid,
        'count': 1,
        'registered': true,
        'e2ee': false,
        'transcript': false,
        'features': _circle()['circle']['features'],
      });
      expect(find.text('本圈的隐私设置'), findsNothing);
      await inject(tester, _circle(plugins: [
        {
          'id': 'x.notes',
          'name': '纪要',
          'enabled': true,
          'permissions': ['transcript.read'],
          'hasWebhook': true,
        },
      ]));
      expect(find.text('本圈的隐私设置'), findsOneWidget);
      expect(find.textContaining('插件 1 个'), findsOneWidget);
    });

    testWidgets('圈主不弹,但静默记 ack', (tester) async {
      await setUpGate(tester);
      await settings.saveOwnerKey(_cid, 'k' * 64);
      enterRoom();
      await inject(tester, _circle(transcript: true));
      expect(find.text('本圈的隐私设置'), findsNothing);
      expect(settings.privacyAckFor(_cid), isNotNull);
    });

    testWidgets('移除圈子时清掉 ack', (tester) async {
      await setUpGate(tester);
      await settings.setPrivacyAck(_cid, 'abc');
      expect(settings.privacyAckFor(_cid), 'abc');
      await settings.forgetCircleSecrets(_cid);
      expect(settings.privacyAckFor(_cid), isNull);
      expect(
          (await SharedPreferences.getInstance())
              .getString('lares.privacyAck.$_cid'),
          isNull);
    });
  });

  test('buildCirclePrivacySummary:字幕要服务器也配了;插件名不进哈希', () async {
    final sig = FakeSignalingClient();
    final c = RoomController(
      signaling: sig,
      rtc: FakeRtcService(),
      userId: 'u',
      deviceId: 'd',
      userName: 'n',
    );
    addTearDown(c.dispose);
    expect(privacyInfoKnown(c, _cid), isFalse);
    sig.testInject({'t': 'welcome', 'userId': 'u', 'captions': false});
    sig.testInject(_circle(focus: true, plugins: [
      {'id': 'z', 'enabled': true, 'permissions': ['b', 'a']},
      {'id': 'y', 'enabled': false, 'permissions': <String>[]},
    ]));
    await pumpEventQueue();
    expect(privacyInfoKnown(c, _cid), isTrue);
    var s = buildCirclePrivacySummary(c, _cid);
    expect(s.captions, isFalse, reason: '服务器没配字幕');
    expect(s.focus, isTrue);
    expect(s.e2ee, isFalse);
    expect(s.plugins.map((p) => p.id), ['z'], reason: '停用的插件不算');
    expect(s.plugins.single.permissions, ['a', 'b']);
    final named = buildCirclePrivacySummary(c, _cid, pluginNames: {'z': 'Zed'});
    expect(named.plugins.single.displayName, 'Zed');
    expect(named.privacyHash(), s.privacyHash());

    sig.testInject({'t': 'welcome', 'userId': 'u', 'captions': true});
    await pumpEventQueue();
    s = buildCirclePrivacySummary(c, _cid);
    expect(s.captions, isTrue);
  });
}
