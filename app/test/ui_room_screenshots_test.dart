// 房间页截图脚手架:用假实现 pump 真正的 RoomScreen,把若干状态截成 PNG。
//
// 这不是回归测试,而是借测试运行器执行的出图脚本。默认全部 skip;
// 只有设置 LARES_SHOTS=1 才会真的跑。
//
// 跑法(app/ 目录下,PowerShell):
//   $env:LARES_SHOTS='1'; $env:LARES_SHOTS_TAG='before'; flutter test test/ui_room_screenshots_test.dart
//
// 只跑某一组(用例名是「room shot <state>」,--plain-name 按子串匹配):
//   ... flutter test test/ui_room_screenshots_test.dart --plain-name 'room shot ai_'
//
// 输出:spike_out/room_shots/<tag>_<state>.png 与 <tag>_exceptions.txt
//
// 注意(沿用 tool/palette/render_test.dart 的经验):
//  - flutter_test 默认字体是方块,必须手动加载中文字体与 MaterialIcons;
//  - toImage 必须包在 runAsync 里,否则假时钟下永远不返回;
//  - 房间页有无限循环动画:不能 pumpAndSettle,每个场景后要 pumpWidget(SizedBox.shrink())。

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/captions/caption_controller.dart';
import 'package:lares_app/src/chat/chat_message.dart';
import 'package:lares_app/src/focus/focus_lock.dart';
import 'package:lares_app/src/net/signaling_client.dart';
import 'package:lares_app/src/plugins/ai_voice_settings.dart';
import 'package:lares_app/src/plugins/plugin_models.dart';
import 'package:lares_app/src/plugins/plugin_service.dart';
import 'package:lares_app/src/state/ai_member.dart';
import 'package:lares_app/src/state/ai_state.dart';
import 'package:lares_app/src/privacy/privacy_sheet.dart';
import 'package:lares_app/src/purpose/purpose_editor.dart';
import 'package:lares_app/src/purpose/purpose_picker.dart';
import 'package:lares_app/src/rtc/rtc_service.dart';
import 'package:lares_app/src/state/location_share_stub.dart'
    if (dart.library.io) 'package:lares_app/src/state/location_share.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/transcript/local_transcript_store.dart';
import 'package:lares_app/src/transcript/transcript_scope.dart';
import 'package:lares_app/src/transcript/transcript_service.dart';
import 'package:lares_app/src/ui/push_settings_widgets.dart';
import 'package:lares_app/src/ui/room_screen.dart';
import 'package:lares_app/src/ui/widgets/avatar_orb.dart';
import 'package:lares_app/src/net/secret_vault.dart';
import 'package:lares_app/src/state/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/caption_fakes.dart';
import 'helpers/chat_fakes.dart';
import 'helpers/focus_fixtures.dart';
import 'helpers/localized_app.dart';

final bool _skip = Platform.environment['LARES_SHOTS'] != '1';
final String _tag = Platform.environment['LARES_SHOTS_TAG'] ?? 'after';
const String _outDir = 'spike_out/room_shots';
const String _font = 'Msyh';

final List<String> _exceptions = <String>[];

// ─────────────────────────── 字体 ───────────────────────────

const List<String> _cjkCandidates = <String>[
  r'C:\Windows\Fonts\msyh.ttc',
  r'C:\Windows\Fonts\simhei.ttf',
];

Future<void> _loadFontFamily(String family, Uint8List bytes) async {
  final FontLoader loader = FontLoader(family)
    ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
  await loader.load();
}

Future<void> _loadFonts() async {
  for (final String path in _cjkCandidates) {
    final File f = File(path);
    if (!f.existsSync()) continue;
    try {
      final Uint8List bytes = await f.readAsBytes();
      // 同时注册成 Roboto:主题没设 fontFamily 时 Typography 默认就找它。
      await _loadFontFamily(_font, bytes);
      await _loadFontFamily('Roboto', bytes);
      break;
    } catch (_) {
      continue;
    }
  }
  final List<String> iconCandidates = <String>[
    r'D:\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
    if (Platform.environment['FLUTTER_ROOT'] != null)
      '${Platform.environment['FLUTTER_ROOT']}\\bin\\cache\\artifacts\\material_fonts\\materialicons-regular.otf',
  ];
  for (final String path in iconCandidates) {
    final File f = File(path);
    if (!f.existsSync()) continue;
    await _loadFontFamily('MaterialIcons', await f.readAsBytes());
    break;
  }
  // emoji(用途名牌 💬 / 📚)与等宽(用途编辑器)。
  // kPurposeMonoStyle = 'monospace' + 后备 [Consolas, Menlo, Courier New]:
  // 它自带后备表会盖掉主题的后备,所以这里借后两个名字挂中文与 emoji,
  // 让编辑器里的「自习室」「📚」也能画出来(仅截图脚手架这么做)。
  Future<void> loadAs(String path, List<String> families) async {
    final File f = File(path);
    if (!f.existsSync()) return;
    final Uint8List bytes = await f.readAsBytes();
    for (final String fam in families) {
      await _loadFontFamily(fam, bytes);
    }
  }

  await loadAs(r'C:\Windows\Fonts\seguiemj.ttf', <String>[
    _emoji,
    'Courier New',
  ]);
  await loadAs(r'C:\Windows\Fonts\consola.ttf', <String>[
    'monospace',
    'Consolas',
  ]);
  await loadAs(r'C:\Windows\Fonts\msyh.ttc', <String>['Menlo']);
}

const String _emoji = 'SegoeEmoji';

ThemeData _withFont(ThemeData t) {
  TextStyle? f(TextStyle? s) => s?.copyWith(
    fontFamily: _font,
    fontFamilyFallback: const <String>[_emoji],
  );
  // 主题里有几处自带 TextStyle(AppBar 标题、FilledButton 字)不走 textTheme,
  // 测试默认字体下会画成方块 —— 一并换字体。
  final ButtonStyle? filled = t.filledButtonTheme.style;
  return t.copyWith(
    textTheme: t.textTheme.apply(
      fontFamily: _font,
      fontFamilyFallback: const <String>[_emoji],
    ),
    primaryTextTheme: t.primaryTextTheme.apply(
      fontFamily: _font,
      fontFamilyFallback: const <String>[_emoji],
    ),
    appBarTheme: t.appBarTheme.copyWith(
      titleTextStyle: f(t.appBarTheme.titleTextStyle),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: filled?.copyWith(
        textStyle: WidgetStatePropertyAll<TextStyle?>(
          f(filled.textStyle?.resolve(<WidgetState>{})),
        ),
      ),
    ),
  );
}

// ─────────────────────────── 假实现 ───────────────────────────

class _FakeSignalingClient extends SignalingClient {
  _FakeSignalingClient() : super(url: 'ws://fake');

  @override
  void connect() {}

  @override
  void send(Map<String, dynamic> msg) {}

  @override
  Future<void> dispose() async {}
}

class _FakeRtcService implements RtcService {
  final StreamController<Set<String>> speaking =
      StreamController<Set<String>>.broadcast();
  final StreamController<void> _dropped = StreamController<void>.broadcast();
  bool _inRoom = false;
  bool muted = true;

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
    _inRoom = true;
    muted = startMuted;
    return RtcJoinResult(
      elapsed: const Duration(milliseconds: 120),
      micOn: !startMuted,
    );
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
  Stream<Set<String>> get speakingIdentities => speaking.stream;

  @override
  Stream<void> get onDisconnected => _dropped.stream;
}

// ─────────────────────────── 场景数据 ───────────────────────────

/// AI 语音助手成员(userId 以 `u_ai_` 开头,见 lib/src/state/ai_member.dart)。
const String _aiId = 'u_ai_1a2b3c4d';

const Map<String, String> _names = <String, String>{
  'u_me': '我',
  'u1': '阿蛮',
  'u2': '小鹿',
  'u3': '大橘',
  _aiId: '小助手',
};

/// 本圈装好的内置 AI 语音助手(默认配置)。
final Map<String, dynamic> _aiPluginJson = <String, dynamic>{
  'id': kAiVoicePluginId,
  'name': 'AI 语音助手',
  'builtin': true,
  'enabled': true,
  'config': Map<String, dynamic>.of(kAiVoiceDefaults),
};

/// 「问 → 答 → 被打断的答」:AI 的回复就是 AI 成员发的普通聊天消息。
List<ChatMessage> _aiChatMessages() {
  ChatMessage text(
    String id,
    String sender,
    String body,
    int min, {
    bool mine = false,
  }) => ChatMessage.text(
    id: id,
    senderId: sender,
    senderName: _names[sender]!,
    circleId: 'home',
    timestamp: DateTime(2026, 1, 1, 21, min),
    body: body,
    isMine: mine,
  );
  return <ChatMessage>[
    text('a1', 'u1', '小助手,明天几点集合?', 1),
    text('a2', _aiId, '明天早上八点在东门集合,记得带水。', 1),
    text('a3', 'u_me', '小助手,长城是什么时候修的?', 2, mine: true),
    // 被人插话打断:回复截在半句,以「…」收尾
    text('a4', _aiId, '长城最早是春秋战…', 2),
    text('a5', 'u1', '先别讲历史了哈哈', 3),
  ];
}

List<ChatMessage> _chatMessages() {
  ChatMessage text(
    String id,
    String sender,
    String body,
    int min, {
    bool mine = false,
  }) => ChatMessage.text(
    id: id,
    senderId: sender,
    senderName: _names[sender]!,
    circleId: 'home',
    timestamp: DateTime(2026, 1, 1, 21, min),
    body: body,
    isMine: mine,
  );
  return <ChatMessage>[
    text('c1', 'u1', '今晚谁还在?', 1),
    text('c2', 'u2', '我在,刚下班,边做饭边挂着', 2),
    text('c3', 'u_me', '在的~ 我在写代码', 3, mine: true),
    // 图片字节尚未到齐:渲染占位
    ChatMessage(
      id: 'c4',
      senderId: 'u1',
      senderName: '阿蛮',
      circleId: 'home',
      timestamp: DateTime(2026, 1, 1, 21, 5),
      kind: ChatMessageKind.image,
      imageWidth: 800,
      imageHeight: 600,
    ),
    text('c5', 'u3', '这张照片是哪里拍的?看起来好舒服,周末一起去吧', 6),
    text('c6', 'u_me', '好呀', 7, mine: true),
  ];
}

class _Scene {
  _Scene({
    required this.name,
    this.people = 4,
    this.speaking = const <String>{},
    this.chatMessages = false,
    this.captions = false,
    this.keyboard = false,
    this.size = const Size(390, 844),
    this.dpr = 2.0,
    this.padTop = 47,
    this.padBottom = 34,
    this.light = false,
    this.focus,
    this.kind = _Kind.room,
    this.circle,
    this.extras = false,
    this.overlay,
    this.social,
    this.ai = false,
    this.aiState,
    this.aiChat = false,
    this.aiCaptions = false,
    this.pickerChoice,
    this.height,
    this.profile,
  });

  /// 成员资料面板:'own'(改自己)/ 'other'(看别人,非圈主)/ 'owner'(圈主看别人)。
  final String? profile;

  /// 房里加一个 AI 语音助手成员([_aiId] / 小助手),并给本圈装上 `lares.ai-voice`。
  final bool ai;

  /// AI 此刻的状态:'idle' / 'listening' / 'thinking' / 'speaking'。
  /// 由 `_applyAiState` 经 `RoomController.debugSetAiState` 钉住。
  final String? aiState;

  /// 聊天面板换成 [_aiChatMessages](AI 回复 + 被打断的回复)。
  final bool aiChat;

  /// 字幕里加一行 AI 说的话。
  final bool aiCaptions;

  /// 用途面板打开后再点一下的选项(如 'meeting' → 展开「加上 AI 助手」)。
  final String? pickerChoice;

  /// 页面类场景(设置表单)要拉长截全时的高度;null = 用 [size]。
  final double? height;

  /// 专注社交(§9/§10):'round' / 'round_all' / 'weekly' / 'summon_wait';null = 只有 🔥。
  final String? social;

  final _Kind kind;

  /// 注入的 circle_settings.circle(功能开关 / 用途);null = 老服务器(全开、无用途)。
  final Map<String, dynamic>? circle;

  /// 挂上插件 / 地图 / 转写服务(「更多」里才有格子可列)。
  final bool extras;

  /// 房间上叠的面板:'more' / 'privacy'。
  final String? overlay;

  final String name;
  final int people;
  final Set<String> speaking;
  final bool chatMessages;
  final bool captions;
  final bool keyboard;
  final Size size;
  final double dpr;
  final double padTop;
  final double padBottom;
  final bool light;

  /// 专注学习场景:'focus' / 'break' / 'board';null = 不装专注插件。
  final String? focus;
}

final List<_Scene> _scenes = <_Scene>[
  _Scene(name: 'a_empty', people: 2),
  _Scene(name: 'b_chat', speaking: <String>{'u1'}, chatMessages: true),
  _Scene(
    name: 'c_captions',
    speaking: <String>{'u1'},
    chatMessages: true,
    captions: true,
  ),
  _Scene(
    name: 'd_keyboard',
    speaking: <String>{'u1'},
    chatMessages: true,
    keyboard: true,
  ),
  _Scene(
    name: 'e_small',
    speaking: <String>{'u1'},
    chatMessages: true,
    captions: true,
    size: const Size(375, 667),
    padTop: 20,
    padBottom: 0,
  ),
  _Scene(
    name: 'f_desktop',
    speaking: <String>{'u1'},
    chatMessages: true,
    captions: true,
    size: const Size(1100, 750),
    dpr: 1.0,
    padTop: 0,
    padBottom: 0,
  ),
  _Scene(
    name: 'g_light',
    speaking: <String>{'u1'},
    chatMessages: true,
    light: true,
  ),
  // 专注段:文字聊天照常(只收地图 / 便签 / 小程序)
  _Scene(
    name: 'focus_phase',
    speaking: <String>{'u1'},
    chatMessages: true,
    focus: 'focus',
  ),
  _Scene(
    name: 'focus_break',
    speaking: <String>{'u1'},
    chatMessages: true,
    focus: 'break',
  ),
  _Scene(name: 'focus_leaderboard', focus: 'board'),
  _Scene(
    name: 'focus_idle',
    speaking: <String>{'u1'},
    chatMessages: true,
    focus: 'idle',
  ),
  _Scene(
    name: 'focus_phase_360',
    speaking: <String>{'u1'},
    captions: true,
    focus: 'focus',
    size: const Size(360, 640),
    padTop: 24,
    padBottom: 0,
  ),
  // ── 功能收纳 / 用途 / 隐私告知 ──
  // 常见情形:新注册圈的默认功能 + 用途「闲聊」(字幕、转写关;地图默认关)。
  _Scene(
    name: 'minimal_room',
    people: 4,
    speaking: <String>{'u1'},
    extras: true,
    circle: _circle(_chatFeatures, _chatPurpose),
  ),
  // 「更多」面板:圈主开了字幕 / 转写 / 地图 / 插件,才有一排格子可看
  _Scene(
    name: 'more_sheet',
    speaking: <String>{'u1'},
    extras: true,
    circle: _circle(_richFeatures, _chatPurpose, transcript: true),
    overlay: 'more',
  ),
  _Scene(
    name: 'more_sheet_light',
    speaking: <String>{'u1'},
    extras: true,
    light: true,
    circle: _circle(_richFeatures, _chatPurpose, transcript: true),
    overlay: 'more',
  ),
  // ── 活动推送 / 专注社交(plugin-focus-contract §9/§10)──
  _Scene(name: 'focus_round_partial', focus: 'break', social: 'round'),
  _Scene(name: 'focus_round_allin', focus: 'break', social: 'round_all'),
  _Scene(name: 'focus_streaks', focus: 'idle', people: 4),
  _Scene(name: 'focus_weekly', focus: 'idle', social: 'weekly'),
  _Scene(name: 'summon_cooldown', focus: 'idle', social: 'summon_wait'),
  _Scene(name: 'push_triggers', focus: 'idle', overlay: 'push_triggers'),
  _Scene(
    name: 'push_triggers_light',
    focus: 'idle',
    light: true,
    overlay: 'push_triggers',
  ),
  _Scene(name: 'push_level', focus: 'idle', overlay: 'push_level'),
  _Scene(name: 'push_quiet', focus: 'idle', overlay: 'push_quiet'),
  _Scene(name: 'purpose_picker', kind: _Kind.picker),
  _Scene(name: 'purpose_editor', kind: _Kind.editor),
  _Scene(name: 'purpose_editor_error', kind: _Kind.editorError),
  _Scene(
    name: 'privacy_sheet',
    people: 3,
    circle: _circle(_chatFeatures, _chatPurpose),
    overlay: 'privacy',
  ),
  // ── AI 语音助手(docs/ai-voice-bot.md)──
  _Scene(name: 'ai_idle', people: 2, ai: true, aiState: 'idle'),
  _Scene(name: 'ai_listening', people: 2, ai: true, aiState: 'listening'),
  _Scene(name: 'ai_thinking', people: 2, ai: true, aiState: 'thinking'),
  _Scene(
    name: 'ai_speaking',
    people: 2,
    ai: true,
    aiState: 'speaking',
    speaking: <String>{_aiId},
  ),
  _Scene(
    name: 'ai_chat',
    people: 2,
    ai: true,
    aiState: 'idle',
    chatMessages: true,
    aiChat: true,
  ),
  _Scene(
    name: 'ai_captions',
    people: 2,
    ai: true,
    aiState: 'speaking',
    speaking: <String>{_aiId},
    captions: true,
    aiCaptions: true,
  ),
  _Scene(
    name: 'ai_more_sheet',
    people: 2,
    ai: true,
    extras: true,
    circle: _circle(_richFeatures, _chatPurpose, transcript: true),
    overlay: 'more',
  ),
  _Scene(
    name: 'ai_info_sheet',
    people: 2,
    ai: true,
    extras: true,
    circle: _circle(_richFeatures, _chatPurpose, transcript: true),
    overlay: 'ai_info',
  ),
  _Scene(name: 'ai_settings', kind: _Kind.aiSettings, height: 1000),
  _Scene(
    name: 'ai_settings_advanced',
    kind: _Kind.aiSettingsAdvanced,
    height: 1560,
  ),
  _Scene(name: 'ai_purpose_picker', kind: _Kind.picker, pickerChoice: 'meeting'),
  // ── 成员资料 ──
  _Scene(name: 'profile_own_edit', people: 3, profile: 'own'),
  _Scene(
    name: 'profile_other_dark',
    speaking: <String>{'u1'},
    focus: 'focus',
    profile: 'other',
  ),
  _Scene(
    name: 'profile_other_light_360',
    speaking: <String>{'u1'},
    focus: 'focus',
    profile: 'other',
    light: true,
    size: const Size(360, 640),
    padTop: 24,
    padBottom: 0,
  ),
  _Scene(name: 'profile_owner_kick', people: 3, profile: 'owner'),
  _Scene(
    name: 'ai_light_360',
    people: 2,
    ai: true,
    aiState: 'speaking',
    speaking: <String>{_aiId},
    light: true,
    size: const Size(360, 640),
    padTop: 24,
    padBottom: 0,
  ),
];

enum _Kind { room, picker, editor, editorError, aiSettings, aiSettingsAdvanced }

/// 新注册圈默认(features-purpose-contract §1)叠上「闲聊」(§3.2)
const Map<String, bool> _chatFeatures = <String, bool>{
  'captions': false,
  'transcript': false,
  'voiceNotes': true,
  'map': false,
  'recording': false,
  'plugins': true,
  'focus': false,
  'p2p': false,
  'devTools': false,
};

final Map<String, bool> _richFeatures = <String, bool>{
  ..._chatFeatures,
  'captions': true,
  'transcript': true,
  'map': true,
};

const Map<String, dynamic> _chatPurpose = <String, dynamic>{
  'id': 'chat',
  'name': '闲聊',
  'icon': '💬',
  'builtin': true,
};

Map<String, dynamic> _circle(
  Map<String, bool> features,
  Map<String, dynamic> purpose, {
  bool transcript = false,
}) => <String, dynamic>{
  'id': 'home',
  'registered': true,
  'e2ee': false,
  'transcript': transcript,
  'features': features,
  'purpose': purpose,
};

const Map<String, dynamic> _studyHall = <String, dynamic>{
  'v': 1,
  'id': 'study-hall',
  'name': '自习室',
  'icon': '📚',
  'description': '一起专注,少说话',
  'features': <String, bool>{
    'focus': true,
    'captions': false,
    'voiceNotes': false,
  },
  'plugins': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'lares.focus',
      'enabled': true,
      'config': <String, int>{'focusMin': 50, 'breakMin': 10, 'rounds': 3},
    },
  ],
};

/// 隐私告知示例:转写开、两个插件(一个带 webhook)、专注开、未加密
const CirclePrivacySummary _privacySample = CirclePrivacySummary(
  circleId: 'home',
  transcript: true,
  e2ee: false,
  focus: true,
  plugins: <PrivacyPlugin>[
    PrivacyPlugin(
      id: 'lares.focus',
      name: '专注学习',
      permissions: <String>['members:read', 'focus:read'],
    ),
    PrivacyPlugin(
      id: 'example.notes',
      name: '会议纪要',
      permissions: <String>['transcript:read', 'chat:send'],
      hasWebhook: true,
    ),
  ],
);

/// 专注社交的推送消息:所有专注场景都带 🔥(座位 / 排行榜),再按 [_Scene.social] 加卡片。
void _injectSocial(FocusHarness focus, _Scene s) {
  focus.inject(<String, dynamic>{
    't': 'focus_streaks',
    'circleId': 'home',
    'streaks': <String, int>{'u_me': 3, 'u1': 12, 'u3': 5},
  });
  focus.inject(<String, dynamic>{
    't': 'push_cfg',
    'circleId': 'home',
    'cfg': <String, dynamic>{
      'triggers': <String, bool>{'focus': true, 'crowd': true, 'arrive': false},
      'crowdN': 4,
    },
    'custom': true,
    'defaults': <String, dynamic>{
      'triggers': <String, bool>{'focus': true, 'crowd': false, 'arrive': false},
      'crowdN': 3,
    },
    'summonReadyAt': s.social == 'summon_wait' ? kFocusNow + 7 * 60000 : 0,
    'now': kFocusNow,
    'limits': <String, int>{'cooldownMin': 30, 'dailyCap': 8, 'summonMin': 10},
  });
  if (s.social == 'round' || s.social == 'round_all') {
    final bool all = s.social == 'round_all';
    focus.inject(<String, dynamic>{
      't': 'focus_round',
      'circleId': 'home',
      'round': 2,
      'rounds': 4,
      'endedAt': kFocusNow,
      'lenMs': 25 * 60000,
      'members': <Map<String, dynamic>>[
        for (final String id in <String>['u_me', 'u1', 'u3'])
          <String, dynamic>{'userId': id, 'name': _names[id] ?? '我', 'awayMs': 0, 'full': true},
        <String, dynamic>{
          'userId': 'u2',
          'name': _names['u2'],
          'awayMs': all ? 0 : 133000,
          'full': all,
        },
      ],
    });
  }
  if (s.social == 'weekly') {
    focus.inject(<String, dynamic>{
      't': 'focus_weekly',
      'circleId': 'home',
      'card': <String, dynamic>{
        'week': '2026-09-07',
        'focusMs': 6 * 3600000 + 40 * 60000,
        'rank': 2,
        'of': 4,
        'streak': 3,
        'circleTotalMs': 21 * 3600000 + 15 * 60000,
      },
    });
  }
}

/// 通知设置三处:圈主活动提醒面板 / 成员「通知我」/ 推送免打扰。
Future<void> _openPushOverlay(
  WidgetTester tester,
  _Scene s,
  FocusHarness? focus,
) async {
  final BuildContext ctx = tester.element(find.byType(RoomScreen));
  if (s.overlay == 'push_triggers' && focus != null) {
    unawaited(
      showModalBottomSheet<void>(
        context: ctx,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) =>
            PushTriggersSheet(activity: focus.service.activity, circleId: 'home'),
      ),
    );
  } else if (s.overlay == 'push_level') {
    unawaited(
      showDialog<String>(
        context: ctx,
        builder: (_) => const PushLevelDialog(current: 'called'),
      ),
    );
  } else if (s.overlay == 'push_quiet') {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsStore? settings = await tester.runAsync(
      () => SettingsStore.load(vault: InMemorySecretVault()),
    );
    unawaited(
      showDialog<void>(
        context: ctx,
        builder: (_) => PushQuietDialog(settings: settings!),
      ),
    );
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

// ─────────────────────────── 出图 ───────────────────────────

/// 当前场景/步骤,供 FlutterError 钩子给异常打标签
String _where = '';

void _drainExceptions(WidgetTester tester, String scene, String step) {
  // 详细内容已由 FlutterError 钩子逐条记下;这里只把框架的待报异常清掉,
  // 免得它把整个用例判失败(这是出图脚本,不是断言)。
  while (tester.takeException() != null) {}
  _where = '$scene/after-$step';
}

void _recordError(FlutterErrorDetails d) {
  final List<String> lines = d
      .exceptionAsString()
      .split('\n')
      .where((String l) => l.trim().isNotEmpty)
      .take(2)
      .toList();
  final String ctx = d.context?.toDescription() ?? '';
  final RegExpMatch? m = RegExp(
    r'lib/src/[^\s:]+\.dart:\d+:\d+',
  ).firstMatch(d.toString());
  final String creator = m?.group(0) ?? '';
  final String entry =
      '[$_where] ${lines.join(' / ')}  ($ctx${creator.isEmpty ? '' : ' @ $creator'})';
  if (!_exceptions.contains(entry)) _exceptions.add(entry);
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey key,
  String path,
  double dpr,
) async {
  final RenderRepaintBoundary boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: dpr);
    final ByteData? bytes = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    image.dispose();
    if (bytes == null) throw StateError('toByteData 返回 null:$path');
    final File file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes.buffer.asUint8List());
  });
}

/// 麦克风偏离正中就记进异常文件(截图里肉眼看不出 1px)。
void _logMicCentre(WidgetTester tester, _Scene s) {
  Finder mic = find.byIcon(Icons.mic_rounded);
  if (mic.evaluate().isEmpty) mic = find.byIcon(Icons.mic_off_rounded);
  if (mic.evaluate().isEmpty) {
    _exceptions.add('[${s.name}] mic not found');
    return;
  }
  final double dx = tester.getCenter(mic.last).dx;
  if ((dx - s.size.width / 2).abs() > 0.5) {
    _exceptions.add('[${s.name}] mic off-centre: dx=$dx');
  }
}

/// 用途选择 / 编辑器:不需要房间,挂在普通 Scaffold 上。
Future<void> _runPurposeScene(WidgetTester tester, _Scene s) async {
  final GlobalKey key = GlobalKey();
  final ThemeData theme = _withFont(
    s.light ? LaresTheme.light() : LaresTheme.dark(),
  );
  PluginService? aiService;
  StreamController<Map<String, dynamic>>? aiMsgs;
  if (s.kind == _Kind.aiSettings || s.kind == _Kind.aiSettingsAdvanced) {
    aiMsgs = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    aiService = PluginService(
      send: (_) {},
      messages: aiMsgs.stream,
      ownerKeyFor: (_) => 'ok_home',
    );
  }
  final Widget home = switch (s.kind) {
    _Kind.aiSettings || _Kind.aiSettingsAdvanced => AiVoiceSettingsPage(
      service: aiService!,
      circleId: 'home',
      plugin: PluginView.fromJson(_aiPluginJson)!,
    ),
    _Kind.editor => const PurposeEditorPage(initial: _studyHall),
    _Kind.editorError => PurposeEditorPage(
      initial: <String, dynamic>{..._studyHall, 'id': 'Study Hall'},
    ),
    _ => Scaffold(
      appBar: AppBar(title: const Text('圈子设置')),
      body: Builder(
        builder: (BuildContext ctx) => Center(
          child: FilledButton(
            key: const ValueKey<String>('shots-open-picker'),
            onPressed: () =>
                unawaited(showPurposePicker(ctx, current: 'study')),
            child: const Text('用途'),
          ),
        ),
      ),
    ),
  };
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: localizedApp(home, theme: theme),
    ),
  );
  await tester.pump();
  _drainExceptions(tester, s.name, 'mount');
  if (s.kind == _Kind.picker) {
    await tester.tap(find.byKey(const ValueKey<String>('shots-open-picker')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    if (s.pickerChoice != null) {
      await tester.tap(
        find.byKey(ValueKey<String>('purpose-option-${s.pickerChoice}')),
        warnIfMissed: false,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
  }
  if (s.kind == _Kind.aiSettingsAdvanced) {
    await tester.tap(
      find.byKey(const ValueKey<String>('ai-voice-advanced')),
      warnIfMissed: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
  // 编辑器的即时校验有 300ms 防抖
  for (int i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 400));
  }
  _drainExceptions(tester, s.name, 'settle');
  await _capture(tester, key, '$_outDir/${_tag}_${s.name}.png', s.dpr);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  _drainExceptions(tester, s.name, 'unmount');
  aiService?.dispose();
  await aiMsgs?.close();
}

/// 把 [_Scene.aiState] 钉到 AI 成员上(`RoomController.debugSetAiState`),
/// 覆盖音量/插件推导出来的状态,截图才稳定。
Future<void> _applyAiState(
  WidgetTester tester,
  RoomController controller,
  _Scene s,
) async {
  if (!s.ai || s.aiState == null) return;
  controller.debugSetAiState(_aiId, AiActivity.values.byName(s.aiState!));
  await tester.pump();
}

/// 打开成员资料面板。别人的面板要先喂排行榜(今天 / 本周),专注统计才有数。
Future<void> _openProfile(
  WidgetTester tester,
  _Scene s,
  FocusHarness? focus,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  if (focus != null) {
    focus.inject(<String, dynamic>{
      't': 'focus_board',
      'circleId': 'home',
      'today': <Map<String, dynamic>>[
        <String, dynamic>{'userId': 'u1', 'name': _names['u1'], 'ms': 142 * 60000},
      ],
      'week': <Map<String, dynamic>>[
        <String, dynamic>{
          'userId': 'u1',
          'name': _names['u1'],
          'ms': 11 * 3600000 + 20 * 60000,
        },
      ],
      'all': <Map<String, dynamic>>[],
    });
    await tester.pump();
  }
  final String who = s.profile == 'own' ? 'u_me' : 'u1';
  final Finder orb = find.byWidgetPredicate(
    (Widget w) => w is AvatarOrb && w.member.userId == who,
  );
  if (orb.evaluate().isEmpty) {
    _exceptions.add('[${s.name}] orb $who not found');
    return;
  }
  await tester.tap(orb.first, warnIfMissed: false);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  if (s.profile == 'own') {
    await tester.enterText(
      find.byKey(const ValueKey<String>('profile-name-field')),
      '小林',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('profile-emoji-🌙')),
      warnIfMissed: false,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('profile-bio-field')),
      '晚上十点后在',
    );
    // 截图里不要光标和键盘:收起焦点
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    // 等点按的水波纹褪完,不然它会糊在选中的格子上
    await tester.pump(const Duration(seconds: 2));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _runScene(WidgetTester tester, _Scene s) async {
  // 视口:改 tester.view,让真实 MediaQuery 看到尺寸/安全区/键盘
  tester.view.physicalSize = Size(
    s.size.width * s.dpr,
    (s.height ?? s.size.height) * s.dpr,
  );
  tester.view.devicePixelRatio = s.dpr;
  tester.view.padding = FakeViewPadding(
    top: s.padTop * s.dpr,
    bottom: s.padBottom * s.dpr,
  );
  tester.view.viewInsets = FakeViewPadding.zero;
  // AI 场景:开「降低动效」,AI 光球停在静态帧(MaterialApp 的 MediaQuery
  // 从 platformDispatcher 读 accessibilityFeatures)。
  if (s.name.startsWith('ai_')) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }
  if (s.kind != _Kind.room) return _runPurposeScene(tester, s);

  final _FakeSignalingClient signaling = _FakeSignalingClient();
  final _FakeRtcService rtc = _FakeRtcService();
  final RoomController controller = RoomController(
    signaling: signaling,
    rtc: rtc,
    userId: 'u_me',
    deviceId: 'd_1',
    userName: '我',
  );
  controller.captionsAvailable = true;
  unawaited(controller.join('home').catchError((Object _) {}));

  final List<String> ids = <String>[
    'u_me',
    'u1',
    'u2',
    'u3',
  ].take(s.people).toList()..addAll(<String>[if (s.ai) _aiId]);
  const Map<String, String> statuses = <String, String>{
    'u_me': 'free',
    'u1': 'free',
    'u2': 'busy',
    'u3': 'ears',
    _aiId: 'free',
  };
  signaling.testInject(<String, dynamic>{
    't': 'room',
    'circleId': 'home',
    'members': <Map<String, dynamic>>[
      for (final String id in ids)
        <String, dynamic>{
          'userId': id,
          'name': _names[id],
          'status': statuses[id],
          // 资料场景:阿蛮带头像 emoji、签名、进房时刻
          if (s.profile != null && id == 'u1') ...<String, dynamic>{
            'emoji': '🦊',
            'bio': '在赶论文,有事喊我',
            'joinedAt': DateTime.now()
                .subtract(const Duration(minutes: 12))
                .millisecondsSinceEpoch,
          },
        },
    ],
  });
  // 非圈主看别人:注册圈 + 没有圈主钥匙 → 没有「移出圈子」
  if (s.profile == 'other') {
    controller.circleInfo['home'] =
        (registered: true, e2ee: null, transcript: false);
  }
  await controller.testInjectToken('wss://fake', 'tok');
  if (s.circle != null) {
    signaling.testInject(<String, dynamic>{
      't': 'circle_settings',
      'circle': s.circle,
    });
  }

  // 「更多」里的格子要有服务在背后:插件 / 地图 / 转写
  PluginService? plugins;
  StreamController<Map<String, dynamic>>? pluginMsgs;
  LocationShareService? location;
  StreamController<Map<String, dynamic>>? transcriptMsgs;
  TranscriptService? transcripts;
  if (s.extras || s.ai) {
    pluginMsgs = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    plugins = PluginService(
      send: (_) {},
      messages: pluginMsgs.stream,
      ownerKeyFor: (_) => null,
    );
    pluginMsgs.add(<String, dynamic>{
      't': 'plugins',
      'circleId': 'home',
      'items': <Map<String, dynamic>>[
        if (s.extras)
          <String, dynamic>{
            'id': 'acme.board',
            'name': '白板',
            'enabled': true,
            'entry': <String, dynamic>{'url': 'https://example.com/board'},
          },
        if (s.ai) _aiPluginJson,
      ],
    });
  }
  if (s.extras) {
    location = LocationShareService(room: controller);
    transcriptMsgs = StreamController<Map<String, dynamic>>.broadcast(
      sync: true,
    );
    transcripts = TranscriptService(
      send: (_) {},
      messages: transcriptMsgs.stream,
      ownerKeyFor: (_) => null,
      circleKeyFor: (_) async => null,
      isE2EE: (_) => false,
      myUserId: () => 'u_me',
      myName: () => '我',
      store: LocalTranscriptStore(backend: MemoryTranscriptBackend()),
    );
  }

  final ShotsChatService chat = ShotsChatService();
  if (s.chatMessages) chat.seed(s.aiChat ? _aiChatMessages() : _chatMessages());

  final FakeChannel ch = FakeChannel(localIdentity: 'u_me');
  final FakeTap tap = FakeTap();
  final CaptionController captions = CaptionController(
    transcriberFactory:
        ({required onPartial, required onFinal, required onFatal}) =>
            FakeTranscriber(onPartial, onFinal, onFatal),
    nameOf: (String id) => _names[id] ?? id,
  );
  captions.bindSession(ch, tap);
  captions.updateConditions(
    const CaptionConditions(
      available: true,
      inRoom: true,
      muted: false,
      provide: true,
    ),
  );

  FocusHarness? focus;
  if (s.focus != null) {
    focus = FocusHarness(ownerKey: 'ok_home');
    focus.enable('home');
    focus.service.setRoom('home');
    final bool brk = s.focus == 'break';
    final bool idle = s.focus == 'idle';
    focus.status(
      'home',
      phase: idle
          ? 'idle'
          : brk
          ? 'break'
          : 'focus',
      endsAt: idle
          ? null
          : kFocusNow + (brk ? 3 * 60 + 42 : 18 * 60 + 27) * 1000,
      round: idle ? 0 : 2,
      rounds: 4,
      members: <Map<String, dynamic>>[
        focusMember(
          'u_me',
          '我',
          idle
              ? 'idle'
              : brk
              ? 'break'
              : 'focus',
        ),
        focusMember(
          'u1',
          _names['u1']!,
          idle
              ? 'idle'
              : brk
              ? 'break'
              : 'focus',
        ),
        focusMember(
          'u2',
          _names['u2']!,
          idle
              ? 'idle'
              : brk
              ? 'break'
              : 'away',
          awaySince: brk || idle ? null : kFocusNow - 133000,
        ),
        focusMember(
          'u3',
          _names['u3']!,
          idle
              ? 'idle'
              : brk
              ? 'break'
              : 'focus',
        ),
      ],
    );
    _injectSocial(focus, s);
  }

  final GlobalKey key = GlobalKey();
  final ThemeData theme = _withFont(
    s.light ? LaresTheme.light() : LaresTheme.dark(),
  );

  final Widget room = RoomScreen(
    controller: controller,
    circleName: '我们的圈',
    chat: chat,
    captions: captions,
    plugins: plugins,
    locationShare: location,
    focus: focus?.service,
    focusLock: focus == null ? null : FocusLock(supported: true),
  );
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: localizedApp(
        transcripts == null
            ? room
            : TranscriptScope(service: transcripts, child: room),
        theme: theme,
      ),
    ),
  );
  await tester.pump();
  _drainExceptions(tester, s.name, 'mount');

  if (s.speaking.isNotEmpty) {
    rtc.speaking.add(s.speaking);
    await tester.pump();
  }

  if (s.captions) {
    ch.join('u1', mic: true);
    ch.join('u3', mic: true); // 开着麦但没表态 → 「大橘 未开启字幕」
    await tester.runAsync(() => captions.setWantCaptions(true));
    await tester.pump();
    ch.receive('u1', <String, dynamic>{'t': 'capack', 'on': true});
    ch.receive('u1', <String, dynamic>{
      't': 'cap',
      'id': 'a',
      'seq': 1,
      'text': '今天晚饭吃的什么呀?',
      'final': true,
    });
    ch.receive('u1', <String, dynamic>{
      't': 'cap',
      'id': 'b',
      'seq': 2,
      'text': '我煮了一锅番茄牛腩,还剩好多。',
      'final': true,
    });
    ch.receive('u1', <String, dynamic>{
      't': 'cap',
      'id': 'c',
      'seq': 3,
      'text': '要不明天带点给',
      'final': false,
    });
    // 有人向本机请求字幕 → 「正在为 小鹿 生成字幕」横幅
    ch.remotes.add('u2');
    ch.receive('u2', <String, dynamic>{'t': 'capreq', 'on': true});
    if (s.aiCaptions) {
      // AI 成员也走 lares.cap:它自己发字幕
      ch.join(_aiId, mic: true);
      ch.receive(_aiId, <String, dynamic>{'t': 'capack', 'on': true});
      ch.receive(_aiId, <String, dynamic>{
        't': 'cap',
        'id': 'ai1',
        'seq': 1,
        'text': '番茄牛腩可以冷藏三天,明天热一下就能带。',
        'final': true,
      });
      ch.receive(_aiId, <String, dynamic>{
        't': 'cap',
        'id': 'ai2',
        'seq': 2,
        'text': '记得用密封盒装',
        'final': false,
      });
    }
    await tester.pump();
  }
  await _applyAiState(tester, controller, s);
  _drainExceptions(tester, s.name, 'setup');

  if (s.chatMessages || s.keyboard) {
    final Finder expand = find.byTooltip('展开消息');
    if (expand.evaluate().isNotEmpty) {
      await tester.tap(expand.first, warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    _drainExceptions(tester, s.name, 'expand');
  }

  if (s.keyboard) {
    tester.view.viewInsets = FakeViewPadding(bottom: 336 * s.dpr);
    final Finder field = find.byType(TextField);
    if (field.evaluate().isNotEmpty) {
      await tester.tap(field.first, warnIfMissed: false);
      await tester.pump();
    }
    _drainExceptions(tester, s.name, 'keyboard');
  }

  if (s.focus == 'board' && focus != null) {
    await tester.tap(
      find.byKey(const ValueKey<String>('focus-board')).first,
      warnIfMissed: false,
    );
    await tester.pump();
    focus.inject(<String, dynamic>{
      't': 'focus_board',
      'circleId': 'home',
      'today': <Map<String, dynamic>>[
        <String, dynamic>{
          'userId': 'u1',
          'name': _names['u1'],
          'ms': 142 * 60000,
        },
        <String, dynamic>{'userId': 'u_me', 'name': '我', 'ms': 96 * 60000},
        <String, dynamic>{
          'userId': 'u3',
          'name': _names['u3'],
          'ms': 75 * 60000,
        },
        <String, dynamic>{
          'userId': 'u2',
          'name': _names['u2'],
          'ms': 31 * 60000,
        },
      ],
      'week': <Map<String, dynamic>>[],
      'all': <Map<String, dynamic>>[],
    });
    await tester.pump();
    _drainExceptions(tester, s.name, 'board');
  }

  for (int i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 700));
  }
  _drainExceptions(tester, s.name, 'settle');

  if (s.overlay == 'more' || s.overlay == 'ai_info') {
    await tester.tap(
      find.byKey(const ValueKey<String>('room-more')).first,
      warnIfMissed: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    _drainExceptions(tester, s.name, 'more');
    if (s.overlay == 'ai_info') {
      // 从「更多」里的 AI 格进去:先关面板再开说明面板
      final Finder tile = find.byKey(const ValueKey<String>('room-ai'));
      if (tile.evaluate().isEmpty) {
        _exceptions.add('[${s.name}] AI tile not found in more sheet');
      } else {
        await tester.tap(tile.first, warnIfMissed: false);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
      }
      _drainExceptions(tester, s.name, 'ai_info');
    }
  } else if (s.overlay == 'privacy') {
    final BuildContext ctx = tester.element(find.byType(RoomScreen));
    unawaited(
      showCirclePrivacySheet(ctx, summary: _privacySample, circleName: '我们的圈'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    _drainExceptions(tester, s.name, 'privacy');
  } else if (s.overlay != null && s.overlay!.startsWith('push_')) {
    await _openPushOverlay(tester, s, focus);
    _drainExceptions(tester, s.name, s.overlay!);
  }
  if (s.name == 'minimal_room') _logMicCentre(tester, s);
  if (s.profile != null) await _openProfile(tester, s, focus);

  await _capture(tester, key, '$_outDir/${_tag}_${s.name}.png', s.dpr);

  // 拆树:停掉无限动画,再收控制器
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  _drainExceptions(tester, s.name, 'unmount');
  captions.dispose();
  chat.dispose();
  plugins?.dispose();
  await pluginMsgs?.close();
  await location?.dispose();
  transcripts?.dispose();
  await transcriptMsgs?.close();
  controller.dispose();
  await focus?.dispose();
  await tester.pump(const Duration(seconds: 30)); // 放掉残余计时器
  _drainExceptions(tester, s.name, 'dispose');
}

void main() {
  setUpAll(() async {
    if (_skip) return;
    TestWidgetsFlutterBinding.ensureInitialized();
    Directory(_outDir).createSync(recursive: true);
    await _loadFonts();
  });

  tearDownAll(() {
    if (_skip) return;
    File('$_outDir/${_tag}_exceptions.txt').writeAsStringSync(
      _exceptions.isEmpty ? '(none)\n' : '${_exceptions.join('\n\n')}\n',
    );
  });

  for (final _Scene s in _scenes) {
    testWidgets(
      'room shot ${s.name}',
      (WidgetTester tester) async {
        addTearDown(tester.view.reset);
        final bool oldBanner = WidgetsApp.debugAllowBannerOverride;
        WidgetsApp.debugAllowBannerOverride = false;
        final void Function(FlutterErrorDetails)? oldOnError =
            FlutterError.onError;
        _where = '${s.name}/mount';
        FlutterError.onError = (FlutterErrorDetails d) {
          _recordError(d);
          oldOnError?.call(d);
        };
        try {
          await _runScene(tester, s);
        } finally {
          FlutterError.onError = oldOnError;
          WidgetsApp.debugAllowBannerOverride = oldBanner;
        }
      },
      skip: _skip,
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }
}
