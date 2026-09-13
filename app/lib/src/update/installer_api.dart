/// 安装器的公共契约(接口 + 结果对象 + Web 兜底实现)。
///
/// 单独成文件是为了让条件导入的两半 —— `installer.dart`(Web)与
/// `installer_io.dart`(原生)—— 共享同一套类型,而不是各自重复声明。
library;

import 'update_models.dart';

/// 安装动作的结果。UI 只关心三件事:成功了吗、要不要展示指引、失败原因是什么。
class InstallOutcome {
  const InstallOutcome({
    required this.ok,
    this.message,
    this.guidance,
    this.revealedPath,
    this.requiresQuit = false,
  });

  const InstallOutcome.failure(String reason)
      : ok = false,
        message = reason,
        guidance = null,
        revealedPath = null,
        requiresQuit = false;

  /// 动作本身是否成功发起(Windows:助手脚本已启动;Android:安装器已拉起)。
  final bool ok;

  /// 失败原因(ok == false 时有值)。
  final String? message;

  /// 需要用户手动完成的步骤(macOS 引导替换、Android 未知来源授权等)。
  final String? guidance;

  /// 下载文件所在路径(用于「在文件夹中显示」)。
  final String? revealedPath;

  /// 是否需要 App **立即退出**,把文件锁让给外部助手进程。
  /// 只有 Windows 自替换会置 true。
  final bool requiresQuit;
}

/// 下载落盘目标。
///
/// 抽象出来的唯一原因:`update_service.dart` 必须能在 **Web** 上编译,
/// 所以它不能碰 `dart:io`,也不能直接调 `path_provider`(Web 不支持)。
/// 文件操作全部关在条件导入的原生侧。
abstract interface class DownloadTarget {
  /// 落盘完整路径。
  String get path;

  void add(List<int> chunk);

  /// 关闭写入流。
  Future<void> close();

  /// 删除已写入的文件(校验失败时清理)。
  Future<void> delete();
}

/// 平台安装器抽象。
abstract interface class UpdateInstaller {
  /// 本平台能做到什么程度。
  UpdateCapability get capability;

  /// 安装前的可行性自检(例如 Windows 检查安装目录是否可写)。
  /// 返回 null 表示没问题;返回字符串表示「不能自助更新」的原因。
  Future<String?> preflight();

  /// 执行安装。[filePath] 是已下载并做过完整性检查的文件。
  Future<InstallOutcome> install(String filePath);

  /// 当 [InstallOutcome.requiresQuit] 为 true 时,由 UI 在提示用户后调用,
  /// 结束本进程以释放文件锁。其他平台是空操作。
  void quitForUpdate();
}

/// Web 端:更新 = 刷新页面,没有可执行的安装动作。
/// 同时用作原生端遇到 unknown 平台时的兜底。
class WebInstaller implements UpdateInstaller {
  const WebInstaller();

  @override
  UpdateCapability get capability => UpdateCapability.notifyOnly;

  @override
  Future<String?> preflight() async =>
      'Web 版随服务端更新:强制刷新页面(Ctrl/Cmd + Shift + R)即可用上新版本。';

  @override
  Future<InstallOutcome> install(String filePath) async =>
      const InstallOutcome.failure('Web 版无需安装:刷新页面即可。');

  @override
  void quitForUpdate() {/* Web 无进程可退 */}
}
