import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/l10n/gen/app_localizations.dart';
import 'package:lares_app/src/platform/widget_service.dart';

/// 主屏幕小组件的**跨语言契约**(设计.md §3.2-1)。
///
/// Dart 把数据写进共享存储,Swift(WidgetKit)与 Kotlin(AppWidgetProvider)
/// 再把它读出来。三侧之间只有一堆**字符串字面量**在对齐:键名、App Group、
/// Widget kind、深链。它们没有任何编译期联系 ——
/// 改了一侧忘了另一侧,不会编译失败、不会抛异常、日志里也一个字都没有,
/// 只会表现成「小组件永远不更新」或「点了没反应」,而这两种症状最难查。
///
/// 所以这一组测试直接去**磁盘上读原生源码**比对字面量。
/// Flutter 测试的 CWD 是包根目录(app/),所以相对路径能解析。
void main() {
  /// 读原生源码。文件读不到时**必须炸**,绝不能 skip 或静默放过:
  /// 一个永远通过的契约测试比没有测试更糟 —— 它给的是假的安全感。
  String readSource(String relativePath) {
    final file = File(relativePath);
    expect(
      file.existsSync(),
      isTrue,
      reason: '找不到 $relativePath —— 跨语言契约无从校验。'
          '文件可能被移动或删除了,请修正本测试里的路径,'
          '或确认这个原生实现是否真的还在。',
    );
    return file.readAsStringSync();
  }

  // 有意**写进去但从不读出来**的键。
  //
  // primary_circle_id 只是给原生侧留的诊断值:点按一律走 lares://join,
  // 目标圈子由 App 内解析,Widget 从不依赖这个 id。
  // 这里把豁免显式写出来,是为了让它是一个**被记录的决定**而不是一次疏忽 ——
  // 下面还会反过来断言它确实没被读,哪天有人开始读它,测试会立刻提醒
  // 「你该更新这份清单了」。
  const writeOnlyKeys = <String>{'primary_circle_id'};

  final readKeys =
      WidgetService.dataKeys.where((k) => !writeOnlyKeys.contains(k)).toList();

  group('主屏小组件跨语言契约:iOS(Swift)', () {
    const swiftPath = 'ios/LaresWidget/LaresWidget.swift';

    test('Dart 声明的每个键,Swift 侧都要有对应的 forKey: 读取', () {
      final swift = readSource(swiftPath);
      for (final key in readKeys) {
        expect(
          swift.contains('forKey: "$key"'),
          isTrue,
          reason: 'Dart 侧声明了 key `$key`,'
              '但 $swiftPath 里没有对应的 forKey: 读取 —— 两侧已经不同步。'
              '要么 Swift 侧漏读了这个键,要么 Dart 侧的 '
              'WidgetService.dataKeys 里多了一个已经废弃的键。',
        );
      }
    });

    test('primary_circle_id 是只写的:Swift 侧不该去读它', () {
      final swift = readSource(swiftPath);
      for (final key in writeOnlyKeys) {
        expect(
          swift.contains('forKey: "$key"'),
          isFalse,
          reason: '$swiftPath 开始读 `$key` 了,但它在设计上是只写的诊断值。'
              '如果这是有意为之,请把它从本测试的 writeOnlyKeys 豁免里移出来,'
              '让它回到正常的双侧校验中。',
        );
      }
    });

    test('App Group 必须与 Swift 侧逐字一致', () {
      final swift = readSource(swiftPath);
      expect(
        swift.contains(WidgetService.iosAppGroup),
        isTrue,
        reason: 'Dart 侧 App Group 是 `${WidgetService.iosAppGroup}`,'
            '但 $swiftPath 里找不到它 —— 两侧读写的不是同一块共享存储,'
            '小组件会永远显示默认文案。',
      );
    });

    test('Widget kind 必须与 StaticConfiguration(kind:) 一致', () {
      final swift = readSource(swiftPath);
      // kind 对不上时 reloadTimelines **静默什么都不做**:没有报错、
      // 没有日志、没有崩溃,只是小组件再也不更新 —— 正是最难查的那种故障。
      expect(
        swift.contains(
          'StaticConfiguration(kind: "${WidgetService.iosWidgetName}"',
        ),
        isTrue,
        reason: 'Dart 侧用 kind `${WidgetService.iosWidgetName}` 触发刷新,'
            '但 $swiftPath 的 StaticConfiguration(kind:) 不是这个值 —— '
            'WidgetCenter.reloadTimelines 会静默失效(找不到 kind 就什么都不做),'
            '症状是「小组件永远不更新」,且任何地方都不会报错。',
      );
    });

    test('点按深链必须与 Swift 的 .widgetURL 一致', () {
      final swift = readSource(swiftPath);
      expect(
        swift.contains(
          '.widgetURL(URL(string: "${WidgetService.joinDeepLink}"))',
        ),
        isTrue,
        reason: 'Dart 侧声明的深链是 `${WidgetService.joinDeepLink}`,'
            '但 $swiftPath 的 .widgetURL 不是这个值 —— 点小组件不会进主圈子。',
      );
    });
  });

  group('主屏小组件跨语言契约:Android(Kotlin)', () {
    const kotlinPath =
        'android/app/src/main/kotlin/com/example/lares_app/LaresWidgetProvider.kt';

    test('Dart 声明的每个键,Kotlin 侧都要有对应的读取', () {
      final kotlin = readSource(kotlinPath);
      for (final key in readKeys) {
        // Kotlin 侧按类型分成 getString / getBoolean 两种读法
        final read = kotlin.contains('getString("$key"') ||
            kotlin.contains('getBoolean("$key"');
        expect(
          read,
          isTrue,
          reason: 'Dart 侧声明了 key `$key`,'
              '但 $kotlinPath 里没有对应的 getString/getBoolean 读取 —— '
              '两侧已经不同步。',
        );
      }
    });

    test('primary_circle_id 是只写的:Kotlin 侧不该去读它', () {
      final kotlin = readSource(kotlinPath);
      for (final key in writeOnlyKeys) {
        final read = kotlin.contains('getString("$key"') ||
            kotlin.contains('getBoolean("$key"');
        expect(
          read,
          isFalse,
          reason: '$kotlinPath 开始读 `$key` 了,但它在设计上是只写的诊断值。'
              '如果这是有意为之,请把它从本测试的 writeOnlyKeys 豁免里移出来。',
        );
      }
    });

    test('点按深链必须与 Kotlin 的 Uri.parse 一致', () {
      final kotlin = readSource(kotlinPath);
      expect(
        kotlin.contains('Uri.parse("${WidgetService.joinDeepLink}")'),
        isTrue,
        reason: 'Dart 侧声明的深链是 `${WidgetService.joinDeepLink}`,'
            '但 $kotlinPath 的 Uri.parse 不是这个值 —— 点小组件不会进主圈子。',
      );
    });

    test('Provider 全限定类名必须与 Kotlin 的 package + 类名拼得起来', () {
      final kotlin = readSource(kotlinPath);
      final qualified = WidgetService.androidProviderClass;
      final lastDot = qualified.lastIndexOf('.');
      final package = qualified.substring(0, lastDot);
      final className = qualified.substring(lastDot + 1);
      expect(
        kotlin.contains('package $package'),
        isTrue,
        reason: 'Dart 侧用 `$qualified` 指定 Provider,'
            '但 $kotlinPath 的 package 不是 `$package` —— '
            'requestPinWidget / updateWidget 找不到这个组件。',
      );
      expect(
        kotlin.contains('class $className'),
        isTrue,
        reason: 'Dart 侧用 `$qualified` 指定 Provider,'
            '但 $kotlinPath 里没有 `class $className` —— 类名已经漂移。',
      );
    });
  });

  group('主屏小组件跨语言契约:App Group 与 URL scheme', () {
    // App Group 写错一个字符,Runner 与 Widget 就在读写两块不同的存储:
    // 不报错、不崩溃,只是数据永远传不过去。
    const appGroupFiles = <String>[
      'ios/Runner/Runner.entitlements',
      'ios/LaresWidget/LaresWidget.entitlements',
    ];

    for (final path in appGroupFiles) {
      test('$path 里的 App Group 必须与 Dart 侧逐字一致', () {
        final content = readSource(path);
        expect(
          content.contains(WidgetService.iosAppGroup),
          isTrue,
          reason: 'Dart 侧 App Group 是 `${WidgetService.iosAppGroup}`,'
              '但 $path 里找不到它 —— Runner 与 Widget 会读写两块不同的共享存储,'
              '数据永远传不过去,而且不会有任何报错。',
        );
      });
    }

    test('add_widget_target.rb 里的 APP_GROUP 必须与 Dart 侧逐字一致', () {
      // 这个脚本负责生成 Xcode target,它写错会让上面两个 entitlements
      // 在下次重新生成时被改回错误值 —— 所以它也必须纳入契约
      const path = 'ios/add_widget_target.rb';
      final ruby = readSource(path);
      expect(
        ruby.contains("APP_GROUP = '${WidgetService.iosAppGroup}'"),
        isTrue,
        reason: 'Dart 侧 App Group 是 `${WidgetService.iosAppGroup}`,'
            '但 $path 里的 APP_GROUP 不是这个值 —— '
            '下次用这个脚本重建 Widget target 时会把 entitlements 写回错的值。',
      );
    });

    test('Info.plist 必须注册深链的 scheme', () {
      const path = 'ios/Runner/Info.plist';
      final plist = readSource(path);
      final scheme = Uri.parse(WidgetService.joinDeepLink).scheme;
      expect(
        plist.contains('CFBundleURLSchemes'),
        isTrue,
        reason: '$path 里没有 CFBundleURLSchemes —— iOS 不会把任何深链交给 App。',
      );
      expect(
        plist.contains('<string>$scheme</string>'),
        isTrue,
        reason: '深链 `${WidgetService.joinDeepLink}` 的 scheme 是 `$scheme`,'
            '但 $path 的 CFBundleURLSchemes 里没有登记它 —— '
            '系统不会把这个 URL 路由给 App,点小组件不会有任何反应。',
      );
    });

    test('Dart 侧确实处理了深链的 join 分支', () {
      // 平台通道把 scheme 剥掉后交给 Dart 的是裸字符串 'join',
      // 所以这里比的是 joinDeepLink 的 host 部分,而不是完整 URL
      const path = 'lib/src/platform/widget_service.dart';
      final dart = readSource(path);
      final action = Uri.parse(WidgetService.joinDeepLink).host;
      expect(
        dart.contains("link == '$action'"),
        isTrue,
        reason: '深链是 `${WidgetService.joinDeepLink}`,'
            '但 $path 的 _handleLink 里没有 `link == \'$action\'` 这个分支 —— '
            '原生侧把深链送进来了,Dart 侧却不认识它。',
      );
    });
  });

  group('主屏小组件跨语言契约:文案', () {
    test('英文空状态文案必须与 Android 的 widget_presence_default 逐字一致', () {
      // 共享存储还没写过东西时(首次安装 / 进程被清),Android 显示的是
      // strings.xml 里的默认值;写过之后显示的是 Dart 推来的这一句。
      // 两者一旦不一样,小组件会在「装好」与「用过」之间莫名其妙地跳文案。
      final en = lookupAppLocalizations(const Locale('en'));
      final strings = readSource('android/app/src/main/res/values/strings.xml');
      expect(
        strings.contains(
          '<string name="widget_presence_default">${en.widgetNobodyHere}</string>',
        ),
        isTrue,
        reason: 'ARB 里 widgetNobodyHere(en)是 `${en.widgetNobodyHere}`,'
            '但 values/strings.xml 的 widget_presence_default 不是这一句 —— '
            '小组件在「刚装好」与「用过之后」会显示两种不同的空状态文案。',
      );
    });

    test('中文空状态文案必须与 values-zh 的 widget_presence_default 逐字一致', () {
      final zh = lookupAppLocalizations(const Locale('zh'));
      final strings =
          readSource('android/app/src/main/res/values-zh/strings.xml');
      expect(
        strings.contains(
          '<string name="widget_presence_default">${zh.widgetNobodyHere}</string>',
        ),
        isTrue,
        reason: 'ARB 里 widgetNobodyHere(zh)是 `${zh.widgetNobodyHere}`,'
            '但 values-zh/strings.xml 的 widget_presence_default 不是这一句。',
      );
    });
  });

  group('requestPin 的平台分支', () {
    test('桌面端返回 unavailable,且不碰任何 HomeWidget 接口', () async {
      // 测试跑在桌面(Windows/macOS/Linux)上。这里真正要证的是:
      // 非移动端这条分支**不会**去调 home_widget —— 它在桌面上没有插件实现,
      // 调了会抛 MissingPluginException。能正常拿到返回值就说明没调。
      expect(await WidgetService.requestPin(), PinWidgetOutcome.unavailable);
    });
  });

  group('主屏小组件跨语言契约:Dart 侧自洽', () {
    test('dataKeys 与 _syncPrimaryCircle 实际写入的键一一对应', () {
      // 契约测试全靠 dataKeys 这份清单。清单本身漏了一个键,
      // 上面所有断言都会跟着漏掉它,却依然全绿 —— 所以反过来校验一次:
      // 源码里出现的每个 saveWidgetData 键名,都必须在清单里。
      final dart = readSource('lib/src/platform/widget_service.dart');
      final written = RegExp(r"saveWidgetData<[^>]+>\('([^']+)'")
          .allMatches(dart)
          .map((m) => m.group(1)!)
          .toSet();

      expect(
        written,
        isNotEmpty,
        reason: '在 widget_service.dart 里一个 saveWidgetData 调用都没匹配到 —— '
            '写法可能变了,本测试的正则需要跟着更新,否则它会变成一个永远通过的空壳。',
      );
      expect(
        written.difference(WidgetService.dataKeys.toSet()),
        isEmpty,
        reason: '_syncPrimaryCircle 写了 WidgetService.dataKeys 里没有的键 —— '
            '这个键不会被任何跨语言校验覆盖到,请把它补进 dataKeys。',
      );
      expect(
        WidgetService.dataKeys.toSet().difference(written),
        isEmpty,
        reason: 'WidgetService.dataKeys 里声明的键没有被 _syncPrimaryCircle 写出 —— '
            '清单里留着一个废弃的键,会让原生侧被要求读一个永远不存在的值。',
      );
    });
  });
}
