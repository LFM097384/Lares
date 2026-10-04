import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/moderation/block_store.dart';
import 'package:lares_app/src/state/identity.dart';
import 'package:lares_app/src/state/models.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/ui/room_screen.dart';
import 'package:lares_app/src/ui/widgets/avatar_orb.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/localized_app.dart';
import 'support/fake_room.dart';

/// 成员资料:点自己改资料、点别人看资料、member_updated 刷新座位、
/// 圈主才有「移出圈子」、AI 座位保持说明卡。
///
/// ⚠️ 不能 pumpAndSettle:房间背景的呼吸动画永远停不下来。
/// controller 在用例体内收(join 挂着 25 秒超时,addTearDown 来不及)。

Future<void> _pumpSheet(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

({RoomController controller, FakeSignalingClient signaling}) _room({
  List<Map<String, dynamic>>? extra,
}) {
  final FakeSignalingClient signaling = FakeSignalingClient();
  final RoomController controller = RoomController(
    signaling: signaling,
    rtc: FakeRtcService(),
    userId: 'u_me',
    deviceId: 'd_1',
    userName: '我',
  );
  unawaited(controller.join('home').catchError((Object _) {}));
  signaling.testInject(<String, dynamic>{
    't': 'room',
    'circleId': 'home',
    'members': <Map<String, dynamic>>[
      <String, dynamic>{'userId': 'u_me', 'name': '我', 'status': 'free'},
      <String, dynamic>{
        'userId': 'u_other',
        'name': '阿蛮',
        'status': 'busy',
        'bio': '在赶论文',
      },
      ...?extra,
    ],
  });
  return (controller: controller, signaling: signaling);
}

Future<void> _pumpRoom(
  WidgetTester tester,
  RoomController controller, {
  BlockStore? blocks,
}) async {
  await tester.pumpWidget(
    localizedApp(
      RoomScreen(
        controller: controller,
        circleName: '我们的圈',
        blocks: blocks,
      ),
      theme: LaresTheme.dark(),
    ),
  );
  await _pumpSheet(tester);
}

Future<void> _dispose(WidgetTester tester, RoomController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
}

Finder _orbOf(String userId) => find.byWidgetPredicate(
      (Widget w) => w is AvatarOrb && w.member.userId == userId,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('Member.fromWire 的资料字段', () {
    test('emoji / bio / joinedAt 读得进来', () {
      final Member m = Member.fromWire(<String, dynamic>{
        'userId': 'u_a',
        'name': '小林',
        'status': 'free',
        'emoji': '🦊',
        'bio': '在赶论文',
        'joinedAt': 1700000000000,
      });
      expect(m.emoji, '🦊');
      expect(m.bio, '在赶论文');
      expect(m.joinedAt, 1700000000000);
    });

    test('老服务器不带 / 空串:一律当没设', () {
      final Member m = Member.fromWire(<String, dynamic>{
        'userId': 'u_a',
        'name': '小林',
        'emoji': '',
      });
      expect(m.emoji, isNull);
      expect(m.bio, isNull);
      expect(m.joinedAt, isNull);
    });
  });

  group('controller', () {
    test('只改状态不会把 emoji / 签名抹掉;快照没带就是清掉了', () async {
      final r = _room();
      final RoomController c = r.controller;
      await Future<void>.delayed(Duration.zero);
      r.signaling.testInject(<String, dynamic>{
        't': 'member_updated',
        'circleId': 'home',
        'member': <String, dynamic>{
          'userId': 'u_other',
          'name': '阿蛮',
          'status': 'busy',
          'emoji': '🐱',
          'bio': '在赶论文',
          'joinedAt': 1700000000000,
        },
      });
      await Future<void>.delayed(Duration.zero);
      r.signaling.testInject(<String, dynamic>{
        't': 'member_status',
        'circleId': 'home',
        'userId': 'u_other',
        'status': 'ears',
      });
      await Future<void>.delayed(Duration.zero);
      Member other = c.members.firstWhere((Member m) => m.userId == 'u_other');
      expect(other.status, MemberStatus.ears);
      expect(other.emoji, '🐱');
      expect(other.bio, '在赶论文');
      expect(other.joinedAt, 1700000000000);

      r.signaling.testInject(<String, dynamic>{
        't': 'member_updated',
        'circleId': 'home',
        'member': <String, dynamic>{
          'userId': 'u_other',
          'name': '阿蛮',
          'status': 'ears',
        },
      });
      await Future<void>.delayed(Duration.zero);
      other = c.members.firstWhere((Member m) => m.userId == 'u_other');
      expect(other.emoji, isNull);
      expect(other.bio, isNull);
      // 进房时刻不会因为一帧没带就丢
      expect(other.joinedAt, 1700000000000);
      c.dispose();
    });

    test('setProfile:没变不发;名字没变不补发老的 profile 帧', () async {
      final r = _room();
      final RoomController c = r.controller;
      await Future<void>.delayed(Duration.zero);
      r.signaling.sent.clear();
      c.setProfile(name: '我', emoji: '', bio: '');
      expect(r.signaling.sent, isEmpty);

      c.setProfile(emoji: '🔥');
      expect(r.signaling.sent.map((m) => m['t']), <String>['profile_set']);
      expect(r.signaling.sent.single['emoji'], '🔥');

      r.signaling.testInject(<String, dynamic>{
        't': 'profile_error',
        'reason': 'rate_limited',
        'retryMs': 4200,
      });
      await Future<void>.delayed(Duration.zero);
      expect(c.profileError.value?.reason, 'rate_limited');
      expect(c.profileError.value?.retryMs, 4200);
      c.dispose();
    });
  });

  group('profile_error invalid', () {
    test('退回最近一次被认过的资料:内存、座位、落盘都退', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'lares.name': '我',
      });
      final r = _room();
      final RoomController c = r.controller;
      await Future<void>.delayed(Duration.zero);

      // 第一次改:服务器认了(并把签名清洗了一下)
      c.setProfile(emoji: '🌙', bio: '晚上在 ');
      r.signaling.testInject(<String, dynamic>{
        't': 'profile_ok',
        'name': '我',
        'emoji': '🌙',
        'bio': '晚上在',
      });
      await Future<void>.delayed(Duration.zero);

      // 第二次改:被拒
      c.setProfile(name: '小林', emoji: '🔥', bio: '不合规');
      await Identity.saveName('小林');
      await Identity.saveProfile(emoji: '🔥', bio: '不合规');
      r.signaling.testInject(<String, dynamic>{
        't': 'profile_error',
        'reason': 'invalid',
      });
      await Future<void>.delayed(Duration.zero);

      expect(c.userName, '我');
      expect(c.myEmoji, '🌙');
      expect(c.myBio, '晚上在');
      final Member me = c.members.firstWhere((Member m) => m.userId == 'u_me');
      expect(me.name, '我');
      expect(me.emoji, '🌙');
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lares.name'), '我');
      expect(prefs.getString('lares.emoji'), '🌙');
      expect(prefs.getString('lares.bio'), '晚上在');
      c.dispose();
    });

    test('还没被认过:退回到这次改之前', () async {
      final r = _room();
      final RoomController c = r.controller;
      await Future<void>.delayed(Duration.zero);
      c.setProfile(emoji: '🔥', bio: 'x');
      c.setProfile(bio: 'y');
      r.signaling.testInject(<String, dynamic>{
        't': 'profile_error',
        'reason': 'invalid',
      });
      await Future<void>.delayed(Duration.zero);
      expect(c.myEmoji, isNull);
      expect(c.myBio, isNull);
      expect(c.userName, '我');
      c.dispose();
    });

    test('rate_limited 不退', () async {
      final r = _room();
      final RoomController c = r.controller;
      await Future<void>.delayed(Duration.zero);
      c.setProfile(emoji: '🔥');
      r.signaling.testInject(<String, dynamic>{
        't': 'profile_error',
        'reason': 'rate_limited',
        'retryMs': 3000,
      });
      await Future<void>.delayed(Duration.zero);
      expect(c.myEmoji, '🔥');
      c.dispose();
    });
  });

  group('资料面板', () {
    testWidgets('点自己的头像:改资料、存下,发 profile_set,座位跟着变',
        (WidgetTester tester) async {
      final r = _room();
      final RoomController c = r.controller;
      await _pumpRoom(tester, c);

      await tester.tap(_orbOf('u_me'));
      await _pumpSheet(tester);
      expect(find.byKey(const ValueKey('profile-own-sheet')), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('profile-name-field')), '小林');
      await tester.ensureVisible(find.byKey(const ValueKey('profile-emoji-🦊')));
      await tester.tap(find.byKey(const ValueKey('profile-emoji-🦊')));
      await tester.pump();
      await tester.enterText(
          find.byKey(const ValueKey('profile-bio-field')), '在赶论文');
      await tester.pump();
      expect(find.text('4/40'), findsOneWidget);

      r.signaling.sent.clear();
      await tester.ensureVisible(find.byKey(const ValueKey('profile-save')));
      await tester.tap(find.byKey(const ValueKey('profile-save')));
      await _pumpSheet(tester);
      await _pumpSheet(tester);

      final Map<String, dynamic> set = r.signaling.sent
          .firstWhere((Map<String, dynamic> m) => m['t'] == 'profile_set');
      expect(set['name'], '小林');
      expect(set['emoji'], '🦊');
      expect(set['bio'], '在赶论文');
      // 名字变了:老服务器也得改得了名
      expect(
        r.signaling.sent.where((Map<String, dynamic> m) => m['t'] == 'profile'),
        hasLength(1),
      );

      expect(find.byKey(const ValueKey('profile-own-sheet')), findsNothing);
      final AvatarOrb mine = tester.widget<AvatarOrb>(_orbOf('u_me'));
      expect(mine.member.name, '小林');
      expect(mine.member.emoji, '🦊');
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lares.emoji'), '🦊');
      expect(prefs.getString('lares.bio'), '在赶论文');
      await _dispose(tester, c);
    });

    testWidgets('member_updated:别人的座位换了名字和 emoji', (WidgetTester tester) async {
      final r = _room();
      final RoomController c = r.controller;
      await _pumpRoom(tester, c);

      r.signaling.testInject(<String, dynamic>{
        't': 'member_updated',
        'circleId': 'home',
        'member': <String, dynamic>{
          'userId': 'u_other',
          'name': '阿蛮蛮',
          'status': 'busy',
          'emoji': '🐼',
        },
      });
      await _pumpSheet(tester);
      final AvatarOrb orb = tester.widget<AvatarOrb>(_orbOf('u_other'));
      expect(orb.member.name, '阿蛮蛮');
      expect(orb.member.emoji, '🐼');
      expect(find.text('🐼'), findsWidgets);
      await _dispose(tester, c);
    });

    testWidgets('点别人的头像:看到名字和一句话', (WidgetTester tester) async {
      final r = _room();
      final RoomController c = r.controller;
      await _pumpRoom(tester, c, blocks: await BlockStore.load());

      await tester.tap(_orbOf('u_other'));
      await _pumpSheet(tester);
      final Finder sheet = find.byKey(const ValueKey('profile-other-sheet'));
      expect(sheet, findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('阿蛮')),
          findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('在赶论文')),
          findsOneWidget);
      // 房间没开聊天:不出 @Ta
      expect(find.byKey(const ValueKey('profile-mention')), findsNothing);
      expect(find.text('屏蔽这个人'), findsOneWidget);
      await _dispose(tester, c);
    });

    testWidgets('env 圈:有「移出圈子」,取消是「算了」,确认才发 kick',
        (WidgetTester tester) async {
      final r = _room();
      final RoomController c = r.controller;
      await _pumpRoom(tester, c);

      await tester.tap(_orbOf('u_other'));
      await _pumpSheet(tester);
      final Finder kick = find.byKey(const ValueKey('profile-kick'));
      expect(kick, findsOneWidget);

      await tester.ensureVisible(kick);
      await tester.tap(kick);
      await _pumpSheet(tester);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('profile-kick-cancel')),
          matching: find.text('算了'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('profile-kick-cancel')));
      await _pumpSheet(tester);
      expect(r.signaling.sent.where((m) => m['t'] == 'kick'), isEmpty);

      await tester.tap(_orbOf('u_other'));
      await _pumpSheet(tester);
      await tester.ensureVisible(kick);
      await tester.tap(kick);
      await _pumpSheet(tester);
      await tester.tap(find.byKey(const ValueKey('profile-kick-confirm')));
      await _pumpSheet(tester);
      final Map<String, dynamic> sent =
          r.signaling.sent.firstWhere((m) => m['t'] == 'kick');
      expect(sent['userId'], 'u_other');
      await _dispose(tester, c);
    });

    testWidgets('注册圈里不是圈主:看不到「移出圈子」', (WidgetTester tester) async {
      final r = _room();
      final RoomController c = r.controller;
      c.circleInfo['home'] = (registered: true, e2ee: null, transcript: false);
      expect(c.canModerate('home'), isFalse);
      await _pumpRoom(tester, c, blocks: await BlockStore.load());

      await tester.tap(_orbOf('u_other'));
      await _pumpSheet(tester);
      expect(find.byKey(const ValueKey('profile-other-sheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('profile-kick')), findsNothing);
      await _dispose(tester, c);
    });

    testWidgets('「听不到 Ta」只改本机名单', (WidgetTester tester) async {
      final r = _room();
      final RoomController c = r.controller;
      await _pumpRoom(tester, c);
      await tester.tap(_orbOf('u_other'));
      await _pumpSheet(tester);
      r.signaling.sent.clear();
      await tester.tap(find.byKey(const ValueKey('profile-mute-for-me')));
      await _pumpSheet(tester);
      expect(c.isLocallyMuted('u_other'), isTrue);
      expect(find.text('重新听到 Ta'), findsOneWidget);
      // 不告诉任何人
      expect(r.signaling.sent, isEmpty);
      await _dispose(tester, c);
    });

    testWidgets('AI 座位:还是说明卡,不出资料面板', (WidgetTester tester) async {
      final r = _room(extra: <Map<String, dynamic>>[
        <String, dynamic>{'userId': 'u_ai_home', 'name': 'AI', 'status': 'free'},
      ]);
      final RoomController c = r.controller;
      await _pumpRoom(tester, c);

      await tester.tap(_orbOf('u_ai_home'));
      await _pumpSheet(tester);
      expect(find.byKey(const ValueKey('ai-hint-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('profile-other-sheet')), findsNothing);
      expect(find.byKey(const ValueKey('profile-own-sheet')), findsNothing);
      await _dispose(tester, c);
    });
  });
}
