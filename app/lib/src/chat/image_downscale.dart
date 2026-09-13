/// 图片降采样:把用户选中的图片压到可经 data channel 发送的体积
/// (设计.md §2.2 流量透明度 / §8.2 图片侧信道)。
///
/// ## 为什么只输出 PNG
///
/// 原生 Flutter **没有 JPEG 编码器**。`dart:ui` 的 [ui.ImageByteFormat] 里
/// 压根不存在 jpeg 项(全 enum 搜 `jpeg`/`jpg` 零命中),
/// 唯一的有损/压缩输出就是 `png`。
/// 而且这不是疏漏,是引擎的**明确取舍**——sky_engine `lib/ui/painting.dart`
/// 在 enum 与 `Image.toByteData` 上各写了一遍同样的注释:
/// 「考虑到 LTO 之后的引擎二进制体积,不打算再往 ImageByteFormat 里加编码格式;
/// 需要其它格式请用第三方纯 Dart image 库」(并指向 flutter#16635)。
/// 所以「只能出 PNG」是上游立场,不是我们的偏好。
///
/// 另外注意 enum 取值在两端并不一致:原生有 5 个,Web 只有 4 个
/// (`rawExtendedRgba128` 在 Web 上不存在)。本文件只用 `png`——两端都有。
///
/// PNG 是无损格式:照片这种高熵内容重编码成 PNG 后体积往往**比原 JPEG 大好几倍**。
/// 本文件的迭代式降采样就是对这件事的唯一补救——既然压不动熵,就只能减像素。
/// 代价是照片被明显缩小;但这是聊天侧信道,语音才是第一等公民,
/// 一张缩到 800px 宽的图足够「看清朋友在说什么」。
///
/// 想要真正的高压缩比,只需按引擎注释的建议把 `image: ^4.9.2` 加为**直接**依赖,
/// 用 `encodeJpg(quality: 82)` 即可在同等观感下拿到 5~10 倍更小的字节数。
/// 这里**故意**不引入:本项目在图片链路上保持零新增依赖,
/// 宁可先牺牲画质换取依赖面干净,等真有人抱怨画质再加。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'chat_limits.dart';

/// 每次重试时宽度的收缩系数。0.75 使字节数大约降到 (0.75)² ≈ 56%,
/// 既收得够快,又不至于一步把图缩得面目全非。
const double _stepFactor = 0.75;

/// 宽度下限。再窄下去连文字截图都看不清,不如直接判定失败。
const int _minWidth = 320;

/// 单张图片最多尝试的编码轮数,用于保证循环一定终止。
///
/// 首轮已由 sqrt 估算直接跳到目标附近(见 [downscaleForChat]),
/// 不再浪费一次全尺寸编码,所以这里给得宽松些:
/// 高熵图片(噪声、纹理)估算偏差大,多留几轮退让空间。
const int _maxAttempts = 8;

/// 结果:压缩后的 PNG 字节 + 最终像素尺寸。
///
/// [bytes] 可能是**原始编码字节**(源图本来就够小、无需重编码时),
/// 也可能是重新编码出的 PNG;调用方无需区分,按字节发送即可。
class DownscaledImage {
  const DownscaledImage({
    required this.bytes,
    required this.width,
    required this.height,
  });

  /// 可直接进入分片流程的编码字节。
  final Uint8List bytes;

  /// 最终像素宽。
  final int width;

  /// 最终像素高。
  final int height;
}

/// 图片处理过程中的**意外**失败。
///
/// 注意与 `null` 返回的区别,这是本文件的核心约定:
///  * 返回 `null` —— 图片本身没问题,只是「无法压到可发送体积」,
///    属于可预期的业务结果,UI 应给出平静的提示而非报错。
///  * 抛出 [ImageDownscaleFailure] —— 真正的异常:字节不是有效图片、
///    引擎解码失败、或 `toByteData` 返回了 null。这类问题需要被记录。
class ImageDownscaleFailure implements Exception {
  const ImageDownscaleFailure(this.message);

  /// 面向日志的中文说明。
  final String message;

  @override
  String toString() => 'ImageDownscaleFailure: $message';
}

/// 把 [source] 压到 [targetImageBytes] 以内,失败(压不下去)时返回 `null`。
///
/// 返回 `null` 表示「无法压到可发送体积」——即便缩到 [_minWidth] 仍然超过
/// [maxImageBytes]。调用方应据此禁用发送并提示用户换一张图。
/// 若字节根本不是图片,则抛出 [ImageDownscaleFailure]。
Future<DownscaledImage?> downscaleForChat(Uint8List source) async {
  // 空输入不值得惊动引擎,直接短路。
  if (source.isEmpty) return null;

  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
    source,
  );
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await _encodedDescriptor(buffer);

    // 这里**绝对不能**读 descriptor.width / .height / .bytesPerPixel。
    // 不是「值不准」,是直接抛异常:Web 版 painting.dart 里 encoded 描述符的
    // `_width` 恒为 null,getter 写成 `_width ?? _throw('width')`,
    // 于是对 ImageDescriptor.encoded(...) 取宽高会抛 UnsupportedError
    // (bytesPerPixel 在 Web 上无条件抛,连 raw 都不行)。
    // 原生端注释也写明这三个 getter「On the Web, this is only supported for
    // [raw] images.」。所以唯一可移植的做法是:先解一帧,读 ui.Image 的宽高。
    // Web 引擎自己的 instantiateImageCodecWithSize 就是这么两趟解码的,
    // 此处照抄其思路。谁想「优化」回 descriptor.width,Web 构建立刻炸。
    final ({int width, int height}) native = await _useFrame<
      ({int width, int height})
    >(descriptor, null, (ui.Image image) async {
      return (width: image.width, height: image.height);
    });

    // 源图已经够小:**原样返回原始字节**,绝不重编码。
    // 这是本文件最关键的一个坑:把一张 80 KiB 的 JPEG 重编码成 PNG,
    // 结果可能变成 600 KiB——「压缩」反而把图压爆了。
    // 只有确实超标的图才值得付出重编码的代价。
    if (source.length <= targetImageBytes) {
      return DownscaledImage(
        bytes: source,
        width: native.width,
        height: native.height,
      );
    }

    // 宽度下限还要再夹一次:原图可能本来就比 [_minWidth] 还窄
    // (比如一张 200px 宽、却因无损内容而巨大的 PNG)。
    // 必须自己夹住,因为放大行为两端不一致——原生 instantiateCodec 会老实放大,
    // Web 则硬编码 allowUpscaling: false,请求超过原宽会让两端结果分叉。
    final int floorWidth = native.width < _minWidth ? native.width : _minWidth;

    // 首轮宽度用「字节比」直接估出来,而不是从原宽开始等比退让。
    // 推导:PNG 字节数 ≈ 像素数,像素数 ≈ 宽度²,
    // 所以要把字节数压到 target/实际 这个比例,宽度只需乘 sqrt(该比例)。
    // 两个好处:一步就逼近目标(实测 1~2 轮收敛);
    // 且不必先花一次全尺寸编码去确认「果然超标」——那是纯浪费,
    // 一张 2400x1600 的 PNG 编码要 1 秒以上。
    //
    // 这只是**种子**,不是答案:PNG 压缩比取决于图像熵,
    // 平滑渐变与高频噪声在同样像素数下能差一个数量级,
    // 真正兜住误差的仍是后面的 [_stepFactor] 等比退让。
    final double ratio = targetImageBytes / source.length;
    final int seed = (native.width * math.sqrt(ratio)).floor();
    int attemptWidth = seed.clamp(floorWidth, native.width);
    DownscaledImage? last;

    for (int attempt = 0; attempt < _maxAttempts; attempt++) {
      last = await _encodePngAtWidth(descriptor, attemptWidth);
      if (last.bytes.length <= targetImageBytes) return last;

      // 已经踩在下限上还超标,再循环也只是重复同一次编码。
      if (attemptWidth <= floorWidth) break;

      // 倒数第二轮之后**直接跳到下限**,不再等比收缩。
      // 这是为了守住一条语义不变量:返回 null 必须意味着
      // 「连 [_minWidth] 都塞不进 [maxImageBytes]」。
      // 若纯靠等比退让,高熵图片可能耗尽 [_maxAttempts] 时仍停在下限之上,
      // 于是下限那一档根本没被试过就判了失败;
      // 实测中恰恰是下限能达标(2400px 噪声图 12.6 MiB → 320px 仅 234 KiB)。
      // 宁可牺牲这一步的尺寸精细度,也要保证下限确实被尝试过。
      final int stepped = attempt == _maxAttempts - 2
          ? floorWidth
          : (attemptWidth * _stepFactor).floor();
      attemptWidth = stepped < floorWidth ? floorWidth : stepped;
    }

    // 没达标,但只要没越过硬上限就仍然可发——聊胜于无。
    if (last != null && last.bytes.length <= maxImageBytes) return last;
    return null;
  } finally {
    // buffer 与 descriptor 必须**双双活过整个迭代循环**:
    // descriptor 只是 buffer 数据的别名,Web 上 buffer 一旦释放,
    // 后续 instantiateCodec 会抛 StateError('Object is disposed')。
    // 我们全程复用同一个 descriptor,所以两者都只在这里、只释放一次
    // (两个 dispose 都会在 debug 下对重复释放 assert,不可多调)。
    descriptor?.dispose();
    buffer.dispose();
  }
}

/// 只测量编码图片的像素尺寸,不做任何降采样;失败时返回 `null`。
///
/// 供 UI 在选图后立刻显示尺寸/比例占位用,避免为了一个数字跑完整条压缩流程。
Future<({int width, int height})?> measureEncodedImage(Uint8List source) async {
  if (source.isEmpty) return null;

  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
    source,
  );
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    // 同样绕开 descriptor.width/.height——它们在 Web 上对 encoded 描述符
    // 会抛 UnsupportedError,详见 [downscaleForChat] 里的长注释。
    return await _useFrame<({int width, int height})>(descriptor, null, (
      ui.Image image,
    ) async {
      return (width: image.width, height: image.height);
    });
  } on Object {
    // 这是一个「测量」工具,任何失败都退化为「不知道尺寸」,不向上抛。
    return null;
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}

/// 以 [targetWidth] 为目标宽度解一帧并编码成 PNG。
Future<DownscaledImage> _encodePngAtWidth(
  ui.ImageDescriptor descriptor,
  int targetWidth,
) {
  return _useFrame<DownscaledImage>(descriptor, targetWidth, (
    ui.Image image,
  ) async {
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (data == null) {
      throw const ImageDownscaleFailure('PNG 编码返回空数据');
    }
    // ByteData 可能是带偏移的视图,必须按 offset/length 取,不能用 asUint8List()。
    return DownscaledImage(
      bytes: Uint8List.fromList(
        Uint8List.view(data.buffer, data.offsetInBytes, data.lengthInBytes),
      ),
      width: image.width,
      height: image.height,
    );
  });
}

/// 解出第一帧交给 [body],并保证 [ui.Codec] 与 [ui.Image] 一定被释放。
///
/// [targetWidth] 传 `null` 表示按原生尺寸解码。**只传宽度**:
/// sky_engine 注明「If only one of targetWidth or targetHeight are specified,
/// the other dimension will be scaled according to the aspect ratio」,
/// 两端都已确认如此(原生在 painting.dart 内按 `~/` 取整,Web 在
/// `_engine/engine/image_decoder.dart` 里用 `.round()`)。
/// 高度务必交给引擎算:我们自己算不仅容易形变,而且**两端取整方式不同**,
/// 导出的高度可能差 1px——所以任何地方都不要断言高度精确相等。
///
/// 释放顺序按引擎语义而来:`Codec.getNextFrame` 的文档明确把 image 的所有权
/// 移交调用方,因此 frame.image 合法地「活得比 codec 久」,
/// codec 可以在拿到帧后立刻 dispose。但 `toByteData` 必须在 image.dispose()
/// **之前** await 完(原生是 assert,Web 直接抛 StateError)。
Future<T> _useFrame<T>(
  ui.ImageDescriptor descriptor,
  int? targetWidth,
  Future<T> Function(ui.Image image) body,
) async {
  final ui.Codec codec = await descriptor.instantiateCodec(
    targetWidth: targetWidth,
  );
  try {
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ui.Image image = frame.image;
    try {
      // 必须 await 完 body(内含 toByteData)才能 dispose,
      // 提前释放会让编码读到已回收的像素内存。
      return await body(image);
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

/// 建立编码描述符,把引擎的原始异常翻译成 [ImageDownscaleFailure]。
Future<ui.ImageDescriptor> _encodedDescriptor(ui.ImmutableBuffer buffer) async {
  try {
    return await ui.ImageDescriptor.encoded(buffer);
  } on Object catch (error, stackTrace) {
    Error.throwWithStackTrace(
      ImageDownscaleFailure('无法解析图片编码:$error'),
      stackTrace,
    );
  }
}
