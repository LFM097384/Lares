// 验证工具(不是生产代码):字幕的**本地麦克风抽头**在本平台是否真的出帧。
//
// 用生产的 LiveKitCaptionSession 作抽头,依次验证:
//   1. 发布麦克风后 attach → 有帧,且是 16 kHz 单声道 Int16(每 10 ms 320 字节)
//   2. mute → unmute(SDK 内部 restartTrack,旧渲染器失效)→ trackChanges 触发,
//      重新 attach 后帧恢复
// 结果写 spike_out/caption_tap.txt,跑完自动退出(退出码 0 = 全部通过)。
//
// 用法:
//   server\livekit\livekit-server.exe --dev --bind 127.0.0.1   (另开窗口)
//   flutter run -d windows -t tool/caption_tap_harness.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:lares_app/src/captions/livekit_caption_session.dart';

const _url = 'ws://127.0.0.1:7880';
final _out = File(r'D:\Projects\Lares\app\spike_out\caption_tap.txt');

void log(String s) {
  final line = '[${DateTime.now().toIso8601String().substring(11, 23)}] $s';
  // ignore: avoid_print
  print(line);
  _out.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

/// livekit --dev 的固定密钥 devkey/secret。
String devToken(String identity, String room) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final h = _b64(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})));
  final p = _b64(utf8.encode(jsonEncode({
    'iss': 'devkey',
    'sub': identity,
    'nbf': now - 10,
    'exp': now + 3600,
    'video': {'room': room, 'roomJoin': true, 'canPublish': true, 'canSubscribe': true, 'canPublishData': true},
  })));
  final s = _b64(Hmac(sha256, utf8.encode('secret')).convert(utf8.encode('$h.$p')).bytes);
  return '$h.$p.$s';
}

Future<({int frames, int bytes, int nonZero})> sample(
    LiveKitCaptionSession s, Duration d) async {
  var frames = 0, bytes = 0, nonZero = 0;
  final cancel = s.attach((Uint8List pcm) {
    frames++;
    bytes += pcm.length;
    final v = ByteData.sublistView(pcm);
    for (var i = 0; i + 1 < pcm.length; i += 2) {
      if (v.getInt16(i, Endian.little) != 0) nonZero++;
    }
  });
  if (cancel == null) {
    log('attach 返回 null(没有本地麦克风轨道)');
    return (frames: 0, bytes: 0, nonZero: 0);
  }
  await Future<void>.delayed(d);
  await cancel();
  return (frames: frames, bytes: bytes, nonZero: nonZero);
}

Future<void> run() async {
  _out.parent.createSync(recursive: true);
  if (_out.existsSync()) _out.deleteSync();
  log('platform=${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
  final room = Room(roomOptions: const RoomOptions(adaptiveStream: false, dynacast: false));
  await room.connect(_url, devToken('u_captap', 'captap'));
  log('connected as ${room.localParticipant?.identity}');
  final session = LiveKitCaptionSession(room);
  var changes = 0;
  session.trackChanges.listen((_) => changes++);

  await room.localParticipant!.setMicrophoneEnabled(true);
  await Future<void>.delayed(const Duration(milliseconds: 800));
  log('mic published; micPublishedAndUnmuted=${session.micPublishedAndUnmuted}');

  var ok = true;
  final a = await sample(session, const Duration(seconds: 3));
  final perFrame = a.frames == 0 ? 0 : a.bytes / a.frames;
  log('阶段1 首次 attach:${a.frames} 帧 / 3 s, ${perFrame.toStringAsFixed(0)} 字节/帧, 非零样本 ${a.nonZero}');
  // 16 kHz 单声道 Int16:10 ms = 320 字节,3 s ≈ 300 帧
  if (a.frames < 200 || perFrame != 320) ok = false;

  await room.localParticipant!.setMicrophoneEnabled(false);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  log('muted; micPublishedAndUnmuted=${session.micPublishedAndUnmuted}');
  if (session.micPublishedAndUnmuted) ok = false;
  final before = changes;
  await room.localParticipant!.setMicrophoneEnabled(true);
  await Future<void>.delayed(const Duration(milliseconds: 800));
  log('unmuted; trackChanges 触发 ${changes - before} 次; micPublishedAndUnmuted=${session.micPublishedAndUnmuted}');
  if (changes == before) ok = false;

  final b = await sample(session, const Duration(seconds: 3));
  log('阶段2 unmute 后重新 attach:${b.frames} 帧 / 3 s, 非零样本 ${b.nonZero}');
  if (b.frames < 200) ok = false;

  log(ok ? 'RESULT PASS' : 'RESULT FAIL');
  session.dispose();
  await room.disconnect();
  exit(ok ? 0 : 1);
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('caption tap harness')))));
  run().catchError((Object e, StackTrace st) {
    log('ERROR $e\n$st');
    exit(2);
  });
}
