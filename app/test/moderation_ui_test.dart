import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/chat/chat_envelope.dart';
import 'package:lares_app/src/chat/chat_message.dart';
import 'package:lares_app/src/chat/chat_service.dart';
import 'package:lares_app/src/chat/chat_transport.dart';
import 'package:lares_app/src/moderation/block_store.dart';
import 'package:lares_app/src/moderation/report.dart';
import 'package:lares_app/src/net/signaling_client.dart';
import 'package:lares_app/src/rtc/rtc_service.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/ui/chat_panel.dart';
import 'package:lares_app/src/ui/moderation_menus.dart';
import 'package:lares_app/src/ui/room_screen.dart';
import 'package:lares_app/src/ui/widgets/avatar_orb.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/localized_app.dart';
import 'helpers/report_reason_labels.dart';

/// 假信令:不碰真实 socket,只记录发出的消息(与 room_screen_test.dart 同款)
class FakeSignalingClient extends SignalingClient {
  FakeSignalingClient() : super(url: 'ws://fake');

  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  @override
  void connect() {}

  @override
  void send(Map<String, dynamic> msg) => sent.add(msg);

  @override
  Future<void> dispose() async {}
}

/// 假 RTC:一行网络都不碰(与 room_screen_test.dart 同款)
class FakeRtcService implements RtcService {
  final StreamController<Set<String>> _speaking =
      StreamController<Set<String>>.broadcast();
  final StreamController<void> _dropped = StreamController<void>.broadcast();
  bool _inRoom = false;
  bool muted = true;

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
    muted = startMuted;
    return const Duration(milliseconds: 120);
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
  Future<void> setMuted(bool m) async {
    muted = m;
  }

  @override
  Stream<Set<String>> get speakingIdentities => _speaking.stream;

  @override
  Stream<void> get onDisconnected => _dropped.stream;
}

/// 假传输:只需要能把一帧「别人发来的消息」投进 ChatService
class FakeTransport implements ChatTransport {
  final StreamController<ChatInboundFrame> _c =
      StreamController<ChatInboundFrame>.broadcast();

  @override
  Future<void> send(Uint8List frame) async {}

  @override
  Stream<ChatInboundFrame> get inbound => _c.stream;

  @override
  Future<void> dispose() async {
    if (!_c.isClosed) await _c.close();
  }

  /// 投一条别人发来的文字消息。走**真实**的信封编解码路径,
  /// 而不是往私有列表里塞 —— 这样测到的才是线上那条链路。
  void deliverText({
    required String id,
    required String senderId,
    required String senderName,
    required String body,
    String circleId = 'home',
  }) {
    if (_c.isClosed) return;
    _c.add(
      ChatInboundFrame(
        senderIdentity: senderId,
        bytes: encodeFrame(
          buildTextHeader(
            id: id,
            senderId: senderId,
            senderName: senderName,
            circleId: circleId,
            timestamp: DateTime(2026, 1, 1, 9, 30),
            body: body,
          ),
        ),
      ),
    );
  }
}

/// 统一宿主:固定暗色主题 + Scaffold(SnackBar 需要 ScaffoldMessenger)
Widget _host(Widget child) =>
    localizedScaffold(child, theme: LaresTheme.dark());

/// 展开态的 ChatPanel 收到新消息会起一段滚动动画([_scrollDuration] 160ms),
/// 用例结束时它可能还没跑完,框架就会报
/// 「A Timer is still pending even after the widget tree was disposed」。
///
/// 断言做完之后调一次:先把动画走完,再把整棵树换成空壳,
/// 逼 ChatPanelState.dispose() 收掉 ScrollController。
/// 不用 addTearDown 是因为它是 LIFO —— 会排在 chat.dispose() **之前**跑,
/// 那时面板还挂着,等于没拆。
Future<void> _settleAndUnmount(WidgetTester tester, ChatService chat) async {
  // ChatService 内部的 ImageAssembler 挂着一个 5 秒的 Timer.periodic,
  // 只有 chat.dispose() 会取消它。addTearDown 是 LIFO,拆树会排在
  // chat.dispose() 之前,所以这里必须显式、按顺序来:
  // 先把树拆掉(停掉展开态的 AnimatedSize / 滚动动画),再关掉 ChatService。
  await tester.pumpAndSettle();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  chat.dispose();
}

/// 把窗口调高一点并登记复位。举报对话框有七个分类 + 输入框,
/// 默认 600px 高的测试窗里会被滚动条藏掉一半,断言就成了碰运气。
void _tallWindow(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(900, 1600)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 房间页里有个永不停歇的呼吸背景动画,`pumpAndSettle` 会一直等到超时。
/// 所以房间页的用例一律用「定量 pump」把弹层动画走完。
Future<void> _pumpSheet(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 造一个带两名成员(我 + 阿蛮)的房间控制器
/// ⚠️ 返回的 controller 必须由用例在**体内**调 [_disposeRoom] 收掉,
/// 不能用 addTearDown。
///
/// 理由与上面 [_settleAndUnmount] 同源但更隐蔽:`join()` 会挂一个 25 秒的
/// 进房总超时(room_controller.dart 的 joinTimeout),而本助手刻意把
/// controller 停在 joining —— 它只注入 'room' 不注入 token。于是用例结束时
/// 那个计时器还活着,框架报「A Timer is still pending after the widget tree
/// was disposed」。addTearDown 救不了:它排在框架这项检查**之后**才跑。
RoomController _roomWithMembers(WidgetTester tester) {
  final FakeSignalingClient signaling = FakeSignalingClient();
  final RoomController controller = RoomController(
    signaling: signaling,
    rtc: FakeRtcService(),
    userId: 'u_me',
    deviceId: 'd_1',
    userName: '我',
  );
  // join 只为把 circleId 定下来;它的 Future 要等 token 才完成,这里不等。
  // catchError 接住 dispose 时的 completeError,否则变成未捕获异步错误。
  unawaited(controller.join('home').catchError((Object _) {}));
  signaling.testInject(<String, dynamic>{
    't': 'room',
    'circleId': 'home',
    'members': <Map<String, dynamic>>[
      <String, dynamic>{'userId': 'u_me', 'name': '我', 'status': 'free'},
      <String, dynamic>{'userId': 'u_other', 'name': '阿蛮', 'status': 'free'},
    ],
  });
  return controller;
}

/// 拆掉房间页并收掉 controller。必须在用例**体内**调,理由见 [_roomWithMembers]。
Future<void> _disposeRoom(WidgetTester tester, RoomController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('成员网格的处置菜单', () {
    testWidgets('长按别人的头像:菜单里有「屏蔽这个人」和「举报」', (WidgetTester tester) async {
      final BlockStore blocks = await BlockStore.load();
      final RoomController controller = _roomWithMembers(tester);

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
      expect(find.text('阿蛮'), findsOneWidget);

      await tester.longPress(find.text('阿蛮'));
      await _pumpSheet(tester);

      expect(find.text('屏蔽这个人'), findsOneWidget);
      expect(find.text('举报'), findsOneWidget);
      // 踢人没有消失,只是从「长按直达」变成菜单里的一行
      expect(find.text('请出房间'), findsOneWidget);
      // 头部露出稳定 id:屏蔽认的是它,不是随时能改的昵称
      expect(find.text('u_other'), findsOneWidget);
      await _disposeRoom(tester, controller);
    });

    testWidgets('轻点别人的头像也能开菜单(长按太隐蔽)', (WidgetTester tester) async {
      final BlockStore blocks = await BlockStore.load();
      final RoomController controller = _roomWithMembers(tester);

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

      await tester.tap(find.text('阿蛮'));
      await _pumpSheet(tester);

      expect(find.text('屏蔽这个人'), findsOneWidget);
      expect(find.text('举报'), findsOneWidget);
      await _disposeRoom(tester, controller);
    });

    testWidgets('点「屏蔽这个人」:名单真的记下了,网格里也看得出来', (WidgetTester tester) async {
      final BlockStore blocks = await BlockStore.load();
      final RoomController controller = _roomWithMembers(tester);

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
      expect(blocks.isBlocked('u_other'), isFalse);
      // 还没屏蔽,标记不该出现
      expect(find.byIcon(Icons.block_rounded), findsNothing);

      await tester.longPress(find.text('阿蛮'));
      await _pumpSheet(tester);
      await tester.tap(find.text('屏蔽这个人'));
      // 菜单退场 + BlockStore 落盘(异步)+ 网格重绘
      await _pumpSheet(tester);
      await _pumpSheet(tester);

      expect(blocks.isBlocked('u_other'), isTrue);
      // 必须**看得见**:压暗 + 角标,否则用户不知道那一下生效了没有
      expect(find.byIcon(Icons.block_rounded), findsOneWidget);
      // 也必须**听得见**:读屏用户靠这个标签知道这人被屏蔽了。
      // AvatarOrb 自带 excludeSemantics,所以标记必须自己独立成语义节点
      // (见 _BlockedOverlay 的 container: true),否则标签会被整个吞掉。
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is Semantics && w.properties.label == '已屏蔽',
        ),
        findsOneWidget,
        reason: '被屏蔽的成员必须带上「已屏蔽」语义标签',
      );

      // 再开一次菜单,这回该是「解除屏蔽」
      await tester.longPress(find.text('阿蛮'));
      await _pumpSheet(tester);
      expect(find.text('解除屏蔽'), findsOneWidget);
      expect(find.text('屏蔽这个人'), findsNothing);
      await _disposeRoom(tester, controller);
    });

    testWidgets('自己的头像点不出处置菜单', (WidgetTester tester) async {
      final BlockStore blocks = await BlockStore.load();
      final RoomController controller = _roomWithMembers(tester);

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

      // 不能用 find.text('我'):房间头部有一个「我」,而 AvatarOrb 自己
      // 还会把名字渲染两遍(首字母 + 全名),一共撞上三个。
      // 直接按 AvatarOrb 定位,再挑出「我」的那一颗,语义最准。
      final Finder myOrb = find.byWidgetPredicate(
        (Widget w) => w is AvatarOrb && w.member.userId == 'u_me',
      );
      expect(myOrb, findsOneWidget);

      await tester.longPress(myOrb);
      await _pumpSheet(tester);
      expect(find.text('屏蔽这个人'), findsNothing);

      await tester.tap(myOrb);
      await _pumpSheet(tester);
      expect(find.text('屏蔽这个人'), findsNothing);
      await _disposeRoom(tester, controller);
    });

    testWidgets('不给 blocks 时一切照旧:长按仍是踢人确认', (WidgetTester tester) async {
      final RoomController controller = _roomWithMembers(tester);

      await tester.pumpWidget(
        localizedApp(
          RoomScreen(controller: controller, circleName: '我们的圈'),
          theme: LaresTheme.dark(),
        ),
      );
      await _pumpSheet(tester);

      await tester.longPress(find.text('阿蛮'));
      await _pumpSheet(tester);

      expect(find.text('屏蔽这个人'), findsNothing);
      expect(find.text('把「阿蛮」请出房间?'), findsOneWidget);
      await _disposeRoom(tester, controller);
    });
  });

  group('消息面板的屏蔽与处置', () {
    testWidgets('屏蔽后那条消息就不见了,解除屏蔽又原样回来', (WidgetTester tester) async {
      final BlockStore blocks = await BlockStore.load();
      final FakeTransport transport = FakeTransport();
      final ChatService chat = ChatService(
        transport: transport,
        userId: 'u_me',
        userNameGetter: () => '我',
        circleIdGetter: () => 'home',
        isBlocked: blocks.isBlocked,
      );
      addTearDown(() async {
        await transport.dispose();
      });

      await tester.pumpWidget(
        _host(ChatPanel(chat: chat, blocks: blocks, initiallyExpanded: true)),
      );
      transport.deliverText(
        id: 'm1',
        senderId: 'u_other',
        senderName: '阿蛮',
        body: '你们在干嘛',
      );
      await tester.pumpAndSettle();
      expect(find.text('你们在干嘛'), findsOneWidget);

      await blocks.block('u_other');
      await tester.pumpAndSettle();
      expect(find.text('你们在干嘛'), findsNothing);

      // 收进来的一条都没丢,只是读取时被过滤 —— 解封后历史必须原样回来
      await blocks.unblock('u_other');
      await tester.pumpAndSettle();
      expect(find.text('你们在干嘛'), findsOneWidget);

      await _settleAndUnmount(tester, chat);
    });

    testWidgets('长按别人的消息:开处置菜单,键是稳定的 senderId', (WidgetTester tester) async {
      final BlockStore blocks = await BlockStore.load();
      final FakeTransport transport = FakeTransport();
      final ChatService chat = ChatService(
        transport: transport,
        userId: 'u_me',
        userNameGetter: () => '我',
        circleIdGetter: () => 'home',
        isBlocked: blocks.isBlocked,
      );
      addTearDown(() async {
        await transport.dispose();
      });

      await tester.pumpWidget(
        _host(ChatPanel(chat: chat, blocks: blocks, initiallyExpanded: true)),
      );
      transport.deliverText(
        id: 'm1',
        senderId: 'u_other',
        senderName: '阿蛮',
        body: '在吗',
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.text('在吗'));
      await tester.pumpAndSettle();

      expect(find.text('屏蔽这个人'), findsOneWidget);
      expect(find.text('举报这条消息'), findsOneWidget);
      expect(find.text('u_other'), findsOneWidget);

      await tester.tap(find.text('屏蔽这个人'));
      await tester.pumpAndSettle();
      expect(blocks.isBlocked('u_other'), isTrue);
      // 屏蔽完那条消息也该消失了
      expect(find.text('在吗'), findsNothing);

      await _settleAndUnmount(tester, chat);
    });

    testWidgets('自己发的消息长按不出菜单', (WidgetTester tester) async {
      final BlockStore blocks = await BlockStore.load();
      final FakeTransport transport = FakeTransport();
      final ChatService chat = ChatService(
        transport: transport,
        userId: 'u_me',
        userNameGetter: () => '我',
        circleIdGetter: () => 'home',
        isBlocked: blocks.isBlocked,
      );
      addTearDown(() async {
        await transport.dispose();
      });

      await tester.pumpWidget(
        _host(ChatPanel(chat: chat, blocks: blocks, initiallyExpanded: true)),
      );
      await chat.sendText('我自己说的');
      await tester.pumpAndSettle();
      expect(find.text('我自己说的'), findsOneWidget);

      await tester.longPress(find.text('我自己说的'));
      await tester.pumpAndSettle();

      expect(find.text('屏蔽这个人'), findsNothing);
      expect(find.text('举报这条消息'), findsNothing);

      await _settleAndUnmount(tester, chat);
    });

    testWidgets('不给 blocks 时面板照旧工作,消息也不挂长按', (WidgetTester tester) async {
      final FakeTransport transport = FakeTransport();
      final ChatService chat = ChatService(
        transport: transport,
        userId: 'u_me',
        userNameGetter: () => '我',
        circleIdGetter: () => 'home',
      );
      addTearDown(() async {
        await transport.dispose();
      });

      await tester.pumpWidget(
        _host(ChatPanel(chat: chat, initiallyExpanded: true)),
      );
      transport.deliverText(
        id: 'm1',
        senderId: 'u_other',
        senderName: '阿蛮',
        body: '老样子',
      );
      await tester.pumpAndSettle();
      expect(find.text('老样子'), findsOneWidget);

      await tester.longPress(find.text('老样子'));
      await tester.pumpAndSettle();
      expect(find.text('屏蔽这个人'), findsNothing);

      await _settleAndUnmount(tester, chat);
    });
  });

  group('举报流程', () {
    /// 开一个只放举报流程的宿主,返回记录下来的草稿列表
    Future<List<ReportDraft>> openReportFlow(
      WidgetTester tester, {
      required BlockStore blocks,
      String? messageId,
      String? messageExcerpt,
    }) async {
      final List<ReportDraft> delivered = <ReportDraft>[];
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showReportFlow(
                context,
                blocks: blocks,
                targetUserId: 'u_other',
                targetName: '阿蛮',
                circleId: 'home',
                reporterUserId: 'u_me',
                messageId: messageId,
                messageExcerpt: messageExcerpt,
                delivery: (ReportDraft d) async => delivered.add(d),
              ),
              child: const Text('开举报'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('开举报'));
      await tester.pumpAndSettle();
      return delivered;
    }

    /// 拿到「提交举报」按钮的 onPressed —— null 就是灰的
    VoidCallback? submitHandler(WidgetTester tester) => tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '提交举报'))
        .onPressed;

    testWidgets('没选理由之前,提交键一直是灰的(绝不替用户预选)', (WidgetTester tester) async {
      _tallWindow(tester);
      final BlockStore blocks = await BlockStore.load();
      await openReportFlow(tester, blocks: blocks);

      // 七个分类都摆出来了,但一个都没选中
      for (final ReportReason r in ReportReason.values) {
        expect(find.text(zhReasonLabel(r)), findsOneWidget);
      }
      expect(submitHandler(tester), isNull);

      await tester.tap(find.text(zhReasonLabel(ReportReason.harassment)));
      await tester.pumpAndSettle();

      expect(submitHandler(tester), isNotNull);
    });

    testWidgets('提交一次只调一次送达,草稿里是稳定 id 和选中的理由', (WidgetTester tester) async {
      _tallWindow(tester);
      final BlockStore blocks = await BlockStore.load();
      final List<ReportDraft> delivered = await openReportFlow(
        tester,
        blocks: blocks,
        messageId: 'm1',
        messageExcerpt: '一段很难听的话',
      );

      await tester.tap(find.text(zhReasonLabel(ReportReason.hateSpeech)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '他连着说了三遍');
      await tester.pumpAndSettle();

      await tester.tap(find.text('提交举报'));
      await tester.pumpAndSettle();

      expect(delivered, hasLength(1));
      final ReportDraft draft = delivered.single;
      expect(draft.targetUserId, 'u_other');
      expect(draft.targetName, '阿蛮');
      expect(draft.reason, ReportReason.hateSpeech);
      expect(draft.note, '他连着说了三遍');
      expect(draft.circleId, 'home');
      expect(draft.reporterUserId, 'u_me');
      expect(draft.messageId, 'm1');
      expect(draft.messageExcerpt, '一段很难听的话');

      // 回执那句承诺要一字不差
      expect(find.text('已提交,我们会在 24 小时内处理'), findsOneWidget);
      // 没有 url_launcher,所以必须把邮箱摊在一个**不会自己溜走**的对话框里
      expect(find.text(kSupportEmail), findsOneWidget);
    });

    testWidgets('举报完顺手问屏蔽:点「屏蔽」就真的记下', (WidgetTester tester) async {
      _tallWindow(tester);
      final BlockStore blocks = await BlockStore.load();
      await openReportFlow(tester, blocks: blocks);

      await tester.tap(find.text(zhReasonLabel(ReportReason.spam)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('提交举报'));
      await tester.pumpAndSettle();

      // 先把「已复制,请发到这个邮箱」的说明关掉
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();

      expect(find.text('顺手屏蔽他?'), findsOneWidget);
      await tester.tap(find.text('屏蔽'));
      await tester.pumpAndSettle();

      expect(blocks.isBlocked('u_other'), isTrue);
    });

    testWidgets('已经屏蔽过的人,不再问第二遍', (WidgetTester tester) async {
      _tallWindow(tester);
      final BlockStore blocks = await BlockStore.load();
      await blocks.block('u_other');
      await openReportFlow(tester, blocks: blocks);

      await tester.tap(find.text(zhReasonLabel(ReportReason.other)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('提交举报'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();

      expect(find.text('顺手屏蔽他?'), findsNothing);
    });

    testWidgets('点「算了」就什么都不做:不送达、不屏蔽', (WidgetTester tester) async {
      _tallWindow(tester);
      final BlockStore blocks = await BlockStore.load();
      final List<ReportDraft> delivered = await openReportFlow(
        tester,
        blocks: blocks,
      );

      await tester.tap(find.text(zhReasonLabel(ReportReason.violence)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('算了'));
      await tester.pumpAndSettle();

      expect(delivered, isEmpty);
      expect(blocks.isBlocked('u_other'), isFalse);
      expect(find.text('已提交,我们会在 24 小时内处理'), findsNothing);
    });
  });

  group('举报正文', () {
    test('图片消息没有文字,摘录是空串(调用方应据此传 null)', () {
      const ChatMessageKind kind = ChatMessageKind.image;
      expect(kind, ChatMessageKind.image);
      expect(excerptForReport(null), '');
      expect(excerptForReport('   '), '');
    });
  });
}
