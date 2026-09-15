/// 连接码的压缩实现(Web 端)。
///
/// Web 上没有 `dart:io` 的 gzip,改用纯 Dart 的 `archive`
/// (它本来就在依赖树里,已提升为直接依赖以免上游哪天移除它)。
///
/// ⚠️ **两端必须产出同一种格式**:原生端用 `dart:io` 的 gzip,
/// 这里用 archive 的 GZipEncoder —— 两者都是标准 RFC 1952 gzip 流,
/// 可以互相解开。有测试专门验这条(见 connect_code_test.dart),
/// 否则会出现「安卓生成的码 Web 打不开」这种只在跨端时才暴露的 bug。
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

Uint8List compressBytes(List<int> raw) =>
    Uint8List.fromList(const GZipEncoder().encode(raw));

Uint8List decompressBytes(List<int> packed) =>
    Uint8List.fromList(const GZipDecoder().decodeBytes(packed));
