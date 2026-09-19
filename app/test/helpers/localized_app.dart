/// 测试用的本地化 App 外壳。
///
/// ## 为什么需要它
///
/// i18n 改造之后,`lib/src/` 下的 widget 普遍走 `AppLocalizations.of(context)`,
/// 而那个方法内部是 `Localizations.of<AppLocalizations>(...)!` —— 带感叹号。
/// 测试里 pump 一个裸 `MaterialApp`(不配 `localizationsDelegates`)时,
/// 查不到 delegate 就返回 null,感叹号当场炸成
/// 「Null check operator used on a null value」,而且报在 widget build 里,
/// 堆栈几百帧,看不出真实原因是「测试外壳少配了东西」。
///
/// 所以本文件只做一件事:**保证测试里的 App 外壳跟 `main.dart` 配得一样齐。**
/// 22 处 pump 点各写各的 `MaterialApp(...)` 是漂移源头 —— 以后再加一个
/// delegate(比如接第三种语言),只改这里一处。
///
/// ## 为什么默认锁 zh
///
/// 现存断言写的都是中文原文(`find.text('房间里还空着,坐一会儿?')`)。
/// 锁 zh 是为了让这批测试**继续验证它们本来验证的东西** ——
/// 语言不是这些用例的被测对象,渲染/交互才是。
/// 真要测多语言,显式传 `locale: Locale('en')`,别改默认值。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/l10n/gen/app_localizations.dart';
// 直接引 zh 实现类:app_localizations.dart 只 import 了它,没有 export。
import 'package:lares_app/l10n/gen/app_localizations_zh.dart';

/// 带齐本地化 delegates 的 `MaterialApp`,[home] 原样放进 `home:`。
///
/// 给「原本就自己搭了 home(常常是整屏 widget,如 `RoomScreen`)」的用例用:
/// 把原来的 `MaterialApp(theme: ..., home: X)` 换成 `localizedApp(X, theme: ...)`
/// 即可,其余不动。
///
/// [theme] 刻意不给默认值:传 null 就是 Material 默认主题,跟改造前
/// 「没写 theme」的那些用例保持逐字一致的行为 —— 顺手塞个深色主题进去,
/// 会悄悄改变颜色/对比度,踩到按主题取色的断言。
Widget localizedApp(
  Widget home, {
  Locale locale = const Locale('zh'),
  ThemeData? theme,
}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: theme,
    home: home,
  );
}

/// 同上,但额外把 [body] 套进 `Scaffold`。
///
/// 单独留一个函数而不是给 [localizedApp] 加 `wrapInScaffold` 开关,
/// 是因为调用点读起来能直接看出有没有 Scaffold ——
/// 而有没有 Scaffold 会影响 `SnackBar`、`showModalBottomSheet`、
/// `Material` 祖先查找这些行为,不该藏在一个 bool 里。
Widget localizedScaffold(
  Widget body, {
  Locale locale = const Locale('zh'),
  ThemeData? theme,
}) {
  return localizedApp(
    Scaffold(body: body),
    locale: locale,
    theme: theme,
  );
}

/// `pumpWidget(localizedScaffold(...))` 的简写。
///
/// 给「只想把一个光秃秃的 widget 挂起来看」的用例用,省掉两层嵌套。
/// 需要自定 home 结构(比如自己套 `ListView`、`MediaQuery`)时,
/// 还是直接 `pumpWidget(localizedApp(...))`,别硬塞进这个便捷函数。
Future<void> pumpLocalized(
  WidgetTester tester,
  Widget body, {
  Locale locale = const Locale('zh'),
  ThemeData? theme,
}) {
  return tester.pumpWidget(
    localizedScaffold(body, locale: locale, theme: theme),
  );
}

/// 不经过 widget 树、直接拿一份中文文案表。
///
/// 给**纯单元测试**用:有些断言是文案本身的护栏
/// (每个举报分类都有非空中文名、用户可见文案里不许出现某些词),
/// 这类断言不需要渲染,为它们 pump 一棵树纯属浪费,
/// 还会把一个 `test` 无端改成 `testWidgets`。
///
/// 生成出来的 `AppLocalizationsZh` 构造函数是公开的且默认 locale 就是 zh,
/// 所以这里不需要 context,也不需要跑 delegate 的异步 load。
AppLocalizations zhStrings() => AppLocalizationsZh();
