// 状态色求解器:在「保住画作色相」的前提下,解出满足色盲可分性的明度/彩度。
//
// 跑法(app/ 目录下):
//   dart run tool/palette/optimize_status.dart
//
// 为什么需要它:
// 手调状态色必然失败。四个状态色要同时满足 6 对 × 4 种色觉 = 24 个色差约束,
// 外加 4 个「环 vs 背景」对比度约束。人眼根本估不准 CIEDE2000,
// 而红绿色盲下「绿 vs 琥珀」、蓝色盲下「绿 vs 蓝」本来就会塌成一团 ——
// 实测现有基线就在蓝色盲下把「随时聊」和「耳朵在」混成了 ΔE=7.41。
//
// 解法(这就是那条设计原则):
//   **色相取自画作,明度阶梯由算法强制。**
// 色相保留画作的身份,而可分性由**明度差**承担 —— 明度是唯一在所有色觉类型下
// 都不丢失的通道。于是四个状态色被摆成一道明度阶梯,且把最容易互相混淆的一对
// (free 与 busy / free 与 ears)放在阶梯两端。
//
// 本文件只输出候选值,由人粘回 palettes.dart —— 不自动改任何文件。

import 'dart:io';
import 'dart:math' as math;

import 'contrast_check.dart';
import 'palettes.dart';

// ── LCH(CIELAB 极坐标)<-> sRGB ──

double _linearToSrgb(double c) => c <= 0.0031308
    ? c * 12.92
    : 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055;

/// LCH -> ARGB。越界时返回 null(不做 clamp —— clamp 会悄悄改变色相)。
int? lchToArgb(double l, double c, double hDeg) {
  final double h = hDeg * math.pi / 180;
  final double a = c * math.cos(h);
  final double b = c * math.sin(h);

  // Lab -> XYZ
  final double fy = (l + 16) / 116;
  final double fx = fy + a / 500;
  final double fz = fy - b / 200;
  double finv(double t) =>
      t > 6 / 29 ? t * t * t : 3 * (6 / 29) * (6 / 29) * (t - 4 / 29);
  const double xn = 0.95047, yn = 1.0, zn = 1.08883;
  final double x = xn * finv(fx);
  final double y = yn * finv(fy);
  final double z = zn * finv(fz);

  // XYZ -> 线性 sRGB
  final double rl = x * 3.2404542 + y * -1.5371385 + z * -0.4985314;
  final double gl = x * -0.9692660 + y * 1.8760108 + z * 0.0415560;
  final double bl = x * 0.0556434 + y * -0.2040259 + z * 1.0572252;

  const double eps = 0.0015; // 允许极小的数值溢出
  if (rl < -eps || gl < -eps || bl < -eps) return null;
  if (rl > 1 + eps || gl > 1 + eps || bl > 1 + eps) return null;

  int ch(double v) =>
      (_linearToSrgb(v.clamp(0.0, 1.0)).clamp(0.0, 1.0) * 255).round();
  return 0xFF000000 | (ch(rl) << 16) | (ch(gl) << 8) | ch(bl);
}

List<double> argbToLch(int argb) {
  final List<double> lab = argbToLab(argb);
  final double c = math.sqrt(lab[1] * lab[1] + lab[2] * lab[2]);
  double h = math.atan2(lab[2], lab[1]) * 180 / math.pi;
  if (h < 0) h += 360;
  return <double>[lab[0], c, h];
}

// ── 目标阈值(比 contrast_check 的门槛留出安全余量)──
const double _tNormal = 12.0; // 正常色觉两两 ΔE 目标
const double _tCvd = 9.0; // 任一色觉障碍下两两 ΔE 目标
const double _tRingVsBg = 3.2; // 状态环 vs 背景对比度目标

const List<Cvd> _cvds = <Cvd>[
  Cvd.protanopia,
  Cvd.deuteranopia,
  Cvd.tritanopia,
];

/// 一组候选的「违规量」。0 表示全部达标;越大越差。
double penalty(List<int> colors, int bg) {
  double p = 0;
  for (int i = 0; i < colors.length; i++) {
    final double ring = contrastRatio(colors[i], bg);
    if (ring < _tRingVsBg) p += (_tRingVsBg - ring) * 12;
    for (int j = i + 1; j < colors.length; j++) {
      final double dn = deltaE2000(colors[i], colors[j]);
      if (dn < _tNormal) p += (_tNormal - dn) * 2;
      for (final Cvd v in _cvds) {
        final double d =
            deltaE2000(simulateCvd(colors[i], v), simulateCvd(colors[j], v));
        if (d < _tCvd) p += (_tCvd - d) * 3;
      }
    }
  }
  return p;
}

/// 在固定色相下,搜索 L/C 使所有约束达标,同时尽量贴近原始设计值。
///
/// 搜索策略:以原值为中心做带约束的随机重启爬山。之所以不用梯度法 ——
/// CIEDE2000 + 色盲投影这条链路不可微,且 sRGB 色域边界是硬的。
List<int> solve(Palette p) {
  final List<int> initial = <int>[
    p.statusFree,
    p.statusBusy,
    p.statusEars,
    p.statusAway,
  ];
  final List<List<double>> lch =
      initial.map((int c) => argbToLch(c)).toList(growable: false);

  // 色相锁死(画作身份),只动 L 和 C。
  final List<double> hues = lch.map((List<double> e) => e[2]).toList();

  final math.Random rnd = math.Random(20260914);
  List<double> bestL = lch.map((List<double> e) => e[0]).toList();
  List<double> bestC = lch.map((List<double> e) => e[1]).toList();
  double bestScore = double.infinity;

  List<int>? build(List<double> ls, List<double> cs) {
    final List<int> out = <int>[];
    for (int i = 0; i < 4; i++) {
      final int? c = lchToArgb(ls[i], cs[i], hues[i]);
      if (c == null) return null;
      out.add(c);
    }
    return out;
  }

  double score(List<double> ls, List<double> cs) {
    final List<int>? cols = build(ls, cs);
    if (cols == null) return double.infinity;
    final double pen = penalty(cols, p.bg);
    // 达标之后,才比「离原始设计有多远」。次序很重要:
    // 先合规,再谈忠于原画。
    double drift = 0;
    for (int i = 0; i < 4; i++) {
      drift += (ls[i] - lch[i][0]).abs() * 0.35;
      drift += (cs[i] - lch[i][1]).abs() * 0.25;
    }
    return pen * 100 + drift;
  }

  for (int restart = 0; restart < 40; restart++) {
    List<double> ls = List<double>.generate(
      4,
      (int i) => (lch[i][0] + (restart == 0 ? 0 : (rnd.nextDouble() - 0.5) * 26))
          .clamp(35.0, 92.0),
    );
    List<double> cs = List<double>.generate(
      4,
      (int i) => (lch[i][1] + (restart == 0 ? 0 : (rnd.nextDouble() - 0.5) * 22))
          .clamp(5.0, 75.0),
    );
    double cur = score(ls, cs);

    double step = 7;
    for (int iter = 0; iter < 5000; iter++) {
      final int idx = rnd.nextInt(4);
      final bool moveL = rnd.nextBool();
      final List<double> nl = List<double>.of(ls);
      final List<double> nc = List<double>.of(cs);
      final double delta = (rnd.nextDouble() - 0.5) * 2 * step;
      if (moveL) {
        nl[idx] = (nl[idx] + delta).clamp(35.0, 92.0);
      } else {
        nc[idx] = (nc[idx] + delta).clamp(5.0, 75.0);
      }
      final double s = score(nl, nc);
      if (s < cur) {
        cur = s;
        ls = nl;
        cs = nc;
      }
      if (iter % 500 == 499) step = math.max(0.6, step * 0.75);
    }

    if (cur < bestScore) {
      bestScore = cur;
      bestL = ls;
      bestC = cs;
    }
    if (bestScore < 1.0) break; // 已无违规且漂移极小
  }

  return build(bestL, bestC)!;
}

void main() {
  for (final Palette p in allPalettes) {
    final List<int> solved = solve(p);
    final List<String> names = <String>[
      'statusFree',
      'statusBusy',
      'statusEars',
      'statusAway',
    ];
    final List<int> before = <int>[
      p.statusFree,
      p.statusBusy,
      p.statusEars,
      p.statusAway,
    ];

    stdout.writeln('── ${p.name} (${p.id}) ──');
    for (int i = 0; i < 4; i++) {
      final List<double> a = argbToLch(before[i]);
      final List<double> b = argbToLch(solved[i]);
      stdout.writeln('  ${names[i].padRight(12)} ${hex(before[i])}'
          ' -> ${hex(solved[i])}'
          '   L ${a[0].toStringAsFixed(0)}→${b[0].toStringAsFixed(0)}'
          '  C ${a[1].toStringAsFixed(0)}→${b[1].toStringAsFixed(0)}'
          '  H ${b[2].toStringAsFixed(0)}');
    }
    stdout.writeln('  违规量 penalty = ${penalty(solved, p.bg).toStringAsFixed(3)}'
        ' (0 = 全部达标)');
    stdout.writeln('  Dart 常量:');
    for (int i = 0; i < 4; i++) {
      stdout.writeln('    ${names[i]}: 0x${solved[i].toRadixString(16).toUpperCase()},');
    }
    stdout.writeln();
  }
}
