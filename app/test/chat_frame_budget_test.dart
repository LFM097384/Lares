import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/chat/chat_envelope.dart';
import 'package:lares_app/src/chat/chat_limits.dart';

/// 帧尺寸预算:最坏情况的图片分片帧必须落在 [maxPacketBytes] 之内。
///
/// 这条测试是分片大小选型的「活证明」:
/// `encodeFrame` 刻意不依赖 chat_limits,`publishData` 也不做长度校验,
/// 超限只会在 SCTP 层**静默失败**,所以这里必须用真实编码器算一遍。
void main() {
  test('分片帧最坏情况不超过单包上限', () {
    // 最坏情况:各字段都取实际可能的最长值
    final Uint8List payload = Uint8List(imageChunkPayloadBytes);
    final Uint8List frame = encodeFrame(
      buildImageChunkHeader(
        // id 形如 `userId-微秒-序号-随机`,给足余量
        id: 'u_${'9' * 24}-1758000000000000-999999-1048575',
        senderId: 'u_${'9' * 24}',
        // 昵称按 32 字素簇上限,取最贵的 emoji(每簇 UTF-8 25 字节 + JSON 转义)
        senderName: '👨‍👩‍👧‍👦' * 32,
        circleId: 'c_${'9' * 24}',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1758000000000),
        seq: 21,
        totalChunks: 22,
        totalBytes: maxImageBytes,
        width: 4096,
        height: 4096,
        mime: 'image/jpeg',
      ),
      payload,
    );

    expect(frame.length, lessThanOrEqualTo(maxPacketBytes));
    // 载荷 + 4 字节长度前缀之外,留给 header 的余量
    expect(maxPacketBytes - imageChunkPayloadBytes - 4, 2708);
  });

  test('文字帧最坏情况不超过单包上限', () {
    final Uint8List frame = encodeFrame(
      buildTextHeader(
        id: 'u_${'9' * 24}-1758000000000000-999999-1048575',
        senderId: 'u_${'9' * 24}',
        senderName: '👨‍👩‍👧‍👦' * 32,
        circleId: 'c_${'9' * 24}',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1758000000000),
        // 500 个字素簇全取 4 字节 emoji 的极端文本
        body: '😀' * maxTextGraphemes,
      ),
    );

    expect(frame.length, lessThanOrEqualTo(maxPacketBytes));
  });
}
