// 配色体检:实测 WCAG 对比度 + 色盲可分性,而不是目测。
//
// 跑法(在 app/ 目录下):
//   dart run tool/palette/contrast_check.dart
//   dart run tool/palette/contrast_check.dart --md   # 输出 Markdown 表格
//
// 纯 Dart,不依赖 flutter,也不 import lib/ 下任何东西。
//
// 三项硬指标:
//   1. 正文 textPrimary vs bg >= 4.5:1(WCAG AA 正文)
//   2. 次要 textSecondary vs bg >= 3.0:1
//   3. 4 个状态色两两可分,且在 deuteranopia / protanopia / tritanopia 下仍可分
//
// 状态色「可分」的判据:不是拍脑袋的色相差,而是 CIEDE2000 色差 >= 阈值。
// 这一点很关键 —— 只靠色相角判断会漏掉「亮度相近的蓝与紫在色盲眼里合并」的情况。

import 'dart:io';
import 'dart:math' as math;

import 'palettes.dart';

// ── sRGB / 线性 RGB ──

double _srgbToLinear(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _linearToSrgb(double c) => c <= 0.0031308
    ? c * 12.92
    : 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055;

int _r(int argb) => (argb >> 16) & 0xFF;
int _g(int argb) => (argb >> 8) & 0xFF;
int _b(int argb) => argb & 0xFF;

/// WCAG 2.x 相对亮度。
double relativeLuminance(int argb) {
  final double rl = _srgbToLinear(_r(argb) / 255);
  final double gl = _srgbToLinear(_g(argb) / 255);
  final double bl = _srgbToLinear(_b(argb) / 255);
  return 0.2126 * rl + 0.7152 * gl + 0.0722 * bl;
}

/// WCAG 2.x 对比度,返回值域 [1, 21]。
double contrastRatio(int fg, int bg) {
  final double l1 = relativeLuminance(fg);
  final double l2 = relativeLuminance(bg);
  final double hi = math.max(l1, l2);
  final double lo = math.min(l1, l2);
  return (hi + 0.05) / (lo + 0.05);
}

// ── CIELAB / CIEDE2000 ──
// 状态色之间「看得出不一样吗」不能用 RGB 欧氏距离糊弄,
// 那个度量在暗色低饱和区完全失真。用 CIEDE2000。

List<double> _argbToXyz(int argb) {
  final double rl = _srgbToLinear(_r(argb) / 255);
  final double gl = _srgbToLinear(_g(argb) / 255);
  final double bl = _srgbToLinear(_b(argb) / 255);
  // sRGB D65
  return <double>[
    rl * 0.4124564 + gl * 0.3575761 + bl * 0.1804375,
    rl * 0.2126729 + gl * 0.7151522 + bl * 0.0721750,
    rl * 0.0193339 + gl * 0.1191920 + bl * 0.9503041,
  ];
}

List<double> argbToLab(int argb) {
  final List<double> xyz = _argbToXyz(argb);
  // D65 白点
  const double xn = 0.95047, yn = 1.0, zn = 1.08883;
  double f(double t) => t > 0.008856451679
      ? math.pow(t, 1 / 3).toDouble()
      : (903.2962962 * t + 16) / 116;
  final double fx = f(xyz[0] / xn);
  final double fy = f(xyz[1] / yn);
  final double fz = f(xyz[2] / zn);
  return <double>[116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}

double _deg(double rad) => rad * 180 / math.pi;
double _rad(double deg) => deg * math.pi / 180;

/// CIEDE2000 色差。经 Sharma 标准测试向量校验(见 main 里的自检)。
double deltaE2000(int argb1, int argb2) {
  final List<double> lab1 = argbToLab(argb1);
  final List<double> lab2 = argbToLab(argb2);
  return deltaE2000Lab(lab1, lab2);
}

double deltaE2000Lab(List<double> lab1, List<double> lab2) {
  final double l1 = lab1[0], a1 = lab1[1], b1 = lab1[2];
  final double l2 = lab2[0], a2 = lab2[1], b2 = lab2[2];

  final double c1 = math.sqrt(a1 * a1 + b1 * b1);
  final double c2 = math.sqrt(a2 * a2 + b2 * b2);
  final double cBar = (c1 + c2) / 2;

  final double cBar7 = math.pow(cBar, 7).toDouble();
  final double g = 0.5 * (1 - math.sqrt(cBar7 / (cBar7 + math.pow(25, 7))));

  final double a1p = (1 + g) * a1;
  final double a2p = (1 + g) * a2;
  final double c1p = math.sqrt(a1p * a1p + b1 * b1);
  final double c2p = math.sqrt(a2p * a2p + b2 * b2);

  double hp(double bb, double ap) {
    if (bb == 0 && ap == 0) return 0;
    final double h = _deg(math.atan2(bb, ap));
    return h >= 0 ? h : h + 360;
  }

  final double h1p = hp(b1, a1p);
  final double h2p = hp(b2, a2p);

  final double dLp = l2 - l1;
  final double dCp = c2p - c1p;

  double dhp;
  if (c1p * c2p == 0) {
    dhp = 0;
  } else if ((h2p - h1p).abs() <= 180) {
    dhp = h2p - h1p;
  } else if (h2p - h1p > 180) {
    dhp = h2p - h1p - 360;
  } else {
    dhp = h2p - h1p + 360;
  }
  final double dHp = 2 * math.sqrt(c1p * c2p) * math.sin(_rad(dhp) / 2);

  final double lBarP = (l1 + l2) / 2;
  final double cBarP = (c1p + c2p) / 2;

  double hBarP;
  if (c1p * c2p == 0) {
    hBarP = h1p + h2p;
  } else if ((h1p - h2p).abs() <= 180) {
    hBarP = (h1p + h2p) / 2;
  } else if (h1p + h2p < 360) {
    hBarP = (h1p + h2p + 360) / 2;
  } else {
    hBarP = (h1p + h2p - 360) / 2;
  }

  final double t = 1 -
      0.17 * math.cos(_rad(hBarP - 30)) +
      0.24 * math.cos(_rad(2 * hBarP)) +
      0.32 * math.cos(_rad(3 * hBarP + 6)) -
      0.20 * math.cos(_rad(4 * hBarP - 63));

  final double dTheta = 30 * math.exp(-math.pow((hBarP - 275) / 25, 2).toDouble());
  final double cBarP7 = math.pow(cBarP, 7).toDouble();
  final double rc = 2 * math.sqrt(cBarP7 / (cBarP7 + math.pow(25, 7)));
  final double sl = 1 +
      (0.015 * math.pow(lBarP - 50, 2)) /
          math.sqrt(20 + math.pow(lBarP - 50, 2));
  final double sc = 1 + 0.045 * cBarP;
  final double sh = 1 + 0.015 * cBarP * t;
  final double rt = -math.sin(_rad(2 * dTheta)) * rc;

  final double dl = dLp / sl;
  final double dc = dCp / sc;
  final double dh = dHp / sh;

  return math.sqrt(dl * dl + dc * dc + dh * dh + rt * dc * dh);
}

// ── 色觉障碍模拟 ──
// 用 Brettel/Viénot 线性 LMS 投影法(machado 近似的经典版本)。
// 目的不是「精确还原色盲所见」,而是给出一个可复现的、比目测可靠的判据。

enum Cvd { normal, deuteranopia, protanopia, tritanopia }

/// sRGB(线性) -> LMS,Hunt-Pointer-Estevez 归一化到 D65。
const List<List<double>> _rgbToLms = <List<double>>[
  <double>[0.31399022, 0.63951294, 0.04649755],
  <double>[0.15537241, 0.75789446, 0.08670142],
  <double>[0.01775239, 0.10944209, 0.87256922],
];

const List<List<double>> _lmsToRgb = <List<double>>[
  <double>[5.47221206, -4.6419601, 0.16963708],
  <double>[-1.1252419, 2.29317094, -0.1678952],
  <double>[0.02980165, -0.19318073, 1.16364789],
];

/// 各类型的 LMS 投影矩阵(Viénot et al. 1999 / Brettel 1997 的常用系数)。
const Map<Cvd, List<List<double>>> _cvdSim = <Cvd, List<List<double>>>{
  Cvd.protanopia: <List<double>>[
    <double>[0, 1.05118294, -0.05116099],
    <double>[0, 1, 0],
    <double>[0, 0, 1],
  ],
  Cvd.deuteranopia: <List<double>>[
    <double>[1, 0, 0],
    <double>[0.9513092, 0, 0.04866992],
    <double>[0, 0, 1],
  ],
  Cvd.tritanopia: <List<double>>[
    <double>[1, 0, 0],
    <double>[0, 1, 0],
    <double>[-0.86744736, 1.86727089, 0],
  ],
};

List<double> _mul(List<List<double>> m, List<double> v) => <double>[
      m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
      m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
      m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2],
    ];

/// 把一个颜色模拟成某类色觉障碍下的观感色。
int simulateCvd(int argb, Cvd type) {
  if (type == Cvd.normal) return argb;
  final List<double> lin = <double>[
    _srgbToLinear(_r(argb) / 255),
    _srgbToLinear(_g(argb) / 255),
    _srgbToLinear(_b(argb) / 255),
  ];
  final List<double> lms = _mul(_rgbToLms, lin);
  final List<double> sim = _mul(_cvdSim[type]!, lms);
  final List<double> back = _mul(_lmsToRgb, sim);
  int ch(double v) {
    final double s = _linearToSrgb(v.clamp(0.0, 1.0));
    return (s.clamp(0.0, 1.0) * 255).round();
  }

  return 0xFF000000 | (ch(back[0]) << 16) | (ch(back[1]) << 8) | ch(back[2]);
}

String hex(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).toUpperCase().padLeft(6, '0')}';

String _f(double v) => v.toStringAsFixed(2);

// ── 判据阈值 ──

/// 正文对比度下限(WCAG AA 正文)。
const double kBodyMin = 4.5;

/// 次要文字对比度下限。
const double kSecondaryMin = 3.0;

/// 状态色两两色差下限(正常色觉)。CIEDE2000 中 >10 是「一眼看出不同色」。
const double kStatusDeltaMin = 11.0;

/// 色觉障碍模拟下的色差下限。允许比正常色觉低,但必须仍然可分。
const double kStatusDeltaCvdMin = 8.0;

/// 状态环必须在背景上看得见(环是 2.5px 描边,按非文字图形 3:1 要求)。
const double kStatusVsBgMin = 3.0;

class Issue {
  Issue(this.palette, this.text);
  final String palette;
  final String text;
  @override
  String toString() => '[$palette] $text';
}

void main(List<String> args) {
  final bool md = args.contains('--md');
  final List<Issue> issues = <Issue>[];

  _selfTest();

  final StringBuffer out = StringBuffer();

  for (final Palette p in allPalettes) {
    final double body = contrastRatio(p.textPrimary, p.bg);
    final double secondary = contrastRatio(p.textSecondary, p.bg);
    final double bodyOnSurface = contrastRatio(p.textPrimary, p.surface);
    final double secondaryOnSurface = contrastRatio(p.textSecondary, p.surface);
    final double bodyOnHigh = contrastRatio(p.textPrimary, p.surfaceHigh);
    final double brandOnBg = contrastRatio(p.brand, p.bg);
    final double onBrandVsBrand = contrastRatio(p.onBrand, p.brand);

    if (md) {
      out.writeln('### ${p.name} — ${p.source}');
      out.writeln();
      out.writeln('| token | hex |');
      out.writeln('|---|---|');
      p.allTokens.forEach((String k, int v) {
        out.writeln('| $k | `${hex(v)}` |');
      });
      out.writeln();
      out.writeln('| 实测对比度 | 值 | 门槛 | 结论 |');
      out.writeln('|---|---|---|---|');
      out.writeln('| 正文 textPrimary vs bg | **${_f(body)}:1** | ≥4.5 |'
          ' ${body >= kBodyMin ? '通过' : '不通过'} |');
      out.writeln('| 次要 textSecondary vs bg | **${_f(secondary)}:1** | ≥3.0 |'
          ' ${secondary >= kSecondaryMin ? '通过' : '不通过'} |');
      out.writeln('| 正文 vs surface | ${_f(bodyOnSurface)}:1 | ≥4.5 |'
          ' ${bodyOnSurface >= kBodyMin ? '通过' : '不通过'} |');
      out.writeln('| 次要 vs surface | ${_f(secondaryOnSurface)}:1 | ≥3.0 |'
          ' ${secondaryOnSurface >= kSecondaryMin ? '通过' : '不通过'} |');
      out.writeln('| 正文 vs surfaceHigh | ${_f(bodyOnHigh)}:1 | ≥4.5 |'
          ' ${bodyOnHigh >= kBodyMin ? '通过' : '不通过'} |');
      out.writeln('| 品牌色 vs bg | ${_f(brandOnBg)}:1 | ≥3.0 |'
          ' ${brandOnBg >= 3.0 ? '通过' : '不通过'} |');
      out.writeln('| 主按钮文字 onBrand vs brand | ${_f(onBrandVsBrand)}:1 |'
          ' ≥4.5 | ${onBrandVsBrand >= kBodyMin ? '通过' : '不通过'} |');
      out.writeln();
      out.writeln('| 状态色 vs bg(环可见性,≥3.0) | 值 |');
      out.writeln('|---|---|');
      p.statusTokens.forEach((String k, int v) {
        out.writeln('| $k `${hex(v)}` | ${_f(contrastRatio(v, p.bg))}:1 |');
      });
      out.writeln();
    } else {
      out.writeln('══════════════════════════════════════════');
      out.writeln('${p.name}  (${p.id})  — ${p.source}');
      out.writeln('══════════════════════════════════════════');
      p.allTokens.forEach((String k, int v) {
        out.writeln('  ${k.padRight(16)} ${hex(v)}');
      });
      out.writeln('  ── 对比度 ──');
      out.writeln('  正文 vs bg          ${_f(body)}:1   (≥4.5)');
      out.writeln('  次要 vs bg          ${_f(secondary)}:1   (≥3.0)');
      out.writeln('  正文 vs surface     ${_f(bodyOnSurface)}:1');
      out.writeln('  次要 vs surface     ${_f(secondaryOnSurface)}:1');
      out.writeln('  正文 vs surfaceHigh ${_f(bodyOnHigh)}:1');
      out.writeln('  品牌 vs bg          ${_f(brandOnBg)}:1');
      out.writeln('  按钮字 vs 品牌      ${_f(onBrandVsBrand)}:1');
    }

    // ── 硬约束检查 ──
    if (body < kBodyMin) {
      issues.add(Issue(p.name, '正文对比度 ${_f(body)} < $kBodyMin'));
    }
    if (secondary < kSecondaryMin) {
      issues.add(Issue(p.name, '次要文字对比度 ${_f(secondary)} < $kSecondaryMin'));
    }
    if (bodyOnSurface < kBodyMin) {
      issues.add(
          Issue(p.name, '正文 vs surface ${_f(bodyOnSurface)} < $kBodyMin'));
    }
    if (secondaryOnSurface < kSecondaryMin) {
      issues.add(Issue(
          p.name, '次要 vs surface ${_f(secondaryOnSurface)} < $kSecondaryMin'));
    }
    if (bodyOnHigh < kBodyMin) {
      issues.add(Issue(p.name, '正文 vs surfaceHigh ${_f(bodyOnHigh)} < $kBodyMin'));
    }
    if (onBrandVsBrand < kBodyMin) {
      issues.add(Issue(
          p.name, '主按钮文字 vs 品牌色 ${_f(onBrandVsBrand)} < $kBodyMin'));
    }
    if (brandOnBg < 3.0) {
      issues.add(Issue(p.name, '品牌色 vs bg ${_f(brandOnBg)} < 3.0(不够醒目)'));
    }

    // 状态环 vs 背景
    p.statusTokens.forEach((String k, int v) {
      final double c = contrastRatio(v, p.bg);
      if (c < kStatusVsBgMin) {
        issues.add(Issue(p.name, '状态色 $k vs bg ${_f(c)} < $kStatusVsBgMin'));
      }
    });

    // 状态色两两可分(含色盲模拟)
    final List<MapEntry<String, int>> st = p.statusTokens.entries.toList();
    if (md) {
      out.writeln('| 状态色两两色差 ΔE2000 | 正常 | 红色盲 | 绿色盲 | 蓝色盲 |');
      out.writeln('|---|---|---|---|---|');
    } else {
      out.writeln('  ── 状态色两两 ΔE2000(正常/红盲/绿盲/蓝盲)──');
    }
    for (int i = 0; i < st.length; i++) {
      for (int j = i + 1; j < st.length; j++) {
        final int c1 = st[i].value;
        final int c2 = st[j].value;
        final double dn = deltaE2000(c1, c2);
        final double dp = deltaE2000(
            simulateCvd(c1, Cvd.protanopia), simulateCvd(c2, Cvd.protanopia));
        final double dd = deltaE2000(simulateCvd(c1, Cvd.deuteranopia),
            simulateCvd(c2, Cvd.deuteranopia));
        final double dt = deltaE2000(
            simulateCvd(c1, Cvd.tritanopia), simulateCvd(c2, Cvd.tritanopia));
        final String pair = '${st[i].key} ↔ ${st[j].key}';
        if (md) {
          out.writeln('| $pair | ${_f(dn)} | ${_f(dp)} | ${_f(dd)} |'
              ' ${_f(dt)} |');
        } else {
          out.writeln('    ${pair.padRight(28)} ${_f(dn).padLeft(6)}'
              ' ${_f(dp).padLeft(6)} ${_f(dd).padLeft(6)} ${_f(dt).padLeft(6)}');
        }
        if (dn < kStatusDeltaMin) {
          issues.add(Issue(p.name, '$pair 正常色觉 ΔE=${_f(dn)} < $kStatusDeltaMin'));
        }
        for (final MapEntry<String, double> e in <String, double>{
          '红色盲': dp,
          '绿色盲': dd,
          '蓝色盲': dt,
        }.entries) {
          if (e.value < kStatusDeltaCvdMin) {
            issues.add(Issue(
                p.name, '$pair ${e.key} ΔE=${_f(e.value)} < $kStatusDeltaCvdMin'));
          }
        }
      }
    }
    out.writeln();
  }

  stdout.write(out.toString());

  stdout.writeln('══════════════════════════════════════════');
  if (issues.isEmpty) {
    stdout.writeln('全部方案通过所有硬约束。');
  } else {
    stdout.writeln('未通过项(${issues.length}):');
    for (final Issue i in issues) {
      stdout.writeln('  ✗ $i');
    }
    exitCode = 1;
  }
}

/// CIEDE2000 自检:Sharma et al. 标准测试向量的若干条。
/// 实现错了的话下面的期望值会立刻炸出来,而不是悄悄给出好看的假数字。
void _selfTest() {
  final List<List<double>> cases = <List<double>>[
    // L1,a1,b1, L2,a2,b2, expected
    <double>[50, 2.6772, -79.7751, 50, 0, -82.7485, 2.0425],
    <double>[50, 3.1571, -77.2803, 50, 0, -82.7485, 2.8615],
    <double>[50, 2.8361, -74.0200, 50, 0, -82.7485, 3.4412],
    <double>[50, -1.3802, -84.2814, 50, 0, -82.7485, 1.0000],
    <double>[50, 2.5, 0, 50, 0, -2.5, 4.3065],
    <double>[50, 2.5, 0, 73, 25, -18, 27.1492],
    <double>[50, 2.5, 0, 50, 3.1736, 0.5854, 1.0000],
    <double>[60.2574, -34.0099, 36.2677, 60.4626, -34.1751, 39.4387, 1.2644],
    <double>[22.7233, 20.0904, -46.6940, 23.0331, 14.9730, -42.5619, 2.0373],
    <double>[2.0776, 0.0795, -1.1350, 0.9033, -0.0636, -0.5514, 0.9082],
  ];
  for (final List<double> c in cases) {
    final double got = deltaE2000Lab(
      <double>[c[0], c[1], c[2]],
      <double>[c[3], c[4], c[5]],
    );
    if ((got - c[6]).abs() > 0.0101) {
      throw StateError('CIEDE2000 自检失败: 期望 ${c[6]}, 实得 '
          '${got.toStringAsFixed(4)}');
    }
  }

  // WCAG 自检:纯白 vs 纯黑必须正好 21:1
  final double wb = contrastRatio(0xFFFFFFFF, 0xFF000000);
  if ((wb - 21).abs() > 0.001) {
    throw StateError('WCAG 自检失败: 白黑对比度 = $wb,应为 21');
  }
}
