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

/// 允许的图片类型。不写 `*` 是为了让对话框默认只列图片,
/// 用户少一次「选错文件类型然后被拒」的来回。
///
/// ## 三组字段必须同时写全,少一组就有一端会炸
///
/// file_selector 的各平台实现**各读各的字段**,而且都会在「筛选非空、
/// 但我认的那组字段是空」时直接抛 `ArgumentError`:
///
///  - **iOS 只读 `uniformTypeIdentifiers`,完全无视 `extensions`**
///    (file_selector_ios 0.5.3+6 `_allowedUtiListFromTypeGroups`);
///  - macOS 三组都读,取并集(且 macOS 11 以下会丢掉 mimeTypes);
///  - Windows 只读 `extensions`;
///  - Linux 读 `extensions` + `mimeTypes`;
///  - Android 读 `extensions` + `mimeTypes`;
///  - Web 读 `extensions` + `mimeTypes` + `webWildCards`。
///
/// **这里有过一个真实的坑:本文件原先只写了 `extensions`,于是 iOS 上
/// `pickImage()` 每次必抛 `ArgumentError`,又被下面的 catch 吞成 null——
/// 表现是「选图按钮能渲染、能点,点了完全没反应」,一声不响藏了很久。
/// 谁都不要因为「本机跑得通」就删掉 `uniformTypeIdentifiers`。**
///
/// UTI 常量对应 Apple UniformTypeIdentifiers 框架(iOS 14 / macOS 11 起)的
/// `UTType` 静态量。写错了同样不报错,只会安静地「那类图选不了」——
/// 系统对不认识的 UTI 是忽略,不是报错。
const XTypeGroup imageTypeGroup = XTypeGroup(
  label: '图片',
  // Windows / Linux / Android / macOS / Web 读这组
  extensions: <String>['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
  // Linux / Android / Web / macOS(11+)读这组
  mimeTypes: <String>[
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'image/bmp',
  ],
  // iOS / macOS 读这组。iOS 缺了它就直接抛 ArgumentError,见上。
  uniformTypeIdentifiers: <String>[
    'public.png', // UTType.png
    'public.jpeg', // UTType.jpeg —— jpg 与 jpeg 共用这一个,没有 public.jpg
    'com.compuserve.gif', // UTType.gif
    'org.webmproject.webp', // UTType.webP
    'com.microsoft.bmp', // UTType.bmp
  ],
);

/// 打开系统选图器。用户取消、或选了空文件时返回 null;**其余失败一律上抛**。
///
/// null 的含义被刻意收窄成「用户什么都没选」这一种正常路径:取消是最常见的
/// 情形,把它做成异常会逼着每个调用点写 try/catch,不值当。
///
/// 但真失败(筛选器配错、权限被拒、文件被删、网络盘掉线)**不再吞**。
/// 上一版把它们一起压成 null,直接导致了上面那个 iOS 筛选器 bug 长期无人发现:
/// 异常被吃干净,UI 只看到 null,而 null 的语义是「用户取消」——于是
/// 一个必现的崩溃被完美伪装成了「用户改主意了」。宁可让调用方接住异常。
///
/// 契约没变:返回类型仍是 `Future<PickedImage?>`,调用方
/// (`chat_panel.dart` 的 `_handlePickImage`)本来就有 try/catch,
/// 接住后会显示那行安静的小字提示,不需要任何改动。
Future<PickedImage?> pickImage() async {
  try {
    final XFile? file = await openFile(acceptedTypeGroups: <XTypeGroup>[
      imageTypeGroup,
    ]);
    if (file == null) return null; // 用户取消
    final Uint8List bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null; // 空文件:当作没选
    return PickedImage(bytes: bytes);
  } catch (e) {
    // 上层那行提示只有五个字,debug 下把真正的原因也留在控制台,
    // 免得下次再出这种「点了没反应」时又得从头猜。
    if (kDebugMode) debugPrint('[lares] 选图失败(已向上抛出): $e');
    rethrow; // rethrow 保留原始栈,别换成 throw e
  }
}
