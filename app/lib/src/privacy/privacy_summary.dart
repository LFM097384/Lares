/// 进圈隐私告知的摘要与哈希(契约 docs/plans/features-purpose-contract.md §4)。
///
/// 纯数据 + 纯函数:不碰 widget、不碰存储,便于测试与截图。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../config.dart';
import '../state/room_controller.dart';

/// 专注学习插件的 id(老服务器没发 features 时,靠它推断专注是否开着)。
const String kFocusPluginId = 'lares.focus';

/// AI 语音助手插件的 id。它在告知里单独成一行(语音送 DashScope 并生成回答),
/// 不算进通用的「插件 N 个」。
const String kAiVoicePrivacyPluginId = 'lares.ai-voice';

/// 圈里启用的一个插件(告知用)。
@immutable
class PrivacyPlugin {
  const PrivacyPlugin({
    required this.id,
    this.name,
    this.permissions = const [],
    this.hasWebhook = false,
  });

  final String id;

  /// 显示名(从 PluginService 取;不知道就 null,界面显示 id)。
  /// **不进哈希**:改名不是隐私变化。
  final String? name;
  final List<String> permissions;

  /// 服务端插件:圈里的事件会发到插件作者的服务器(第三方)。
  final bool hasWebhook;

  String get displayName => (name == null || name!.isEmpty) ? id : name!;
}

/// 一个圈子与隐私有关的配置快照。
@immutable
class CirclePrivacySummary {
  const CirclePrivacySummary({
    required this.circleId,
    this.transcript = false,
    this.e2ee,
    this.captions = false,
    this.plugins = const [],
    this.focus = false,
    this.recording = false,
    this.map = false,
    this.ai = false,
    this.showRecording = LaresConfig.recordingEnabled,
  });

  final String circleId;

  /// 转写记录开着(语音经云端识别并存档;E2EE 圈服务器只存密文)。
  final bool transcript;

  /// 圈级端到端加密规定:true / false / null(没有统一规定)。
  final bool? e2ee;

  /// 服务器配了实时字幕 且 本圈开着字幕(语音片段送阿里云 DashScope 识别)。
  final bool captions;

  /// 启用的插件(按 id 排序)。
  final List<PrivacyPlugin> plugins;

  /// 专注追踪(谁在专注、离开时长)。
  final bool focus;

  /// 录音功能开着。只有编译开关 [LaresConfig.recordingEnabled] 打开时才显示,
  /// 但无论如何都进哈希。
  final bool recording;

  /// 位置共享 / 地图可用。
  final bool map;

  /// AI 语音助手(内置插件 lares.ai-voice)启用:房里的语音送阿里云百炼识别并生成回答。
  /// 不出现在 [plugins] 里。
  final bool ai;

  /// 界面上要不要出现「录音」一行。
  final bool showRecording;

  /// 有没有值得一提的(E2EE 那一行永远会说,不算在内)。
  bool get hasNotable =>
      ai ||
      transcript ||
      captions ||
      plugins.isNotEmpty ||
      focus ||
      map ||
      (recording && showRecording);

  /// 进哈希的规范化结构:键排序,插件按 id 排序,权限排序。
  /// 插件名**不进**。
  Map<String, Object?> canonical() {
    final ps = [...plugins]..sort((a, b) => a.id.compareTo(b.id));
    return <String, Object?>{
      // 只在开着时写进去:老圈(没有 AI)的哈希保持不变,升级后不必人人重看一遍告知
      if (ai) 'ai': true,
      'captions': captions,
      'e2ee': e2ee,
      'focus': focus,
      'map': map,
      'plugins': [
        for (final p in ps)
          <String, Object?>{
            'hasWebhook': p.hasWebhook,
            'id': p.id,
            'permissions': (p.permissions.toSet().toList()..sort()),
          },
      ],
      'recording': recording,
      'transcript': transcript,
    };
  }

  /// sha256(规范 JSON) 前 16 位 hex。
  String privacyHash() =>
      sha256.convert(utf8.encode(jsonEncode(canonical()))).toString().substring(0, 16);

  /// 截图 / 预览用的示例(转写开、两个插件、专注开、未加密)。
  factory CirclePrivacySummary.sample({String circleId = 'c_sample'}) =>
      CirclePrivacySummary(
        circleId: circleId,
        transcript: true,
        e2ee: false,
        captions: true,
        focus: true,
        plugins: const [
          PrivacyPlugin(
            id: 'lares.focus',
            name: '专注学习',
            permissions: ['members:read', 'focus:read'],
          ),
          PrivacyPlugin(
            id: 'example.notes',
            name: '会议纪要',
            permissions: ['transcript:read', 'chat:send'],
            hasWebhook: true,
          ),
        ],
      );
}

/// 本机是否已知道这个圈子的完整隐私配置(可以弹告知了)。
///
/// circleInfo 必须有;新服务器(发了 features)还要等带权限的插件列表
/// (welcome.circle / circle_settings 才有,circle_summary 只有 {id, enabled})。
/// 老服务器没有 features → 有 circleInfo 就算完整。
bool privacyInfoKnown(RoomController c, String circleId) {
  if (!c.circleInfo.containsKey(circleId)) return false;
  if (c.circleFeatures.containsKey(circleId)) {
    return c.circlePrivacyPlugins.containsKey(circleId);
  }
  return true;
}

/// 从控制器状态拼出某圈的隐私摘要。
///
/// [pluginNames] 插件 id → 显示名(可选,来自 PluginService);不进哈希。
CirclePrivacySummary buildCirclePrivacySummary(
  RoomController c,
  String circleId, {
  Map<String, String> pluginNames = const {},
  bool showRecording = LaresConfig.recordingEnabled,
}) {
  final info = c.circleInfo[circleId];
  final hasFeatures = c.circleFeatures.containsKey(circleId);
  final f = c.featuresOf(circleId);
  final raw = c.circlePrivacyPlugins[circleId] ?? const [];
  // AI 助手单独一行,不进通用插件列表(数量 / 名单 / 哈希里的 plugins 都一致排除)
  final ai = raw.any((p) => p.id == kAiVoicePrivacyPluginId);
  final plugins = [
    for (final p in raw)
      if (p.id != kAiVoicePrivacyPluginId)
      PrivacyPlugin(
        id: p.id,
        name: pluginNames[p.id],
        permissions: (p.permissions.toSet().toList()..sort()),
        hasWebhook: p.hasWebhook,
      ),
  ]..sort((a, b) => a.id.compareTo(b.id));
  return CirclePrivacySummary(
    circleId: circleId,
    transcript: info?.transcript ?? false,
    e2ee: info?.e2ee,
    captions: c.captionsAvailable && f.captions,
    plugins: plugins,
    // 老服务器不发 features:CircleFeatures.legacy 会说「专注开」,
    // 那不是真的 —— 改看专注插件是否启用。
    focus: hasFeatures
        ? f.focus
        : plugins.any((p) => p.id == kFocusPluginId),
    recording: f.recording,
    map: f.map,
    ai: ai,
    showRecording: showRecording,
  );
}
