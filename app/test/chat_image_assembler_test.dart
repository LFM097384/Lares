import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/chat/chat_envelope.dart';
import 'package:lares_app/src/chat/chat_limits.dart';
import 'package:lares_app/src/chat/image_assembler.dart';

/// 确定性图片字节。用质数 251 取模,使字节模式不与分片边界对齐,
/// 从而「顺序拼错」必定被 equals 抓到。
Uint8List makeImage(int size, int seed) =>
    Uint8List.fromList(List<int>.generate(size, (int i) => (i * seed + seed) % 251));

/// 一个待投喂的分片:已解码 header + 该片原始字节
class Chunk {
  Chunk(this.header, this.payload);

  final Map<String, dynamic> header;
  final Uint8List payload;
}

/// 按 [imageChunkPayloadBytes] 切片,产出可直接喂给 addChunk 的分片列表
List<Chunk> sliceImage(
  String id,
  Uint8List bytes, {
  String senderId = 'u-a',
  String senderName = '甲',
  String circleId = 'home',
  DateTime? timestamp,
  int? width,
  int? height,
  String mime = 'image/png',
}) {
  final DateTime ts = timestamp ?? DateTime.fromMillisecondsSinceEpoch(1700000000000);
  final int total = bytes.length;
  final int n = (total + imageChunkPayloadBytes - 1) ~/ imageChunkPayloadBytes;
  final List<Chunk> out = <Chunk>[];
  for (int seq = 0; seq < n; seq++) {
    final int start = seq * imageChunkPayloadBytes;
    final int end = start + imageChunkPayloadBytes < total
        ? start + imageChunkPayloadBytes
        : total;
    out.add(Chunk(
      buildImageChunkHeader(
        id: id,
        senderId: senderId,
        senderName: senderName,
        circleId: circleId,
        timestamp: ts,
        seq: seq,
        totalChunks: n,
        totalBytes: total,
        width: width,
        height: height,
        mime: mime,
      ),
      Uint8List.fromList(bytes.sublist(start, end)),
    ));
  }
  return out;
}

void main() {
  group('图片分片重组', () {
    late List<AssembledImage> images;
    late List<ImageAssemblyError> failures;

    setUp(() {
      images = <AssembledImage>[];
      failures = <ImageAssemblyError>[];
    });

    /// 统一构造:startTimer:false,绝不起真实 Timer
    ImageAssembler build({DateTime Function()? now}) => ImageAssembler(
          onImage: images.add,
          onFailure: failures.add,
          now: now,
          startTimer: false,
        );

    test('切片重组 happy path:顺序到达,字节完全一致', () {
      final Uint8List original = makeImage(100 * 1024, 7);
      final List<Chunk> chunks = sliceImage(
        'img-a',
        original,
        width: 800,
        height: 600,
        mime: 'image/jpeg',
      );
      expect(chunks.length, greaterThan(1)); // 确保真的是多片

      final ImageAssembler a = build();
      addTearDown(a.dispose);
      for (final Chunk c in chunks) {
        a.addChunk(c.header, c.payload);
      }

      expect(images.length, 1);
      expect(failures, isEmpty);
      final AssembledImage img = images.single;
      expect(img.bytes, equals(original)); // 逐字节一致
      expect(img.bytes.length, original.length);
      // 元数据取自首片
      expect(img.id, 'img-a');
      expect(img.senderId, 'u-a');
      expect(img.senderName, '甲');
      expect(img.circleId, 'home');
      expect(img.width, 800);
      expect(img.height, 600);
      expect(img.mime, 'image/jpeg');
      // 完成后缓冲精确归还
      expect(a.pendingCount, 0);
      expect(a.bufferedBytes, 0);
    });

    test('乱序到达:逆序投喂,结果与顺序投喂一致', () {
      final Uint8List original = makeImage(100 * 1024, 11);
      final List<Chunk> chunks = sliceImage('img-b', original);

      final ImageAssembler a = build();
      addTearDown(a.dispose);
      for (final Chunk c in chunks.reversed) {
        a.addChunk(c.header, c.payload);
      }

      expect(images.length, 1);
      expect(failures, isEmpty);
      expect(images.single.bytes, equals(original));
      expect(a.pendingCount, 0);
      expect(a.bufferedBytes, 0);
    });

    test('重复分片:首到即定,只完成一次且不重复计账', () {
      final Uint8List original = makeImage(50 * 1024, 13);
      final List<Chunk> chunks = sliceImage('img-c', original);

      final ImageAssembler a = build();
      addTearDown(a.dispose);
      // 第 0 片喂两次
      a.addChunk(chunks[0].header, chunks[0].payload);
      a.addChunk(chunks[0].header, chunks[0].payload);
      for (final Chunk c in chunks.skip(1)) {
        a.addChunk(c.header, c.payload);
      }

      expect(images.length, 1); // 恰好一次
      expect(failures, isEmpty);
      expect(images.single.bytes, equals(original));
      expect(a.pendingCount, 0);
      expect(a.bufferedBytes, 0); // 重复片没被重复计入
    });

    test('缺片超时:回调一次 timeout 且缓冲彻底释放', () {
      final DateTime start = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      DateTime clock = start;

      final Uint8List original = makeImage(100 * 1024, 17);
      final List<Chunk> chunks = sliceImage('img-d', original);

      final ImageAssembler a = build(now: () => clock);
      addTearDown(a.dispose);
      // 故意扣下最后一片
      for (final Chunk c in chunks.take(chunks.length - 1)) {
        a.addChunk(c.header, c.payload);
      }

      expect(images, isEmpty);
      expect(failures, isEmpty);
      expect(a.pendingCount, 1);
      expect(a.bufferedBytes, greaterThan(0));

      // 未到硬截止:不该失败
      clock = start.add(const Duration(seconds: 10));
      a.sweepExpired(clock);
      expect(failures, isEmpty);
      expect(a.pendingCount, 1);

      // 越过硬截止
      clock = start.add(reassemblyTimeout + const Duration(seconds: 1));
      a.sweepExpired(clock);

      expect(failures.length, 1);
      expect(failures.single.reason, ImageAssemblyFailure.timeout);
      expect(failures.single.id, 'img-d');
      expect(failures.single.senderName, '甲');
      expect(images, isEmpty); // 从未成图
      expect(a.pendingCount, 0);
      expect(a.bufferedBytes, 0); // 缓冲真的还回去了
    });

    test('两张图交错:各自独立完成,互不串扰', () {
      final Uint8List first = makeImage(40 * 1024, 19);
      final Uint8List second = makeImage(70 * 1024, 23);
      final List<Chunk> ca = sliceImage('img-e', first, senderName: '甲');
      final List<Chunk> cb = sliceImage('img-f', second, senderName: '乙');
      expect(ca.length, isNot(cb.length)); // 片数不同,更容易暴露串扰

      final ImageAssembler a = build();
      addTearDown(a.dispose);
      final int maxLen = ca.length > cb.length ? ca.length : cb.length;
      for (int i = 0; i < maxLen; i++) {
        if (i < ca.length) a.addChunk(ca[i].header, ca[i].payload);
        if (i < cb.length) a.addChunk(cb[i].header, cb[i].payload);
      }

      expect(images.length, 2);
      expect(failures, isEmpty);
      final AssembledImage e =
          images.firstWhere((AssembledImage x) => x.id == 'img-e');
      final AssembledImage f =
          images.firstWhere((AssembledImage x) => x.id == 'img-f');
      expect(e.bytes, equals(first));
      expect(e.senderName, '甲');
      expect(f.bytes, equals(second));
      expect(f.senderName, '乙');
      expect(a.pendingCount, 0);
      expect(a.bufferedBytes, 0);
    });

    test('内存上限淘汰:并发超限时牺牲最旧的一张', () {
      final ImageAssembler a = build();
      addTearDown(a.dispose);

      // 起 maxConcurrentInboundImages + 1 张,每张只喂第 0 片(n=2,永不完成)
      final int count = maxConcurrentInboundImages + 1;
      for (int i = 0; i < count; i++) {
        final Uint8List part = makeImage(1024, i + 2);
        a.addChunk(
          buildImageChunkHeader(
            id: 'img-$i',
            senderId: 'u-$i',
            senderName: '用户$i',
            circleId: 'home',
            timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
            seq: 0,
            totalChunks: 2,
            totalBytes: 4096,
          ),
          part,
        );
      }

      expect(images, isEmpty); // 没有一张能拼完
      expect(failures.length, 1);
      expect(failures.single.reason, ImageAssemblyFailure.evicted);
      expect(failures.single.id, 'img-0'); // 最旧的那张
      expect(a.pendingCount, maxConcurrentInboundImages);
    });
  });
}
