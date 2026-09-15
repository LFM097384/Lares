/// 连接码的压缩实现(原生端)。
///
/// 用 `dart:io` 自带的 gzip:实测把一份 1804 字节的真实 SDP
/// 压到 base64 后 688 字节(29%),二维码放得下。
library;

import 'dart:io';
import 'dart:typed_data';

Uint8List compressBytes(List<int> raw) =>
    Uint8List.fromList(gzip.encode(raw));

Uint8List decompressBytes(List<int> packed) =>
    Uint8List.fromList(gzip.decode(packed));
