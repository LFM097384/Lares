import '../rtc/rtc_service.dart';

/// 麦克风操作没成时给用户的一次性提示。
///
/// 模型层只存语义,文案在 UI 层查 ARB(见 docs/l10n-guide.md「模型只存语义 key」)。
enum MicNotice {
  /// 没有麦克风权限:要去系统设置里打开,App 内再点多少次都没用。
  permissionDenied,

  /// 想开麦没开成(设备被占用、采集启动失败、后台不允许启动录音……)。
  unmuteFailed,

  /// 想静音没静成 —— 麦克风**仍然开着**。罕见,但这是最不能瞒的一种。
  muteFailed;

  /// 开麦失败的原因 -> 提示。关麦失败不走这里(原因对用户不重要,重要的是「还开着」)。
  static MicNotice forUnmute(MicFailure? failure) =>
      failure == MicFailure.permissionDenied ? permissionDenied : unmuteFailed;
}
