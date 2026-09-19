import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/chat/chat_limits.dart';
import 'package:lares_app/src/chat/chat_message.dart';
import 'package:lares_app/src/chat/chat_service.dart';
import 'package:lares_app/src/chat/chat_text.dart';
// 选图接缝的返回类型。测试 VM 上 dart.library.io 为真,
// 与 chat_panel.dart 的条件导入落到同一个实现文件,类型才对得上。
import 'package:lares_app/src/chat/image_source.dart'
    if (dart.library.io) 'package:lares_app/src/chat/image_source_io.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/ui/chat_panel.dart';

import 'helpers/localized_app.dart';

/// 最小合法 PNG:1×1、RGBA、全透明。
///
/// 为什么非得是真字节:`Image.memory` 拿到垃圾字节会走 errorBuilder,
/// 那样测到的是「降级路径」而不是「缩略图真的解出来了」。
/// 为什么写成字面量而不是 base64 解码:让人一眼看出这就是常量,
/// 也免得测试依赖 dart:convert 的解码结果。
/// 结构:8 字节 PNG 签名 + IHDR(13 字节数据)+ IDAT + IEND,各带 CRC32。
const List<int> _tinyPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG 签名
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR 段长 + 类型
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 宽 1、高 1
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //位深 8、色型 6(RGBA)+ CRC
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, // IDAT 段长 + 类型
  0x54, 0x78, 0xDA, 0x63, 0xFC, 0xCF, 0xC0, 0x50, // zlib 压缩的一个像素
  0x0F, 0x00, 0x04, 0x85, 0x01, 0x80, 0x84, 0xA9, //(续)+ CRC
  0x8C, 0x21, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, // IEND 段长 + 类型
  0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, // (续)+ CRC
];

/// ZWJ 家庭 emoji:6 个码点(4 个人 + 3 个零宽连接符),`String.length` 数出 11,
/// `characters.length` 数出 1。截断口径对不对,全看它会不会被劈开。
const String _family = '👨‍👩‍👧‍👦';

/// 假聊天服务:不碰 LiveKit、不碰传输层,只记录发送并驱动 UI 重建。
///
/// 用 `implements ChatService` 而非 `extends`:真实构造函数要
/// transport / circleIdGetter 等一堆协作者,继承就得把它们全造出来。
class FakeChatService extends ChangeNotifier implements ChatService {
  final List<String> sentTexts = <String>[];
  final List<Uint8List> sentImages = <Uint8List>[];
  final List<ChatMessage> _messages = <ChatMessage>[];
  int _unread = 0;
  int markReadCalls = 0;

  /// 非 null 时 [sendImage] 直接抛它,用来验证 UI 的宽 catch 不会把异常泄出去
  Object? imageError;

  @override
  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);

  @override
  int get unreadCount => _unread;

  @override
  void markRead() {
    markReadCalls++;
    if (_unread == 0) return;
    _unread = 0;
    notifyListeners();
  }

  @override
  Future<void> sendText(String raw) async {
    sentTexts.add(raw);
    _messages.add(
      ChatMessage.text(
        id: 'm${_messages.length}',
        senderId: 'u_me',
        senderName: '我',
        circleId: 'home',
        timestamp: DateTime(2026, 1, 1, 9, 5),
        body: raw,
        isMine: true,
      ),
    );
    notifyListeners();
  }

  @override
  Future<void> sendImage(
    Uint8List bytes, {
    int? width,
    int? height,
    String mime = 'image/png',
  }) async {
    final Object? err = imageError;
    if (err != null) throw err;
    sentImages.add(bytes);
    _messages.add(
      ChatMessage.image(
        id: 'm${_messages.length}',
        senderId: 'u_me',
        senderName: '我',
        circleId: 'home',
        timestamp: DateTime(2026, 1, 1, 9, 6),
        bytes: bytes,
        imageWidth: width,
        imageHeight: height,
        isMine: true,
      ),
    );
    notifyListeners();
  }

  /// 模拟别人发来一条消息(计未读),供未读圆点与自动滚动的用例驱动
  void pushIncoming(ChatMessage message) {
    _messages.add(message);
    _unread++;
    notifyListeners();
  }

  void seed(List<ChatMessage> initial, {int unread = 0}) {
    _messages
      ..clear()
      ..addAll(initial);
    _unread = unread;
    notifyListeners();
  }

  // 真实 ChatService 可能带有本 fake 未覆盖的成员(如 userId / userName);
  // 声明 noSuchMethod 可让分析器放过「未实现全部接口」的报错,
  // 同时保证误调用会立刻抛错暴露问题,而不是悄悄返回 null。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 统一的宿主:固定成暗色主题,与 room_screen_test.dart 一致。
Widget _host(Widget child) =>
    localizedScaffold(child, theme: LaresTheme.dark());

/// 把窗口调成指定尺寸与字体缩放,并登记好复位。
/// 直接改 tester.view 而不是套一层 MediaQuery,是为了让溢出检测作用于真实约束。
void _useWindow(
  WidgetTester tester, {
  required Size size,
  double textScale = 1.0,
}) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

ChatMessage _text(String body, {bool isMine = false, String sender = '阿蛮'}) =>
    ChatMessage.text(
      id: 'seed-$body-$sender',
      senderId: isMine ? 'u_me' : 'u_other',
      senderName: sender,
      circleId: 'home',
      timestamp: DateTime(2026, 1, 1, 9, 30),
      body: body,
      isMine: isMine,
    );

void main() {
  testWidgets('默认收起:只有一条窄栏,空态文案平静', (tester) async {
    final chat = FakeChatService();
    addTearDown(chat.dispose);

    await tester.pumpWidget(_host(ChatPanel(chat: chat)));

    // 收起时列表不该存在
    expect(find.byType(ListView), findsNothing);
    expect(find.text('这里很安静。想说的话、一张图,都可以放这儿。'), findsNothing);
    // 但输入入口一直在
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byTooltip('展开消息'), findsOneWidget);

    // 展开后空态优雅呈现,不像报错
    await tester.tap(find.byTooltip('展开消息'));
    await tester.pumpAndSettle();
    expect(find.text('这里很安静。想说的话、一张图,都可以放这儿。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('展开:显示消息列表,markRead 被调用且未读圆点消失', (tester) async {
    final chat = FakeChatService();
    addTearDown(chat.dispose);
    chat.seed(<ChatMessage>[_text('炉子还热着')], unread: 1);

    await tester.pumpWidget(_host(ChatPanel(chat: chat)));

    // 收起状态下**不**清未读:圆点是唯一提示,不能被偷偷抹掉
    expect(chat.markReadCalls, 0);
    expect(find.bySemanticsLabel('有新消息'), findsOneWidget);

    await tester.tap(find.byTooltip('展开消息'));
    await tester.pumpAndSettle();

    expect(find.byType(ListView), findsOneWidget);
    expect(find.text('炉子还热着'), findsOneWidget);
    expect(chat.markReadCalls, greaterThan(0));
    expect(chat.unreadCount, 0);
    expect(find.bySemanticsLabel('有新消息'), findsNothing);

    // 展开期间再来新消息,应再清一次未读
    final int before = chat.markReadCalls;
    chat.pushIncoming(_text('我也在'));
    await tester.pumpAndSettle();
    expect(chat.markReadCalls, greaterThan(before));
    expect(chat.unreadCount, 0);
  });

  testWidgets('未读提示是一颗余烬圆点,不是数字角标', (tester) async {
    final chat = FakeChatService();
    addTearDown(chat.dispose);
    chat.seed(<ChatMessage>[_text('在么')], unread: 7);

    await tester.pumpWidget(_host(ChatPanel(chat: chat)));

    expect(find.bySemanticsLabel('有新消息'), findsOneWidget);
    // 绝不用 Material 的 Badge
    expect(find.byType(Badge), findsNothing);
    // 收起态下界面上不该出现任何数字(尤其不该是未读数 7)
    final Iterable<Text> texts = tester.widgetList<Text>(find.byType(Text));
    for (final Text t in texts) {
      final String? data = t.data;
      if (data == null) continue;
      expect(
        RegExp(r'\d').hasMatch(data),
        isFalse,
        reason: '收起态出现了数字「$data」,未读提示必须无数字',
      );
    }
  });

  testWidgets('桌面端:回车发送,Shift+回车换行不发送', (tester) async {
    final chat = FakeChatService();
    addTearDown(chat.dispose);

    await tester.pumpWidget(_host(ChatPanel(chat: chat, enterToSend: true)));

    // ── 裸回车:应当恰好发出一条 ──
    await tester.enterText(find.byType(TextField), '来了');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(chat.sentTexts, <String>['来了']);
    // 发出去之后输入框清空
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );

    // ── Shift+回车:一条都不该发 ──
    await tester.enterText(find.byType(TextField), '第一行');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pumpAndSettle();

    // 关键断言:Shift+回车之后发送次数**没有增加**
    expect(chat.sentTexts, <String>['来了']);
    // 文本也原样留在框里,没被当成发送而清空
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '第一行',
    );
  });

  testWidgets('触摸端:回车只换行,永远不发送', (tester) async {
    final chat = FakeChatService();
    addTearDown(chat.dispose);

    await tester.pumpWidget(_host(ChatPanel(chat: chat, enterToSend: false)));

    await tester.enterText(find.byType(TextField), '晚点说');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    // 触摸端回车不发送,发送只有按钮一条路
    expect(chat.sentTexts, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '晚点说',
    );

    // 点发送按钮才发得出去
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(chat.sentTexts, <String>['晚点说']);
  });

  testWidgets('空消息与纯空白一律静默拒发', (tester) async {
    final chat = FakeChatService();
    addTearDown(chat.dispose);

    await tester.pumpWidget(_host(ChatPanel(chat: chat, enterToSend: true)));

    for (final String raw in <String>['', '   ', '\n\n', '\u3000\t ']) {
      await tester.enterText(find.byType(TextField), raw);
      await tester.pump();
      // 发送键必须是禁用的。
      // 按图标定位而不是按 tooltip:find.byTooltip 命中的是 RawTooltip 包装层,
      // 直接 widget<IconButton>() 会类型转换失败。
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.send_rounded),
            )
            .onPressed,
        isNull,
        reason: '「$raw」不该让发送键可用',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }

    // 一条都没发出去,而且全程没有报错弹窗
    expect(chat.sentTexts, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('粘贴一万字不撑破布局', (tester) async {
    _useWindow(tester, size: const Size(320, 640));
    final chat = FakeChatService();
    addTearDown(chat.dispose);

    await tester.pumpWidget(
      _host(ChatPanel(chat: chat, initiallyExpanded: true)),
    );

    final String huge = '词' * 10000;
    await tester.enterText(find.byType(TextField), huge);
    await tester.pumpAndSettle();

    // 任何 RenderFlex overflowed 都会在这里现形
    expect(tester.takeException(), isNull);
    // 输入框被限高,不会把整条栏顶穿
    expect(tester.getSize(find.byType(TextField)).height, lessThan(200));
  });

  testWidgets('窄窗 320x640 叠加 2.0 字体缩放仍不溢出', (tester) async {
    _useWindow(tester, size: const Size(320, 640), textScale: 2.0);
    final chat = FakeChatService();
    addTearDown(chat.dispose);
    chat.seed(<ChatMessage>[
      _text('外面下雪了,炉子刚生好'),
      _text('我把汤热上了', isMine: true, sender: '我'),
      _text('等你回来一起吃'),
    ]);

    await tester.pumpWidget(
      _host(ChatPanel(chat: chat, initiallyExpanded: true)),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 面板整体仍在窗口高度之内,没有把语音主界面挤走
    expect(
      tester.getSize(find.byType(ChatPanel)).height,
      lessThanOrEqualTo(640),
    );
  });

  // 超大字号回归。必须还原 RoomScreen 的真实结构才复现得出来:
  // 上有 Expanded 兄弟、下有固定高度控制栏,面板被夹在中间才会真正被挤爆。
  // 只测 ChatPanel 自己是测不出溢出的 —— 它单独存在时父级约束是无限的。
  for (final double scale in <double>[2.0, 3.0]) {
    testWidgets('超大字号($scale×)窄窗口下展开也不溢出', (tester) async {
      const Size window = Size(320, 560);
      _useWindow(tester, size: window, textScale: scale);

      final chat = FakeChatService();
      addTearDown(chat.dispose);
      // 塞满 30 条,让列表真的「想要」空间,而不是乐得缩成 0
      chat.seed(<ChatMessage>[
        for (int i = 0; i < 30; i++) _text('第 $i 句话,外面下雪了', isMine: i.isEven),
      ]);

      await tester.pumpWidget(
        localizedScaffold(
          SafeArea(
            child: Column(
              children: <Widget>[
                const Expanded(child: SizedBox.expand()), // 成员网格
                ChatPanel(chat: chat, initiallyExpanded: true),
                const SizedBox(height: 140), // 主麦克风控制栏
              ],
            ),
          ),
          theme: LaresTheme.dark(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '长' * 10000);
      await tester.pumpAndSettle();

      // RenderFlex overflowed 会在这里现形
      expect(tester.takeException(), isNull);
      // 面板连同下方 140px 控制栏必须一起塞得进窗口
      expect(
        tester.getSize(find.byType(ChatPanel)).height,
        lessThanOrEqualTo(window.height - 140),
      );
      // 输入框始终至少留得下一行,不会被夹成 0 而没法用
      expect(tester.getSize(find.byType(TextField)).height, greaterThan(0));
    });
  }

  testWidgets('中文与 emoji:字素簇截断不劈开 ZWJ 家庭 emoji', (tester) async {
    final chat = FakeChatService();
    addTearDown(chat.dispose);

    await tester.pumpWidget(
      _host(ChatPanel(chat: chat, enterToSend: true, initiallyExpanded: true)),
    );

    // 故意让家庭 emoji 正好压在上限边界上:前面垫满 maxTextGraphemes - 1 个汉字
    final String body = '${'团' * (maxTextGraphemes - 1)}$_family';
    await tester.enterText(find.byType(TextField), body);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(chat.sentTexts, hasLength(1));
    final String sent = chat.sentTexts.single;

    // 口径必须是字素簇:这串的 String.length 远大于 maxTextGraphemes
    expect(sent.characters.length, maxTextGraphemes);
    expect(sent.length, greaterThan(maxTextGraphemes));
    // 家庭 emoji 完整幸存,没有留下半个代理对
    expect(sent.endsWith(_family), isTrue);
    expect(sent.characters.last, _family);
    // 与 chat_text 的截断口径对齐
    expect(sent, capGraphemes(body, maxTextGraphemes));

    // 中文照常渲染
    expect(find.byType(ListView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('图片消息渲染缩略图,点击进大图', (tester) async {
    final chat = FakeChatService();
    addTearDown(chat.dispose);
    final Uint8List png = Uint8List.fromList(_tinyPng);
    chat.seed(<ChatMessage>[
      ChatMessage.image(
        id: 'img-1',
        senderId: 'u_other',
        senderName: '阿蛮',
        circleId: 'home',
        timestamp: DateTime(2026, 1, 1, 9, 41),
        bytes: png,
        imageWidth: 1,
        imageHeight: 1,
      ),
    ]);

    await tester.pumpWidget(
      _host(ChatPanel(chat: chat, initiallyExpanded: true)),
    );
    await tester.pumpAndSettle();

    // 断言在 widget 树上而不是像素上:widget test 里 Image.memory 的解码
    // 走异步码流,pumpAndSettle 不保证帧已绘出,验颜色会偶发失败。
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 语义标签用正则而不是全等匹配:缩略图的 Semantics 会与同一条消息的
    // 发送人/时间戳表头合并成一个节点,标签实际是「阿蛮  09:41\n图片,点开看大图」。
    // 这个合并对读屏是好事(一次读全「谁、什么时候、发了张图」),故保留。
    expect(find.bySemanticsLabel(RegExp('图片,点开看大图')), findsOneWidget);

    // 点击落在 Image 上而不是那个语义节点上:合并后的节点横跨整行,
    // 其中心点在 160px 宽的缩略图之外,tap 会打空。
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);

    // 必须能退出去
    await tester.tap(find.byTooltip('关闭大图'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('选图接缝:注入字节可端到端走完发送链路', (tester) async {
    final chat = FakeChatService();
    addTearDown(chat.dispose);
    final Uint8List png = Uint8List.fromList(_tinyPng);

    await tester.pumpWidget(
      _host(ChatPanel(chat: chat, initiallyExpanded: true)),
    );

    // file_selector 已接入,选图按钮应当**可用**。
    // (此前依赖未落地时的行为是:按钮禁用但不隐藏,tooltip 平静说明原因。)
    // 取 IconButton 本体按图标定位:byTooltip 命中的是 RawTooltip 包装层
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.image_outlined),
          )
          .onPressed,
      isNotNull,
      reason: '选图依赖已落地,按钮不应再是禁用态',
    );

    await tester
        .state<ChatPanelState>(find.byType(ChatPanel))
        .debugIngestImage(png, width: 1, height: 1);
    await tester.pumpAndSettle();

    expect(chat.sentImages, hasLength(1));
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('发图抛异常时安静提示,不外泄未捕获异常', (tester) async {
    final chat = FakeChatService();
    addTearDown(chat.dispose);
    // 模拟 ChatService 对超限图片的同步抛出(不 import 具体异常类型,避免耦合)
    chat.imageError = Exception('图片太大');

    await tester.pumpWidget(
      _host(ChatPanel(chat: chat, initiallyExpanded: true)),
    );

    await tester
        .state<ChatPanelState>(find.byType(ChatPanel))
        .debugIngestImage(Uint8List.fromList(_tinyPng));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(chat.sentImages, isEmpty);
    // 平静的一行小字,不是横幅、不是 SnackBar
    expect(find.text('这张图没发出去'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  // ——— 选图器自身失败(不是发送失败)的处理 ————————————————
  //
  // 背景:pickImage() 从前把一切异常压成 null,而 null 的语义是「用户取消」。
  // iOS 上筛选器配错导致的必现 ArgumentError 就这样被伪装成了「用户改主意」,
  // 藏了很久。现在真失败一律上抛,由面板接住并留下痕迹。

  testWidgets('选图器抛异常:显示安静提示,不外泄未捕获异常', (tester) async {
    final chat = FakeChatService();
    addTearDown(chat.dispose);

    await tester.pumpWidget(
      _host(
        ChatPanel(
          chat: chat,
          initiallyExpanded: true,
          // 模拟 file_selector 在筛选器字段缺失时抛的那个 ArgumentError
          onPickImage: () async => throw ArgumentError(
            'The provided type group should either allow all files, '
            'or have a non-empty "uniformTypeIdentifiers"',
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithIcon(IconButton, Icons.image_outlined));
    await tester.pumpAndSettle();

    // 异常必须被面板接住,不能冒泡成未捕获异常
    expect(tester.takeException(), isNull);
    expect(chat.sentImages, isEmpty);
    // 关键:失败必须留下痕迹。这正是从前缺失的那一环。
    expect(find.text('没能打开图片'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('选图器返回 null(用户取消):什么都不发生,不报错', (tester) async {
    final chat = FakeChatService();
    addTearDown(chat.dispose);

    await tester.pumpWidget(
      _host(
        ChatPanel(
          chat: chat,
          initiallyExpanded: true,
          onPickImage: () async => null, // 用户取消
        ),
      ),
    );

    await tester.tap(find.widgetWithIcon(IconButton, Icons.image_outlined));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(chat.sentImages, isEmpty);
    // 取消是正常路径:既不发图,也**不该**出现任何失败提示
    expect(find.text('没能打开图片'), findsNothing);
  });

  testWidgets('选图器成功返回:字节走完发送链路', (tester) async {
    final chat = FakeChatService();
    addTearDown(chat.dispose);
    final Uint8List png = Uint8List.fromList(_tinyPng);

    await tester.pumpWidget(
      _host(
        ChatPanel(
          chat: chat,
          initiallyExpanded: true,
          onPickImage: () async => PickedImage(bytes: png, width: 1, height: 1),
        ),
      ),
    );

    await tester.tap(find.widgetWithIcon(IconButton, Icons.image_outlined));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(chat.sentImages, hasLength(1));
    expect(find.text('没能打开图片'), findsNothing);
  });
}
