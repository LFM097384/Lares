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

/// 允许的图片类型。不写 `*` 是为了让对话框默认只列图片。
///
/// Web 实现只读 `extensions` + `mimeTypes`(+ `webWildCards`),用不上
/// `uniformTypeIdentifiers`。但这里仍与 image_source_io.dart 逐字段对齐,
/// 理由有二:一是两个文件是同一接缝的两半,字段分叉早晚会咬人;
/// 二是**iOS 只读 `uniformTypeIdentifiers`、完全无视 `extensions`**,
/// 这个坑已经真实发作过一次(表现为选图按钮点了毫无反应),
/// 谁要是照着这份「Web 用不到」的理由把它删掉,原生端就会立刻复发。
/// 多写的字段对不认它的平台是纯粹的无害冗余——这也是官方推荐做法。
const XTypeGroup imageTypeGroup = XTypeGroup(
  label: '图片',
  extensions: <String>['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
  mimeTypes: <String>[
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'image/bmp',
  ],
  uniformTypeIdentifiers: <String>[
    'public.png', // UTType.png
    'public.jpeg', // UTType.jpeg —— jpg 与 jpeg 共用这一个
    'com.compuserve.gif', // UTType.gif
    'org.webmproject.webp', // UTType.webP
    'com.microsoft.bmp', // UTType.bmp
  ],
);

/// 打开系统选图器。用户取消、或选了空文件时返回 null;**其余失败一律上抛**。
///
/// 与原生端实现保持一致的契约:取消是正常路径,不做成异常;
/// 而真失败不再被压成 null——吞异常正是那个 iOS 选图 bug 藏了很久的原因。
Future<PickedImage?> pickImage() async {
  try {
    final XFile? file = await openFile(acceptedTypeGroups: <XTypeGroup>[
      imageTypeGroup,
    ]);
    if (file == null) return null; // 用户取消
    final Uint8List bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    return PickedImage(bytes: bytes);
  } catch (e) {
    if (kDebugMode) debugPrint('[lares] 选图失败(已向上抛出): $e');
    rethrow; // rethrow 保留原始栈,别换成 throw e
  }
}
