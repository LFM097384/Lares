/// 把 [AnonymController] 挂在树上:房间页 / 「更多」按需取,
/// 不必沿 LaresApp → HomeScreen → RoomScreen 一路加构造参数。
/// 没挂(测试 / 老入口)时 [maybeOf] 返回 null,整套入口不显示。
library;

import 'package:flutter/widgets.dart';

import 'anonym_controller.dart';

class AnonymScope extends InheritedWidget {
  const AnonymScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final AnonymController controller;

  static AnonymController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AnonymScope>()?.controller;

  @override
  bool updateShouldNotify(AnonymScope old) => old.controller != controller;
}
