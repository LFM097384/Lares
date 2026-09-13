/// 「从系统选图」的 **原生端实现**。Web 侧见 image_source.dart。
///
/// 经条件导入替换 Web 版,调用方写
/// ```dart
/// import '../chat/image_source.dart'
///     if (dart.library.io) '../chat/image_source_io.dart';
/// ```
///
/// ## 实现:file_selector(系统文件对话框)
///
/// 背景:原生 Flutter 自身不提供文件打开对话框;剪贴板也不是出路——
/// `flutter/lib/src/services/clipboard.dart` 只定义了唯一一个常量
/// `kTextPlain = 'text/plain'`,`ClipboardData` 也只有 `text` 字段,
/// 即原生 Flutter 里确实不存在任何图片剪贴板通路。所以必须有依赖。
///
/// 选 `file_selector` 而非 `image_picker`:桌面是当前主力端,且它不需要
/// 运行时权限申请。移动端将来若要相册/相机双入口,再叠加 image_picker
/// 即可——本文件的接缝不变(设计.md §8.2 图片侧信道)。
///
/// 尺寸此处一律不返回:`XFile` 不提供像素尺寸,交由
/// `image_downscale.dart` 的 `measureEncodedImage` 现场测量,
/// 避免在这里白解一次码。
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

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
/// file_selector 在 Windows/macOS/Linux 上都有实现;Android/iOS 上它
/// 走的是系统文件选择器(能用,但不如相册入口顺手——见文件头的说明)。
bool get isImagePickSupported => true;

/// 常见图片扩展名。不写 `*` 是为了让对话框默认只列图片,
/// 用户少一次「选错文件类型然后被拒」的来回。
const XTypeGroup _imageGroup = XTypeGroup(
  label: '图片',
  extensions: <String>['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
);

/// 打开系统选图器。用户取消、或读取失败时返回 null(不抛)。
///
/// 不抛的理由:取消是最常见的正常路径,把它做成异常会逼着每个调用点
/// 写 try/catch;而读文件失败(权限/文件被删/网络盘掉线)对聊天这个
/// **副通道**来说也不值得打断用户——上层据 null 静默收场即可。
Future<PickedImage?> pickImage() async {
  try {
    final XFile? file = await openFile(acceptedTypeGroups: <XTypeGroup>[
      _imageGroup,
    ]);
    if (file == null) return null; // 用户取消
    final Uint8List bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null; // 空文件:当作没选
    return PickedImage(bytes: bytes);
  } catch (e) {
    debugPrint('[lares] 选图失败(已忽略): $e');
    return null;
  }
}
