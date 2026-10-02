import 'focus_service.dart';

/// Web / 无 dart:io:没有 window_manager。Web 的标签页失焦走生命周期 inactive/hidden。
FocusHostKind focusHostKind() => FocusHostKind.web;

/// 空操作。
void attachFocusWindowListener(FocusService focus) {}
