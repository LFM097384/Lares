import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/l10n/gen/app_localizations.dart';
import 'package:lares_app/src/auth/auth_credential.dart';
import 'package:lares_app/src/auth/auth_verifier.dart';
import 'package:lares_app/src/auth/circle_identity.dart';
import 'package:lares_app/src/auth/wordlist_bip39.dart';
import 'package:lares_app/src/e2ee/e2ee_controller.dart';
import 'package:lares_app/src/e2ee/e2ee_store.dart';
import 'package:lares_app/src/net/secret_vault.dart';
import 'package:lares_app/src/net/signaling_client.dart';
import 'package:lares_app/src/state/circle_store.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/state/settings_store.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/ui/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/localized_app.dart';
import 'signaling_auth_test.dart' show FakeTransport, challenge, sayHello;
import 'support/fake_room.dart';

/// 注册圈 / 圈主权限的客户端测试。
///
/// 三件事分三组:随机物(id、口令)够不够随机;信令层「待登记 → 拿到钥匙 → 清标记」
/// 的顺序对不对;界面上非圈主是不是**真的看不到**圈主控件。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  debugUseInMemoryVault = true;
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('圈子 id 与默认口令', () {
    test('id 是 c_ + 26 位 base32,满足服务端 ^c_[a-z0-9]{16,64}\$', () {
      final re = RegExp(r'^c_[a-z2-7]{26}$');
      for (var i = 0; i < 200; i++) {
        expect(generateCircleId(), matches(re));
      }
    });

    test('1000 个 id 两两不同,且每一位都在变(不是时间戳那种前缀固定)', () {
      final ids = {for (var i = 0; i < 1000; i++) generateCircleId()};
      expect(ids, hasLength(1000));
      // 每个位置上出现过的字符数:128 bit 随机下每位都该有很多种
      for (var pos = 2; pos < 27; pos++) {
        final chars = {for (final id in ids) id[pos]};
        expect(chars.length, greaterThan(16), reason: '第 $pos 位几乎不变');
      }
    });

    test('同一种子复现同一 id:实现确实只取了 16 字节随机', () {
      expect(generateCircleId(Random(7)), generateCircleId(Random(7)));
      expect(generateCircleId(Random(7)), isNot(generateCircleId(Random(8))));
    });

    test('默认口令是 4 个 BIP39 词,且过得了 8 字符下限', () {
      expect(kBip39English, hasLength(2048));
      for (var i = 0; i < 100; i++) {
        final p = generateCirclePasscode();
        final words = p.split('-');
        expect(words, hasLength(4));
        for (final w in words) {
          expect(kBip39English, contains(w));
        }
        expect(isAcceptableCirclePasscode(p), isTrue);
      }
    });

    test('圈主钥匙:本机生成的 32 字节随机数,64 位小写 hex,两两不同', () {
      final keys = {for (var i = 0; i < 500; i++) generateOwnerKey()};
      expect(keys, hasLength(500));
      for (final k in keys) {
        expect(k, matches(RegExp(r'^[0-9a-f]{64}$')));
      }
      // sha256 与服务端 createHash('sha256').update(key).digest('hex') 一致
      expect(AuthProof.sha256Hex('abc'),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });

    test('8 字符下限', () {
      expect(isAcceptableCirclePasscode('1234567'), isFalse);
      expect(isAcceptableCirclePasscode('12345678'), isTrue);
      expect(isAcceptableCirclePasscode('   abc   '), isFalse);
    });
  });

  group('verifier 缓存', () {
    test('按口令指纹存:换口令后旧值自然失效', () async {
      var calls = 0;
      final vault = InMemorySecretVault();
      Future<String> fakeDerive(
          {required String passcode, required String circleId}) async {
        calls++;
        return deriveAuthVerifier(passcode: passcode, circleId: circleId);
      }

      final a = AuthVerifierCache(vault: vault, deriver: fakeDerive);
      final v1 = await a.get('c_x', 'old-passcode');
      expect(await a.get('c_x', 'old-passcode'), v1);
      expect(calls, 1, reason: '同一口令只算一次 Argon2');

      // 新进程(内存缓存空)从 vault 读回,不重算
      final b = AuthVerifierCache(vault: vault, deriver: fakeDerive);
      expect(await b.get('c_x', 'old-passcode'), v1);
      expect(calls, 1);

      final v2 = await b.get('c_x', 'new-passcode');
      expect(v2, isNot(v1));
      expect(calls, 2, reason: '口令变了必须重算,不能拿旧 verifier 去证明');
    });

    test('⚠️ fakeAsync 下 get() 能完成(回归:whenComplete 自己等自己)', () {
      fakeAsync((async) {
        String? got;
        AuthVerifierCache().get('home', 'p').then((v) => got = v);
        async.flushMicrotasks();
        expect(got, isNotNull);
      });
    });
  });

  group('信令:本机生成钥匙 → 登记只报 ownerHash → 清标记', () {
    const cid = 'c_newcircle0000000000000000';
    const pass = 'river-maple-quiet-lamp';
    final key = 'ab' * 32;

    SignalingClient mk(FakeTransport t, bool Function() pending,
        void Function(String) settled) {
      final c = SignalingClient(
        url: 'wss://x/ws',
        connector: t.connect,
        credentials: () =>
            const AuthCredential(mode: AuthMode.circle, passcode: pass),
        userId: 'u_me',
        circleHints: (id) => (register: pending(), ownerKey: key),
      );
      c.onRegistrationSettled = settled;
      c.authCircleId = cid;
      return c;
    }

    test('hello 带 register{verifier, ownerHash=sha256(ownerKey)} 与 ownerKey;明文钥匙不进 register',
        () {
      fakeAsync((async) {
        final t = FakeTransport();
        var pending = true;
        final settled = <String>[];
        final c = mk(t, () => pending, (id) {
          settled.add(id);
          pending = false;
        });
        c.connect();
        sayHello(c);
        t.last.serverSend(challenge('a' * 32));
        async.flushMicrotasks();

        final auth = t.last.sentOfType('hello').single['auth'] as Map;
        expect(auth['v'], 2);
        expect(auth['register'], {
          'verifier': deriveAuthVerifier(passcode: pass, circleId: cid),
          'ownerHash': sha256.convert(utf8.encode(key)).toString(),
        });
        expect((auth['register'] as Map).values, isNot(contains(key)));
        expect(auth['ownerKey'], key);

        // 新服务器的 welcome:created + isOwner,不带 ownerKey
        t.last.serverSend({
          't': 'welcome',
          'userId': 'u_me',
          'circle': {'id': cid, 'registered': true, 'isOwner': true, 'created': true},
        });
        async.flushMicrotasks();
        expect(settled, [cid], reason: 'welcome 到了才清持久的待登记标记');

        // 掉线重连:不再带 register(否则必 circle_exists),照常带 ownerKey
        t.last.serverClose(1006);
        async.elapse(const Duration(seconds: 5));
        t.last.serverSend(challenge('b' * 32));
        async.flushMicrotasks();
        final again = t.last.sentOfType('hello').last['auth'] as Map;
        expect(again.containsKey('register'), isFalse);
        expect(again['ownerKey'], key);
        c.dispose();
      });
    });

    test('⚠️ welcome 丢了 → 重试撞 4409 → 带本机钥匙普通登录,isOwner=true 即登记成功', () {
      fakeAsync((async) {
        final t = FakeTransport();
        var pending = true;
        final settled = <String>[];
        final c = mk(t, () => pending, (id) {
          settled.add(id);
          pending = false;
        });
        c.connect();
        sayHello(c);
        t.last.serverSend(challenge('a' * 32));
        async.flushMicrotasks();
        expect((t.last.sentOfType('hello').single['auth'] as Map)['register'],
            isNotNull);

        // 服务器其实建好了,但 welcome 丢了、连接断了
        t.last.serverClose(1006);
        async.elapse(const Duration(seconds: 5));
        t.last.serverSend(challenge('b' * 32));
        async.flushMicrotasks();
        // 待登记还在 → 又带 register → 服务器 4409
        expect((t.last.sentOfType('hello').last['auth'] as Map)['register'],
            isNotNull);
        t.last.serverSend({'t': 'error', 'message': 'circle_exists'});
        t.last.serverClose(4409, 'circle_exists');
        async.elapse(const Duration(seconds: 1));
        expect(settled, isEmpty,
            reason: '4409 本身不是结论:还不知道这圈是不是我的');

        t.last.serverSend(challenge('c' * 32));
        async.flushMicrotasks();
        final retry = t.last.sentOfType('hello').last['auth'] as Map;
        expect(retry.containsKey('register'), isFalse);
        expect(retry['ownerKey'], key, reason: '钥匙一直在本机,拿它去认领');

        t.last.serverSend({
          't': 'welcome',
          'userId': 'u_me',
          'circle': {'id': cid, 'registered': true, 'isOwner': true},
        });
        async.flushMicrotasks();
        expect(settled, [cid], reason: 'isOwner=true 就算登记成功,不会落成无主圈');
        c.dispose();
      });
    });

    test('没有钥匙就不发 register(免得服务器回 register_invalid 终局)', () {
      final obj = AuthProof.build(
        credential: const AuthCredential(
            mode: AuthMode.circle, passcode: pass, circleId: cid),
        nonce: 'n' * 32,
        userId: 'u',
        register: true,
        verifier: 'a' * 64,
      );
      expect(obj!.containsKey('register'), isFalse);
      expect(obj.containsKey('ownerKey'), isFalse);
    });

    test('兼容旧服务器:welcome 里下发 ownerKey 时先落盘再清标记', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final events = <String>[];
        final c = SignalingClient(
          url: 'wss://x/ws',
          connector: t.connect,
          credentials: () =>
              const AuthCredential(mode: AuthMode.circle, passcode: pass),
          userId: 'u_me',
          circleHints: (id) => (register: true, ownerKey: null),
        );
        c.onOwnerKeyIssued = (id, k) async => events.add('save');
        c.onRegistrationSettled = (_) => events.add('settled');
        c.authCircleId = cid;
        c.connect();
        sayHello(c);
        t.last.serverSend(challenge('a' * 32));
        async.flushMicrotasks();
        t.last.serverSend({
          't': 'welcome',
          'userId': 'u_me',
          'circle': {'id': cid, 'registered': true, 'ownerKey': 'k' * 64},
        });
        async.flushMicrotasks();
        expect(events, ['save', 'settled']);
        expect(c.issuedOwnerKey(cid), 'k' * 64);
        c.dispose();
      });
    });
  });

  group('SettingsStore:圈主钥匙与待登记', () {
    test('saveOwnerKey 落进 vault,重启读回;forgetCircleSecrets 清干净', () async {
      final vault = InMemorySecretVault();
      final s1 = await SettingsStore.load(vault: vault);
      await s1.markPendingRegistration('c_a');
      expect(s1.isPendingRegistration('c_a'), isTrue);
      await s1.saveOwnerKey('c_a', 'key-a');
      await s1.clearPendingRegistration('c_a');

      final s2 = await SettingsStore.load(vault: vault);
      expect(s2.ownerKeyFor('c_a'), 'key-a');
      expect(s2.isPendingRegistration('c_a'), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().map(prefs.get).join(), isNot(contains('key-a')),
          reason: '圈主钥匙不得落进明文 prefs');

      await s2.forgetCircleSecrets('c_a');
      final s3 = await SettingsStore.load(vault: vault);
      expect(s3.ownerKeyFor('c_a'), isNull);
    });
  });

  group('RoomController:谁能动管理控件', () {
    test('env 圈人人可动;注册圈只有圈主', () async {
      final settings = await SettingsStore.load(vault: InMemorySecretVault());
      final c = RoomController(
        signaling: FakeSignalingClient(),
        rtc: FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
        settings: settings,
      );
      addTearDown(c.dispose);
      expect(c.canModerate('home'), isTrue, reason: '不知道的圈按老行为');
      c.circleInfo['c_r'] = (registered: true, e2ee: null);
      expect(c.canModerate('c_r'), isFalse);
      await settings.saveOwnerKey('c_r', 'kk');
      expect(c.canModerate('c_r'), isTrue);
    });

    test('踢人 / 敲门在注册圈里带上 ownerKey;没钥匙的圈主操作不发', () async {
      final settings = await SettingsStore.load(vault: InMemorySecretVault());
      final sig = FakeSignalingClient();
      final c = RoomController(
        signaling: sig,
        rtc: FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
        settings: settings,
      );
      addTearDown(c.dispose);
      expect(await c.deleteCircleAsOwner('c_r'), 'no_key');
      expect(sig.sent, isEmpty);
      await settings.saveOwnerKey('c_r', 'kk');
      c.setKnockMode('c_r', true);
      expect(sig.sent.last['ownerKey'], 'kk');
    });

    test('圈主操作等服务器回执:owner_ok → null,owner_error → reason', () async {
      final settings = await SettingsStore.load(vault: InMemorySecretVault());
      final sig = FakeSignalingClient();
      final c = RoomController(
        signaling: sig,
        rtc: FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
        settings: settings,
      );
      addTearDown(c.dispose);
      await settings.saveOwnerKey('c_r', 'kk');
      final f1 = c.setCircleE2EEAsOwner('c_r', true);
      sig.testInject(
          {'t': 'owner_ok', 'op': 'circle_e2ee_set', 'circleId': 'c_r'});
      expect(await f1, isNull);
      final f2 = c.setCirclePasscodeAsOwner('c_r', 'a' * 64);
      sig.testInject({
        't': 'owner_error',
        'op': 'circle_passcode_set',
        'circleId': 'c_r',
        'reason': 'not_owner',
      });
      expect(await f2, 'not_owner');
    });
  });

  group('界面:非圈主看不到圈主控件', () {
    final AppLocalizations t = zhStrings();

    Future<void> openMenu(WidgetTester tester,
        {required bool registered,
        required bool owner,
        bool pending = false}) async {
      tester.view
        ..physicalSize = const Size(1000, 2400)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final settings = await SettingsStore.load();
      final controller = RoomController(
        signaling: FakeSignalingClient(),
        rtc: FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
        settings: settings,
      );
      addTearDown(controller.dispose);
      final circleStore = await CircleStore.load();
      final id = circleStore.circles.first.id;
      if (registered) controller.circleInfo[id] = (registered: true, e2ee: null);
      if (owner) await settings.saveOwnerKey(id, 'kk');
      if (pending) await settings.markPendingRegistration(id);
      await tester.pumpWidget(localizedApp(
        HomeScreen(
          controller: controller,
          circleStore: circleStore,
          settings: settings,
          e2ee: E2EEController(
            store: E2EEStore.inMemory(),
            settings: settings,
            platformProbe: () => true,
          ),
        ),
        theme: LaresTheme.dark(),
      ));
      await tester.pump();
      await tester.longPress(find.text(circleStore.circles.first.name).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('注册圈 · 非圈主:没有敲门、加密、换口令、解散', (tester) async {
      await openMenu(tester, registered: true, owner: false);
      expect(find.text(t.homeKnockModeOff), findsNothing);
      expect(find.text(t.e2eeTitle), findsNothing);
      expect(find.text(t.homeChangePasscode), findsNothing);
      expect(find.text(t.homeDissolveCircle), findsNothing);
      expect(find.text(t.homeInviteFriends), findsOneWidget,
          reason: '邀请照常可用');
    });

    testWidgets('注册圈 · 圈主:换口令、解散、全圈加密、钥匙说明都在', (tester) async {
      await openMenu(tester, registered: true, owner: true);
      expect(find.text(t.homeKnockModeOff), findsOneWidget);
      expect(find.byKey(const ValueKey('owner-e2ee-switch')), findsOneWidget);
      expect(find.text(t.homeChangePasscode), findsOneWidget);
      expect(find.text(t.homeDissolveCircle), findsOneWidget);
      expect(find.text(t.homeOwnerKeyNote), findsOneWidget);
    });

    testWidgets('钥匙已生成但登记未确认:只显示「还在登记」,不给圈主菜单', (tester) async {
      await openMenu(tester, registered: false, owner: true, pending: true);
      expect(find.text(t.homeOwnerPending), findsOneWidget);
      expect(find.text(t.homeChangePasscode), findsNothing);
      expect(find.text(t.homeDissolveCircle), findsNothing);
    });

    testWidgets('env 圈:老行为,人人都有敲门与本机加密开关,没有圈主项', (tester) async {
      await openMenu(tester, registered: false, owner: false);
      expect(find.text(t.homeKnockModeOff), findsOneWidget);
      expect(find.text(t.e2eeTitle), findsOneWidget);
      expect(find.text(t.homeChangePasscode), findsNothing);
    });
  });
}
