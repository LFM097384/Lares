/// 设置页底部的版本号 —— 也是开发者模式的解锁入口。
///
/// 为什么版本号要单独成一个 widget:它同时承担两件事(展示 + 连点解锁),
/// 而 settings_sheet.dart 是多人在改的文件,把这段自包含逻辑摘出来能少一点冲突。
///
/// 设计纪律(设计.md §8.2):不硬编码颜色/圆角/间距,一律引用 tokens.dart。
library;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../l10n/gen/app_localizations.dart';
import '../state/dev_mode_store.dart';
import '../theme/tokens.dart';

/// 版本号读取器的类型。默认走 [PackageInfo.fromPlatform];
/// 测试里注入一个假的,免得依赖平台通道。
typedef VersionReader = Future<String> Function();

/// 设置页最底下那行版本号,形如「炉灵 v0.1.1 (2)」/「Lares Circle v0.1.1 (2)」。
/// App 名取自 ARB 的 appTitle,随语言变。
///
/// 连点 [DevModeStore.unlockTaps] 次解锁开发者模式。不传 [devMode] 时它
/// 就只是一行普通的版本号 —— 点不出任何东西。
class VersionFooter extends StatefulWidget {
  const VersionFooter({super.key, this.devMode, this.versionReader});

  /// 开发者模式状态;为 null 时版本号不可解锁(纯展示)。
  final DevModeStore? devMode;

  /// 版本号读取器(测试注入用);不传则读真实包信息。
  final VersionReader? versionReader;

  @override
  State<VersionFooter> createState() => _VersionFooterState();
}

class _VersionFooterState extends State<VersionFooter> {
  /// 还没读到包信息时显示的占位。读失败也停在这里 ——
  /// 一行版本号读不出来不是值得打扰用户的事,静默降级即可。
  String _version = '…';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final reader = widget.versionReader ?? _defaultVersionReader;
      final v = await reader();
      if (mounted) setState(() => _version = v);
    } catch (_) {
      if (mounted) setState(() => _version = '未知');
    }
  }

  static Future<String> _defaultVersionReader() async {
    final info = await PackageInfo.fromPlatform();
    // 与更新面板的口径保持一致:version 是 0.1.1,buildNumber 是 +2 那部分。
    // 这里连 buildNumber 一起显示 —— 排查问题时「装的是哪个构建」比
    // 「哪个版本」更有用,而这行字正是用来报给开发者的。
    final build = info.buildNumber;
    return build.isEmpty ? info.version : '${info.version} ($build)';
  }

  void _onTap() {
    final devMode = widget.devMode;
    if (devMode == null) return;

    final messenger = ScaffoldMessenger.of(context);
    final justUnlocked = devMode.registerTap();

    if (justUnlocked) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('开发者模式已开启')),
        );
      return;
    }

    // 已经开着就别再提示了 —— 否则每点一下版本号都会弹一次,很烦。
    if (devMode.enabled) return;

    // 快到了才出声。前几下完全安静,保持「彩蛋」的质感,
    // 也避免误触时莫名其妙地弹提示。
    final left = devMode.tapsRemaining;
    if (left > 0 && left <= 3) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text('再点 $left 次就打开开发者模式'),
            duration: const Duration(milliseconds: 900),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final devMode = widget.devMode;

    final label = Text(
      '${AppLocalizations.of(context).appTitle} v$_version',
      textAlign: TextAlign.center,
      style: theme.textTheme.bodyMedium,
    );

    return Padding(
      padding: const EdgeInsets.only(
        top: LaresSpacing.lg,
        bottom: LaresSpacing.md,
      ),
      child: Center(
        child: devMode == null
            ? label
            : InkWell(
                onTap: _onTap,
                borderRadius: BorderRadius.circular(LaresRadii.sm),
                // 连点解锁是个彩蛋:不给视觉提示,但要给足够大的热区,
                // 否则连点 7 次的过程中很容易点空。
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LaresSpacing.lg,
                    vertical: LaresSpacing.sm,
                  ),
                  child: label,
                ),
              ),
      ),
    );
  }
}
