/// 「从系统选图」的 **Web 侧实现**(不含 dart:io)。原生端见 image_source_io.dart。
///
/// 与 `installer.dart` / `platform_info.dart` 同一套条件导入写法:
/// 调用方写
/// ```dart
/// import '../chat/image_source.dart'
///     if (dart.library.io) '../chat/image_source_io.dart';
/// ```
/// 即可在 Web 上拿到这里的实现、在原生端拿到 image_source_io.dart 的实现。
///
/// ## 实现:file_selector(Web 端是隐藏的 `<input type=file>`)
///
/// 背景:原生 Flutter 在任何平台都没有「打开文件对话框」的能力,
/// 剪贴板也走不通:`flutter/lib/src/services/clipboard.dart` 全文只定义了
/// **一个**常量 `kTextPlain = 'text/plain'`,`ClipboardData` 也只有 `text`
/// 一个字段——原生 Flutter 里根本不存在图片剪贴板通路。所以必须有依赖。
///
/// file_selector 的 Web 实现内部就是一个隐藏的 `<input type=file>`,
/// 行为与桌面一致,故两端可以共用同一份调用代码(设计.md §8.2 图片侧信道)。
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

/// 已选中的图片:原始编码字节 + 可选的像素尺寸。
///
/// 尺寸可选,因为部分选图器只给字节;拿不到时交由
/// `image_downscale.dart` 的 `measureEncodedImage` 现场测量。
class PickedImage {
  const PickedImage({required this.bytes, this.width, this.height});

  /// 未经处理的原始编码字节(JPEG/PNG/...)。
  final Uint8List bytes;

  /// 像素宽,未知时为 null。
  final int? width;

  /// 像素高,未知时为 null。
  final int? height;
}

/// 当前构建是否支持「从系统选图」。Web 上由 file_selector 提供。
bool get isImagePickSupported => true;

/// 常见图片扩展名。不写 `*` 是为了让对话框默认只列图片。
const XTypeGroup _imageGroup = XTypeGroup(
  label: '图片',
  extensions: <String>['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
);

/// 打开系统选图器。用户取消、或读取失败时返回 null(不抛)。
///
/// 与原生端实现保持一致的契约:取消是正常路径,不做成异常。
Future<PickedImage?> pickImage() async {
  try {
    final XFile? file = await openFile(acceptedTypeGroups: <XTypeGroup>[
      _imageGroup,
    ]);
    if (file == null) return null; // 用户取消
    final Uint8List bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    return PickedImage(bytes: bytes);
  } catch (e) {
    debugPrint('[lares] 选图失败(已忽略): $e');
    return null;
  }
}
