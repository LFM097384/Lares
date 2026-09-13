/// 图片分片重组(设计.md §8.1 RTC 抽象层)。
///
/// 为什么不用 SDK 自带的字节流 API:
/// livekit_client 2.12.0 提供 `localParticipant.streamBytes(StreamBytesOptions(...))`
/// (`lib/src/participant/local.dart:1195`)与 `room.registerByteStreamHandler(topic, cb)`
/// (`lib/src/core/room.dart:1460`),会按 `kStreamChunkSize = 15_000` 自动切片并带
/// `waitForBufferStatusLow` 背压 —— 看着正好够用,但我们刻意不用,理由四条:
///
/// 1. **乱序即损坏**:`ByteStreamReader.readAll()`
///    (`lib/src/data_stream/stream_reader.dart:66-67`)把分片堆进
///    `final Set<Uint8List> chunks = {};`,**完全不按 `chunkIndex` 重排**;
///    只有 `TextStreamReader` 才按下标归位(`stream_reader.dart:103-109`)。
///    字节流的最终顺序取决于 LinkedHashSet 的插入顺序,乱序到达就是一张坏图。
/// 2. **注册不可替换**:`registerByteStreamHandler` 对同一 topic 重复注册会抛
///    `DataStreamError(HandlerAlreadyRegistered)` 而非覆盖,重连/热重载场景很脆。
/// 3. **绑死活 Room**:该 API 必须挂在活的 `Room` 上;重组器坐在 `ChatTransport`
///    抽象之后,才能脱离 LiveKit 纯单测。且 `Room` 私有在一个我们改不了的文件里,
///    传输抽象无论如何都得有。
/// 4. **策略要自己捏**:超时、淘汰、内存上限这三条守则只有自己实现才能精确控制。
library;

import 'dart:async';
import 'dart:typed_data';

import 'chat_limits.dart';

/// 重组失败的原因(设计.md §8.1:失败必须可见,不能静默吞掉)
enum ImageAssemblyFailure {
  /// 超时:缺片,发送端可能已离场
  timeout,

  /// 被淘汰:并发数或总缓冲超限,牺牲最旧的一张
  evicted,

  /// 分片头字段不合法(seq/n/total 越界或声明尺寸超过 [maxImageBytes])
  malformed,
}

/// 一张重组完成的图片
class AssembledImage {
  /// 全部字段由发送端 header 携带,[bytes] 是按 seq 升序拼好的完整图片
  const AssembledImage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.circleId,
    required this.timestamp,
    required this.bytes,
    this.width,
    this.height,
    this.mime = 'image/png',
  });

  /// 发送端生成的消息 id,重组与去重都以它为键
  final String id;

  /// 发送者 id(header `sid`)
  final String senderId;

  /// 发送者昵称(header `sn`)
  final String senderName;

  /// 所属圈子 id(header `cid`)
  final String circleId;

  /// 发送端时间戳(header `ts`)
  final DateTime timestamp;

  /// 完整图片字节,长度等于 header 声明的 `total`
  final Uint8List bytes;

  /// 可空:仅用于渲染前占位比例,避免图片到达时布局跳动
  final int? width;

  /// 可空:同 [width]
  final int? height;

  /// MIME 类型,缺省 `image/png`
  final String mime;
}

/// 一次重组失败的通知(UI 可据此显示失败占位)
class ImageAssemblyError {
  /// 元数据取自该 id 的**首个**分片,失败时仍足以定位气泡位置
  const ImageAssemblyError({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.circleId,
    required this.timestamp,
    required this.reason,
  });

  /// 失败的消息 id
  final String id;

  /// 发送者 id
  final String senderId;

  /// 发送者昵称
  final String senderName;

  /// 所属圈子 id
  final String circleId;

  /// 发送端时间戳
  final DateTime timestamp;

  /// 失败原因
  final ImageAssemblyFailure reason;
}

/// 已拒绝 id 的记忆上限。
/// 取 64:远大于 [maxConcurrentInboundImages],
/// 足以覆盖一张坏图的全部分片(最多 22 片)且内存可忽略;
/// 超出按插入序淘汰最旧的,保证恶意端不能靠海量假 id 撑爆这张表。
const int _maxRejectedIds = 64;

/// 单张图片允许的最大分片数。
/// 必须有这个上限:`List.filled(n, null)` 的开销只跟 n 走,不计入 [bufferedBytes],
/// 否则一条 `{"n":1000000,"total":1}` 的假 header 就能在字节账本毫无察觉的情况下
/// 吃掉几 MB 指针数组。取 256 = [maxImageBytes] ÷ 1 KiB:
/// 正常发送端按 [imageChunkPayloadBytes] 切片只需 22 片,
/// 即便对端用 1 KiB 的极小分片也够用,留了十倍余量。
const int _maxChunksPerImage = 256;

/// 图片分片重组器(设计.md §8.1 RTC 抽象层)。
///
/// 纯 Dart,不依赖 Flutter binding:可直接单测,无需 TestWidgetsFlutterBinding。
/// 输入是**已解码**的 JSON header + 该片原始字节,
/// 信封的编解码由传输层负责,这里只管「拼回一张图」与「守住内存」。
class ImageAssembler {
  /// [now] 注入时钟,[sweepInterval] 是内部定时清扫周期;
  /// [startTimer] 传 false 则不起真实 Timer,由测试手动驱动 [sweepExpired]。
  ImageAssembler({
    required this.onImage,
    required this.onFailure,
    DateTime Function()? now,
    Duration sweepInterval = const Duration(seconds: 5),
    bool startTimer = true,
  }) : _now = now ?? DateTime.now {
    if (startTimer) {
      _sweepTimer = Timer.periodic(sweepInterval, (Timer _) {
        sweepExpired(_now());
      });
    }
  }

  /// 一张图片重组完成时回调
  final void Function(AssembledImage image) onImage;

  /// 一张图片重组失败时回调(超时/淘汰/非法各只报一次)
  final void Function(ImageAssemblyError error) onFailure;

  final DateTime Function() _now;

  /// 在途重组任务。用 Map 字面量,Dart 保证其为 LinkedHashMap:
  /// 迭代序即插入序,因此 `keys.first` 天然是**最旧**的一张,淘汰直接取它。
  final Map<String, _Assembly> _pending = <String, _Assembly>{};

  /// 已判定非法的 id。Set 字面量同样是插入序的 LinkedHashSet,
  /// 超过 [_maxRejectedIds] 时淘汰最旧的一个。
  final Set<String> _rejected = <String>{};

  int _bufferedBytes = 0;
  bool _disposed = false;
  Timer? _sweepTimer;

  /// 当前在途的重组任务数(供单测断言,非 UI 用途)
  int get pendingCount => _pending.length;

  /// 当前缓冲占用的总字节数(供单测断言:超时/淘汰/完成后应精确归还)
  int get bufferedBytes => _bufferedBytes;

  /// 喂入一个图片分片。[header] 是已解码的 JSON header,[payload] 是该片原始字节。
  void addChunk(Map<String, dynamic> header, Uint8List payload) {
    if (_disposed) {
      return;
    }

    // JSON 来的都是 dynamic:strict-casts 下裸 `as int` 虽合法但会在类型不符时抛,
    // 故一律走安全取值,把「脏数据」降级为 malformed 而不是异常。
    final String id = _stringOf(header, 'id');
    if (id.isEmpty) {
      // 无 id 无法定位气泡,也无法去重;统一记到空串名下,只报一次。
      _rejectMalformed(_metaFromHeader(header, ''));
      return;
    }
    if (_rejected.contains(id)) {
      return;
    }

    final int n = _intOf(header, 'n');
    final int seq = _intOf(header, 'seq');
    final int total = _intOf(header, 'total');

    // 先校验后分配:任何越界都不许触碰缓冲,也不许触发 List.filled。
    if (n <= 0 ||
        n > _maxChunksPerImage ||
        seq < 0 ||
        seq >= n ||
        total <= 0 ||
        total > maxImageBytes ||
        payload.isEmpty ||
        payload.length > total) {
      _rejectMalformed(_metaFromHeader(header, id));
      return;
    }

    final _Assembly? existing = _pending[id];
    if (existing != null && (existing.n != n || existing.total != total)) {
      // 同一 id 前后声明不一致:发送端错乱或恶意,整张作废。
      _rejectMalformed(existing.meta);
      return;
    }

    if (existing != null && existing.chunks[seq] != null) {
      // 重复片:保留先到的那一份,直接忽略。
      // 选「忽略」而非「覆盖」,是因为覆盖会让 receivedBytes 需要做增减修正,
      // 多一条容易算错的路径;先到即定还能天然抵抗后到的伪造片。
      return;
    }

    // 累计长度不得超过声明的 total。这条比「逐片长度必须等于 chunk size」更宽松,
    // 却足以封死「用超量分片撑爆 total 之外内存」的路子,且不假设发送端的切片粒度。
    if ((existing?.receivedBytes ?? 0) + payload.length > total) {
      _rejectMalformed(existing?.meta ?? _metaFromHeader(header, id));
      return;
    }

    if (existing == null) {
      // 并发数超限:淘汰最旧的一张(此时 id 尚未入表,不会误伤自己)。
      while (_pending.length >= maxConcurrentInboundImages) {
        final String? victim = _oldestIdExcept(id);
        if (victim == null) {
          break;
        }
        _evict(victim);
      }
    }

    // 总缓冲超限:循环淘汰最旧的**其它**任务,直到塞得下。
    while (_bufferedBytes + payload.length > maxInboundBufferBytes) {
      final String? victim = _oldestIdExcept(id);
      if (victim == null) {
        // 把别人全淘汰了还是塞不下:这一片本身就不合理,按非法拒收。
        _rejectMalformed(existing?.meta ?? _metaFromHeader(header, id));
        return;
      }
      _evict(victim);
    }

    final _Assembly assembly = existing ??
        _Assembly(
          meta: _metaFromHeader(header, id),
          n: n,
          total: total,
          width: _positiveOrNull(_intOf(header, 'w')),
          height: _positiveOrNull(_intOf(header, 'h')),
          mime: _mimeOf(header),
          // 硬截止时间锚在「首片到达」而非「最后一片到达」:
          // 防止攻击者靠持续喂片给一张永远拼不完的图无限续命。
          createdAt: _now(),
        );
    if (existing == null) {
      _pending[id] = assembly;
    }

    assembly.chunks[seq] = payload;
    assembly.receivedCount++;
    assembly.receivedBytes += payload.length;
    _bufferedBytes += payload.length;

    if (assembly.receivedCount == assembly.n) {
      _complete(id, assembly);
    }
  }

  /// 清扫超时的重组任务。测试直接调用它,避免真的等 30 秒。
  void sweepExpired(DateTime now) {
    if (_pending.isEmpty) {
      return;
    }
    final List<String> expired = <String>[];
    _pending.forEach((String id, _Assembly a) {
      if (now.difference(a.createdAt) >= reassemblyTimeout) {
        expired.add(id);
      }
    });
    for (final String id in expired) {
      final _Assembly? a = _pending.remove(id);
      if (a == null) {
        continue;
      }
      // 先归还缓冲再回调:回调里若又 addChunk,看到的状态也是自洽的。
      _bufferedBytes -= a.receivedBytes;
      _fail(a.meta, ImageAssemblyFailure.timeout);
    }
  }

  /// 释放:取消定时器并清空全部在途任务。幂等。
  ///
  /// 刻意**不**发失败回调 —— 此时宿主正在销毁,再通知 UI 无意义。
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _sweepTimer?.cancel();
    _sweepTimer = null;
    _pending.clear();
    _rejected.clear();
    _bufferedBytes = 0;
  }

  void _complete(String id, _Assembly a) {
    _pending.remove(id);
    _bufferedBytes -= a.receivedBytes;

    // 预分配 total 长度后 setRange,避免反复 `+` 拼接造成 O(n²) 拷贝。
    final Uint8List out = Uint8List(a.total);
    int offset = 0;
    for (int i = 0; i < a.n; i++) {
      final Uint8List? part = a.chunks[i];
      if (part == null || offset + part.length > a.total) {
        _rejectMalformed(a.meta);
        return;
      }
      out.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    if (offset != a.total) {
      // 片数齐了但总长对不上:宁可报失败,也不交出一张残图。
      _rejectMalformed(a.meta);
      return;
    }

    onImage(AssembledImage(
      id: a.meta.id,
      senderId: a.meta.senderId,
      senderName: a.meta.senderName,
      circleId: a.meta.circleId,
      timestamp: a.meta.timestamp,
      bytes: out,
      width: a.width,
      height: a.height,
      mime: a.mime,
    ));
  }

  /// 取最旧的一个任务 id,跳过 [exceptId](绝不淘汰正在写入的那张)
  String? _oldestIdExcept(String exceptId) {
    for (final String key in _pending.keys) {
      if (key != exceptId) {
        return key;
      }
    }
    return null;
  }

  void _evict(String id) {
    final _Assembly? a = _pending.remove(id);
    if (a == null) {
      return;
    }
    _bufferedBytes -= a.receivedBytes;
    _fail(a.meta, ImageAssemblyFailure.evicted);
  }

  /// 判非法:丢弃该 id 的在途缓冲,记入 [_rejected],且**每个 id 只回调一次**,
  /// 后续同 id 的分片静默丢弃,避免一张坏图刷屏几十次回调。
  void _rejectMalformed(_ChunkMeta meta) {
    final _Assembly? a = _pending.remove(meta.id);
    if (a != null) {
      _bufferedBytes -= a.receivedBytes;
    }
    if (_rejected.contains(meta.id)) {
      return;
    }
    _rejected.add(meta.id);
    while (_rejected.length > _maxRejectedIds) {
      _rejected.remove(_rejected.first);
    }
    _fail(meta, ImageAssemblyFailure.malformed);
  }

  void _fail(_ChunkMeta meta, ImageAssemblyFailure reason) {
    onFailure(ImageAssemblyError(
      id: meta.id,
      senderId: meta.senderId,
      senderName: meta.senderName,
      circleId: meta.circleId,
      timestamp: meta.timestamp,
      reason: reason,
    ));
  }

  _ChunkMeta _metaFromHeader(Map<String, dynamic> header, String id) {
    final int ts = _intOf(header, 'ts');
    return _ChunkMeta(
      id: id,
      senderId: _stringOf(header, 'sid'),
      senderName: _stringOf(header, 'sn'),
      circleId: _stringOf(header, 'cid'),
      // ts 缺失/非法时退回本地时钟:宁可时间略偏,也不要 1970 年的气泡。
      timestamp: ts > 0 ? DateTime.fromMillisecondsSinceEpoch(ts) : _now(),
    );
  }
}

/// 一张图片的在途重组状态(私有)
class _Assembly {
  _Assembly({
    required this.meta,
    required this.n,
    required this.total,
    required this.width,
    required this.height,
    required this.mime,
    required this.createdAt,
  }) : chunks = List<Uint8List?>.filled(n, null);

  /// 元数据取首片,后续片的 sid/sn/ts 一律忽略
  final _ChunkMeta meta;
  final int n;
  final int total;
  final int? width;
  final int? height;
  final String mime;
  final DateTime createdAt;

  /// 按 seq 下标存放,拼接时严格升序遍历,不依赖到达顺序
  final List<Uint8List?> chunks;

  int receivedCount = 0;
  int receivedBytes = 0;
}

/// 失败/完成回调所需的最小元数据(私有)
class _ChunkMeta {
  const _ChunkMeta({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.circleId,
    required this.timestamp,
  });

  final String id;
  final String senderId;
  final String senderName;
  final String circleId;
  final DateTime timestamp;
}

/// 安全取整:JSON 的 dynamic 可能是 int/double/String/null。
/// 只接受数值,其余一律返回 -1 —— 这个哨兵值必定触发上面的越界校验,
/// 于是「字段缺失」与「字段非法」走同一条 malformed 路径,无需额外分支。
int _intOf(Map<String, dynamic> header, String key) {
  final Object? raw = header[key];
  if (raw is int) {
    return raw;
  }
  if (raw is num) {
    return raw.toInt();
  }
  return -1;
}

/// 安全取串:非 String 一律退回空串,不做隐式 toString。
String _stringOf(Map<String, dynamic> header, String key) {
  final Object? raw = header[key];
  if (raw is String) {
    return raw;
  }
  return '';
}

/// mime 缺失或非串时退回 `image/png`,与 [AssembledImage] 的默认值一致。
String _mimeOf(Map<String, dynamic> header) {
  final String raw = _stringOf(header, 'mime');
  return raw.isEmpty ? 'image/png' : raw;
}

/// 宽高是可选字段:非正数视为「未提供」
int? _positiveOrNull(int value) => value > 0 ? value : null;
