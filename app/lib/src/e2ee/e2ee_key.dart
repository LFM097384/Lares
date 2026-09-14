/// 圈子 E2EE 密钥派生(纯 Dart,只依赖 `crypto`)。
///
/// 刻意做成顶层纯函数、单独一个文件:不碰插件通道、不碰 LiveKit、不碰异步,
/// 于是「密钥是怎么来的」这件最要命的事可以在 `flutter test` 里被完整驱动,
/// 不需要真机、不需要 WebRTC、不需要第二个人。
library;

import '../auth/auth_credential.dart';

/// 派生用的域分隔前缀。
///
/// **为什么必须有它**:圈口令同时还是服务端 HMAC 挑战应答的密钥
/// (`AuthProof.circle` 对 `${nonce}:${userId}:${circleId}` 做 HMAC)。
/// 如果直接拿口令当加密密钥,认证凭据与加密密钥就被绑死成同一个值 ——
/// 任何一侧泄露都会同时毁掉另一侧。
///
/// 这里用同一把 HMAC,但把**消息空间**彻底隔开:
/// 认证侧的消息永远以 32 位小写 hex 的 nonce 开头
/// (`AuthProof.isValidNonce` 强制),而本前缀是字面量 `lares-e2ee-v1:`,
/// 不可能撞进那个形状。于是两边的输出在密码学上互不可推。
///
/// 版本号写进前缀:将来换派生方案时改成 `v2`,老圈子的密钥自动失效而不是
/// 半新半旧地互相解不开。
const String kE2EEKeyDomain = 'lares-e2ee-v1:';

/// 由「圈口令 + 圈子 id」派生出该圈的 E2EE 共享密钥。
///
/// 返回 64 个字符的小写 hex(HMAC-SHA256 的完整输出)。
///
/// **为什么返回 hex 而不是原始字节**:LiveKit 的
/// `BaseKeyProvider.setSharedKey(String key)` 内部做的是
/// `Uint8List.fromList(key.codeUnits)` —— 逐 UTF-16 码元截断成字节。
/// 只要字符串里出现任何非 ASCII 字符(中文口令很常见),
/// 各端截断出来的字节就可能不一致,表现为「明明口令一样却听不见对方」。
/// hex 全部落在 ASCII 范围内,`codeUnits` 与 UTF-8 逐字节等价,五端一致。
///
/// [circleId] 进入派生消息,保证**同一个口令在不同圈子里派生出不同密钥** ——
/// 用户把同一个口令复用到两个圈子时,两个圈子之间仍然互不解密。
String deriveCircleE2EEKey({
  required String passcode,
  required String circleId,
}) =>
    AuthProof.hmacHex(passcode, '$kE2EEKeyDomain$circleId');

/// 口令是否足以派生密钥。空口令派生出的是一个**人人可算**的常量,
/// 那比不加密更危险(用户以为加密了)。所以宁可不开。
bool canDeriveCircleKey(String passcode) => passcode.isNotEmpty;
