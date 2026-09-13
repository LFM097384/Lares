/// 选图筛选器(`XTypeGroup`)的字段完整性护栏。
///
/// 这组用例是为一个**真实发生过的 bug** 立的墓碑:
/// `image_source_io.dart` 里的筛选器原先只写了 `extensions`,而
/// file_selector_ios(0.5.3+6)**只读 `uniformTypeIdentifiers`、
/// 完全无视 `extensions`**,校验不过就直接抛 `ArgumentError`。
/// 异常又被 `pickImage()` 的宽 catch 吞成 null,于是 iOS 上的表现是
/// 「选图按钮渲染正常、能点,点下去毫无反应,也没有任何错误提示」。
///
/// Windows 上跑 `flutter test` 永远测不到 iOS 的那条分支,所以只能用
/// **对常量本身的断言**来守:任何人把 `uniformTypeIdentifiers` 删掉、
/// 或者让三组字段失去同步,这里立刻就红。
///
/// 两个实现文件走的是条件导入(只会被导入其中一个),这里刻意用前缀
/// 同时导入两份,好顺便盯住它们不许分叉。
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/chat/image_source.dart' as web;
import 'package:lares_app/src/chat/image_source_io.dart' as io;

/// 各平台实现分别读哪组字段,决定了下面每条断言存在的理由:
///
///  - iOS            → 只读 uniformTypeIdentifiers
///  - macOS          → 三组都读(11 以下丢 mimeTypes)
///  - Windows        → 只读 extensions
///  - Linux/Android  → extensions + mimeTypes
///  - Web            → extensions + mimeTypes + webWildCards
void main() {
  group('imageTypeGroup 字段完整性', () {
    // 注意别把循环变量叫 group —— 会遮蔽 test 包的 group() 函数。
    for (final (String name, XTypeGroup tg) in <(String, XTypeGroup)>[
      ('原生端(image_source_io.dart)', io.imageTypeGroup),
      ('Web 端(image_source.dart)', web.imageTypeGroup),
    ]) {
      group(name, () {
        test('uniformTypeIdentifiers 非空(缺了 iOS 必抛 ArgumentError)', () {
          expect(
            tg.uniformTypeIdentifiers,
            isNotNull,
            reason: 'file_selector_ios 只读这个字段,为 null 时 iOS 选图必失败',
          );
          expect(tg.uniformTypeIdentifiers, isNotEmpty);
        });

        test('extensions 非空(Windows 只读这个字段)', () {
          expect(tg.extensions, isNotNull);
          expect(tg.extensions, isNotEmpty);
        });

        test('mimeTypes 非空(Linux / Android / Web 读这个字段)', () {
          expect(tg.mimeTypes, isNotNull);
          expect(tg.mimeTypes, isNotEmpty);
        });

        test('不是 allowsAny —— 筛选器要真的在筛', () {
          // allowsAny 为真会让 file_selector 放弃整份筛选,
          // 那就等于回到「什么文件都能选」,与本常量的意图相反。
          expect(tg.allowsAny, isFalse);
        });

        test('UTI 取值与 Apple UTType 常量逐一对齐', () {
          // 写错不会报错,只会安静地「那类图选不出来」——系统对不认识的
          // UTI 是忽略而非报错,所以只能在这里钉死。
          expect(
            tg.uniformTypeIdentifiers,
            containsAll(<String>[
              'public.png', // UTType.png
              'public.jpeg', // UTType.jpeg(jpg/jpeg 共用,没有 public.jpg)
              'com.compuserve.gif', // UTType.gif
              'org.webmproject.webp', // UTType.webP
              'com.microsoft.bmp', // UTType.bmp
            ]),
          );
        });

        test('不写 jpg 的 UTI —— Apple 没有 public.jpg 这个常量', () {
          expect(tg.uniformTypeIdentifiers, isNot(contains('public.jpg')));
        });

        test('六个扩展名与五个 MIME / UTI 一一对得上', () {
          // jpg 与 jpeg 是同一种格式,所以扩展名比 MIME/UTI 多一个。
          expect(tg.extensions, hasLength(6));
          expect(tg.mimeTypes, hasLength(5));
          expect(tg.uniformTypeIdentifiers, hasLength(5));
        });

        test('extensions 不带前导点,且与 mimeTypes 语义一致', () {
          expect(
            tg.extensions,
            containsAll(<String>['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp']),
          );
          expect(
            tg.mimeTypes,
            containsAll(<String>[
              'image/png',
              'image/jpeg',
              'image/gif',
              'image/webp',
              'image/bmp',
            ]),
          );
        });
      });
    }

    test('两端实现不许分叉', () {
      // 条件导入的两半是同一个接缝,字段一旦不同步,
      // 「Web 上好好的、原生上点不动」这类 bug 就会卷土重来。
      expect(
        io.imageTypeGroup.uniformTypeIdentifiers,
        web.imageTypeGroup.uniformTypeIdentifiers,
      );
      expect(io.imageTypeGroup.extensions, web.imageTypeGroup.extensions);
      expect(io.imageTypeGroup.mimeTypes, web.imageTypeGroup.mimeTypes);
    });

    test('构造该筛选器不抛(macUTIs 与 uniformTypeIdentifiers 不可同时给)', () {
      // XTypeGroup 的构造里有一条 assert 禁止同时传 macUTIs 和
      // uniformTypeIdentifiers。assert 只在 debug 生效,而测试正是 debug,
      // 所以这条能真的兜住误用。
      expect(() => io.imageTypeGroup.label, returnsNormally);
      expect(io.imageTypeGroup.label, '图片');
    });
  });
}
