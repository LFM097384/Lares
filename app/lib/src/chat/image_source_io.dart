/// 「从系统选图」的 **原生端实现**。Web 侧见 image_source.dart。
///
/// 经条件导入替换 Web 版,调用方写
/// ```dart
/// import '../chat/image_source.dart'
///     if (dart.library.io) '../chat/image_source_io.dart';
/// ```
///
/// ## 现状:同样是**空实现**
///
/// 原生 Flutter 自身不提供文件打开对话框;剪贴板也不是出路——
/// `flutter/lib/src/services/clipboard.dart` 只定义了唯一一个常量
/// `kTextPlain = 'text/plain'`,`ClipboardData` 也只有 `text` 字段,
/// 即原生 Flutter 里确实不存在任何图片剪贴板通路。
/// 而项目当前不引入选图依赖,所以这里也只能返回 false / null。
/// 留住接缝,好让 UI 平静地禁用入口,而不是抛异常(设计.md §8.2 图片侧信道)。
///
/// 注意:本文件逻辑上并不需要 dart:io(只用到 Uint8List),
/// 因此故意不 import 它——白引会触发 unused_import。
library;

import 'dart:typed_data';

/// 已选中的图片:原始编码字节 + 可选的像素尺寸。
///
/// 与 image_source.dart 中的同名类完全一致:两个文件只会被导入其中一个,
/// 因此重复声明不会冲突,这也是 `PlatformInfo` 在
/// platform_info.dart / platform_info_io.dart 里的既有做法。
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
/// 原生端目前恒为 false:没有任何可用的选图依赖。
// TODO(依赖): 需要 file_selector: ^1.0.3(桌面/Web 均支持系统文件对话框)
// 分平台的正确选择:
//  * 移动端(Android/iOS)用 image_picker: ^1.1.2 更合适——
//    自带相册 + 相机两个入口,并且把运行时权限申请一并处理了。
//  * 桌面端(Windows/macOS/Linux)用 file_selector,原生文件对话框、无需权限。
//
// 警告:**不要**为了绕开依赖去碰 package:web 之类的传递依赖,
// 直接 import 会触发 depend_on_referenced_packages lint 并弄脏 flutter analyze。
bool get isImagePickSupported => false;

/// 打开系统选图器。不支持时返回 null。
///
/// 原生端永远返回 null,见 [isImagePickSupported] 的说明。
Future<PickedImage?> pickImage() async => null;
