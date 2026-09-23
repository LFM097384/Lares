import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/net/secret_vault.dart';
import 'package:lares_app/src/net/server_profile.dart';
import 'package:lares_app/src/net/signaling_client.dart';
import 'package:lares_app/src/platform/push_service.dart';
import 'package:lares_app/src/rtc/rtc_service.dart';
import 'package:lares_app/src/state/circle_store.dart';
import 'package:lares_app/src/state/models.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/state/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// PushService 的行为验收:发给服务器什么、什么时候问权限、点了通知进哪个圈、麦克风开不开。
/// 原生侧(Swift)在 Windows 上编译不了,那一半由 push_contract_test.dart 做字符串对账。

class _Signaling extends SignalingClient {
  _Signaling() : super(url: 'ws://fake');
  final List<Map<String, dynamic>> sent = [];
  @override
  void connect() {}
  @override
  void send(Map<String, dynamic> msg) => sent.add(msg);
  @override
  Future<bool> waitHandshake(Duration timeout) async => true;
  @override
  Future<void> dispose() async {}
}

/// 只记录「以什么麦克风状态进房」的 RTC 假件
class _Rtc implements RtcService {
  final _speaking = StreamController<Set<String>>.broadcast();
  final _dropped = StreamController<void>.broadcast();
  bool _inRoom = false;
  final List<bool> joinStartMuted = [];

  @override
  bool get inRoom => _inRoom;
  @override
  Future<RtcJoinResult> join({
    required String url,
    required String token,
    required bool startMuted,
    bool highQuality = true,
    AudioTuning tuning = AudioTuning.standard,
  }) async {
    joinStartMuted.add(startMuted);
    _inRoom = true;
    return RtcJoinResult(
        elapsed: const Duration(milliseconds: 5), micOn: !startMuted);
  }

  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> leave() async => _inRoom = false;
  @override
  Stream<Set<String>> get speakingIdentities => _speaking.stream;
  @override
  Stream<void> get onDisconnected => _dropped.stream;
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
}

class _Platform implements PushPlatform {
  String status = 'authorized';
  String? tokenValue = 'ab' * 32;
  bool grant = true;
  Map<String, dynamic>? initialOpen;
  int requestCalls = 0;
  int initialOpenCalls = 0;
  void Function(String)? onToken;
  Future<void> Function(Map<String, dynamic>)? onOpen;

  @override
  Future<bool> requestPermission() async {
    requestCalls++;
    if (grant) status = 'authorized';
    return grant;
  }

  @override
  Future<String?> getToken() async =>
      _granted.contains(status) ? tokenValue : null;
  static const _granted = {'authorized', 'provisional', 'ephemeral'};

  @override
  Future<String> permissionStatus() async => status;

  @override
  Future<Map<String, dynamic>?> getInitialOpen() async {
    initialOpenCalls++;
    final o = initialOpen;
    initialOpen = null;
    return o;
  }

  @override
  Future<String> getEnvironment() async => 'sandbox';

  @override
  void setHandler({
    required void Function(String token) onToken,
    required Future<void> Function(Map<String, dynamic> open) onOpen,
  }) {
    this.onToken = onToken;
    this.onOpen = onOpen;
  }
}

class _Harness {
  _Harness(this.signaling, this.rtc, this.controller, this.settings,
      this.circles, this.platform, this.messages);
  final _Signaling signaling;
  final _Rtc rtc;
  final RoomController controller;
  final SettingsStore settings;
  final CircleStore circles;
  final _Platform platform;
  final StreamController<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>> pushSent = [];
  late PushService push;
  int explainCalls = 0;
  bool explainAnswer = true;

  List<Map<String, dynamic>> get registers =>
      pushSent.where((m) => m['t'] == PushService.msgRegister).toList();
  List<Map<String, dynamic>> get unregisters =>
      pushSent.where((m) => m['t'] == PushService.msgUnregister).toList();

  Future<void> welcome() async {
    messages.add({'t': 'welcome'});
    await pumpEventQueue();
  }

  /// 用户主动进圈并连上媒体
  Future<void> enterRoom(String circleId) async {
    unawaited(controller.join(circleId).catchError((Object _) {}));
    await controller.testInjectToken('wss://fake', 'tok');
    await pumpEventQueue();
  }
}

Future<_Harness> _make({
  String platformName = 'ios',
  String status = 'authorized',
  bool joinWithMicOn = true,
  bool init = true,
}) async {
  final settings = await SettingsStore.load(vault: InMemorySecretVault());
  await settings.setJoinWithMicOn(joinWithMicOn);
  await settings.setServerProfiles(const ServerProfiles(
    profiles: [
      ServerProfile(id: 'srvA', label: 'A', url: 'ws://fake'),
      ServerProfile(id: 'srvB', label: 'B', url: 'wss://other.example/ws'),
    ],
    activeId: 'srvA',
  ));
  final circles = await CircleStore.load();
  await circles.add(const Circle(id: 'work', name: '工作'));
  await circles.add(const Circle(id: 'far', name: '远方', serverId: 'srvB'));
  await circles.add(const Circle(id: 'here', name: '这台', serverId: 'srvA'));
  final signaling = _Signaling();
  final rtc = _Rtc();
  final controller = RoomController(
    signaling: signaling,
    rtc: rtc,
    userId: 'u_me',
    deviceId: 'd_1',
    userName: '我',
    settings: settings,
  );
  addTearDown(controller.dispose);
  final platform = _Platform()..status = status;
  final messages = StreamController<Map<String, dynamic>>.broadcast();
  addTearDown(messages.close);
  final h = _Harness(
      signaling, rtc, controller, settings, circles, platform, messages);
  h.push = PushService(
    controller: controller,
    settings: settings,
    circleStore: circles,
    messages: messages.stream,
    send: h.pushSent.add,
    explain: () async {
      h.explainCalls++;
      return h.explainAnswer;
    },
    platform: platform,
    platformOverride: platformName,
    systemLanguage: () => 'zh',
  );
  addTearDown(h.push.dispose);
  if (init) await h.push.init();
  return h;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('push_register 的内容', () {
    test('形状正确,只含当前服务器上的圈,静音标记来自设置', () async {
      final h = await _make();
      await h.settings.setCirclePushMuted('work', true);
      await h.welcome();
      final m = h.registers.last;
      expect(m['t'], 'push_register');
      expect(m['provider'], 'apns');
      expect(m['token'], 'ab' * 32);
      expect(m['env'], 'sandbox');
      expect(m['lang'], 'zh');
      final circles = (m['circles'] as List).cast<Map<String, dynamic>>();
      // home(serverId null)、work(null)、here(srvA = 当前)在;far(srvB)不在
      expect(circles.map((c) => c['circleId']), ['home', 'work', 'here']);
      expect(circles.firstWhere((c) => c['circleId'] == 'work')['muted'], isTrue);
      expect(circles.firstWhere((c) => c['circleId'] == 'home')['muted'], isFalse);
      expect(circles.firstWhere((c) => c['circleId'] == 'work')['name'], '工作');
    });

    test('没见过 welcome 不发;每次 welcome 都重发', () async {
      final h = await _make();
      expect(h.pushSent, isEmpty);
      await h.welcome();
      expect(h.registers, hasLength(1));
      await h.welcome();
      expect(h.registers, hasLength(2), reason: '服务器可能重启过,握手后必须整份重发');
    });

    test('内容没变不重发;改名 / 静音 / 语言 / 增删圈都会重发', () async {
      final h = await _make();
      await h.welcome();
      expect(h.registers, hasLength(1));
      h.settings.notifyListeners(); // 无关的设置变化
      await h.settings.setWifiOnlyHq(false);
      h.circles.notifyListeners();
      await pumpEventQueue();
      expect(h.registers, hasLength(1), reason: '去重:同样的内容不发第二遍');

      await h.settings.setCirclePushMuted('home', true);
      expect(h.registers, hasLength(2));
      expect((h.registers.last['circles'] as List).first['muted'], isTrue);

      await h.settings.setAppLanguage(AppLanguage.en);
      expect(h.registers, hasLength(3));
      expect(h.registers.last['lang'], 'en');

      await h.circles.add(const Circle(id: 'new', name: '新圈'));
      expect(h.registers, hasLength(4));

      await h.circles.remove('new');
      expect(h.registers, hasLength(5));
    });

    test('换了当前服务器:名单跟着变', () async {
      final h = await _make();
      await h.welcome();
      await h.settings.setServerProfiles(h.settings.serverProfiles
          .copyWith(activeId: 'srvB'));
      final ids = (h.registers.last['circles'] as List)
          .map((c) => (c as Map)['circleId']);
      expect(ids, ['home', 'work', 'far']);
    });

    test('没有 token(没授权)什么都不发', () async {
      final h = await _make(status: 'denied');
      await h.welcome();
      expect(h.pushSent, isEmpty);
    });

    test('token 晚到(授权之后)立刻补发', () async {
      final h = await _make(status: 'notDetermined');
      await h.welcome();
      expect(h.pushSent, isEmpty);
      h.platform.onToken!('cd' * 32);
      expect(h.registers.single['token'], 'cd' * 32);
    });
  });

  group('总开关', () {
    test('关掉 -> 只发一次 push_unregister,之后不再注册', () async {
      final h = await _make();
      await h.welcome();
      await h.settings.setPushEnabled(false);
      expect(h.unregisters, hasLength(1));
      expect(h.unregisters.single['token'], 'ab' * 32);
      final before = h.pushSent.length;
      await h.settings.setCirclePushMuted('work', true);
      await h.settings.setAppLanguage(AppLanguage.en);
      h.messages.add({'t': 'push_unregistered'});
      await pumpEventQueue();
      await h.welcome();
      expect(h.pushSent.length, before, reason: '关着就彻底安静(已确认退订,welcome 也不再发)');
      expect(h.registers, hasLength(1));
    });

    test('重新打开 -> 再注册', () async {
      final h = await _make();
      await h.welcome();
      await h.settings.setPushEnabled(false);
      await h.settings.setPushEnabled(true);
      expect(h.pushSent.last['t'], 'push_register');
    });

    test('设置持久化', () async {
      final s = await SettingsStore.load(vault: InMemorySecretVault());
      expect(s.pushEnabled, isTrue);
      expect(s.pushPermissionAsked, isFalse);
      await s.setPushEnabled(false);
      await s.setCirclePushMuted('a', true);
      await s.markPushPermissionAsked();
      final again = await SettingsStore.load(vault: InMemorySecretVault());
      expect(again.pushEnabled, isFalse);
      expect(again.pushMutedCircles, {'a'});
      expect(again.pushPermissionAsked, isTrue);
    });
  });

  group('权限', () {
    test('装好之后不问;第一次进房后才问,只问一次', () async {
      final h = await _make(status: 'notDetermined');
      await pumpEventQueue();
      expect(h.explainCalls, 0);
      expect(h.platform.requestCalls, 0);

      await h.enterRoom('home');
      expect(h.explainCalls, 1);
      expect(h.platform.requestCalls, 1);
      expect(h.settings.pushPermissionAsked, isTrue);

      await h.controller.leave();
      await h.enterRoom('work');
      expect(h.explainCalls, 1, reason: '只问一次');
      expect(h.platform.requestCalls, 1);
    });

    test('同意 -> 拿到 token 并注册', () async {
      final h = await _make(status: 'notDetermined');
      await h.welcome();
      expect(h.pushSent, isEmpty);
      await h.enterRoom('home');
      expect(h.registers, hasLength(1));
    });

    test('点「算了」:记为已问,不调系统权限框,下次启动也不再问', () async {
      final h = await _make(status: 'notDetermined');
      h.explainAnswer = false;
      await h.enterRoom('home');
      expect(h.explainCalls, 1);
      expect(h.platform.requestCalls, 0);
      expect(h.settings.pushPermissionAsked, isTrue);
      final again = await SettingsStore.load(vault: InMemorySecretVault());
      expect(again.pushPermissionAsked, isTrue);
    });

    test('之前问过(持久化)就不再问', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{'lares.pushPermissionAsked': true});
      final h = await _make(status: 'notDetermined');
      await h.enterRoom('home');
      expect(h.explainCalls, 0);
      expect(h.platform.requestCalls, 0);
    });

    test('总开关关着不问;已拒绝(denied)不问', () async {
      final a = await _make(status: 'notDetermined', init: false);
      await a.settings.setPushEnabled(false);
      await a.push.init();
      await a.enterRoom('home');
      expect(a.explainCalls, 0);

      final b = await _make(status: 'denied');
      await b.enterRoom('home');
      expect(b.explainCalls, 0);
      expect(b.settings.pushPermissionAsked, isFalse);
    });
  });

  group('点了通知', () {
    test('空闲时点「加入」-> 进圈,麦克风按设置(开)', () async {
      final h = await _make(joinWithMicOn: true);
      await h.platform.onOpen!({'circleId': 'work', 'action': 'JOIN'});
      expect(h.controller.circleId, 'work');
      expect(h.controller.phase, RoomPhase.joining);
      await h.controller.testInjectToken('wss://fake', 'tok');
      expect(h.rtc.joinStartMuted, [false], reason: '用户亲手点的 = 主动进圈');
    });

    test('设置「进圈时打开麦克风」关 -> 点通知静音进', () async {
      final h = await _make(joinWithMicOn: false);
      await h.platform.onOpen!({'circleId': 'work', 'action': 'open'});
      await h.controller.testInjectToken('wss://fake', 'tok');
      expect(h.rtc.joinStartMuted, [true]);
    });

    test('在别的房间 -> 先退再进', () async {
      final h = await _make();
      await h.enterRoom('home');
      h.signaling.sent.clear();
      await h.platform.onOpen!({'circleId': 'work', 'action': 'JOIN'});
      final types = h.signaling.sent.map((m) => m['t']).toList();
      expect(types.indexOf('leave'), lessThan(types.indexOf('join')));
      expect(h.signaling.sent.lastWhere((m) => m['t'] == 'join')['circleId'],
          'work');
      expect(h.controller.circleId, 'work');
    });

    test('已经在这个圈里 -> 什么都不做', () async {
      final h = await _make();
      await h.enterRoom('home');
      h.signaling.sent.clear();
      await h.platform.onOpen!({'circleId': 'home', 'action': 'JOIN'});
      expect(h.signaling.sent.where((m) => m['t'] == 'leave'), isEmpty);
      expect(h.signaling.sent.where((m) => m['t'] == 'join'), isEmpty);
      expect(h.controller.phase, RoomPhase.inRoom);
    });

    test('本机没有的圈 -> 不理', () async {
      final h = await _make();
      await h.platform.onOpen!({'circleId': 'stranger', 'action': 'JOIN'});
      expect(h.controller.phase, RoomPhase.idle);
    });

    test('冷启动缓冲:init(= 同意之后)时取走并进圈', () async {
      final h = await _make(init: false);
      h.platform.initialOpen = {'circleId': 'work', 'action': 'JOIN'};
      await pumpEventQueue();
      expect(h.controller.phase, RoomPhase.idle, reason: 'init 之前(未同意)不许进圈');
      await h.push.init();
      expect(h.platform.initialOpenCalls, 1);
      expect(h.controller.circleId, 'work');
      await h.controller.testInjectToken('wss://fake', 'tok');
      expect(h.rtc.joinStartMuted, [false]);
    });

    test('另一台**已存**的服务器 -> 切过去再进,麦克风按设置', () async {
      final h = await _make(joinWithMicOn: true);
      await h.platform.onOpen!({
        'circleId': 'far',
        'action': 'JOIN',
        // 写法与档案不同(带默认端口、结尾斜杠),仍应认出是同一台
        'server': 'wss://OTHER.example:443/ws/',
      });
      expect(h.signaling.url, 'wss://other.example/ws');
      expect(h.controller.circleId, 'far');
      await h.controller.testInjectToken('wss://fake', 'tok');
      expect(h.rtc.joinStartMuted, [false],
          reason: 'switchServerAndJoin 收到 micOn: null,不能被默认值 false 盖掉');
    });

    test('通知里的地址不认识 -> 不理(不把主连接指向任意地址)', () async {
      final h = await _make();
      await h.platform.onOpen!({
        'circleId': 'work',
        'action': 'JOIN',
        'server': 'wss://evil.example/ws',
      });
      expect(h.signaling.url, 'ws://fake');
      expect(h.controller.phase, RoomPhase.idle);
    });

    test('通知里的地址就是当前服务器 -> 按本服务器处理', () async {
      final h = await _make();
      await h.platform.onOpen!(
          {'circleId': 'work', 'action': 'JOIN', 'server': 'ws://fake/'});
      expect(h.signaling.url, 'ws://fake');
      expect(h.controller.circleId, 'work');
    });
  });

  group('地址比较', () {
    test('默认端口、大小写、结尾斜杠视为同一台', () {
      expect(PushService.normalizeUrl('wss://h.example/ws'),
          PushService.normalizeUrl('wss://H.example:443/ws/'));
      expect(PushService.normalizeUrl('ws://h:80'),
          PushService.normalizeUrl('ws://h/'));
      expect(PushService.normalizeUrl('wss://h/ws'),
          isNot(PushService.normalizeUrl('wss://h:8443/ws')));
      expect(PushService.normalizeUrl('wss://h/ws'),
          isNot(PushService.normalizeUrl('ws://h/ws')));
    });
  });

  group('非 iOS', () {
    for (final p in ['android', 'web', 'windows', 'macos']) {
      test('$p:什么都不做', () async {
        final h = await _make(platformName: p, status: 'notDetermined');
        h.platform.initialOpen = {'circleId': 'work', 'action': 'JOIN'};
        await h.push.init();
        await h.welcome();
        await h.enterRoom('home');
        expect(h.pushSent, isEmpty);
        expect(h.explainCalls, 0);
        expect(h.platform.onOpen, isNull);
        expect(h.platform.initialOpenCalls, 0);
      });
    }
  });

  group('RoomController.switchServerAndJoin 的 micOn', () {
    test('默认仍是 false(presence reach 不是用户点的,不许开麦)', () async {
      final h = await _make(joinWithMicOn: true, init: false);
      await h.controller.switchServerAndJoin(
          circleId: 'far', url: 'wss://other.example/ws');
      await h.controller.testInjectToken('wss://fake', 'tok');
      expect(h.rtc.joinStartMuted, [true]);
    });
  });
}
