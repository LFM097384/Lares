/// 把 [PluginService] 挂在树上(同 TranscriptScope):圈子菜单 / 房间页按需取,
/// 不必沿 LaresApp → HomeScreen → RoomScreen 一路加参数。没挂时整块不显示。
library;

import 'package:flutter/widgets.dart';

import 'plugin_owner_section.dart';
import 'plugin_service.dart';

class PluginScope extends InheritedWidget {
  const PluginScope({
    super.key,
    required this.service,
    this.focusSettingsBuilder,
    required super.child,
  });

  final PluginService service;

  /// 专注学习设置页(lib/src/focus/ 注入);null = 通用 JSON 编辑器。
  final FocusSettingsBuilder? focusSettingsBuilder;

  static PluginScope? maybeScopeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PluginScope>();

  static PluginService? maybeOf(BuildContext context) =>
      maybeScopeOf(context)?.service;

  @override
  bool updateShouldNotify(PluginScope old) =>
      old.service != service ||
      old.focusSettingsBuilder != focusSettingsBuilder;
}
