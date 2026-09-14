/// 圈子 E2EE 密钥派生(纯 Dart,只依赖 `crypto`)。
///
/// 刻意做成顶层纯函数、单独一个文件:不碰插件通道、不碰 LiveKit、不碰异步,
/// 于是「密钥是怎么来的」这件最要命的事可以在 `flutter test` 里被完整驱动,
/// 不需要真机、不需要 WebRTC、不需要第二个人。
library;

import 'package:flutter/foundation.dart';
// crypto 与 hashlib 都导出 sha256,这里只用 hashlib 的,避免歧义导入。
import 'package:hashlib/hashlib.dart';

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

// ─────────────────────────────────────────────────────────────────────────────
// Argon2id 派生(v2) —— 上面那个单次 HMAC 的替代品
// ─────────────────────────────────────────────────────────────────────────────

/// v2 的域分隔前缀。换了派生算法就必须换版本号,否则新老客户端
/// 会各自算出不同的密钥却都以为自己是对的 —— 症状是「连上了但听不见」。
const String kE2EEKeyDomainV2 = 'lares-e2ee-v2:';

/// Argon2id 参数。**这三个数一旦上线就不能再改**。
///
/// 它们不是配置项,是密钥的一部分:改任何一个,所有既有圈子的密钥全部变化,
/// 老成员与新成员互相解不开。实测确认过并行度确实影响输出(p=1 与 p=4
/// 产出不同的密钥),所以「在慢设备上降到 p=1」这种优化是**不允许**的。
///
/// 取值依据是本机实测(见 tool/argon2_bench.dart),Windows 桌面:
///
/// | 内存 | 迭代 | 并行 | 耗时 |
/// |---|---|---|---|
/// | 32 MiB | 2 | 1 | 94 ms |
/// | 64 MiB | 3 | 1 | 253 ms |
/// | 64 MiB | 2 | 4 | 162 ms |
/// | 128 MiB | 2 | 1 | 309 ms |
/// | 512 MiB | 2 | 1 | **1305 ms** |
///
/// 没有选 OWASP 推荐的 512 MiB:桌面就要 1.3 秒,低端安卓只会更久,
/// 而且在手机上一次性要 512 MiB 很可能直接 OOM。
///
/// 选 `p=1` 而不是更快的 `p=4`:并行度锁死之后,单核受限的设备也必须
/// 按 4 来算,跨设备一致性比那 90ms 重要。
const int kArgon2MemoryKiB = 64 * 1024; // 64 MiB
const int kArgon2Iterations = 3;
const int kArgon2Parallelism = 1;
const int kArgon2KeyLength = 32; // 32 字节 = 64 hex 字符

/// 由「圈口令 + 圈子 id」用 **Argon2id** 派生该圈的 E2EE 共享密钥。
///
/// ## 为什么不再用单次 HMAC
///
/// 圈口令是人手输的自由文本,熵很低。而 HMAC-SHA256 **算得太快** ——
/// 攻击者拿到加密流量后可以每秒试上亿个口令。
/// Argon2id 的作用不是「更安全的哈希」,而是**故意让它变慢且吃内存**:
/// 把每秒上亿次压到每秒几千次,并且 GPU/ASIC 也占不到便宜
/// (内存硬化,这正是 Argon2 相对 PBKDF2 的关键优势)。
///
/// ## 盐的来源
///
/// 盐由 `circleId` 确定性派生,而不是随机生成 —— 因为圈内每个人
/// 必须**各自独立算出同一把密钥**,没有地方可以分发随机盐。
/// 这牺牲了「彩虹表抗性」,但换来了共享密钥这个必要属性;
/// 真正的防线是 Argon2 本身的计算成本,不是盐的随机性。
/// 盐里拌进版本前缀,让 v1/v2 即使同圈同口令也落在不同的密钥空间。
///
/// 返回 64 个小写 hex 字符。**为什么是 hex 而不是原始字节**:
/// LiveKit 的 `BaseKeyProvider.setSharedKey(String)` 内部做
/// `Uint8List.fromList(key.codeUnits)` —— 逐 UTF-16 码元截断。
/// 非 ASCII 字符在各端截出的字节可能不一致,症状是「口令一样却听不见」。
///
/// ⚠️ 这个函数会阻塞约 250ms(桌面),**调用方应当放进 isolate**
/// (Flutter 的 `compute()`),否则会掉帧。见 [deriveCircleE2EEKeyAsync]。
String deriveCircleE2EEKeyV2({
  required String passcode,
  required String circleId,
}) {
  final Uint8List salt = _saltFor(circleId);
  final result = Argon2(
    version: Argon2Version.v13,
    type: Argon2Type.argon2id,
    hashLength: kArgon2KeyLength,
    iterations: kArgon2Iterations,
    parallelism: kArgon2Parallelism,
    memorySizeKB: kArgon2MemoryKiB,
    salt: salt,
  ).convert(passcode.codeUnits);
  return result.hex();
}

/// 16 字节盐,由版本前缀 + circleId 确定性派生。
///
/// 用 SHA-256 取前 16 字节而不是直接截 circleId 的字节:
/// 圈子 id 可能很短(比如 `home`),直接截会让盐的大部分是填充字节,
/// 不同圈子之间只差开头几位。哈希一遍让整个盐空间都被用上。
Uint8List _saltFor(String circleId) {
  final digest = sha256.convert(
    '$kE2EEKeyDomainV2$circleId'.codeUnits,
  );
  return Uint8List.fromList(digest.bytes.sublist(0, 16));
}

/// 口令是否足以派生密钥。空口令派生出的是一个**人人可算**的常量,
/// 那比不加密更危险(用户以为加密了)。所以宁可不开。
bool canDeriveCircleKey(String passcode) => passcode.isNotEmpty;

/// [deriveCircleE2EEKeyV2] 的异步版:在**后台 isolate** 里算,不卡 UI。
///
/// 为什么必须这样:Argon2id 是刻意设计成慢的,实测桌面约 250ms、
/// 低端手机只会更久。在 UI 线程上同步跑它 = 进房那一刻界面卡住十几帧。
/// `compute()` 是 Flutter 自带的,不引入新依赖。
///
/// 注意 `compute` 的参数必须可跨 isolate 传递,所以这里传一个 record
/// 而不是闭包捕获。
Future<String> deriveCircleE2EEKeyAsync({
  required String passcode,
  required String circleId,
}) =>
    compute(_deriveInIsolate, (passcode: passcode, circleId: circleId));

/// isolate 入口。必须是顶层函数(或静态方法),不能是闭包。
String _deriveInIsolate(({String passcode, String circleId}) args) =>
    deriveCircleE2EEKeyV2(
      passcode: args.passcode,
      circleId: args.circleId,
    );
