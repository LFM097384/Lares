import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/chat/chat_envelope.dart';

/// 手工拼一帧:长度前缀可以故意与实际 header 长度不符,用于构造畸形帧。
Uint8List rawFrame(
  int declaredHeaderLength,
  List<int> headerBytes, [
  List<int> payload = const <int>[],
]) {
  final Uint8List frame = Uint8List(4 + headerBytes.length + payload.length);
  ByteData.sublistView(frame, 0, 4)
      .setUint32(0, declaredHeaderLength, Endian.big);
  frame.setRange(4, 4 + headerBytes.length, headerBytes);
  if (payload.isNotEmpty) {
    frame.setRange(4 + headerBytes.length, frame.length, payload);
  }
  return frame;
}

void main() {
  final DateTime ts = DateTime.fromMillisecondsSinceEpoch(1700000000000);

  group('信封编解码', () {
    test('信封往返:文字帧与图片分片帧字段与载荷均无损', () {
      // --- 文字帧:无 payload ---
      final Map<String, dynamic> textHeader = buildTextHeader(
        id: 'msg-1',
        senderId: 'u-a',
        senderName: '甲',
        circleId: 'home',
        timestamp: ts,
        body: '你好世界',
      );
      final ChatFrame text = decodeFrame(encodeFrame(textHeader));

      expect(text.status, ChatFrameStatus.ok);
      expect(text.isOk, isTrue);
      expect(text.version, chatProtocolVersion);
      expect(text.type, chatTypeText);
      expect(text.header['id'], 'msg-1');
      expect(text.header['sid'], 'u-a');
      expect(text.header['sn'], '甲');
      expect(text.header['cid'], 'home');
      expect(text.header['ts'], ts.millisecondsSinceEpoch);
      expect(text.header['body'], '你好世界');
      expect(text.payload, isEmpty);

      // --- 图片分片帧:带非平凡二进制载荷 ---
      // 用质数 251 取模,让字节模式不与分片边界对齐
      final Uint8List payload =
          Uint8List.fromList(List<int>.generate(3000, (int i) => (i * 7) % 251));
      final Map<String, dynamic> imgHeader = buildImageChunkHeader(
        id: 'img-1',
        senderId: 'u-b',
        senderName: '乙',
        circleId: 'c-2',
        timestamp: ts,
        seq: 3,
        totalChunks: 9,
        totalBytes: 100000,
        width: 640,
        height: 480,
        mime: 'image/jpeg',
      );
      final ChatFrame img = decodeFrame(encodeFrame(imgHeader, payload));

      expect(img.status, ChatFrameStatus.ok);
      expect(img.type, chatTypeImage);
      expect(img.header['id'], 'img-1');
      expect(img.header['sid'], 'u-b');
      expect(img.header['sn'], '乙');
      expect(img.header['cid'], 'c-2');
      expect(img.header['ts'], ts.millisecondsSinceEpoch);
      expect(img.header['seq'], 3);
      expect(img.header['n'], 9);
      expect(img.header['total'], 100000);
      expect(img.header['w'], 640);
      expect(img.header['h'], 480);
      expect(img.header['mime'], 'image/jpeg');
      // 载荷必须逐字节一致
      expect(img.payload, equals(payload));
      expect(img.payload.length, 3000);
    });

    test('宽高为 null 时整个键不写入', () {
      final Map<String, dynamic> header = buildImageChunkHeader(
        id: 'img-2',
        senderId: 'u',
        senderName: 'n',
        circleId: 'c',
        timestamp: ts,
        seq: 0,
        totalChunks: 1,
        totalBytes: 10,
      );
      expect(header.containsKey('w'), isFalse);
      expect(header.containsKey('h'), isFalse);
      expect(header['mime'], 'image/png');

      final ChatFrame decoded = decodeFrame(encodeFrame(header, <int>[1, 2, 3]));
      expect(decoded.status, ChatFrameStatus.ok);
      expect(decoded.header.containsKey('w'), isFalse);
      expect(decoded.header.containsKey('h'), isFalse);
    });

    test('前向兼容:未知版本保留内容、未知类型仍 ok、未知键不丢', () {
      // --- 未知版本:仍完整填充 header 与 payload ---
      final Uint8List payload =
          Uint8List.fromList(List<int>.generate(128, (int i) => (i * 13) % 251));
      final Uint8List future = encodeFrame(
        <String, dynamic>{'v': 99, 't': 'text', 'id': 'x', 'body': 'hi'},
        payload,
      );

      expect(() => decodeFrame(future), returnsNormally);
      final ChatFrame decoded = decodeFrame(future);
      expect(decoded.status, ChatFrameStatus.unsupportedVersion);
      expect(decoded.isOk, isFalse);
      expect(decoded.version, 99);
      // 关键:未知版本不是「丢弃」,内容必须还在
      expect(decoded.header['id'], 'x');
      expect(decoded.header['body'], 'hi');
      expect(decoded.payload, equals(payload));

      // --- 未知类型:信封层不管,仍判 ok,由调用方忽略 ---
      final ChatFrame video = decodeFrame(encodeFrame(
        <String, dynamic>{'v': 1, 't': 'video', 'id': 'z'},
      ));
      expect(video.status, ChatFrameStatus.ok);
      expect(video.type, 'video');

      // --- 未知 JSON 键原样保留 ---
      final ChatFrame extra = decodeFrame(encodeFrame(<String, dynamic>{
        'v': 1,
        't': chatTypeText,
        'id': 'k',
        'body': 'b',
        'futureField': <String, dynamic>{
          'a': 1,
          'b': <int>[1, 2],
        },
      }));
      expect(extra.status, ChatFrameStatus.ok);
      expect(extra.header.containsKey('futureField'), isTrue);
      final Object? nested = extra.header['futureField'];
      expect(nested, isA<Map<String, dynamic>>());
      expect((nested! as Map<String, dynamic>)['a'], 1);
      expect((nested as Map<String, dynamic>)['b'], equals(<int>[1, 2]));
    });

    test('畸形帧软失败:五类坏帧一律 invalid 且不抛', () {
      final Map<String, Uint8List> bad = <String, Uint8List>{
        // (a) 不足 4 字节
        '长度不足': Uint8List.fromList(<int>[1, 2]),
        // (b) 长度字段远超实际缓冲
        '长度越界': rawFrame(0xFFFFFF, <int>[1, 2, 3, 4]),
        // (c) header 不是合法 JSON
        '非 JSON': (() {
          final Uint8List h = utf8.encode('not json{{{');
          return rawFrame(h.length, h);
        })(),
        // (d) JSON 顶层是数组而非对象
        'JSON 数组': (() {
          final Uint8List h = utf8.encode(jsonEncode(<int>[1, 2, 3]));
          return rawFrame(h.length, h);
        })(),
        // (e) headerLength == 0
        '空 header': rawFrame(0, const <int>[], <int>[9, 9, 9]),
        // 附加:非法 UTF-8 序列
        '非 UTF-8': rawFrame(2, <int>[0xC3, 0x28]),
        // 附加:结构合法但缺 v
        '缺版本号': (() {
          final Uint8List h =
              utf8.encode(jsonEncode(<String, dynamic>{'t': 'text'}));
          return rawFrame(h.length, h);
        })(),
        // 附加:v 存在但不是 int
        'v 非整数': (() {
          final Uint8List h =
              utf8.encode(jsonEncode(<String, dynamic>{'v': '1', 't': 'text'}));
          return rawFrame(h.length, h);
        })(),
      };

      bad.forEach((String name, Uint8List bytes) {
        expect(() => decodeFrame(bytes), returnsNormally, reason: name);
        final ChatFrame decoded = decodeFrame(bytes);
        expect(decoded.status, ChatFrameStatus.invalid, reason: name);
        expect(decoded.isOk, isFalse, reason: name);
        // invalid 时 header 与 payload 均为空
        expect(decoded.header, isEmpty, reason: name);
        expect(decoded.payload, isEmpty, reason: name);
        expect(decoded.version, -1, reason: name);
        expect(decoded.type, '', reason: name);
      });

      // 空缓冲也不能炸
      expect(() => decodeFrame(const <int>[]), returnsNormally);
      expect(decodeFrame(const <int>[]).status, ChatFrameStatus.invalid);
    });
  });
}
