import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../text/grapheme_text.dart';

/// 昵称长度上限,按**字素簇**计(不是 `String.length`)。
///
/// ## 为什么放在 identity.dart
///
/// 昵称的所有权在这里 —— [Identity.name] 是它的持久化形态,[Identity.saveName]
/// 是唯一的落盘出口。上限跟着「谁拥有这个字段」走,而不是跟着「谁碰巧先用到」走。
///
/// 三个调用方取的都是这一个值:`RoomController.rename()`(唯一绕不过去的关口)、
/// 设置页的改名对话框、主屏的改名按钮。此前主屏那个自己写死 `maxLength: 12`,
/// 而别处不设限 —— 同一个字段两套口径,正是本轮要消掉的真实缺陷。
///
/// ## 为什么按字素簇
///
/// 一个汉字、一个 emoji(哪怕是 👨‍👩‍👧‍👦 这种 7 码点的 ZWJ 序列)在用户眼里
/// 都是「一个字」。按 UTF-16 code unit 数会把 emoji 算成 2 个,还可能从中间劈开。
const int maxNicknameGraphemes = 24;

/// 把用户输入规整成**可以安全保存的昵称**:去首尾空白 + 按字素簇截断。
///
/// ⚠️ UI 与 `RoomController.rename()` 必须都走这一个函数。
/// 否则会出现「落盘的是 30 个字、内存里是 24 个字」这种两头不一致 ——
/// 下次启动重新加载,名字会毫无征兆地自己变短一截,而当时没人改过它。
String capNickname(String raw) =>
    capGraphemes(raw.trim(), maxNicknameGraphemes);

/// 本地身份:MVP 无账号体系,userId/deviceId 本地生成并持久化。
///
/// ## 跨设备是同一个「人」
///
/// `userId` 标识**人**,`deviceId` 标识**这台设备**。服务端按这个模型
/// 组织成员(`server/src/index.js:230`:
/// `Member = { userId, name, status, devices: Map<deviceId, ws> }`,
/// 注释写着「一个用户可多端在线」),所以电脑和手机用同一个 userId
/// 时会被正确合并成一个人,而不是互相挤掉。
///
/// 要做到这一点,用户需要把 userId 从一台设备搬到另一台 ——
/// 见 [exportCode] / [importCode]。
///
/// 后续接入真实账号体系时只需替换本类的 [load]。
class Identity {
  Identity({required this.userId, required this.deviceId, required this.name});

  final String userId;

  /// 本设备的标识。**跨设备绑定时不共享** —— 每台设备必须有自己的,
  /// 否则服务端的 `devices` Map 会把两台设备当成同一条连接,
  /// 后进的会把先进的顶掉(表现是「手机一连,电脑就掉线」)。
  final String deviceId;

  final String name;

  static const _kUserId = 'lares.userId';
  static const _kDeviceId = 'lares.deviceId';
  static const _kName = 'lares.name';

  /// 身份码的前缀。带上它是为了让用户一眼看出这串东西是什么,
  /// 也方便将来扩展格式(v2 前缀不同,老客户端会明确拒绝而不是误解析)。
  static const _codePrefix = 'lares-id-v1:';

  static Future<Identity> load() async {
    final prefs = await SharedPreferences.getInstance();
    var userId = prefs.getString(_kUserId);
    var deviceId = prefs.getString(_kDeviceId);
    if (userId == null) {
      userId = 'u_${_randId()}';
      await prefs.setString(_kUserId, userId);
    }
    if (deviceId == null) {
      deviceId = 'd_${_randId()}';
      await prefs.setString(_kDeviceId, deviceId);
    }
    return Identity(
      userId: userId,
      deviceId: deviceId,
      name: prefs.getString(_kName) ?? '我',
    );
  }

  static Future<void> saveName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kName, name);
  }

  /// 导出身份码,拿到另一台设备上导入,两边就是同一个人。
  ///
  /// 码里**只有 userId 和昵称**,不含 deviceId(每台设备必须有自己的,
  /// 理由见 [deviceId] 的说明),也不含任何圈子口令 ——
  /// 那些是另一回事,而且把它们塞进一个要在设备间传递的字符串里
  /// 等于多开一条泄漏路径。
  String exportCode() {
    final payload = jsonEncode(<String, String>{'u': userId, 'n': name});
    return '$_codePrefix${base64Url.encode(utf8.encode(payload))}';
  }

  /// 解析身份码。格式不对返回 null —— 调用方据此提示「这不是一个身份码」。
  ///
  /// 做成静态纯函数,方便穷举各种坏输入而不必碰 SharedPreferences。
  static ({String userId, String name})? parseCode(String code) {
    final s = code.trim();
    if (!s.startsWith(_codePrefix)) return null;
    try {
      // ⚠️ Dart 的 base64Url.decode **要求填充的 `=`**,而很多工具
      // (以及 RFC 4648 §5 允许的省略形式)产出的是不带填充的。
      // 用户可能从别处复制到这种码,或者中间被某个环节裁掉了尾部。
      // 补齐到 4 的倍数,否则会抛 FormatException 而我们只会
      // 笼统地说「这不是身份码」—— 那对用户毫无帮助。
      final body = base64Url.normalize(s.substring(_codePrefix.length));
      final raw = utf8.decode(base64Url.decode(body));
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final u = m['u'];
      final n = m['n'];
      if (u is! String || u.isEmpty) return null;
      return (userId: u, name: n is String && n.isNotEmpty ? n : '我');
    } catch (_) {
      // base64 坏了 / 不是 JSON / 编码不对 —— 都当作「这不是身份码」。
      // 不区分具体原因:用户能做的事都一样(重新复制一份)。
      return null;
    }
  }

  /// 导入身份码:换掉本机的 userId 与昵称,**保留本机的 deviceId**。
  ///
  /// 返回导入后的身份;码不合法时返回 null 且不改动任何东西。
  static Future<Identity?> importCode(String code) async {
    final parsed = parseCode(code);
    if (parsed == null) return null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUserId, parsed.userId);
    await prefs.setString(_kName, parsed.name);

    // deviceId 不动。没有就补一个 —— 导入发生在全新设备上是常见情形。
    var deviceId = prefs.getString(_kDeviceId);
    if (deviceId == null) {
      deviceId = 'd_${_randId()}';
      await prefs.setString(_kDeviceId, deviceId);
    }
    return Identity(
      userId: parsed.userId,
      deviceId: deviceId,
      name: parsed.name,
    );
  }

  /// 随机 id。
  ///
  /// ⚠️ 这里曾经是 `DateTime.now().microsecondsSinceEpoch.toRadixString(36)`。
  /// 那个实现有两个问题:同一微秒启动的两台设备会撞号,
  /// 而且**完全可预测** —— 知道大概安装时间就能枚举出来。
  /// 身份能被猜到意味着能被冒充,而跨设备绑定让 userId 变得更值钱了。
  static String _randId() {
    final r = Random.secure();
    // 9 字节 → base64url 12 字符,无填充。够长到不可枚举,又不至于
    // 让用户要传递的身份码变得笨重。
    final bytes = List<int>.generate(9, (_) => r.nextInt(256));
    return base64Url.encode(bytes);
  }
}
