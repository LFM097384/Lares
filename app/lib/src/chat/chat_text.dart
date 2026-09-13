/// 文字消息的规整与截断(设计.md §2.2)。
///
/// 为什么全程按「字素簇」(grapheme cluster)而非 `String.length`:
/// `String.length` 数的是 UTF-16 code unit。CJK 字符恰好各占 1 个,看着没事;
/// 但 emoji 是代理对(2 个 code unit),ZWJ 序列 👨‍👩‍👧‍👦 由 7 个码点拼成,
/// 区域指示符旗帜 🇨🇳 由 2 个码点拼成 —— 按 code unit 截会从中间劈开,
/// 留下半个代理对或孤立的区域指示符,渲染成乱码方块。
///
/// [Characters] 与 `.characters` 扩展经 `package:flutter/widgets.dart`
/// 再导出获得。不直接 import `package:characters`:它只是传递依赖,
/// 未写进 pubspec,会被 `depend_on_referenced_packages` 判违规。
library;

import 'package:flutter/widgets.dart';

/// 去除首尾空白;全空白/空串返回 null(空消息不允许发送)。
///
/// 用 `String.trim()` —— 它按 Unicode 空白定义裁剪,
/// 全角空格、不换行空格之类也一并干掉,正是我们要的。
String? normalizeOutgoing(String raw) {
  final String trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 按「字素簇」截断到 [max] 个,绝不切断 emoji(含 ZWJ 序列 👨‍👩‍👧‍👦
/// 与区域指示符旗帜 🇨🇳)或代理对。
///
/// [max] <= 0 时返回空串。未超限时原样返回 [s],省掉一次无谓的重新遍历。
String capGraphemes(String s, int max) {
  if (max <= 0) return '';
  final Characters chars = s.characters;
  if (chars.length <= max) return s;
  return chars.take(max).toString();
}

/// 字素簇计数(不是 `String.length`)。
/// 用户眼里的「一个字」= 一个字素簇,计数口径必须与截断口径一致。
int graphemeCount(String s) => s.characters.length;
