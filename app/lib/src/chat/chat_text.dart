/// 文字消息的规整与截断(设计.md §2.2)。
///
/// 按字素簇计数/截断的两个函数([capGraphemes] / [graphemeCount])已经搬到
/// `lib/src/text/grapheme_text.dart` —— 它们跟「聊天」无关,只是「怎么数一个字」。
/// 搬家的动因是昵称长度上限必须在 `state/room_controller.dart` 里强制执行,
/// 而 `state/` 不该为了数几个字就去 import `chat/`(现有依赖方向是
/// chat/ → state/,反过来会让目录图成双向;详见 grapheme_text.dart 顶部)。
///
/// 这里原样 re-export:既有的 `import 'chat_text.dart'` 调用点与
/// `test/chat_text_test.dart` 一行都不用改,搬家对它们是隐形的。
library;

export '../text/grapheme_text.dart' show capGraphemes, graphemeCount;

/// 去除首尾空白;全空白/空串返回 null(空消息不允许发送)。
///
/// 用 `String.trim()` —— 它按 Unicode 空白定义裁剪,
/// 全角空格、不换行空格之类也一并干掉,正是我们要的。
String? normalizeOutgoing(String raw) {
  final String trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}
