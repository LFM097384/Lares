/// 新建圈子要用到的两样随机物:圈子 id 与默认口令。
library;

import 'dart:math';

import 'wordlist_bip39.dart';

/// 口令最短长度。服务器只存 Argon2 verifier,离线猜口令的代价全靠
/// 「口令空间 × 每次 Argon2」撑着;8 位以下的手选口令在 GPU 面前撑不了多久。
const int kMinCirclePasscodeLength = 8;

const String _base32 = 'abcdefghijklmnopqrstuvwxyz234567';

/// `c_` + 128 位随机数(小写 base32,26 位)。
///
/// 为什么不再用时间戳:旧写法 `c_<毫秒 36 进制>` 可猜、会撞 ——
/// 有了注册表之后,「先到先得」意味着谁猜中别人将要用的 id 谁就能抢注。
/// 128 位随机让抢注只剩理论可能。格式必须满足服务端 `^c_[a-z0-9]{16,64}$`。
String generateCircleId([Random? random]) {
  final r = random ?? Random.secure();
  var bits = 0;
  var value = 0;
  final out = StringBuffer('c_');
  for (var i = 0; i < 16; i++) {
    value = ((value << 8) | r.nextInt(256)) & 0xFFFF;
    bits += 8;
    while (bits >= 5) {
      out.write(_base32[(value >> (bits - 5)) & 31]);
      bits -= 5;
    }
  }
  if (bits > 0) out.write(_base32[(value << (5 - bits)) & 31]);
  return out.toString();
}

/// 圈主钥匙:32 字节随机数(64 位小写 hex),**由本机生成**。
///
/// 为什么不让服务器生成:服务器生成就得靠 welcome 把明文送回来,
/// welcome 一丢、或者本机落盘失败,圈子就永远没有圈主。本机先生成、
/// 先存进安全存储并读回确认,再只把 sha256 报给服务器 —— 任何一步
/// 失败都还能用手里的钥匙重来。
String generateOwnerKey([Random? random]) {
  final r = random ?? Random.secure();
  final out = StringBuffer();
  for (var i = 0; i < 32; i++) {
    out.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

/// 默认口令:4 个 BIP39 英文词,`-` 相连(≈44 位熵)。
///
/// 为什么是词而不是乱码:口令是要念给家人听、抄在纸上的;
/// 4 个词好记好念,而 44 位 × Argon2 已经让离线穷举不现实。
String generateCirclePasscode([Random? random, int words = 4]) {
  final r = random ?? Random.secure();
  return List<String>.generate(
    words,
    (_) => kBip39English[r.nextInt(kBip39English.length)],
  ).join('-');
}

/// 口令是否够长(按字符数,不 trim 以外做任何改写 —— 用户输了什么就是什么)。
bool isAcceptableCirclePasscode(String passcode) =>
    passcode.trim().length >= kMinCirclePasscodeLength;
