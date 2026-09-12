import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:record/record.dart';

import 'models.dart';
import 'room_controller.dart';

/// 语音便签(设计.md §2.2):圈子里没人时留一条 ≤15s 语音,
/// 下一个进房的人点一下就听,听过即删。
class VoiceNote {
  const VoiceNote({
    required this.id,
    required this.userId,
    required this.name,
    required this.audioBase64,
    required this.mime,
    required this.durationSec,
    required this.createdAt,
  });

  final String id;
  final String userId;
  final String name;
  final String audioBase64;
  final String mime;
  final double durationSec;
  final int createdAt;

  factory VoiceNote.fromWire(Map<String, dynamic> j) => VoiceNote(
        id: j['id'] as String,
        userId: j['userId'] as String? ?? '',
        name: j['name'] as String? ?? '圈友',
        audioBase64: j['audio'] as String? ?? '',
        mime: j['mime'] as String? ?? 'audio/aac',
        durationSec: (j['durationSec'] as num?)?.toDouble() ?? 0,
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      );
}

class VoiceNotesController extends ChangeNotifier {
  VoiceNotesController({required this.httpBase, required RoomController room})
      : _room = room {
    // 进房后拉取便签;收到 note_added 广播时刷新
    _room.addListener(_onRoomChanged);
  }

  /// 信令服务的 HTTP 基地址(ws://host:port -> http://host:port)
  final String httpBase;
  final RoomController _room;

  final List<VoiceNote> _notes = [];
  bool _fetched = false;
  RoomPhase _lastPhase = RoomPhase.idle;

  final AudioRecorder _recorder = AudioRecorder();
  Player? _player;
  bool _mediaKitReady = false;

  /// 惰性初始化 media_kit:首次播放时才初始化
  /// (启动更快;Web/WASM 下初始化异常不影响 App 启动)
  Future<Player> _ensurePlayer() async {
    if (!_mediaKitReady) {
      MediaKit.ensureInitialized();
      _mediaKitReady = true;
    }
    return _player ??= Player();
  }

  bool recording = false;
  bool playing = false;
  DateTime? _recordStartedAt;

  static const maxRecordSeconds = 15;

  List<VoiceNote> get notes => List.unmodifiable(_notes);
  int get pendingCount => _notes.length;

  void _onRoomChanged() {
    // 进房成功时拉一次
    if (_room.phase == RoomPhase.inRoom && _lastPhase != RoomPhase.inRoom) {
      refresh();
    }
    // 收到 note_added 广播(controller 只 notify,消息体简化处理:直接刷新)
    if (_room.phase == RoomPhase.inRoom && _room.noteBumpCounter != _lastNoteBump) {
      _lastNoteBump = _room.noteBumpCounter;
      refresh();
    }
    _lastPhase = _room.phase;
  }

  int _lastNoteBump = 0;

  Future<void> refresh() async {
    final circleId = _room.circleId;
    if (circleId == null) return;
    try {
      final res = await http.get(Uri.parse('$httpBase/notes?circleId=$circleId'));
      if (res.statusCode != 200) return;
      final list = (jsonDecode(res.body)['notes'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(VoiceNote.fromWire)
          // 自己留的不算「待听」
          .where((n) => n.userId != _room.userId)
          .toList();
      _notes
        ..clear()
        ..addAll(list);
      _fetched = true;
      notifyListeners();
    } catch (e) {
      debugPrint('[lares] 拉取语音便签失败: $e');
    }
  }

  /// 长按开始录音
  Future<void> startRecording() async {
    if (recording) return;
    try {
      if (!await _recorder.hasPermission()) return;
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: '',
      );
      recording = true;
      _recordStartedAt = DateTime.now();
      notifyListeners();
      // 15s 硬上限
      Future.delayed(const Duration(seconds: maxRecordSeconds), () {
        if (recording) stopAndSend();
      });
    } catch (e) {
      debugPrint('[lares] 录音启动失败: $e');
    }
  }

  /// 松开发送
  Future<void> stopAndSend() async {
    if (!recording) return;
    recording = false;
    notifyListeners();
    final circleId = _room.circleId;
    try {
      final path = await _recorder.stop();
      if (path == null || path.isEmpty || circleId == null) return;
      final duration = _recordStartedAt == null
          ? 0.0
          : DateTime.now().difference(_recordStartedAt!).inMilliseconds / 1000;
      if (duration < 0.5) return; // 太短不算
      // 读音频字节(Web 返回 blob URL,http.get 可读;原生为文件路径)
      final bytes = await http.readBytes(Uri.parse(path));
      await http.post(
        Uri.parse('$httpBase/notes'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'circleId': circleId,
          'userId': _room.userId,
          'name': _room.userName,
          'audio': base64Encode(bytes),
          'mime': 'audio/aac',
          'durationSec': duration,
        }),
      );
    } catch (e) {
      debugPrint('[lares] 语音便签发送失败: $e');
    }
  }

  /// 点一下:顺序播放全部待听便签,听过即删
  Future<void> playAll() async {
    if (playing || _notes.isEmpty) return;
    playing = true;
    notifyListeners();
    final queue = List.of(_notes);
    for (final note in queue) {
      try {
        final player = await _ensurePlayer();
        final media = await Media.memory(
          base64Decode(note.audioBase64),
          type: 'audio/aac',
        );
        await player.open(media, play: true);
        await player.stream.completed.first.timeout(
          Duration(seconds: note.durationSec.ceil() + 5),
        );
      } catch (e) {
        debugPrint('[lares] 播放失败: $e');
      }
      // 听过即删(服务端 + 本地)
      _notes.removeWhere((n) => n.id == note.id);
      notifyListeners();
      unawaited(http.delete(
          Uri.parse('$httpBase/notes/${note.id}?circleId=${_room.circleId}')));
    }
    playing = false;
    notifyListeners();
  }

  bool get ready => _fetched;

  @override
  void dispose() {
    _room.removeListener(_onRoomChanged);
    _recorder.dispose();
    _player?.dispose();
    super.dispose();
  }
}

/// ws://host:8787 -> http://host:8787
String httpBaseFromWs(String wsUrl) {
  final uri = Uri.parse(wsUrl);
  final scheme = uri.scheme == 'wss' ? 'https' : 'http';
  return uri.replace(scheme: scheme, path: '').toString();
}
