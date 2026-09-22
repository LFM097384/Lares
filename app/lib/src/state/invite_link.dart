/// 邀请链接的解析与生成。
///
/// ## 格式
///
/// ```text
/// lares://circle/<圈子id>?name=<显示名>&server=<信令地址>&pass=<口令>
/// ```
///
/// `name` / `server` / `pass` 都是可选的:
///
/// - **name** —— 显示名。没有时调用方给一个回落名。
/// - **server** —— 信令地址。**几乎总该带上**:朋友的圈子多半在朋友的
///   服务器上,不带的话对方要先手动换服务器才能进,而那一步
///   他根本不知道要做。地址不是秘密(域名本来就公开),带上没有代价。
/// - **pass** —— 圈口令。**默认不带**,由分享者显式勾选。
///
/// ## 为什么口令要用户自己决定
///
/// 口令经 Argon2id 派生出该圈的 E2EE 密钥(见 `e2ee_key.dart`)。
/// 把它写进链接 = 把密钥写进链接,而链接会经微信、短信、剪贴板流转,
/// 还可能被截图。那条链路上任何一环泄漏,这个圈子的历史与未来通话
/// 就都能被解密 —— 而 E2EE 的全部意义正是「连服务器都听不到」。
///
/// 所以:
/// - 圈子**没开 E2EE** 时,口令只是门票,带上是纯粹的便利;
/// - 圈子**开了 E2EE** 时,带上等于自废武功。
///
/// 这个判断只有分享者做得了(他知道要发给谁、发在哪),所以做成
/// 一个明确的勾选,并在开了 E2EE 时把代价写在旁边。
library;

/// 从邀请链接里解析出来的东西。
class InviteLink {
  const InviteLink({
    required this.circleId,
    this.name,
    this.serverUrl,
    this.passcode,
  });

  final String circleId;

  /// 圈子显示名;链接没带时为 null(调用方给回落)
  final String? name;

  /// 信令地址;链接没带时为 null(沿用当前服务器)
  final String? serverUrl;

  /// 圈口令;链接没带时为 null(需要用户另外输入)
  final String? passcode;

  bool get hasServer => (serverUrl ?? '').isNotEmpty;
  bool get hasPasscode => (passcode ?? '').isNotEmpty;
}

const _scheme = 'lares://circle/';

/// 解析邀请链接,或一个裸的圈子 id。
///
/// 解析不出圈子 id 时返回 null —— 空串、只有 scheme、乱七八糟的输入
/// 都走这条路,调用方据此提示「这不是一个邀请链接」。
InviteLink? parseInviteLink(String input) {
  final s = input.trim();
  if (s.isEmpty) return null;

  if (!s.startsWith(_scheme)) {
    // 裸圈子 id。不做字符校验 —— 圈子 id 的合法性由服务端说了算,
    // 客户端多一道规则只会在将来放宽命名时变成障碍。
    // 但不能含空白,那多半是用户粘错了整段话。
    if (RegExp(r'\s').hasMatch(s)) return null;
    return InviteLink(circleId: s);
  }

  final uri = Uri.tryParse(s);
  if (uri == null) return null;
  final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
  if (id.isEmpty) return null;

  final q = uri.queryParameters;
  return InviteLink(
    circleId: id,
    name: _nullIfEmpty(q['name']),
    serverUrl: _nullIfEmpty(q['server']),
    passcode: _nullIfEmpty(q['pass']),
  );
}

/// 生成邀请链接。
///
/// [serverUrl] 传了就带上 —— 对方多半不在你的服务器上。
/// [passcode] **只在分享者明确要求时**才传,理由见文件头。
String buildInviteLink({
  required String circleId,
  required String name,
  String? serverUrl,
  String? passcode,
}) {
  final q = <String, String>{
    'name': name,
    if ((serverUrl ?? '').isNotEmpty) 'server': serverUrl!,
    if ((passcode ?? '').isNotEmpty) 'pass': passcode!,
  };
  final query = q.entries
      .map((e) =>
          '${e.key}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  return '$_scheme${Uri.encodeComponent(circleId)}?$query';
}

String? _nullIfEmpty(String? v) => (v == null || v.isEmpty) ? null : v;
