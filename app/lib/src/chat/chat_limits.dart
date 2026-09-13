/// 文字+图片消息的全部可调常量(设计.md §2.2 流量透明度 / §8.1 RTC 抽象层)。
///
/// 集中一处,便于按实测网络表现整体收紧或放宽;
/// 每个数字都写明依据,避免后人「随手改大」。
library;

/// LiveKit data channel 单包上限。
/// 依据:livekit_client 2.12.0 `lib/src/types/data_stream.dart:10`
/// `const kStreamChunkSize = 15_000;` —— SDK 自身分片就按这个尺寸切,
/// 因此这是经 SDK 验证过的安全载荷大小。注意 `publishData` 本身不做任何
/// 长度校验,超限只会在 SCTP 层静默失败,必须由我们自己守住。
const int maxPacketBytes = 15000;

/// 单个图片分片的「纯二进制载荷」大小(12 KiB)。
/// 算术:4(帧长前缀) + ~300(JSON header 最坏情况) + 12288 = 12592 < 15000,
/// 余量 ~2.4 KB,足够吸收超长昵称/圈子 id 带来的 header 膨胀。
const int imageChunkPayloadBytes = 12288;

/// 单张图片硬上限(256 KiB)。超出直接拒发,不进入分片流程。
/// 依据:256 KiB ÷ 12 KiB ≈ 22 个可靠包,弱网下仍可在数秒内送达。
const int maxImageBytes = 256 * 1024;

/// 压缩目标(200 KiB)。留 56 KiB 给压缩器的估算误差,
/// 保证压完基本不会撞上 [maxImageBytes]。
const int targetImageBytes = 200 * 1024;

/// 单条文字上限,按「字素簇」计而非 UTF-16 code unit。
/// 依据:500 个 CJK 字符 ≈ 1500 字节 UTF-8,单包可发;
/// 用字素簇计数才不会把 👨‍👩‍👧‍👦 这类 ZWJ 序列拦腰截断。
const int maxTextGraphemes = 500;

/// 单张图片的重组超时。超时即丢弃并释放缓冲,UI 显示「接收失败」占位。
/// 依据:22 个包在可靠通道上最坏也应在 30s 内到齐,否则判定发送端已离场。
const Duration reassemblyTimeout = Duration(seconds: 30);

/// 同时在途的入站图片数上限。小圈子场景 4 张足够,超出淘汰最旧的一张。
const int maxConcurrentInboundImages = 4;

/// 入站重组缓冲总字节上限(1 MiB)。
/// 依据:4 × 256 KiB = 1 MiB,与 [maxConcurrentInboundImages] 对齐,
/// 防止恶意/异常端声明大量分片撑爆内存。
const int maxInboundBufferBytes = 1024 * 1024;

/// 内存中保留的历史消息条数。纯内存态,超出丢弃最旧的。
const int maxHistoryMessages = 200;

/// 聊天帧使用的 LiveKit data topic。
/// 注意:不可使用 `lk.` 前缀(SDK 保留,如 `lk.rpc`)。
const String chatTopic = 'lares.chat';
