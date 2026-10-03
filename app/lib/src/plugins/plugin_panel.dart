/// 房间里打开插件(网页小程序)的面板(契约 §7)。
///
/// - Android / iOS / macOS:沙箱 WebView + `LaresBridge` 通道 + 注入 `window.lares`;
///   导航只许留在入口 origin,其它 https 交给系统浏览器,其余一律拦下。
/// - Windows / Linux / Web:没有内嵌 WebView → 「此平台暂不支持内嵌插件」+「在浏览器打开」
///   (浏览器里没有桥)。
/// - 只加载网页,从不加载原生代码(App Store 2.5.2)。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/gen/app_localizations.dart';
import '../captions/caption_controller.dart';
import '../chat/chat_message.dart';
import '../chat/chat_service.dart';
import '../state/room_controller.dart';
import '../theme/tokens.dart';
import '../transcript/transcript_models.dart';
import '../transcript/transcript_service.dart';
import 'plugin_bridge.dart';
import 'plugin_consent.dart';
import 'plugin_models.dart';
import 'plugin_service.dart';

/// 本平台能不能内嵌 WebView。
bool get pluginWebViewSupported {
  if (kIsWeb) return false;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.macOS => true,
    _ => false,
  };
}

/// 导航判定:同 origin 放行;其它 https 交给浏览器;其余拦下。
enum PluginNavDecision { allow, external, block }

PluginNavDecision pluginNavDecision(String entryUrl, String target) {
  final entry = Uri.tryParse(entryUrl);
  final to = Uri.tryParse(target);
  if (entry == null || to == null) return PluginNavDecision.block;
  if (to.scheme == 'about' && (to.path == 'blank' || to.path == 'srcdoc')) {
    return PluginNavDecision.allow;
  }
  if ((to.scheme == 'https' || to.scheme == 'http') &&
      to.hasAuthority &&
      to.origin == entry.origin) {
    return PluginNavDecision.allow;
  }
  if (to.scheme == 'https') return PluginNavDecision.external;
  return PluginNavDecision.block;
}

/// 把房间里现有的服务适配成 [PluginHost]。缺的能力回 not_available。
class RoomPluginHost implements PluginHost {
  RoomPluginHost({
    required this.controller,
    required this.circleId,
    required this.circleName,
    required this.pluginId,
    this.plugins,
    this.chat,
    this.captions,
    this.transcripts,
  }) {
    _members = {for (final m in controller.members) m.userId: m.name};
    controller.addListener(_onRoom);
    final c = chat;
    if (c != null) {
      _chatSeen = c.messages.length;
      c.addListener(_onChat);
    }
    final cap = captions;
    if (cap != null) {
      _captionSeen = _finalKeys(cap.lines);
      cap.addListener(_onCaptions);
    }
    final p = plugins;
    if (p != null) {
      _subs.add(p.stateChanges
          .where((e) => e.circleId == circleId && e.pluginId == pluginId)
          .listen((e) => _emit('state', {'state': e.state, 'rev': e.rev})));
    }
    final tr = transcripts;
    if (tr != null) {
      _subs.add(tr.lines
          .where((l) => l.circleId == circleId)
          .listen((l) => _emit('transcript', _entryJson(l.entry))));
    }
  }

  final RoomController controller;
  final String circleId;
  final String circleName;
  final String pluginId;
  final PluginService? plugins;
  final ChatService? chat;
  final CaptionController? captions;
  final TranscriptService? transcripts;

  final StreamController<PluginHostEvent> _events =
      StreamController.broadcast();
  final List<StreamSubscription<Object?>> _subs = [];
  Map<String, String> _members = {};
  int _chatSeen = 0;
  Set<String> _captionSeen = {};

  @override
  Stream<PluginHostEvent> get events => _events.stream;

  void _emit(String name, Object? data) {
    if (!_events.isClosed) _events.add(PluginHostEvent(name, data));
  }

  void _onRoom() {
    if (controller.circleId != circleId) return;
    final now = {for (final m in controller.members) m.userId: m.name};
    for (final e in now.entries) {
      if (!_members.containsKey(e.key)) {
        _emit('join', {'userId': e.key, 'name': e.value});
      }
    }
    for (final e in _members.entries) {
      if (!now.containsKey(e.key)) {
        _emit('leave', {'userId': e.key, 'name': e.value});
      }
    }
    _members = now;
  }

  void _onChat() {
    final msgs = chat!.messages;
    if (msgs.length < _chatSeen) _chatSeen = 0;
    for (final m in msgs.skip(_chatSeen)) {
      if (m.kind != ChatMessageKind.text || m.circleId != circleId) continue;
      _emit('chat', {
        'id': m.id,
        'userId': m.senderId,
        'name': m.senderName,
        'text': m.text,
        'ts': m.timestamp.millisecondsSinceEpoch,
        'mine': m.isMine,
        'bot': m.isBot,
      });
    }
    _chatSeen = msgs.length;
  }

  static Set<String> _finalKeys(List<CaptionLine> lines) =>
      {for (final l in lines) if (l.isFinal) '${l.identity}/${l.itemId}'};

  void _onCaptions() {
    for (final l in captions!.lines) {
      if (!l.isFinal) continue;
      final k = '${l.identity}/${l.itemId}';
      if (_captionSeen.add(k)) {
        _emit('caption', {
          'userId': l.identity,
          'name': l.name,
          'text': l.text,
          'final': true,
          'self': l.isSelf,
          'bot': l.isBot,
        });
      }
    }
  }

  static Map<String, dynamic> _entryJson(TranscriptEntry e) => {
        'userId': e.userId,
        'name': e.name,
        'id': e.id,
        'text': e.text,
        'startedAt': e.startedAt,
        'ts': e.ts,
      };

  @override
  Future<Map<String, dynamic>?> getCircle() async => {
        'id': circleId,
        'name': circleName,
        'e2ee': controller.circleInfo[circleId]?.e2ee ?? false,
        'registered': controller.isRegisteredCircle(circleId),
      };

  @override
  Future<List<Map<String, dynamic>>> getMembers() async => [
        if (controller.circleId == circleId)
          for (final m in controller.members)
            {'userId': m.userId, 'name': m.name, 'status': m.status.wire},
      ];

  @override
  Future<Map<String, dynamic>?> getSelf() async =>
      {'userId': controller.userId, 'name': controller.userName};

  @override
  Future<void> sendChat(String text) async {
    final c = chat;
    if (c == null || controller.circleId != circleId) {
      throw const PluginNotAvailable('chat');
    }
    await c.sendText(text);
  }

  @override
  Future<void> sendCaption(String text, {bool isFinal = true}) async {
    // CaptionController 没有「代发任意字幕」的接口(字幕只来自本人麦克风)。
    throw const PluginNotAvailable('captions');
  }

  @override
  Future<Map<String, dynamic>> getState() async {
    final p = plugins;
    if (p == null) throw const PluginNotAvailable('state');
    final cached = p.stateOf(circleId, pluginId);
    if (cached != null) {
      return {'state': cached, 'rev': p.revOf(circleId, pluginId)};
    }
    final next = p.stateChanges
        .firstWhere((e) => e.circleId == circleId && e.pluginId == pluginId)
        .timeout(const Duration(seconds: 5));
    p.getState(circleId, pluginId);
    try {
      final e = await next;
      return {'state': e.state, 'rev': e.rev};
    } on TimeoutException {
      throw const PluginNotAvailable('state');
    }
  }

  @override
  Future<void> setState(Map<String, dynamic> patch) async {
    final p = plugins;
    if (p == null) throw const PluginNotAvailable('state');
    p.setState(circleId, pluginId, patch);
  }

  final List<Object?> _transcriptCursors = [null];

  @override
  Future<Map<String, dynamic>?> getTranscript(int page) async {
    final tr = transcripts;
    if (tr == null || !controller.isTranscriptOn(circleId)) {
      throw const PluginNotAvailable('transcript');
    }
    final history = tr.historyFor(circleId);
    try {
      // 页号 → 游标:按需顺序翻到第 page 页
      var i = 0;
      TranscriptPage? res;
      while (true) {
        if (i >= _transcriptCursors.length) return {'items': <Object?>[], 'more': false};
        res = await history.page(cursor: _transcriptCursors[i]);
        if (i + 1 >= _transcriptCursors.length && res.more) {
          _transcriptCursors.add(res.cursor);
        }
        if (i == page) break;
        if (!res.more) return {'items': <Object?>[], 'more': false};
        i++;
      }
      return {
        'items': [for (final e in res.items) _entryJson(e)],
        'more': res.more,
      };
    } on TranscriptOpException {
      throw const PluginNotAvailable('transcript');
    } finally {
      if (history is ChangeNotifier) (history as ChangeNotifier).dispose();
    }
  }

  void dispose() {
    controller.removeListener(_onRoom);
    chat?.removeListener(_onChat);
    captions?.removeListener(_onCaptions);
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_events.close());
  }
}

/// 同意 → 打开插件面板。
Future<void> openPluginPanel(
  BuildContext context, {
  required PluginView plugin,
  required String circleId,
  required String circleName,
  required RoomController controller,
  PluginService? plugins,
  ChatService? chat,
  CaptionController? captions,
  TranscriptService? transcripts,
  PluginConsentStore? consentStore,
}) async {
  final e2ee = controller.circleInfo[circleId]?.e2ee ?? false;
  final ok = await ensurePluginConsent(context,
      circleId: circleId, plugin: plugin, e2ee: e2ee, store: consentStore);
  if (!ok || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => PluginPanelScreen(
      plugin: plugin,
      hostFactory: () => RoomPluginHost(
        controller: controller,
        circleId: circleId,
        circleName: circleName,
        pluginId: plugin.id,
        plugins: plugins,
        chat: chat,
        captions: captions,
        transcripts: transcripts,
      ),
      storageFactory: () => SharedPrefsPluginStorage(circleId, plugin.id),
    ),
  ));
}

class PluginPanelScreen extends StatefulWidget {
  const PluginPanelScreen({
    super.key,
    required this.plugin,
    required this.hostFactory,
    required this.storageFactory,
    this.forceUnsupported = false,
  });

  final PluginView plugin;
  final RoomPluginHost Function() hostFactory;
  final PluginStorage Function() storageFactory;

  /// 测试用:强制走「不支持内嵌」分支。
  final bool forceUnsupported;

  @override
  State<PluginPanelScreen> createState() => _PluginPanelScreenState();
}

class _PluginPanelScreenState extends State<PluginPanelScreen> {
  RoomPluginHost? _host;
  PluginBridge? _bridge;
  WebViewController? _web;
  StreamSubscription<PluginHostEvent>? _eventSub;

  bool get _embedded => pluginWebViewSupported && !widget.forceUnsupported;

  @override
  void initState() {
    super.initState();
    final url = widget.plugin.entryUrl;
    if (!_embedded || url == null) return;
    final host = _host = widget.hostFactory();
    final bridge = _bridge = PluginBridge(
      permissions: widget.plugin.permissions,
      host: host,
      storage: widget.storageFactory(),
    );
    final web = _web = WebViewController();
    unawaited(web.setJavaScriptMode(JavaScriptMode.unrestricted));
    unawaited(web.addJavaScriptChannel('LaresBridge',
        onMessageReceived: (m) async {
      final res = await bridge.dispatch(m.message);
      if (!mounted) return;
      unawaited(web.runJavaScript(pluginResolveJs(res)).catchError((_) {}));
    }));
    unawaited(web.setNavigationDelegate(NavigationDelegate(
      onPageStarted: (_) => _inject(),
      onPageFinished: (_) => _inject(),
      onNavigationRequest: (req) {
        switch (pluginNavDecision(url, req.url)) {
          case PluginNavDecision.allow:
            return NavigationDecision.navigate;
          case PluginNavDecision.external:
            unawaited(launchUrl(Uri.parse(req.url),
                    mode: LaunchMode.externalApplication)
                .catchError((_) => false));
            return NavigationDecision.prevent;
          case PluginNavDecision.block:
            return NavigationDecision.prevent;
        }
      },
    )));
    _eventSub = bridge.events.listen((e) {
      unawaited(web.runJavaScript(pluginEmitJs(e.name, e.data)).catchError((_) {}));
    });
    unawaited(web.loadRequest(Uri.parse(url)));
  }

  void _inject() {
    unawaited(_web?.runJavaScript(laresBridgeShim).catchError((_) {}));
  }

  @override
  void dispose() {
    unawaited(_eventSub?.cancel());
    _bridge?.dispose();
    _host?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final web = _web;
    return Scaffold(
      appBar: AppBar(title: Text(widget.plugin.name)),
      body: web != null
          ? WebViewWidget(controller: web)
          : _Unsupported(url: widget.plugin.entryUrl, t: t),
    );
  }
}

class _Unsupported extends StatelessWidget {
  const _Unsupported({required this.url, required this.t});
  final String? url;
  final AppLocalizations t;

  @override
  Widget build(BuildContext context) {
    final u = url == null ? null : Uri.tryParse(url!);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(LaresSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.pluginPlatformUnsupported, textAlign: TextAlign.center),
            const SizedBox(height: LaresSpacing.md),
            if (u != null && u.scheme == 'https')
              FilledButton(
                key: const ValueKey('plugin-open-browser'),
                onPressed: () => launchUrl(u,
                        mode: LaunchMode.externalApplication)
                    .catchError((_) => false),
                child: Text(t.pluginOpenInBrowser),
              ),
          ],
        ),
      ),
    );
  }
}

/// 本圈启用且带网页入口的插件。[thirdParty] = false(圈主关了「插件」功能)
/// 时只留内置插件(features-purpose-contract §1:客户端隐藏第三方插件入口)。
List<PluginView> roomEntryPlugins(
  PluginService service,
  String circleId, {
  bool thirdParty = true,
}) => [
  for (final p in service.pluginsFor(circleId))
    if (p.enabled && p.hasEntry && (thirdParty || p.builtin)) p,
];

/// 弹出插件选择表,选中即打开插件面板。房间「更多」与 [RoomPluginsButton] 共用。
Future<void> pickAndOpenRoomPlugin(
  BuildContext context, {
  required List<PluginView> items,
  required PluginService service,
  required RoomController controller,
  required String circleId,
  required String circleName,
  ChatService? chat,
  CaptionController? captions,
  TranscriptService? transcripts,
}) async {
  if (items.isEmpty) return;
  final picked = await showModalBottomSheet<PluginView>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final p in items)
            ListTile(
              key: ValueKey('room-plugin-${p.id}'),
              leading: const Icon(Icons.extension_outlined),
              title: Text(p.name),
              subtitle: p.description.isEmpty
                  ? null
                  : Text(p.description,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.of(ctx).pop(p),
            ),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  await openPluginPanel(context,
      plugin: picked,
      circleId: circleId,
      circleName: circleName,
      controller: controller,
      plugins: service,
      chat: chat,
      captions: captions,
      transcripts: transcripts);
}

/// 「插件」按钮:列出本圈启用且有网页入口的插件。
/// (房间页现在走「更多」里的插件格;此按钮保留给其它入口 / 测试。)
class RoomPluginsButton extends StatelessWidget {
  const RoomPluginsButton({
    super.key,
    required this.service,
    required this.controller,
    required this.circleId,
    required this.circleName,
    this.chat,
    this.captions,
    this.transcripts,
  });

  final PluginService service;
  final RoomController controller;
  final String circleId;
  final String circleName;
  final ChatService? chat;
  final CaptionController? captions;
  final TranscriptService? transcripts;

  @override
  Widget build(BuildContext context) {
    if (!service.hasListFor(circleId)) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => service.ensureList(circleId));
    }
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final items = roomEntryPlugins(service, circleId);
        if (items.isEmpty) return const SizedBox.shrink();
        final t = AppLocalizations.of(context);
        return IconButton(
          key: const ValueKey('room-plugins'),
          tooltip: t.pluginTitle,
          icon: const Icon(Icons.extension_outlined),
          onPressed: () => pickAndOpenRoomPlugin(context,
              items: items,
              service: service,
              controller: controller,
              circleId: circleId,
              circleName: circleName,
              chat: chat,
              captions: captions,
              transcripts: transcripts),
        );
      },
    );
  }
}
