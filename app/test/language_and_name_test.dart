/// 语言切换与昵称改名的回归测试。
///
/// 这里有两条**曾经真实存在的 bug**,每条都配了一个会失败的用例:
///
/// 1. 改名之后,一次掉线重连就把名字悄悄变回去了 —— 因为 `SignalingClient`
///    把整条 hello 存成 `_identity` 快照,重连时原样重放,而改名从没动过它。
/// 2. 改名对聊天完全不可见 —— `ChatService` 持的是启动时从 `Identity.name`
///    拷来的一份值,`rename()` 改的是 `RoomController.userName`,两者毫无关系。
///
/// 这两条的共同形状是「同一个事实存了两份,只改了一份」。所以断言都盯着
/// **线上真正发出去的字节**,而不是某个字段的内存值 —— 后者当初也是「对」的。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/l10n/gen/app_localizations.dart';
// 直接引实现类:app_localizations.dart 只 import 了它们,没有 export。
// 与 test/helpers/localized_app.dart 里 zhStrings() 同样的做法。
import 'package:lares_app/l10n/gen/app_localizations_en.dart';
import 'package:lares_app/l10n/gen/app_localizations_zh.dart';
import 'package:lares_app/src/auth/auth_credential.dart';
import 'package:lares_app/src/chat/chat_envelope.dart';
import 'package:lares_app/src/chat/chat_service.dart';
import 'package:lares_app/src/chat/chat_transport.dart';
import 'package:lares_app/src/net/signaling_client.dart';
import 'package:lares_app/src/rtc/rtc_service.dart';
import 'package:lares_app/src/state/identity.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/state/settings_store.dart';
import 'package:lares_app/src/text/grapheme_text.dart';
import 'package:lares_app/src/ui/settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';
// stream_channel 是 web_socket_channel 的传递依赖,这里只为实现假通道用它的 mixin;
// 与 signaling_auth_test.dart 里同样的理由,不动 pubspec。
// ignore: depend_on_referenced_packages
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'helpers/localized_app.dart';

// ─────────────────────────────────────────────────────────────────────
// 假通道:与 signaling_auth_test.dart 里那套同款(不共用是为了不去动那个文件)。
// 关键能力是「每次 connect 产出一条新通道」—— 重连后发了什么,只能这样看见。
// ─────────────────────────────────────────────────────────────────────

class FakeChannel extends StreamChannelMixin implements WebSocketChannel {
  final StreamController<dynamic> incoming = StreamController<dynamic>();
  final List<String> sent = <String>[];
  bool closedByClient = false;

  List<Map<String, dynamic>> get sentJson => <Map<String, dynamic>>[
        for (final String s in sent) jsonDecode(s) as Map<String, dynamic>,
      ];

  List<Map<String, dynamic>> sentOfType(String t) => <Map<String, dynamic>>[
        for (final Map<String, dynamic> m in sentJson)
          if (m['t'] == t) m,
      ];

  void serverSend(Map<String, dynamic> msg) {
    if (!incoming.isClosed) incoming.add(jsonEncode(msg));
  }

  /// 模拟连接被掐断(服务端没了 / 网络断了),触发客户端排重连
  void serverDrop() {
    if (!incoming.isClosed) incoming.close();
  }

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  WebSocketSink get sink => _FakeSink(this);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future<void>.value();
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._ch);

  final FakeChannel _ch;

  @override
  void add(dynamic data) {
    if (_ch.closedByClient) return;
    _ch.sent.add(data as String);
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    _ch.closedByClient = true;
    if (!_ch.incoming.isClosed) await _ch.incoming.close();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {}

  @override
  Future<void> get done => _ch.incoming.done;
}

/// 连接工厂:每次 connect 产出一条新通道并记下来。
class FakeConnector {
  final List<FakeChannel> channels = <FakeChannel>[];

  FakeChannel get last => channels.last;

  WebSocketChannel connect(Uri uri) {
    final FakeChannel ch = FakeChannel();
    channels.add(ch);
    return ch;
  }
}

/// 假 ChatTransport:只记录发出的帧。
class FakeChatTransport implements ChatTransport {
  final List<Uint8List> sent = <Uint8List>[];
  final StreamController<ChatInboundFrame> _c =
      StreamController<ChatInboundFrame>.broadcast();

  @override
  Future<void> send(Uint8List frame) async => sent.add(frame);

  @override
  Stream<ChatInboundFrame> get inbound => _c.stream;

  @override
  Future<void> dispose() async {
    if (!_c.isClosed) await _c.close();
  }
}

/// 记录发出消息的假信令(给 RoomController 用,不碰 socket)。
class RecordingSignaling extends SignalingClient {
  RecordingSignaling() : super(url: 'ws://fake');

  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  @override
  void connect() {}

  @override
  void send(Map<String, dynamic> msg) => sent.add(msg);

  @override
  Future<void> dispose() async {}
}

class FakeRtcService implements RtcService {
  final StreamController<Set<String>> _speaking =
      StreamController<Set<String>>.broadcast();
  final StreamController<void> _dropped = StreamController<void>.broadcast();
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
  ResolvedAudioTuning? get activeTuning =>
      _inRoom ? previewTuning(AudioTuning.standard) : null;

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('语言切换', () {
    // 与 LaresApp 逐字同构的外壳:同一批 delegates、同一份 supportedLocales、
    // 同一个 localeResolutionCallback。不直接 pump LaresApp 是因为它要
    // RoomController + CircleStore + 一串可选协作者,而被测的只有 locale 这一条线。
    //
    // ⚠️ 断言取的是**真实生成的** AppLocalizations 的值,不是手抄的字面量。
    // 手抄一份等于把翻译复制成两处,改了 ARB 测试还绿 —— 那就白测了。
    Widget app(SettingsStore settings) => ListenableBuilder(
          listenable: settings,
          builder: (BuildContext context, _) => MaterialApp(
            locale: settings.preferredLocale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            localeResolutionCallback: (Locale? locale, Iterable<Locale> sup) {
              if (locale != null) {
                for (final Locale l in sup) {
                  if (l.languageCode == locale.languageCode) return l;
                }
              }
              return const Locale('en');
            },
            home: Builder(
              builder: (BuildContext ctx) =>
                  Text(AppLocalizations.of(ctx).settingsLanguage),
            ),
          ),
        );

    testWidgets('选中文/英文,界面文字真的跟着变', (WidgetTester tester) async {
      final SettingsStore settings = await loadSettings();

      await tester.pumpWidget(app(settings));

      await settings.setAppLanguage(AppLanguage.zh);
      await tester.pumpAndSettle();
      expect(find.text(zhLanguageLabel), findsOneWidget);

      await settings.setAppLanguage(AppLanguage.en);
      await tester.pumpAndSettle();
      expect(find.text(enLanguageLabel), findsOneWidget);
      // 中文那一版必须真的不见了 —— 否则只是多渲染了一份,不叫切换
      expect(find.text(zhLanguageLabel), findsNothing);
    });

    testWidgets('跟随系统:支持的系统语言用它自己,不支持的回落英文(不是中文)',
        (WidgetTester tester) async {
      final SettingsStore settings = await loadSettings();
      // 默认就是 system,preferredLocale 为 null,协商完全交给 Flutter
      expect(settings.preferredLocale, isNull);

      addTearDown(tester.platformDispatcher.clearLocalesTestValue);

      // 系统中文 -> 中文
      tester.platformDispatcher.localesTestValue = <Locale>[const Locale('zh')];
      await tester.pumpWidget(app(settings));
      await tester.pumpAndSettle();
      expect(find.text(zhLanguageLabel), findsOneWidget);

      // 系统法语(不支持)-> 英文。**绝不能**是中文:
      // App Store 主语言是 English,这条回落规则是上架叙事的一部分。
      tester.platformDispatcher.localesTestValue = <Locale>[const Locale('fr')];
      await tester.pumpAndSettle();
      expect(find.text(enLanguageLabel), findsOneWidget);
      expect(find.text(zhLanguageLabel), findsNothing);
    });

    test('appLanguage 按序数持久化,重新 load 记得住', () async {
      final SettingsStore a = await loadSettings();
      expect(a.appLanguage, AppLanguage.system, reason: '默认跟随系统');
      await a.setAppLanguage(AppLanguage.en);

      final SettingsStore b = await SettingsStore.load();
      expect(b.appLanguage, AppLanguage.en);
      expect(b.preferredLocale, const Locale('en'));
    });

    test('存了越界序号时 clamp 回落,不在启动路径上崩', () async {
      // 模拟「老版本存过一个更大的序号」(枚举将来若缩短就会这样)。
      // 直接取下标会 RangeError 崩在 App 启动路径上 —— 比语言不对严重得多。
      SharedPreferences.setMockInitialValues(<String, Object>{
        'lares.appLanguage': 99,
      });
      debugUseInMemoryVault = true;
      final SettingsStore s = await SettingsStore.load();
      expect(s.appLanguage, AppLanguage.values.last);
    });
  });

  group('改名:三份名字拷贝都要跟上', () {
    test('改名后重连,hello 带的是新名字而不是启动快照', () async {
      // 这是那条真 bug 的回归测试。用**真的** SignalingClient 配假通道,
      // 因为被测对象正是它内部的 _identity 快照重放逻辑。
      final FakeConnector conn = FakeConnector();
      final SignalingClient signaling = SignalingClient(
        url: 'wss://fake/ws',
        connector: conn.connect,
        userId: 'u_me',
        credentials: () => AuthCredential.none,
      );
      addTearDown(signaling.dispose);

      final RoomController controller = RoomController(
        signaling: signaling,
        rtc: FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '旧名字',
      );
      addTearDown(controller.dispose);

      signaling.connect();
      signaling.hello(
        userId: 'u_me',
        deviceId: 'd_1',
        name: '旧名字',
        platform: 'windows',
      );
      await pump();
      // 没有鉴权要求,challenge 超时后按老协议裸发 hello
      conn.last.serverSend(<String, dynamic>{
        't': 'challenge',
        'nonce': 'n' * 32,
        'modes': <String>[],
        'authRequired': false,
      });
      await pump();
      expect(conn.last.sentOfType('hello').single['name'], '旧名字');
      // welcome 才算握手完成。不走这一步的话 profile 会被压进 outbox
      // 而不是发出去 —— 那测的就不是「改名广播」了。
      conn.last.serverSend(<String, dynamic>{'t': 'welcome', 'userId': 'u_me'});
      await pump();

      // 改名。profile 帧走当前连接,同时刷新重连快照。
      controller.rename('新名字');
      await pump();
      expect(
        conn.last.sentOfType('profile').single['name'],
        '新名字',
        reason: '当前连接上的人应当立刻看到新名字',
      );

      // 掉线 -> 重连。新通道上重放的 hello 必须带新名字。
      //
      // 重连是真 Timer(退避从 1 秒起,见 _scheduleReconnect),抽微任务
      // 抽不动它,所以这里等真实时间。不用 fakeAsync 是因为本用例同时
      // 牵着 RoomController 的异步链,两套时间体系混在一起更难读。
      final int before = conn.channels.length;
      conn.last.serverDrop();
      await waitUntil(() => conn.channels.length > before);
      expect(conn.channels.length, greaterThan(before),
          reason: '应当已经重连出一条新通道');
      conn.last.serverSend(<String, dynamic>{
        't': 'challenge',
        'nonce': 'm' * 32,
        'modes': <String>[],
        'authRequired': false,
      });
      await pump();

      final List<Map<String, dynamic>> replayed = conn.last.sentOfType('hello');
      expect(replayed, isNotEmpty, reason: '重连后应当重新自报家门');
      expect(
        replayed.last['name'],
        '新名字',
        reason: '重连重放的 hello 若还带旧名字,所有人看到的名字就悄悄变回去了',
      );
    });

    test('改名后发出的聊天帧带新名字(ChatService 不再持死拷贝)', () async {
      final RecordingSignaling signaling = RecordingSignaling();
      final RoomController controller = RoomController(
        signaling: signaling,
        rtc: FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '旧名字',
      );
      addTearDown(controller.dispose);

      final FakeChatTransport transport = FakeChatTransport();
      final ChatService chat = ChatService(
        transport: transport,
        userId: 'u_me',
        // 正是 main.dart 里的接法:现取,不拷
        userNameGetter: () => controller.userName,
        circleIdGetter: () => 'home',
      );
      addTearDown(() async {
        chat.dispose();
        await transport.dispose();
      });

      await chat.sendText('改名前');
      expect(senderNameOf(transport.sent.last), '旧名字');

      controller.rename('新名字');
      await chat.sendText('改名后');
      expect(
        senderNameOf(transport.sent.last),
        '新名字',
        reason: '此前 ChatService 持的是启动快照,改名对聊天完全不可见',
      );
    });

    test('空名字被拒:不改、不广播', () {
      final RecordingSignaling signaling = RecordingSignaling();
      final RoomController controller = RoomController(
        signaling: signaling,
        rtc: FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
      );
      addTearDown(controller.dispose);
      signaling.sent.clear();

      controller.rename('');
      controller.rename('   ');
      controller.rename('\u3000\t\n'); // 全角空格也算空白

      expect(controller.userName, '我');
      expect(
        signaling.sent.where((Map<String, dynamic> m) => m['t'] == 'profile'),
        isEmpty,
        reason: '一个没有名字的人在成员列表里就是一行空白,别人无从称呼',
      );
    });

    test('超长名字按字素簇截到 24,且不劈开 emoji', () {
      final RecordingSignaling signaling = RecordingSignaling();
      final RoomController controller = RoomController(
        signaling: signaling,
        rtc: FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
      );
      addTearDown(controller.dispose);

      // 30 个字素簇:23 个汉字 + 7 个家庭 emoji(每个 7 码点的 ZWJ 序列)。
      // 按 UTF-16 code unit 数会是 100 出头 —— 正是 maxLength 会数错的那种输入。
      const String family = '👨‍👩‍👧‍👦';
      final String long = '一二三四五六七八九十一二三四五六七八九十一二三${family * 7}';
      expect(graphemeCount(long), 30, reason: '先确认这个输入真的是 30 簇');

      controller.rename(long);

      expect(graphemeCount(controller.userName), maxNicknameGraphemes);
      // 第 24 簇是第一个家庭 emoji,必须**完整**保留 —— 劈开会渲染成乱码方块
      expect(controller.userName.endsWith(family), isTrue,
          reason: '截断点落在 emoji 上时不许把它切成半个代理对');
      expect(
        signaling.sent
            .where((Map<String, dynamic> m) => m['t'] == 'profile')
            .single['name'],
        controller.userName,
        reason: '广播出去的必须与本地生效的是同一个值',
      );
    });

    testWidgets('设置页改名对话框:空/纯空白时确认按钮是灰的', (WidgetTester tester) async {
      final SettingsStore settings = await loadSettings();
      final RecordingSignaling signaling = RecordingSignaling();
      final RoomController controller = RoomController(
        signaling: signaling,
        rtc: FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(localizedApp(
        Builder(
          builder: (BuildContext ctx) => TextButton(
            onPressed: () => showSettingsSheet(
              ctx,
              settings: settings,
              controller: controller,
              signalingUrl: 'ws://fake',
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 「我的名字」那一行,副标题就是当前昵称
      final AppLocalizations t = zhStrings();
      expect(find.text(t.settingsMyName), findsOneWidget);
      await tester.tap(find.text(t.settingsMyName));
      await tester.pumpAndSettle();

      // 预填的是当前名字,非空 -> 可保存
      expect(find.text(t.settingsMyNameTitle), findsOneWidget);
      expect(confirmButton(tester).onPressed, isNotNull);

      // 清空 -> 按钮必须当场变灰(靠 StatefulBuilder + onChanged 实时反应)
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(confirmButton(tester).onPressed, isNull);

      // 纯空白同理:trim 之后还是空
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      expect(confirmButton(tester).onPressed, isNull,
          reason: '全是空格的名字在成员列表里就是一行空白');

      // 填回真名字 -> 又能按了
      await tester.enterText(find.byType(TextField), '新名字');
      await tester.pump();
      expect(confirmButton(tester).onPressed, isNotNull);
      await tester.tap(find.text(t.homeRenameConfirm));
      await tester.pumpAndSettle();
      expect(controller.userName, '新名字');
    });

    test('capNickname 是 UI 与 rename 共用的那一个口径', () {
      // UI 落盘用 capNickname,rename 内部也用它 —— 两边算出来必须一样,
      // 否则「存下去的」和「用起来的」会差一截(每次启动名字自己变短)。
      const String raw = '  一二三四五六七八九十一二三四五六七八九十一二三四五六  ';
      final String capped = capNickname(raw);
      expect(graphemeCount(capped), maxNicknameGraphemes);
      expect(capped, capGraphemes(raw.trim(), maxNicknameGraphemes));
      expect(capNickname('   '), isEmpty);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────
// 辅助
// ─────────────────────────────────────────────────────────────────────

/// 从一条已编码的聊天帧里把发送者昵称抠出来('sn' 是 chat_envelope 定的键名)
String senderNameOf(Uint8List frame) {
  final ChatFrame f = decodeFrame(frame);
  expect(f.isOk, isTrue, reason: '帧本身该是合法的,否则断言的是别的毛病');
  return f.header['sn'] as String;
}

/// 事件队列抽干(入站/重连定时器都是异步的)
Future<void> pump([int times = 8]) async {
  for (int i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 轮询等一个条件成立(默认最多 5 秒)。
///
/// 给「被测代码用的是真 Timer」的场合:重连退避从 1 秒起,
/// 抽微任务抽不动它。轮询而不是死等固定时长,是为了条件一成立就往下走,
/// 不给测试套件白添 1 秒。
Future<void> waitUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// 干净的 SettingsStore:空 prefs + 内存 vault
/// (真 vault 在 `flutter test` 里会**挂起**而不是报错,见 settings_store.dart)。
Future<SettingsStore> loadSettings() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  debugUseInMemoryVault = true;
  return SettingsStore.load();
}

/// 改名对话框里的确认按钮(复用了既有的 homeRenameConfirm 文案)。
/// 取 FilledButton 本身而不是找文字:要断言的是 `onPressed` 是否为 null。
FilledButton confirmButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byType(FilledButton));

/// 断言用的文案取自**真实生成的** AppLocalizations 实现类,不是手抄的字面量。
/// 手抄等于把翻译复制成两处 —— 改了 ARB 测试还绿,那就白测了。
final String zhLanguageLabel = AppLocalizationsZh().settingsLanguage;
final String enLanguageLabel = AppLocalizationsEn().settingsLanguage;
