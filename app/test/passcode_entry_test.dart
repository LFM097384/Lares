import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/auth/auth_credential.dart';
import 'package:lares_app/src/e2ee/e2ee_controller.dart';
import 'package:lares_app/src/e2ee/e2ee_status.dart';
import 'package:lares_app/src/e2ee/e2ee_store.dart';
import 'package:lares_app/src/net/secret_vault.dart';
import 'package:lares_app/src/net/server_profile.dart';
import 'package:lares_app/src/net/signaling_client.dart';
import 'package:lares_app/src/rtc/rtc_service.dart';
import 'package:lares_app/src/state/join_error.dart';
import 'package:lares_app/src/state/models.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/state/settings_store.dart';
import 'package:lares_app/src/ui/room_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/localized_app.dart';

/// 「进不去的时候当场把口令填上」这条路的测试。
///
/// 为什么这件事值得单独一个文件:邀请链接**刻意不带口令**(口令派生 E2EE
/// 密钥,写进链接等于把密钥一起发出去),所以「通过链接加的圈子第一次进房
/// 必然被 4401 拒」是设计的一部分,不是 bug。既然必然发生,补救路径就必须
/// 好用 —— 而它有两个很容易写错的地方:
///
///  1. 口令存下来了,但**不会被用上**(档案不存在、或鉴权模式不是 circle);
///  2. 口令框在**不该出现的时候**出现(网络错、服务器没配 LiveKit)。
///
/// 这两条各自都会表现成「填了没用」,且都不会让任何现有测试变红。

class _FakeSignaling extends SignalingClient {
  _FakeSignaling() : super(url: 'ws://fake');

  final List<Map<String, dynamic>> sent = [];
  int reconnectCount = 0;

  /// 握手要不要成功。retryJoin 会等它。
  bool handshakeOk = true;

  @override
  void connect() {}

  @override
  void send(Map<String, dynamic> msg) => sent.add(msg);

  @override
  void reconnectWithNewCredential() => reconnectCount++;

  @override
  Future<bool> waitHandshake(Duration timeout) async => handshakeOk;

  @override
  Future<void> dispose() async {}
}

class _FakeRtc implements RtcService {
  final _speaking = StreamController<Set<String>>.broadcast();
  final _dropped = StreamController<void>.broadcast();
  bool _inRoom = false;

  @override
  bool get inRoom => _inRoom;

  @override
  Future<Duration> join({
    required String url,
    required String token,
    required bool startMuted,
    bool highQuality = true,
    AudioTuning tuning = AudioTuning.standard,
  }) async {
    _inRoom = true;
    return const Duration(milliseconds: 10);
  }

  @override
  ResolvedAudioTuning? get activeTuning => null;

  @override
  ResolvedAudioTuning previewTuning(AudioTuning tuning) => resolveAudioTuning(
        tuning,
        const AudioPlatformCapabilities(
          platform: 'windows',
          supportsAudioSession: false,
          supportsEnhanced: false,
        ),
      );

  @override
  Future<void> leave() async {
    _inRoom = false;
  }

  @override
  Future<void> setMuted(bool m) async {}

  @override
  Stream<Set<String>> get speakingIdentities => _speaking.stream;

  @override
  Stream<void> get onDisconnected => _dropped.stream;
}

RoomController _makeController(_FakeSignaling s, {SettingsStore? settings}) =>
    RoomController(
      signaling: s,
      rtc: _FakeRtc(),
      userId: 'u_me',
      deviceId: 'd_1',
      userName: '我',
      settings: settings,
    );

/// 把 controller 推到「4401 被拒」那个状态。
///
/// [pump] 由调用方给:纯 `test` 里用 `pumpEventQueue`,而 `testWidgets`
/// 跑在 fake-async 时区里,`pumpEventQueue` 在那儿**不会**推进 ——
/// 必须用 `tester.pump()`。踩过一次:症状是整个测试文件静默挂死到超时,
/// 没有任何失败信息。
Future<void> _failWith4401(
  _FakeSignaling signaling,
  RoomController controller,
  String circleId, {
  required Future<void> Function() pump,
}) async {
  final joined = controller.join(circleId);
  // completeError 必须有人接,否则变成未捕获异步错误,
  // 测试会以一个与被测行为无关的理由失败。
  final expectation = expectLater(joined, throwsA(isA<StateError>()));
  signaling.testInject({'t': '_disconnected', 'closeCode': 4401});
  await pump();
  await expectation;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    debugUseInMemoryVault = true;
  });

  group('错误分类:只有「要口令」才该弹输入框', () {
    test('4401 / auth_failed 归为 needsPasscode', () {
      expect(classifyJoinError('closed with 4401'),
          JoinErrorKind.needsPasscode);
      expect(classifyJoinError(StateError('auth_failed')),
          JoinErrorKind.needsPasscode);
    });

    test('网络类错误不是口令问题', () {
      expect(
        classifyJoinError(TimeoutException('x', const Duration(seconds: 1))),
        JoinErrorKind.network,
      );
      expect(classifyJoinError(const SocketException('refused')),
          JoinErrorKind.network);
      expect(classifyJoinError(const HandshakeException('cert')),
          JoinErrorKind.network);
    });

    test('限流与「服务器没配 LiveKit」也不是口令问题', () {
      // 这两条尤其要分清:4429 时再填口令只会把封禁拖得更久。
      expect(classifyJoinError('closed with 4429'), JoinErrorKind.rateLimited);
      expect(classifyJoinError('rtc_not_configured'),
          JoinErrorKind.serverNotReady);
    });

    test('分类与文案不会各自漂移(同一判据的两个出口)', () {
      // 这条守的是设计本身:humanizeJoinError 与 classifyJoinError
      // 必须由同一个判定驱动。反查回来对不上就说明两者已经分家。
      for (final Object e in <Object>[
        'closed with 4401',
        'closed with 4429',
        'rtc_not_configured',
        TimeoutException('x', const Duration(seconds: 1)),
        const SocketException('Failed host lookup: x'),
        const HandshakeException('cert'),
        StateError('完全未知'),
      ]) {
        expect(
          kindOfJoinMessage(humanizeJoinError(e)),
          classifyJoinError(e),
          reason: '$e 的文案与分类对不上',
        );
      }
    });
  });

  group('RoomController 暴露的「要不要口令」', () {
    test('4401 之后 needsPasscode 为真', () async {
      final signaling = _FakeSignaling();
      final controller = _makeController(signaling);
      addTearDown(controller.dispose);

      expect(controller.needsPasscode, isFalse, reason: '还没失败过');
      await _failWith4401(signaling, controller, 'work',
          pump: pumpEventQueue);

      expect(controller.phase, RoomPhase.error);
      expect(controller.lastErrorKind, JoinErrorKind.needsPasscode);
      expect(controller.needsPasscode, isTrue);
    });

    test('4429 之后不显示口令框', () async {
      final signaling = _FakeSignaling();
      final controller = _makeController(signaling);
      addTearDown(controller.dispose);

      final joined = controller.join('work');
      final expectation = expectLater(joined, throwsA(isA<StateError>()));
      signaling.testInject({'t': '_disconnected', 'closeCode': 4429});
      await pumpEventQueue();
      await expectation;

      expect(controller.phase, RoomPhase.error);
      expect(controller.needsPasscode, isFalse,
          reason: '限流时填口令没用,只会把封禁拖得更久');
    });

    test('普通断线既不报错也不要口令', () async {
      final signaling = _FakeSignaling();
      final controller = _makeController(signaling);
      addTearDown(controller.dispose);

      controller.join('work');
      signaling.testInject({'t': '_disconnected'}); // 无 closeCode
      await pumpEventQueue();

      expect(controller.phase, RoomPhase.joining, reason: '抖动交给自动重连');
      expect(controller.needsPasscode, isFalse);
    });
  });

  group('口令存进去要真的能用', () {
    test('一个档案都没有时:就地建一个 circle 模式的档案', () async {
      // 这是全新安装 + 粘贴邀请链接的路径,也是本功能最主要的场景。
      // 从前这里会静默失败:没有 active 档案,口令无处可写。
      final s = await SettingsStore.load(vault: InMemorySecretVault());
      expect(s.activeProfile, isNull);

      final ok = await s.setCirclePasscode('work', '芝麻开门');

      expect(ok, isTrue);
      expect(s.activeProfile, isNotNull);
      expect(s.activeProfile!.authMode, AuthMode.circle);
      // 最要紧的一条:取凭据时真的拿得到。
      expect(s.credentialFor('work').passcode, '芝麻开门');
      expect(s.credentialFor('work').isComplete, isTrue);
    });

    test('档案是 none 模式时:升级成 circle,口令立即生效', () async {
      final s = await SettingsStore.load(vault: InMemorySecretVault());
      await s.setServerProfiles(const ServerProfiles(
        profiles: [ServerProfile(id: 'p1', label: '家里', url: 'wss://x/ws')],
        activeId: 'p1',
      ));
      expect(s.activeProfile!.authMode, AuthMode.none);

      final ok = await s.setCirclePasscode('work', '芝麻开门');

      expect(ok, isTrue);
      expect(s.credentialFor('work').passcode, '芝麻开门');
    });

    test('档案是 token 模式时:只存不改模式,并如实返回 false', () async {
      // 纪律:不动用户显式配过的鉴权方式。改成 circle 会让一个本来
      // 能用的配置当场连不上 —— circle 模式下口令为空即拒绝连接。
      final s = await SettingsStore.load(vault: InMemorySecretVault());
      await s.setServerProfiles(const ServerProfiles(
        profiles: [
          ServerProfile(
            id: 'p1',
            label: '公司',
            url: 'wss://x/ws',
            authMode: AuthMode.token,
            token: 'T',
          ),
        ],
        activeId: 'p1',
      ));

      final ok = await s.setCirclePasscode('work', '芝麻开门');

      expect(ok, isFalse, reason: 'UI 要据此如实告诉用户「还没生效」');
      expect(s.activeProfile!.authMode, AuthMode.token, reason: '不得擅自改模式');
      // 存是存下了 —— 将来切到 circle 模式即刻可用,不让用户白填一次。
      expect(s.activeProfile!.circlePasscodes['work'], '芝麻开门');
    });

    test('口令不进明文 prefs', () async {
      // 与 settings_vault_test.dart 同一条纪律,但守的是**新入口**:
      // 新加的写入路径同样不许把口令写进明文。
      final vault = InMemorySecretVault();
      final s = await SettingsStore.load(vault: vault);
      await s.setCirclePasscode('work', '芝麻开门');

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('lares.serverProfiles') ?? '';
      expect(raw, isNot(contains('芝麻开门')), reason: '口令不得落进明文 prefs');
      expect(raw, contains('work'), reason: '但要记下哪个圈子配过口令');
    });
  });

  group('填完口令重试进房', () {
    test('retryJoin:带新凭据重新握手,然后才发 join', () async {
      final signaling = _FakeSignaling();
      final settings = await SettingsStore.load(vault: InMemorySecretVault());
      final controller = _makeController(signaling, settings: settings);
      addTearDown(controller.dispose);

      await _failWith4401(signaling, controller, 'work',
          pump: pumpEventQueue);
      expect(controller.needsPasscode, isTrue);

      // 用户填了口令
      await settings.setCirclePasscode('work', '芝麻开门');
      signaling.sent.clear();

      await controller.retryJoin('work');

      // 连接要证明的是**这个**圈子,不是主圈子 ——
      // 服务端把 circle 模式的会话钉死在证明过的那个圈上。
      expect(signaling.authCircleId, 'work');
      expect(
        signaling.sent.any((m) => m['t'] == 'join' && m['circleId'] == 'work'),
        isTrue,
        reason: '握手之后必须真的发出 join',
      );
      expect(controller.phase, RoomPhase.joining);
      expect(controller.needsPasscode, isFalse, reason: '旧错误要清掉');
    });

    test('圈子没变、只换了口令:也必须显式重连', () async {
      // 关键边界:4401 两次之后信令层**不再自己重连**(否则 5 分钟 10 次
      // 必然撞上 4429 封禁),它等着上层叫醒。authCircleId 没变时
      // 它的 setter 不会触发重连 —— 漏掉这一步,用户填完口令按重试,
      // join 消息只会躺在 outbox 里,界面毫无反应。
      final signaling = _FakeSignaling();
      final settings = await SettingsStore.load(vault: InMemorySecretVault());
      final controller = _makeController(signaling, settings: settings);
      addTearDown(controller.dispose);

      signaling.authCircleId = 'work'; // 已经就是这个圈
      await _failWith4401(signaling, controller, 'work',
          pump: pumpEventQueue);
      await settings.setCirclePasscode('work', '芝麻开门');

      final before = signaling.reconnectCount;
      await controller.retryJoin('work');

      expect(signaling.reconnectCount, greaterThan(before),
          reason: '必须叫醒已经停下来的信令层');
    });

    test('握手仍然失败:落回 error,且仍然给补填口令的机会', () async {
      final signaling = _FakeSignaling();
      final settings = await SettingsStore.load(vault: InMemorySecretVault());
      final controller = _makeController(signaling, settings: settings);
      addTearDown(controller.dispose);

      await _failWith4401(signaling, controller, 'work',
          pump: pumpEventQueue);
      await settings.setCirclePasscode('work', '错的口令');

      signaling.handshakeOk = false;
      await controller.retryJoin('work');

      expect(controller.phase, RoomPhase.error);
      expect(controller.needsPasscode, isTrue, reason: '让用户能再改一次');
    });

    test('重试后口令还是错:落 error,不能第二次卡死在 joining', () async {
      // retryJoin 刻意不 await join() —— 4401 时服务端根本不回话,
      // await 就是永远。失败靠 _failJoin 的 notifyListeners 送到 UI。
      // 这条守的就是那条通道真的通:重试再被拒,界面必须还有出路。
      final signaling = _FakeSignaling();
      final settings = await SettingsStore.load(vault: InMemorySecretVault());
      final controller = _makeController(signaling, settings: settings);
      addTearDown(controller.dispose);

      await _failWith4401(signaling, controller, 'work',
          pump: pumpEventQueue);
      await settings.setCirclePasscode('work', '还是错的');
      await controller.retryJoin('work');
      expect(controller.phase, RoomPhase.joining, reason: '重试期间应在转圈');

      // 服务端第二次拒绝
      signaling.testInject({'t': '_disconnected', 'closeCode': 4401});
      await pumpEventQueue();

      expect(controller.phase, RoomPhase.error, reason: '不能再卡住一次');
      expect(controller.needsPasscode, isTrue);
    });
  });

  group('E2EE 要跟着口令一起刷新', () {
    test('刚填的口令能立刻被 E2EE 读到(派生密钥用的就是它)', () async {
      // 口令变化 = E2EE 密钥变化。这里守的是「新填的口令真的走到了
      // 派生那一步」—— 而不是派生用的还是空口令(那会得出一把
      // 谁也对不上的密钥,表现为进去了但互相听不见)。
      final settings = await SettingsStore.load(vault: InMemorySecretVault());
      final e2ee = E2EEController(
        store: await E2EEStore.load(),
        settings: settings,
      );
      addTearDown(e2ee.dispose);

      await e2ee.setEnabled('work', true);
      expect(e2ee.hasPasscode('work'), isFalse, reason: '还没填过');
      expect(e2ee.previewStatusFor('work'), E2EEStatus.noPasscode);

      await settings.setCirclePasscode('work', '芝麻开门');

      // 不需要任何额外调用:E2EEController 在构造时就 listen 了 settings,
      // 而 prepareFor 每次都现取 credentialFor(id).passcode。
      expect(e2ee.hasPasscode('work'), isTrue);
    });

    test('E2EEController 会在口令变化时通知监听者(角标自动刷新)', () async {
      final settings = await SettingsStore.load(vault: InMemorySecretVault());
      final e2ee = E2EEController(
        store: await E2EEStore.load(),
        settings: settings,
      );
      addTearDown(e2ee.dispose);

      var notified = 0;
      e2ee.addListener(() => notified++);

      await settings.setCirclePasscode('work', '芝麻开门');

      expect(notified, greaterThan(0),
          reason: '否则设置页/圈子列表上的加密角标会停在旧状态');
    });
  });

  group('房内补填口令的界面', () {
    testWidgets('4401 时出现输入框;填完能重新进房', (tester) async {
      final signaling = _FakeSignaling();
      final settings = await SettingsStore.load(vault: InMemorySecretVault());
      final controller = _makeController(signaling, settings: settings);
      addTearDown(controller.dispose);

      await _failWith4401(signaling, controller, 'work',
          pump: () => tester.pump());

      await tester.pumpWidget(localizedApp(
        RoomScreen(
          controller: controller,
          circleName: '朋友的圈',
          settings: settings,
        ),
      ));
      await tester.pump();

      expect(find.text('再试一次'), findsOneWidget,
          reason: '进不去的时候要能当场填,而不是被打发去设置页');

      await tester.enterText(find.byType(TextField).last, '芝麻开门');
      signaling.sent.clear();
      await tester.tap(find.text('再试一次'));
      // ⚠️ 不能用 pumpAndSettle:房间页底下那层「呼吸感」背景是
      // `repeat(reverse: true)` 的无限动画,永远不会 settle,
      // pumpAndSettle 会一直等到超时(现有 room_screen_test 也都用 pump)。
      // 这里要等的是几个 await(存口令 -> 握手),手动泵几帧足够。
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // 口令确实存下来了,而且是能用的那种存法
      expect(settings.credentialFor('work').passcode, '芝麻开门');
      expect(settings.activeProfile!.authMode, AuthMode.circle);
      // 而且真的重新进了一次房
      expect(
        signaling.sent.any((m) => m['t'] == 'join' && m['circleId'] == 'work'),
        isTrue,
      );
    });

    testWidgets('非鉴权错误不显示口令框', (tester) async {
      // 网络不好的时候弹口令框是误导:用户会反复输入一个本来就没错的口令,
      // 而真正的问题在别处。
      final signaling = _FakeSignaling();
      final settings = await SettingsStore.load(vault: InMemorySecretVault());
      final controller = _makeController(signaling, settings: settings);
      addTearDown(controller.dispose);

      final joined = controller.join('work');
      final expectation = expectLater(joined, throwsA(isA<StateError>()));
      signaling.testInject({'t': '_disconnected', 'closeCode': 4429});
      // 同上:fake-async 时区里只有 tester.pump() 能推进。
      await tester.pump();
      await expectation;

      await tester.pumpWidget(localizedApp(
        RoomScreen(
          controller: controller,
          circleName: '朋友的圈',
          settings: settings,
        ),
      ));
      await tester.pump();

      expect(controller.phase, RoomPhase.error, reason: '确实是错误状态');
      expect(find.text('再试一次'), findsNothing);
    });

    testWidgets('没进过房(idle)时也不显示', (tester) async {
      final signaling = _FakeSignaling();
      final settings = await SettingsStore.load(vault: InMemorySecretVault());
      final controller = _makeController(signaling, settings: settings);
      addTearDown(controller.dispose);

      await tester.pumpWidget(localizedApp(
        RoomScreen(
          controller: controller,
          circleName: '朋友的圈',
          settings: settings,
        ),
      ));
      await tester.pump();

      expect(find.text('再试一次'), findsNothing);
    });
  });
}
