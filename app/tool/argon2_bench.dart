// 实测 Argon2id 在不同参数下的耗时,用来给密钥派生定档。
// 用法:dart run tool/argon2_bench.dart
//
// 为什么必须实测:Argon2 的三个参数(内存/迭代/并行)没有"标准答案",
// 只有"在目标设备上花多久"。桌面跑得飞快的参数可能在低端安卓上卡 5 秒。
// 这里先量桌面,移动端的数要等真机。

import 'dart:typed_data';
import 'package:hashlib/hashlib.dart';

void main() {
  print('Argon2id 参数实测(本机 = Windows 桌面)\n');
  print('内存      迭代  并行   耗时      说明');
  print('--------------------------------------------------------');

  final salt = Uint8List.fromList('lares-e2ee-salt-16b'.codeUnits.take(16).toList());
  const passcode = '我们的圈子口令2026';

  // OWASP 2024 对 Argon2id 的推荐档位,以及更轻的几档供对比
  final configs = <({int m, int t, int p, String note})>[
    (m: 12, t: 1, p: 1, note: '4 MiB  —— 太弱,仅作对照'),
    (m: 15, t: 2, p: 1, note: '32 MiB'),
    (m: 16, t: 3, p: 1, note: '64 MiB'),
    (m: 16, t: 2, p: 4, note: '64 MiB 并行4'),
    (m: 17, t: 2, p: 1, note: '128 MiB'),
    (m: 19, t: 2, p: 1, note: '512 MiB —— OWASP 推荐档之一'),
  ];

  for (final c in configs) {
    final memKiB = 1 << c.m;
    final sw = Stopwatch()..start();
    try {
      final ctx = Argon2(
        version: Argon2Version.v13,
        type: Argon2Type.argon2id,
        hashLength: 32,
        iterations: c.t,
        parallelism: c.p,
        memorySizeKB: memKiB,
        salt: salt,
      );
      final out = ctx.convert(passcode.codeUnits);
      sw.stop();
      final hex = out.hex();
      print('${(memKiB / 1024).toStringAsFixed(0).padLeft(5)} MiB'
          '${c.t.toString().padLeft(6)}'
          '${c.p.toString().padLeft(6)}'
          '${sw.elapsedMilliseconds.toString().padLeft(8)} ms'
          '   ${c.note}');
      // 顺带自检:输出必须是 64 位 hex,且确定性
      assert(hex.length == 64, 'hashLength=32 应产出 64 hex 字符');
    } catch (e) {
      sw.stop();
      print('  ${c.note}: 失败 $e');
    }
  }

  print('\n── 确定性自检 ──');
  Uint8List derive(String pass, String circle) {
    final s = Uint8List(16);
    final cb = circle.codeUnits;
    for (var i = 0; i < 16; i++) {
      s[i] = i < cb.length ? cb[i] & 0xFF : (0x5A + i) & 0xFF;
    }
    return Uint8List.fromList(Argon2(
      version: Argon2Version.v13,
      type: Argon2Type.argon2id,
      hashLength: 32,
      iterations: 2,
      parallelism: 1,
      memorySizeKB: 1 << 16,
      salt: s,
    ).convert(pass.codeUnits).bytes);
  }

  final a1 = derive('口令A', 'circle-1');
  final a2 = derive('口令A', 'circle-1');
  final b = derive('口令A', 'circle-2');
  final c = derive('口令B', 'circle-1');

  bool eq(Uint8List x, Uint8List y) {
    if (x.length != y.length) return false;
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }

  print('同口令同圈两次   -> ${eq(a1, a2) ? "一致 ✓" : "不一致 ✗"}');
  print('同口令不同圈     -> ${eq(a1, b) ? "一致 ✗(应不同)" : "不同 ✓"}');
  print('不同口令同圈     -> ${eq(a1, c) ? "一致 ✗(应不同)" : "不同 ✓"}');
}
