/// 原生端安装器(Windows / Android / macOS / iOS)。
///
/// 经条件导入替换 `installer.dart` 的 Web 版实现;两边导出同名的
/// [createInstaller] / [readDeviceAbis],调用方无需感知平台。
library;

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'installer_api.dart';
import 'update_models.dart';
import 'update_service.dart' show UpdateNoticeCode, encodeInstallerNotice;

export 'installer_api.dart';

/// 原生端落盘:写进系统临时目录。
Future<DownloadTarget> openDownloadTarget(String fileName) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  if (file.existsSync()) file.deleteSync();
  return _FileDownloadTarget(file);
}

class _FileDownloadTarget implements DownloadTarget {
  _FileDownloadTarget(this._file) : _sink = _file.openWrite();

  final File _file;
  final IOSink _sink;

  @override
  String get path => _file.path;

  @override
  void add(List<int> chunk) => _sink.add(chunk);

  @override
  Future<void> close() async {
    await _sink.flush();
    await _sink.close();
  }

  @override
  Future<void> delete() async {
    try {
      if (await _file.exists()) await _file.delete();
    } catch (e) {
      debugPrint('[update] 删除下载文件失败: $e');
    }
  }
}

/// 原生端工厂:按平台给出对应安装器。
UpdateInstaller createInstaller(UpdatePlatform platform) {
  switch (platform) {
    case UpdatePlatform.windows:
      return WindowsInstaller();
    case UpdatePlatform.android:
      return AndroidInstaller();
    case UpdatePlatform.macos:
      return MacOsInstaller();
    case UpdatePlatform.ios:
      return const IosInstaller();
    case UpdatePlatform.web:
    case UpdatePlatform.unknown:
      return const WebInstaller();
  }
}

/// 读取设备真实 ABI(只有 Android 有意义)。
/// 失败返回空表 —— 调用方会因此拒绝盲猜 APK,而不是装错包。
Future<List<String>> readDeviceAbis() async {
  if (!Platform.isAndroid) return const [];
  try {
    final info = await DeviceInfoPlugin().androidInfo;
    return info.supportedAbis
        .where((e) => e.trim().isNotEmpty)
        .toList(growable: false);
  } catch (e) {
    debugPrint('[update] 读取设备 ABI 失败: $e');
    return const [];
  }
}

// ─────────────────────────── Windows ───────────────────────────

/// Windows 自替换更新。
///
/// ## 为什么需要助手脚本
/// 运行中的 `lares_app.exe` 被系统加了写锁,进程自己无法覆盖自己。
/// 业界标准解法是「外部代理」:App 生成一个脚本 -> 脱离父进程启动它 ->
/// App 主动退出 -> 脚本等锁释放后替换文件 -> 脚本重新拉起 App。
///
/// ## 本实现的确切步骤
/// 1. `preflight()`:探测安装目录**可写性**(实际写一个临时文件再删),
///    Program Files 无提权时会失败,此时直接告知用户手动更新,不做无用下载。
/// 2. 把下载好的 zip 交给 [install]。
/// 3. 用 `Expand-Archive` 把 zip 解到 `<temp>\lares_update_<pid>\new\`。
///    ——刻意用 PowerShell 而非 Dart 的 archive 包:少一个依赖,且解压由系统
///    组件完成,行为与 CI 的 `Compress-Archive` 对称。
/// 4. 解压后**校验产物**:必须存在 `lares_app.exe`,否则判定包损坏并中止
///    (此时旧版本一个字节都没动)。
/// 5. 生成 `apply_update.ps1` 并以分离进程启动,随后 App `exit(0)`。
/// 6. 脚本:等旧进程退出 -> 备份当前安装目录 -> 复制新文件覆盖 ->
///    重新启动 exe -> 删除自身与临时目录。复制失败则从备份回滚。
class WindowsInstaller implements UpdateInstaller {
  WindowsInstaller();

  @override
  UpdateCapability get capability => UpdateCapability.downloadAndInstall;

  /// 当前安装目录(exe 所在目录)。
  Directory get installDir => File(Platform.resolvedExecutable).parent;

  @override
  Future<String?> preflight() async {
    try {
      final dir = installDir;
      if (!dir.existsSync()) {
        return encodeInstallerNotice(
          UpdateNoticeCode.winNoInstallDir,
          '找不到安装目录,请手动下载新版本覆盖安装。',
        );
      }
      // 真写一次:比对比路径字符串(Program Files)可靠得多,
      // 因为用户可能装在任意目录,也可能以管理员身份运行。
      final probe = File(
        '${dir.path}${Platform.pathSeparator}.lares_write_probe',
      );
      try {
        probe.writeAsStringSync('ok', flush: true);
      } finally {
        if (probe.existsSync()) {
          try {
            probe.deleteSync();
          } catch (_) {/* 探针删不掉不影响判断 */}
        }
      }
      return null;
    } on FileSystemException {
      return encodeInstallerNotice(
        UpdateNoticeCode.winNotWritable,
        '安装目录不可写(通常是装在 Program Files 且未以管理员身份运行)。'
        '请手动下载新版本,或把 Lares 移到用户目录后再试。',
      );
    } catch (e) {
      return encodeInstallerNotice(
        UpdateNoticeCode.winProbeFailed,
        '无法确认安装目录是否可写:$e',
        arg: '$e',
      );
    }
  }

  @override
  Future<InstallOutcome> install(String zipPath) async {
    final blocker = await preflight();
    if (blocker != null) return InstallOutcome.failure(blocker);

    try {
      final target = installDir;
      final exeName = File(Platform.resolvedExecutable).uri.pathSegments.last;
      final work = Directory(
        '${Directory.systemTemp.path}\\lares_update_$pid',
      );
      if (work.existsSync()) work.deleteSync(recursive: true);
      work.createSync(recursive: true);
      final extractDir = Directory('${work.path}\\new');

      // 3) 解压
      final unzip = await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        "Expand-Archive -LiteralPath '${_esc(zipPath)}' "
            "-DestinationPath '${_esc(extractDir.path)}' -Force",
      ]);
      if (unzip.exitCode != 0) {
        return InstallOutcome.failure(encodeInstallerNotice(
          UpdateNoticeCode.winUnzipFailed,
          '更新包解压失败:${unzip.stderr}',
          arg: '${unzip.stderr}',
        ));
      }

      // 4) 校验:必须解出可执行文件,否则包是坏的,立即中止(不动旧版本)
      final root = _findPayloadRoot(extractDir, exeName);
      if (root == null) {
        return InstallOutcome.failure(encodeInstallerNotice(
          UpdateNoticeCode.winPackageInvalid,
          '更新包内容异常(未找到 $exeName),已中止,当前版本未被改动。',
          arg: exeName,
        ));
      }

      // 5) 写助手脚本并脱离启动
      final script = File('${work.path}\\apply_update.ps1');
      script.writeAsStringSync(
        _applyScript(
          pid: pid,
          sourceDir: root.path,
          targetDir: target.path,
          exePath: Platform.resolvedExecutable,
          workDir: work.path,
        ),
        flush: true,
      );

      await Process.start(
        'powershell',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          script.path,
        ],
        mode: ProcessStartMode.detached, // 关键:父进程退出后脚本继续活着
      );

      return InstallOutcome(
        ok: true,
        requiresQuit: true,
        guidance: encodeInstallerNotice(
          UpdateNoticeCode.winRestarting,
          '即将退出并完成更新,几秒后会自动重新启动。',
        ),
      );
    } catch (e) {
      return InstallOutcome.failure(encodeInstallerNotice(
        UpdateNoticeCode.winLaunchFailed,
        '安装启动失败:$e',
        arg: '$e',
      ));
    }
  }

  /// 退出 App,把文件锁让给助手脚本。UI 在收到 ok 后调用。
  @override
  void quitForUpdate() => exit(0);

  /// zip 里可能是「平铺」也可能多包一层目录,两种都认。
  static Directory? _findPayloadRoot(Directory extractDir, String exeName) {
    if (!extractDir.existsSync()) return null;
    if (File('${extractDir.path}\\$exeName').existsSync()) return extractDir;
    for (final entity in extractDir.listSync()) {
      if (entity is Directory &&
          File('${entity.path}\\$exeName').existsSync()) {
        return entity;
      }
    }
    return null;
  }

  static String _esc(String s) => s.replaceAll("'", "''");

  /// 助手脚本正文。带备份回滚,失败时尽力把用户留在一个能启动的状态。
  static String _applyScript({
    required int pid,
    required String sourceDir,
    required String targetDir,
    required String exePath,
    required String workDir,
  }) {
    return '''
# Lares 自动更新助手(由 App 生成,完成后自删)
\$ErrorActionPreference = 'Stop'
\$log = Join-Path '${_esc(workDir)}' 'update.log'
function Log(\$m) { "\$(Get-Date -Format o)  \$m" | Out-File -FilePath \$log -Append -Encoding utf8 }

try {
  Log '等待旧进程退出 (pid $pid)'
  try { Wait-Process -Id $pid -Timeout 30 -ErrorAction Stop } catch { Log "等待超时或进程已退出: \$_" }
  Start-Sleep -Milliseconds 800   # 给文件句柄释放留余量

  \$src = '${_esc(sourceDir)}'
  \$dst = '${_esc(targetDir)}'
  \$backup = Join-Path '${_esc(workDir)}' 'backup'

  Log "备份当前版本 -> \$backup"
  New-Item -ItemType Directory -Force -Path \$backup | Out-Null
  Copy-Item -Path (Join-Path \$dst '*') -Destination \$backup -Recurse -Force -ErrorAction SilentlyContinue

  try {
    Log "覆盖安装 \$src -> \$dst"
    Copy-Item -Path (Join-Path \$src '*') -Destination \$dst -Recurse -Force
    Log '覆盖完成'
  } catch {
    Log "覆盖失败,回滚: \$_"
    try {
      Copy-Item -Path (Join-Path \$backup '*') -Destination \$dst -Recurse -Force
      Log '回滚完成'
    } catch { Log "回滚也失败了: \$_" }
  }

  Log '重新启动 App'
  Start-Process -FilePath '${_esc(exePath)}'
} catch {
  Log "助手脚本异常: \$_"
  try { Start-Process -FilePath '${_esc(exePath)}' } catch { }
} finally {
  # 清理临时目录(含脚本自身);删不掉就留给系统临时目录清理
  Start-Sleep -Seconds 2
  try { Remove-Item -LiteralPath '${_esc(workDir)}' -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
''';
  }
}

// ─────────────────────────── Android ───────────────────────────

/// Android:下载 APK 后拉起系统包安装器。
///
/// 真正的 Intent 构造在 Kotlin 侧([LaresUpdateInstaller]),因为需要
/// `FileProvider.getUriForFile` + `FLAG_GRANT_READ_URI_PERMISSION`,
/// 这些没法从 Dart 侧完成。
class AndroidInstaller implements UpdateInstaller {
  AndroidInstaller();

  static const _channel = MethodChannel('lares/update');

  @override
  UpdateCapability get capability => UpdateCapability.downloadAndInstall;

  @override
  Future<String?> preflight() async => null;

  @override
  Future<InstallOutcome> install(String apkPath) async {
    try {
      final ok = await _channel.invokeMethod<bool>('installApk', {
        'path': apkPath,
      });
      if (ok == true) {
        return InstallOutcome(
          ok: true,
          guidance: encodeInstallerNotice(
            UpdateNoticeCode.androidInstallerOpened,
            '系统安装器已打开。若提示「禁止安装未知应用」,'
            '请在弹出的设置里允许「Lares 炉灵」安装应用后重试。',
          ),
        );
      }
      return InstallOutcome.failure(encodeInstallerNotice(
        UpdateNoticeCode.androidInstallerNotOpened,
        '系统安装器未能打开。',
      ));
    } on PlatformException catch (e) {
      final detail = e.message ?? e.code;
      return InstallOutcome.failure(encodeInstallerNotice(
        UpdateNoticeCode.androidLaunchFailed,
        '拉起安装器失败:$detail',
        arg: detail,
      ));
    } catch (e) {
      return InstallOutcome.failure(encodeInstallerNotice(
        UpdateNoticeCode.androidLaunchFailed,
        '拉起安装器失败:$e',
        arg: '$e',
      ));
    }
  }

  @override
  void quitForUpdate() {/* Android 由系统安装器接管,App 不需要退出 */}
}

// ─────────────────────────── macOS ───────────────────────────

/// macOS:不做自替换。
///
/// 理由(也是给 reviewer 的交代):产物是**未签名/未公证**的 .app zip,
/// Gatekeeper + 沙箱下自替换极易半路失败并留下坏掉的 App。这里只做
/// 「解压 + 在访达中显示 + 给出三步指引」,把最后一步交给用户,可靠得多。
class MacOsInstaller implements UpdateInstaller {
  MacOsInstaller();

  @override
  UpdateCapability get capability => UpdateCapability.downloadAndGuide;

  @override
  Future<String?> preflight() async => null;

  @override
  Future<InstallOutcome> install(String zipPath) async {
    var revealPath = zipPath;
    try {
      // 尽力解压到同目录,用户直接拖 .app 即可;失败就退回到 zip 本身。
      final outDir = File(zipPath).parent.path;
      final r = await Process.run('/usr/bin/ditto', [
        '-x',
        '-k',
        zipPath,
        outDir,
      ]);
      if (r.exitCode == 0) {
        final app = Directory(outDir)
            .listSync()
            .whereType<Directory>()
            .where((d) => d.path.endsWith('.app'))
            .firstOrNull;
        if (app != null) revealPath = app.path;
      }
      await Process.run('/usr/bin/open', ['-R', revealPath]);
    } catch (e) {
      debugPrint('[update] macOS 揭示文件失败: $e');
    }

    return InstallOutcome(
      ok: true,
      revealedPath: revealPath,
      guidance: encodeInstallerNotice(
        UpdateNoticeCode.macosDragToApps,
        // 多步指引:UI 依据语义码决定用弹窗承载(不再靠数换行符判断)
        '已在访达中为你打开新版本:\n'
        '1. 退出正在运行的 Lares;\n'
        '2. 把新的 lares_app.app 拖进「应用程序」,选择替换;\n'
        '3. 首次打开若提示「无法验证开发者」,右键点图标选「打开」。',
      ),
    );
  }

  @override
  void quitForUpdate() {/* macOS 由用户手动替换,不自动退出 */}
}

// ─────────────────────────── iOS ───────────────────────────

/// iOS:**不可能**自助更新。免费签名侧载 7 天过期,重签需要电脑;
/// TestFlight 则由 App Store 流程接管。这里只负责把话说清楚。
class IosInstaller implements UpdateInstaller {
  const IosInstaller();

  @override
  UpdateCapability get capability => UpdateCapability.notifyOnly;

  @override
  Future<String?> preflight() async => encodeInstallerNotice(
        UpdateNoticeCode.iosNoSelfUpdate,
        'iOS 无法在 App 内自我更新:请通过 TestFlight 更新,'
        '或用电脑重新侧载新版本 .ipa。',
      );

  @override
  Future<InstallOutcome> install(String filePath) async =>
      InstallOutcome.failure(encodeInstallerNotice(
        UpdateNoticeCode.iosCannotInstall,
        'iOS 无法在 App 内安装更新包。',
      ));

  @override
  void quitForUpdate() {/* iOS 不允许 App 自行退出 */}
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
