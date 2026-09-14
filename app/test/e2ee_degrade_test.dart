/// 平台降级逻辑的测试。
///
/// 这一组的存在理由很具体:`lkPlatformSupportsE2EE()` **不看**
/// `lkPlatformIsTest()`,在 Windows 上跑 `flutter test` 它返回 true。
/// 也就是说,如果不把平台探针做成可注入的,「平台不支持」这条分支
/// 在 CI 里永远跑不到 —— 而它恰恰是最危险的那一条(静默降级成明文)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/auth/auth_credential.dart';
import 'package:lares_app/src/e2ee/e2ee_controller.dart';
import 'package:lares_app/src/e2ee/e2ee_key.dart';
import 'package:lares_app/src/e2ee/e2ee_status.dart';
import 'package:lares_app/src/e2ee/e2ee_store.dart';
import 'package:lares_app/src/net/server_profile.dart';
import 'package:lares_app/src/state/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 记录「被要求装载的密钥」的假安装器。
///
/// 真的安装器会穿到 flutter_webrtc 的平台通道去建 frame cryptor,
/// `flutter test` 里没有那个通道。这里只记录参数,
/// 于是「密钥装好了」这条成功路径也能被断言。
class _FakeInstaller {
  _FakeInstaller({this.throws = false});

  /// 模拟底层 frame cryptor 起不来
  final bool throws;
  final List<String> keys = [];

  Future<void> call(Object? rtc, String key) async {
    keys.add(key);
    if (throws) throw StateError('frame cryptor 没起来');
  }
}

/// 造一个 circle 鉴权模式、带指定圈口令的 SettingsStore。
Future<SettingsStore> _settingsWithPasscodes(
  Map<String, String> passcodes,
) async {
  SharedPreferences.setMockInitialValues({});
  final s = await SettingsStore.load();
  await s.setServerProfiles(ServerProfiles(
    profiles: [
      ServerProfile(
        id: 'p1',
        label: '测试',
        url: 'wss://example.com/ws',
        authMode: AuthMode.circle,
        circlePasscodes: passcodes,
      ),
    ],
    activeId: 'p1',
  ));
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 测试里不碰真实 Keychain —— 没有平台通道时它会挂起而不是报错。
  debugUseInMemoryVault = true;

  group('纯决策:resolveE2EEStatus', () {
    test('没开 -> disabled(其它条件一概不看)', () {
      expect(
        resolveE2EEStatus(
            enabled: false, platformSupported: false, hasPasscode: false),
        E2EEStatus.disabled,
      );
      expect(
        resolveE2EEStatus(
            enabled: false, platformSupported: true, hasPasscode: true),
        E2EEStatus.disabled,
      );
    });

    test('开了 + 平台不支持 -> platformUnsupported(即使口令齐备)', () {
      expect(
        resolveE2EEStatus(
            enabled: true, platformSupported: false, hasPasscode: true),
        E2EEStatus.platformUnsupported,
      );
    });

    test('开了 + 平台支持 + 没口令 -> noPasscode', () {
      expect(
        resolveE2EEStatus(
            enabled: true, platformSupported: true, hasPasscode: false),
        E2EEStatus.noPasscode,
      );
    });

    test('三者齐备 -> encrypted', () {
      expect(
        resolveE2EEStatus(
            enabled: true, platformSupported: true, hasPasscode: true),
        E2EEStatus.encrypted,
      );
    });

    test('只有 encrypted 会被当成「真的加密了」', () {
      for (final s in E2EEStatus.values) {
        expect(s.isEncrypted, s == E2EEStatus.encrypted,
            reason: '$s 的 isEncrypted 判断错了 —— 这个判断直接决定 UI 画不画锁');
      }
    });

    test('三种降级态都算「承诺落空」,必须让用户看见', () {
      expect(E2EEStatus.platformUnsupported.isBrokenPromise, isTrue);
      expect(E2EEStatus.noPasscode.isBrokenPromise, isTrue);
      expect(E2EEStatus.failed.isBrokenPromise, isTrue);
      // 没开不算落空(用户自己的选择),真加密了更不算
      expect(E2EEStatus.disabled.isBrokenPromise, isFalse);
      expect(E2EEStatus.encrypted.isBrokenPromise, isFalse);
    });

    test('每种降级态的说明都明说「没有加密」,不留模糊空间', () {
      for (final s in E2EEStatus.values.where((s) => s.isBrokenPromise)) {
        expect(s.explanation.contains('没有加密'), isTrue,
            reason: '$s 的说明必须明确写出「没有加密」');
        expect(s.shortLabel.contains('未加密'), isTrue);
      }
    });
  });

  group('E2EEController:平台降级', () {
    test('平台不支持时,开了也不硬开 —— 报 platformUnsupported 而非 encrypted',
        () async {
      final settings = await _settingsWithPasscodes({'home': 'pass'});
      final store = E2EEStore.inMemory({'home'});
      final c = E2EEController(
        store: store,
        settings: settings,
        // rtc 为 null:本测试只验决策,不碰任何 WebRTC 通道
        platformProbe: () => false,
      );
      expect(c.platformSupported, isFalse);
      expect(await c.prepareFor('home'), E2EEStatus.platformUnsupported);
      // 关键:仍然给出一个可进房的结论,不抛异常 ——
      // 硬开会让 room.connect() 抛 LiveKitE2EEException,用户直接进不去房间。
      expect(c.activeStatus, E2EEStatus.platformUnsupported);
      expect(c.activeStatus!.isEncrypted, isFalse);
    });

    test('平台支持 + 开了 + 有口令 -> encrypted,且装进去的正是派生出的密钥', () async {
      final settings = await _settingsWithPasscodes({'home': 'pass'});
      final installer = _FakeInstaller();
      final c = E2EEController(
        store: E2EEStore.inMemory({'home'}),
        settings: settings,
        platformProbe: () => true,
        keyInstaller: installer.call,
      );
      expect(await c.prepareFor('home'), E2EEStatus.encrypted);
      // 装进去的必须是派生密钥,**不是口令本身** ——
      // 直接拿口令当密钥等于把认证凭据和加密密钥绑死。
      expect(installer.keys.single, isNot('pass'));
      // 且必须是 **v2(Argon2id)** 而不是 v1 的单次 HMAC。
      // 这条断言的意义:v1 对人手输的低熵口令几乎没有暴力破解成本。
      // 若哪天默认派生器被改回 v1,这里会当场变红。
      expect(installer.keys.single,
          deriveCircleE2EEKeyV2(passcode: 'pass', circleId: 'home'));
      expect(installer.keys.single,
          isNot(deriveCircleE2EEKey(passcode: 'pass', circleId: 'home')));
    });

    test('密钥装载失败 -> failed,绝不谎报 encrypted', () async {
      final settings = await _settingsWithPasscodes({'home': 'pass'});
      final c = E2EEController(
        store: E2EEStore.inMemory({'home'}),
        settings: settings,
        platformProbe: () => true,
        keyInstaller: _FakeInstaller(throws: true).call,
      );
      final status = await c.prepareFor('home');
      expect(status, E2EEStatus.failed);
      expect(status.isEncrypted, isFalse);
      expect(status.isBrokenPromise, isTrue);
    });

    test('没开的圈子不会去派生任何密钥(装载器一次都不该被调到)', () async {
      final settings = await _settingsWithPasscodes({'home': 'pass'});
      final installer = _FakeInstaller();
      final c = E2EEController(
        store: E2EEStore.inMemory(),
        settings: settings,
        platformProbe: () => true,
        keyInstaller: installer.call,
      );
      await c.prepareFor('home');
      expect(installer.keys, isEmpty);
    });

    test('平台不支持时不会去派生密钥 —— 硬开会让 room.connect() 直接抛异常', () async {
      final settings = await _settingsWithPasscodes({'home': 'pass'});
      final installer = _FakeInstaller();
      final c = E2EEController(
        store: E2EEStore.inMemory({'home'}),
        settings: settings,
        platformProbe: () => false,
        keyInstaller: installer.call,
      );
      await c.prepareFor('home');
      expect(installer.keys, isEmpty);
    });

    test('开了但没这个圈的口令 -> noPasscode,绝不拿空口令派生常量密钥', () async {
      final settings = await _settingsWithPasscodes({'other': 'pass'});
      final c = E2EEController(
        store: E2EEStore.inMemory({'home'}),
        settings: settings,
        platformProbe: () => true,
      );
      expect(c.hasPasscode('home'), isFalse);
      expect(await c.prepareFor('home'), E2EEStatus.noPasscode);
    });

    test('没开的圈子 -> disabled,平台支不支持都不影响', () async {
      final settings = await _settingsWithPasscodes({'home': 'pass'});
      for (final supported in [true, false]) {
        final c = E2EEController(
          store: E2EEStore.inMemory(),
          settings: settings,
          platformProbe: () => supported,
        );
        expect(await c.prepareFor('home'), E2EEStatus.disabled);
      }
    });

    test('circleId 为空(还没选圈)-> disabled,不残留上一次的结论', () async {
      final settings = await _settingsWithPasscodes({'home': 'pass'});
      final c = E2EEController(
        store: E2EEStore.inMemory({'home'}),
        settings: settings,
        platformProbe: () => true,
        keyInstaller: _FakeInstaller().call,
      );
      await c.prepareFor('home');
      expect(await c.prepareFor(null), E2EEStatus.disabled);
      expect(c.activeCircleId, isNull);
    });

    test('换圈子会重算 —— 加密圈的结论不会漂到不加密圈上', () async {
      final settings = await _settingsWithPasscodes({'home': 'pass'});
      final c = E2EEController(
        store: E2EEStore.inMemory({'home'}),
        settings: settings,
        platformProbe: () => true,
        keyInstaller: _FakeInstaller().call,
      );
      expect(await c.prepareFor('home'), E2EEStatus.encrypted);
      expect(await c.prepareFor('work'), E2EEStatus.disabled);
      // 圈子对不上时 statusForActiveCircle 必须返回 null,
      // UI 因此什么都不显示,而不是把 home 的锁挂到 work 头上。
      expect(c.statusForActiveCircle('home'), isNull);
      expect(c.statusForActiveCircle('work'), E2EEStatus.disabled);
    });

    test('previewStatusFor:按下开关之前就如实预告本设备的结果', () async {
      final settings = await _settingsWithPasscodes({'home': 'pass'});
      final unsupported = E2EEController(
        store: E2EEStore.inMemory({'home'}),
        settings: settings,
        platformProbe: () => false,
      );
      expect(unsupported.previewStatusFor('home'),
          E2EEStatus.platformUnsupported);

      final supported = E2EEController(
        store: E2EEStore.inMemory({'home'}),
        settings: settings,
        platformProbe: () => true,
      );
      expect(supported.previewStatusFor('home'), E2EEStatus.encrypted);
      expect(supported.previewStatusFor('work'), E2EEStatus.disabled);
    });

    test('代价说明写明了转录与炉灵两件事', () {
      expect(kE2EECostNotice.contains('转录'), isTrue);
      expect(kE2EECostNotice.contains('炉灵'), isTrue);
    });
  });
}
