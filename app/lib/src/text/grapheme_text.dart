/// 按「字素簇」(grapheme cluster)计数与截断的纯工具。
///
/// ## 为什么单独占一个 `text/` 目录,而不是留在 `chat/chat_text.dart`
///
/// 这两个函数一点都不「聊天」—— 它们只是「怎么数一个字」。昵称长度上限
/// 要在 `state/room_controller.dart` 里强制执行(那是唯一绕不过去的关口),
/// 于是 `state/` 就得拿到 `capGraphemes`。
///
/// 但现有的依赖方向是 **chat/ → state/**(`chat/session_chat_transport.dart`
/// 引了 `state/room_controller.dart`),而 `state/` 至今**一条**都没有引过
/// `chat/`。让 `room_controller.dart` 去 import `../chat/chat_text.dart`,
/// 在文件图上不成环(chat_text 是叶子),但在目录图上就成了双向依赖 ——
/// 以后有人扫一眼 import 列表,会合理地问「房间状态凭什么依赖聊天?」,
/// 然后照着这条先例把真正的聊天类型也引进来。结构一旦撒了谎就会被当真。
///
/// 所以把它搬到一个谁都可以依赖的中立叶子上。`chat_text.dart` 原样
/// re-export,既有 import 与 `test/chat_text_test.dart` 一行都不用改。
///
/// ## 为什么全程按字素簇而非 `String.length`
///
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
