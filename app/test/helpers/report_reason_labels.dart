/// 举报分类的中文显示名 —— 测试侧的**独立镜像**。
///
/// ## 为什么不直接调 lib 里的 reportReasonLabel
///
/// i18n 改造后,显示名查表搬到了 `lib/src/ui/moderation_menus.dart` 的
/// `reportReasonLabel(context, reason)`。测试里当然可以 `tester.element(...)`
/// 掏个 context 出来调它 —— 但那样断言就退化成了「函数等于它自己」:
/// 万一有人把 switch 里 `harassment` 和 `hateSpeech` 两行的返回值写串了,
/// 测试跟着一起串,照样全绿。
///
/// 这里改成从 ARB 生成的 zh 文案表**按键名逐条取**,和 lib 里那张 switch
/// 各走一条路。两边对不上时测试才会红 —— 这正是我们想抓的错。
/// 顺带一个好处:不需要 BuildContext,纯单元测试(文案护栏那几条)也能用。
///
/// switch 不写 default:往枚举里加一类时,编译器会指着这里要求补一行,
/// 而不是让某个分类悄悄漏出测试覆盖。
library;

import 'package:lares_app/l10n/gen/app_localizations.dart';
import 'package:lares_app/src/moderation/report.dart';

import 'localized_app.dart';

/// [reason] 在中文界面上显示的那行字。
String zhReasonLabel(ReportReason reason, {AppLocalizations? strings}) {
  final AppLocalizations t = strings ?? zhStrings();
  return switch (reason) {
    ReportReason.harassment => t.reportReasonHarassment,
    ReportReason.hateSpeech => t.reportReasonHateSpeech,
    ReportReason.sexualContent => t.reportReasonSexualContent,
    ReportReason.violence => t.reportReasonViolence,
    ReportReason.illegal => t.reportReasonIllegal,
    ReportReason.spam => t.reportReasonSpam,
    ReportReason.other => t.reportReasonOther,
  };
}

/// 七个分类的中文显示名,顺序同 `ReportReason.values`。
List<String> zhAllReasonLabels() {
  final AppLocalizations t = zhStrings();
  return <String>[
    for (final ReportReason r in ReportReason.values)
      zhReasonLabel(r, strings: t),
  ];
}
