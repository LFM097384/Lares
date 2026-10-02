import 'package:window_manager/window_manager.dart';

import '../platform/platform_info_io.dart';
import 'focus_service.dart';

FocusHostKind focusHostKind() =>
    PlatformInfo.isDesktop ? FocusHostKind.desktop : FocusHostKind.mobile;

/// 桌面:窗口失焦算离开(切去别的窗口刷网页,生命周期是看不出来的)。
/// 与 App 同生命周期,不移除。
void attachFocusWindowListener(FocusService focus) {
  if (!PlatformInfo.isDesktop) return;
  windowManager.addListener(_FocusWindowListener(focus));
}

class _FocusWindowListener with WindowListener {
  _FocusWindowListener(this.focus);
  final FocusService focus;

  @override
  void onWindowBlur() => focus.onWindowFocus(false);

  @override
  void onWindowFocus() => focus.onWindowFocus(true);
}
