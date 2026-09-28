// 实时字幕真机联调(opt-in):本地起服务端 → 走真实 cap_token 签发 →
// 真实 QwenRealtimeStt 连阿里云 → 按实时速度喂 phase0 语料 → CER ≤ 10%。
//
// 运行(Key 只进本进程环境变量,不落盘、不打印):
//   $env:LARES_CAPTIONS_LIVE='1'; $env:LARES_DASHSCOPE_API_KEY='…'
//   flutter test test/captions_live_test.dart
//
// 语料在仓库外的 .tmp-win/captions/phase0/set(16 kHz 单声道 wav + manifest.json)。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/captions/caption_protocol.dart';
import 'package:lares_app/src/captions/caption_wiring.dart';
import 'package:lares_app/src/captions/qwen_realtime_stt.dart';
import 'package:web_socket_channel/io.dart';

const _port = 18990;
const _pass = 'cap-live-pass';

final _strip = RegExp(r'''[\s，。！？、,.!?;；:：“”"'‘’…—\-（）()·~～《》<>]''');
final _tok = RegExp(r"[a-z0-9]+(?:'[a-z]+)?|[^a-z0-9]");

List<String> tokens(String s) {
  // 与 phase0 eval_asr.py 同一口径:小写、去标点空白、拉丁词整词、其余逐字
  final lower = s.toLowerCase();
  final out = <String>[];
  for (final m in _tok.allMatches(lower)) {
    final t = m.group(0)!;
    if (t.length == 1 && _strip.hasMatch(t)) continue;
    out.add(t);
  }
  return out;
}

int editDistance(List<String> a, List<String> b) {
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      cur[j] = [
        prev[j] + 1,
        cur[j - 1] + 1,
        prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
      ].reduce(math.min);
    }
    prev = cur;
  }
  return prev[b.length];
}

Uint8List wavPcm(File f) {
  final b = f.readAsBytesSync();
  final bd = ByteData.sublistView(b);
  var off = 12;
  while (off + 8 <= b.length) {
    final id = ascii.decode(b.sublist(off, off + 4));
    final len = bd.getUint32(off + 4, Endian.little);
    if (id == 'fmt ') {
      final ch = bd.getUint16(off + 10, Endian.little);
      final sr = bd.getUint32(off + 12, Endian.little);
      final bits = bd.getUint16(off + 22, Endian.little);
      if (ch != 1 || sr != 16000 || bits != 16) {
        throw StateError('${f.path}: 需要 16k/单声道/16bit');
      }
    }
    if (id == 'data') return Uint8List.sublistView(b, off + 8, off + 8 + len);
    off += 8 + len + (len.isOdd ? 1 : 0);
  }
  throw StateError('${f.path}: 没有 data 块');
}

void main() {
  final enabled = Platform.environment['LARES_CAPTIONS_LIVE'] == '1';
  final key = Platform.environment['LARES_DASHSCOPE_API_KEY'] ?? '';

  group('实时字幕 · 阿里云真机', skip: enabled ? null : '需环境变量 LARES_CAPTIONS_LIVE=1', () {
    test('本地服务端签 token → qwen3-asr 实时识别 25 条语料,CER ≤ 10%', () async {
      expect(key, isNotEmpty, reason: '需要 LARES_DASHSCOPE_API_KEY');
      final setDir = Directory('../.tmp-win/captions/phase0/set');
      expect(setDir.existsSync(), isTrue, reason: '缺 phase0 语料');
      final manifest = (jsonDecode(
              File('${setDir.path}/manifest.json').readAsStringSync()) as List)
          .cast<Map<String, dynamic>>();

      // ── 起服务端(只把需要的变量传下去,Key 不进日志)──
      final env = Map<String, String>.from(Platform.environment)
        ..removeWhere((k, _) => k.startsWith('LARES_') || k.startsWith('LIVEKIT_'))
        ..addAll({
          'LARES_PORT': '$_port',
          'LARES_AUTH_MODE': 'circle',
          'LARES_CIRCLE_PASSCODE': _pass,
          'LARES_DATA_DIR': Directory.systemTemp.createTempSync('lares-cap-live').path,
          'LARES_DASHSCOPE_API_KEY': key,
        });
      final server = await Process.start('node', ['src/index.js'],
          workingDirectory: '../server', environment: env, includeParentEnvironment: false);
      final serverLog = StringBuffer();
      server.stdout.transform(utf8.decoder).listen(serverLog.write);
      server.stderr.transform(utf8.decoder).listen(serverLog.write);
      addTearDown(() => server.kill());

      final http = HttpClient();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (true) {
        try {
          final r = await (await http.getUrl(Uri.parse('http://127.0.0.1:$_port/health'))).close();
          await r.drain<void>();
          if (r.statusCode == 200) break;
        } catch (_) {}
        if (DateTime.now().isAfter(deadline)) fail('服务端启动超时');
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      http.close();
      expect(serverLog.toString(), isNot(contains(key)), reason: '服务端日志不得含 Key');

      // ── 信令:challenge → hello → welcome → join ──
      const cid = 'caplive';
      const uid = 'u_live';
      final ch = IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$_port/ws'));
      final inbox = StreamController<Map<String, dynamic>>.broadcast();
      ch.stream.listen((raw) {
        final m = jsonDecode(raw as String) as Map<String, dynamic>;
        if (m['t'] == 'challenge') {
          final nonce = m['nonce'] as String;
          final proof = Hmac(sha256, utf8.encode(_pass))
              .convert(utf8.encode('$nonce:$uid:$cid'))
              .toString();
          ch.sink.add(jsonEncode({
            't': 'hello', 'userId': uid, 'deviceId': 'd-live', 'name': 'live',
            'platform': 'windows',
            'auth': {'mode': 'circle', 'circleId': cid, 'nonce': nonce, 'proof': proof},
          }));
        }
        inbox.add(m);
      });
      addTearDown(() => ch.sink.close());
      final welcome = await inbox.stream.firstWhere((m) => m['t'] == 'welcome' || m['t'] == 'error')
          .timeout(const Duration(seconds: 10));
      expect(welcome['t'], 'welcome');
      expect(welcome['captions'], isTrue);
      ch.sink.add(jsonEncode({'t': 'join', 'circleId': cid}));
      await inbox.stream.firstWhere((m) => m['t'] == 'room').timeout(const Duration(seconds: 10));

      final tokens0 = SignalingCaptionTokenSource(
        send: (m) => ch.sink.add(jsonEncode(m)),
        messages: inbox.stream,
        e2eeOptIn: () => false,
      );

      // ── 识别:一条连接跑完 25 条(每条后补 1.5 s 静音让 VAD 断句)──
      final finals = <String>[];
      final logs = <String>[];
      var partials = 0;
      final stt = QwenRealtimeStt(
        tokenSource: tokens0.call,
        onPartial: (_, _) => partials++,
        onFinal: (_, t) => finals.add(t),
        onLog: logs.add,
        finishTimeout: const Duration(seconds: 4),
      );
      stt.start();
      final sw = Stopwatch()..start();
      final t0 = DateTime.now();
      while (!stt.live) {
        if (DateTime.now().difference(t0) > const Duration(seconds: 25)) {
          fail('连不上 DashScope:${logs.join(' | ')}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final connectMs = sw.elapsedMilliseconds;

      final silence = Uint8List(3200);
      Future<void> feed(Uint8List pcm) async {
        final start = DateTime.now();
        for (var off = 0, i = 0; off < pcm.length; off += 3200, i++) {
          stt.addPcm(Uint8List.sublistView(pcm, off, math.min(off + 3200, pcm.length)));
          final due = start.add(Duration(milliseconds: 100 * (i + 1)));
          final wait = due.difference(DateTime.now());
          if (wait > Duration.zero) await Future<void>.delayed(wait);
        }
      }

      var edits = 0, refLen = 0;
      final byCat = <String, List<int>>{};
      final rows = <String>[];
      for (final item in manifest) {
        final pcm = wavPcm(File('${setDir.path}/${item['id']}.wav'));
        final before = finals.length;
        await feed(pcm);
        await feed(Uint8List.fromList(List.filled(15, silence).expand((e) => e).toList()));
        // 等这条的定稿(最多 5 s;来了后再等 400 ms 收尾)
        final until = DateTime.now().add(const Duration(seconds: 5));
        while (finals.length == before && DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final hypRaw = finals.sublist(before).where((f) => !isFillerOnly(f)).join();
        final ref = tokens(item['text'] as String);
        final hyp = tokens(hypRaw);
        final e = editDistance(ref, hyp);
        edits += e;
        refLen += ref.length;
        (byCat[item['cat'] as String] ??= [0, 0])
          ..[0] += e
          ..[1] += ref.length;
        rows.add('${item['id']} ${item['cat']} ${(100 * e / ref.length).toStringAsFixed(1)}%'
            '${e > 0 ? '  ref=${item['text']}  hyp=$hypRaw' : ''}');
      }
      await stt.stop();
      await stt.dispose();

      final cer = edits / refLen;
      // ignore: avoid_print
      print([
        '── 实时字幕 live CER ──',
        '连接耗时 ${connectMs}ms, 建连 ${stt.connectAttempts} 次, 发送 ${stt.chunksSent} 块, partial $partials 条, final ${finals.length} 条',
        ...rows,
        for (final e in byCat.entries)
          '${e.key}: ${(100 * e.value[0] / e.value[1]).toStringAsFixed(1)}%',
        '总 CER: ${(100 * cer).toStringAsFixed(2)}% ($edits/$refLen)',
      ].join('\n'));
      expect(cer, lessThanOrEqualTo(0.10));
    }, timeout: const Timeout(Duration(minutes: 8)));
  });
}
