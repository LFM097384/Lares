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
/// ## 现状:这是一个**空实现**,但接缝是真的
///
/// 原生 Flutter 在任何平台都没有「打开文件对话框」的能力,
/// 剪贴板也走不通:`flutter/lib/src/services/clipboard.dart` 全文只定义了
/// **一个**常量 `kTextPlain = 'text/plain'`,`ClipboardData` 也只有 `text`
/// 一个字段——原生 Flutter 里根本不存在图片剪贴板通路。
/// 项目当前又不引入任何选图依赖,所以两端都诚实地返回 false / null。
///
/// 保留这层接缝的意义:UI 可以据 [isImagePickSupported] 把按钮置灰、
/// 配一句平静的 tooltip;将来只要加一行依赖,补上 [pickImage] 的实现,
/// 上层代码一个字都不用改(设计.md §8.2 图片侧信道)。
library;

import 'dart:typed_data';

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

/// 当前构建是否支持「从系统选图」。
///
/// Web 上恒为 false:没有依赖能打开文件选择器。
// TODO(依赖): 需要 file_selector: ^1.0.3(桌面/Web 均支持系统文件对话框)
// Web 端 file_selector 内部用一个隐藏的 <input type=file> 实现,行为与桌面一致。
//
// 警告:**不要**改用 package:web 自己撸 HTMLInputElement。
// package:web 只是传递依赖,直接 import 会触发 depend_on_referenced_packages
// lint,把 `flutter analyze` 弄脏;要么正经加 file_selector,要么保持空实现。
bool get isImagePickSupported => false;

/// 打开系统选图器。不支持时返回 null。
///
/// Web 上永远返回 null,见 [isImagePickSupported] 的说明。
Future<PickedImage?> pickImage() async => null;
