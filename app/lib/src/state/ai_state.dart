/// AI 语音助手此刻在干什么(docs/ai-voice-bot.md「bot→客户端状态」)。
///
/// 协议:AI 成员(identity 以 `u_ai_` 开头)在 LiveKit 数据 topic `lares.ai` 上发
/// reliable JSON `{"t":"state","state":"idle"|"listening"|"thinking"|"speaking","seq":int}`,
/// 状态变化时发,有人进房时再补发一次。
///
/// 本文件是纯 Dart(不 import LiveKit),规则全在这里,方便单测:
///  - 不是 `u_ai_` 发的帧一律不认(别人冒充不了 AI 的状态);
///  - 同一发送者 seq 只认更大的(乱序 / 重放的旧帧丢掉);
///  - thinking / speaking 超过 [AiStateHolder.staleAfter] 没更新 → 当它回到 listening
///    (AI 进程挂了、帧丢了,座位也不能一直「在想…」);
///  - 一帧都没收到过 → 状态未知:在 speakingIds 里就当 speaking,否则按配置的
///    触发方式推断(ptt 不听语音 → idle,其余 → listening)。
///
/// 测试 / 截图替身:[AiStateHolder.force](或 `RoomController.debugSetAiState`)
/// 直接钉死某个状态,钉住的状态不会过期。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'ai_member.dart';

/// AI 状态的数据 topic。
const String kAiStateTopic = 'lares.ai';

/// AI 此刻的状态。
enum AiActivity { idle, listening, thinking, speaking }

/// 一帧解析结果。
typedef AiStateFrame = ({AiActivity state, int seq});

/// 解析一帧 `lares.ai` 数据。不认识 / 不合法 / 不是 AI 发的 → null。
AiStateFrame? parseAiStateFrame(String senderIdentity, List<int> bytes) {
  if (!isAiMemberId(senderIdentity)) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } catch (_) {
    return null;
  }
  return parseAiStateJson(decoded);
}

/// 解析已解码的 JSON(不校验发送者)。
AiStateFrame? parseAiStateJson(Object? json) {
  if (json is! Map) return null;
  if (json['t'] != 'state') return null;
  final Object? s = json['state'];
  final Object? seq = json['seq'];
  if (s is! String || seq is! num || !seq.isFinite) return null;
  final AiActivity? state = aiActivityFromName(s);
  if (state == null) return null;
  return (state: state, seq: seq.toInt());
}

/// `'thinking'` → [AiActivity.thinking];不认识 → null。
AiActivity? aiActivityFromName(String name) {
  for (final AiActivity a in AiActivity.values) {
    if (a.name == name) return a;
  }
  return null;
}

/// 一帧都没收到时的推断(也是过期后 / 未知时的兜底)。
///
/// [trigger] 是插件配置里的触发方式(`wake` / `always` / `ptt`,null = 不知道)。
AiActivity fallbackAiActivity({required bool speaking, String? trigger}) {
  if (speaking) return AiActivity.speaking;
  return trigger == 'ptt' ? AiActivity.idle : AiActivity.listening;
}

class _Entry {
  _Entry(this.state, this.seq, this.at);
  final AiActivity state;
  final int seq;
  final DateTime at;
}

/// 每个房间一份:按 AI 成员 userId 记最近一帧。
///
/// 进房 / 换房时调 [clear];AI 离开时可调 [remove]。
class AiStateHolder extends ChangeNotifier {
  AiStateHolder({
    DateTime Function()? now,
    this.staleAfter = const Duration(seconds: 30),
    this.scheduleStaleCheck = true,
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// thinking / speaking 多久没更新算过期。
  final Duration staleAfter;

  /// 收到 thinking / speaking 后是否排一个定时器,到点通知界面重画(过期 → listening)。
  /// 纯单测(注入时钟)可关掉,免得留下挂起的 Timer。
  final bool scheduleStaleCheck;

  final Map<String, _Entry> _frames = {};
  final Map<String, AiActivity> _forced = {};
  Timer? _staleTimer;
  bool _disposed = false;

  /// 喂一帧原始数据。认了(状态被更新)返回 true。
  bool ingest(String senderIdentity, List<int> bytes) {
    final AiStateFrame? f = parseAiStateFrame(senderIdentity, bytes);
    if (f == null) return false;
    return ingestFrame(senderIdentity, f);
  }

  /// 喂一帧已解析的数据。
  bool ingestFrame(String senderIdentity, AiStateFrame f) {
    if (_disposed || !isAiMemberId(senderIdentity)) return false;
    final _Entry? prev = _frames[senderIdentity];
    if (prev != null && f.seq <= prev.seq) return false;
    _frames[senderIdentity] = _Entry(f.state, f.seq, _now());
    _armStaleTimer(f.state);
    notifyListeners();
    return true;
  }

  /// 收到过这个 AI 的帧吗(或被 [force] 钉住了)。
  bool isKnown(String userId) =>
      _forced.containsKey(userId) || _frames.containsKey(userId);

  /// 最近一帧给出的状态(已考虑过期);一帧都没有 → null。
  AiActivity? reported(String userId) {
    final AiActivity? forced = _forced[userId];
    if (forced != null) return forced;
    final _Entry? e = _frames[userId];
    if (e == null) return null;
    final bool active =
        e.state == AiActivity.thinking || e.state == AiActivity.speaking;
    if (active && _now().difference(e.at) > staleAfter) {
      return AiActivity.listening;
    }
    return e.state;
  }

  /// 界面该画的状态:有帧用帧,没帧用 [fallbackAiActivity]。
  AiActivity resolve(String userId, {required bool speaking, String? trigger}) =>
      reported(userId) ??
      fallbackAiActivity(speaking: speaking, trigger: trigger);

  /// 测试 / 截图用:把某个 AI 钉在 [state](null = 取消钉住,回到按帧推断)。
  void force(String userId, AiActivity? state) {
    if (state == null) {
      if (_forced.remove(userId) == null) return;
    } else {
      if (_forced[userId] == state) return;
      _forced[userId] = state;
    }
    if (!_disposed) notifyListeners();
  }

  /// AI 离开房间:忘掉它的帧(钉住的状态保留)。
  void remove(String userId) {
    if (_frames.remove(userId) != null && !_disposed) notifyListeners();
  }

  /// 换房 / 退房:清空所有帧(钉住的状态保留 —— 那是测试的意图,不是房间状态)。
  void clear() {
    _staleTimer?.cancel();
    _staleTimer = null;
    if (_frames.isEmpty) return;
    _frames.clear();
    if (!_disposed) notifyListeners();
  }

  void _armStaleTimer(AiActivity state) {
    _staleTimer?.cancel();
    _staleTimer = null;
    if (!scheduleStaleCheck) return;
    if (state != AiActivity.thinking && state != AiActivity.speaking) return;
    // 多留一点余量,保证定时器触发时确实已经越过阈值
    _staleTimer = Timer(staleAfter + const Duration(milliseconds: 50), () {
      _staleTimer = null;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _staleTimer?.cancel();
    _staleTimer = null;
    super.dispose();
  }
}
