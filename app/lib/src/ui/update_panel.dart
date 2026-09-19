/// 自动更新面板 —— 一个自包含、可直接挂进设置页的 Widget。
///
/// 设计纪律(设计.md §8.2):**不硬编码任何颜色/圆角/间距**,
/// 一律引用 `theme/tokens.dart` 与当前 ThemeData。
///
/// 用法(设置页里一行):
/// ```dart
/// const UpdatePanel(),
/// ```
library;

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../theme/tokens.dart';
import '../update/update_models.dart';
import '../update/update_service.dart';

/// 更新面板。
///
/// 默认自己创建并持有 [UpdateService];若外部已有实例(例如 main.dart 里
/// 启动时做过静默检查),可通过 [service] 传入复用,此时本 Widget 不负责销毁它。
class UpdatePanel extends StatefulWidget {
  const UpdatePanel({super.key, this.service, this.autoCheckOnOpen = false});

  /// 外部注入的服务实例(可选)。传入则复用,不传则内部自建。
  final UpdateService? service;

  /// 打开面板时是否顺带发起一次(受节流约束的)检查。
  final bool autoCheckOnOpen;

  @override
  State<UpdatePanel> createState() => _UpdatePanelState();
}

class _UpdatePanelState extends State<UpdatePanel> {
  late final UpdateService _service;
  late final bool _ownsService;

  /// null 表示还没读出来(界面显示省略号);读失败则置为空串走「未知」文案。
  String? _currentVersion;
  bool _autoCheck = true;

  @override
  void initState() {
    super.initState();
    _ownsService = widget.service == null;
    _service = widget.service ?? UpdateService();
    _service.addListener(_onServiceChanged);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final v = await _service.currentVersion();
      final auto = await _service.autoCheckEnabled();
      if (!mounted) return;
      setState(() {
        _currentVersion = v;
        _autoCheck = auto;
      });
      if (widget.autoCheckOnOpen) await _service.maybeAutoCheck();
    } catch (_) {
      if (mounted) setState(() => _currentVersion = '');
    }
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    if (_ownsService) _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = _service.state;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(LaresSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(theme),
            const SizedBox(height: LaresSpacing.sm),
            _statusLine(theme, state),
            if (state.info != null && state.stage != UpdateStage.upToDate) ...[
              const SizedBox(height: LaresSpacing.md),
              _releaseNotes(theme, state.info!),
            ],
            if (state.stage == UpdateStage.downloading) ...[
              const SizedBox(height: LaresSpacing.md),
              _progressBar(theme, state),
            ],
            if (state.stage == UpdateStage.readyToInstall) ...[
              const SizedBox(height: LaresSpacing.sm),
              _integrityLine(theme, state),
            ],
            const SizedBox(height: LaresSpacing.md),
            _actions(theme, state),
            const Divider(height: LaresSpacing.xl),
            _autoCheckToggle(theme),
          ],
        ),
      ),
    );
  }

  Widget _header(ThemeData theme) {
    final t = AppLocalizations.of(context);
    final v = _currentVersion;
    return Row(
      children: [
        Icon(
          Icons.system_update_alt_rounded,
          color: LaresColors.ember,
          size: 20,
        ),
        const SizedBox(width: LaresSpacing.sm),
        Text(t.updateTitle, style: theme.textTheme.titleLarge),
        const Spacer(),
        Text(
          v == null
              ? t.updateCurrentVersion('…')
              : (v.isEmpty
                  ? t.updateVersionUnknown
                  : t.updateCurrentVersion(v)),
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }

  Widget _statusLine(ThemeData theme, UpdateState state) {
    final t = AppLocalizations.of(context);
    final (text, color) = switch (state.stage) {
      UpdateStage.idle => (t.updateStatusIdle, null),
      UpdateStage.checking => (t.updateStatusChecking, null),
      UpdateStage.upToDate => (t.updateStatusUpToDate, LaresColors.statusFree),
      UpdateStage.available => (
          t.updateStatusAvailable(state.info?.latestDisplay ?? ''),
          LaresColors.ember,
        ),
      UpdateStage.downloading => (t.updateStatusDownloading, null),
      UpdateStage.readyToInstall => (
          t.updateStatusReady,
          LaresColors.statusFree,
        ),
      UpdateStage.failed => (
          // 失败原因一律走语义码翻译;state.reason 是中文调试文本,不上界面。
          state.failure == null
              ? t.updateStatusCheckFailed
              : _noticeText(t, state.failure!),
          theme.colorScheme.error,
        ),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state.isBusy)
          const Padding(
            padding: EdgeInsets.only(top: 2, right: LaresSpacing.sm),
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyLarge?.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  /// 语义码 -> 本地化文案。
  ///
  /// 这就是 l10n 规范里「模型只存标识,翻译查表放 UI 层」的那张表:服务层与
  /// 安装器拿不到 BuildContext,于是把 [UpdateNoticeCode] 传上来,在这里落地。
  String _noticeText(AppLocalizations t, UpdateFailure f) => switch (f.code) {
        // ── 检查 ──
        UpdateNoticeCode.unknownVersion =>
          t.updateErrUnknownVersion(f.text ?? ''),
        UpdateNoticeCode.rateLimited => f.number == null
            ? t.updateErrRateLimited
            : t.updateErrRateLimitedUntil(f.number!),
        UpdateNoticeCode.githubRefused =>
          t.updateErrGithubRefused(f.number ?? 0),
        UpdateNoticeCode.noReleases => t.updateErrNoReleases,
        UpdateNoticeCode.httpError => t.updateErrHttp(f.number ?? 0),
        UpdateNoticeCode.malformed => t.updateErrMalformed,
        UpdateNoticeCode.timeout => t.updateErrTimeout,
        UpdateNoticeCode.offline => t.updateErrOffline,

        // ── 下载 ──
        UpdateNoticeCode.noAsset => t.updateErrNoAsset,
        UpdateNoticeCode.downloadHttp =>
          t.updateErrDownloadHttp(f.number ?? 0),
        UpdateNoticeCode.sizeMismatch =>
          t.updateErrSizeMismatch(f.number ?? 0, f.number2 ?? 0),
        UpdateNoticeCode.checksum => t.updateErrChecksum,
        UpdateNoticeCode.downloadTimeout => t.updateErrDownloadTimeout,
        UpdateNoticeCode.downloadError =>
          t.updateErrDownloadFailed(f.text ?? ''),

        // ── 安装 ──
        UpdateNoticeCode.notDownloaded => t.updateErrNotDownloaded,
        // 兜底:未编码的原文(如 Web 侧实现)直接显示,不显示裸 key
        UpdateNoticeCode.installFailed =>
          f.text ?? t.updateErrInstallFailed,

        // ── Windows ──
        UpdateNoticeCode.winNoInstallDir => t.updateErrWinNoInstallDir,
        UpdateNoticeCode.winNotWritable => t.updateErrWinNotWritable,
        UpdateNoticeCode.winProbeFailed =>
          t.updateErrWinProbeFailed(f.text ?? ''),
        UpdateNoticeCode.winUnzipFailed =>
          t.updateErrWinUnzipFailed(f.text ?? ''),
        UpdateNoticeCode.winPackageInvalid =>
          t.updateErrWinPackageInvalid(f.text ?? ''),
        UpdateNoticeCode.winLaunchFailed =>
          t.updateErrWinLaunchFailed(f.text ?? ''),
        UpdateNoticeCode.winRestarting => t.updateWinRestarting,

        // ── Android ──
        UpdateNoticeCode.androidInstallerNotOpened =>
          t.updateErrAndroidInstallerNotOpened,
        UpdateNoticeCode.androidLaunchFailed =>
          t.updateErrAndroidLaunchFailed(f.text ?? ''),
        UpdateNoticeCode.androidInstallerOpened =>
          t.updateAndroidInstallerOpened,

        // ── macOS / iOS ──
        UpdateNoticeCode.macosDragToApps => t.updateMacosDragToApps,
        UpdateNoticeCode.iosNoSelfUpdate => t.updateErrIosNoSelfUpdate,
        UpdateNoticeCode.iosCannotInstall => t.updateErrIosCannotInstall,
      };

  /// 这条通知是否是「多步指引」——需要用弹窗承载,SnackBar 放不下。
  ///
  /// 按语义码判断,而不是数翻译后文本里的换行符:换行结构会随语言变化。
  bool _needsDialog(UpdateNoticeCode code) =>
      code == UpdateNoticeCode.macosDragToApps ||
      code == UpdateNoticeCode.androidInstallerOpened;

  /// 平台无法自助更新时的解释(iOS / Web / 缺包)。
  Widget? _platformNotice(ThemeData theme, UpdateInfo info) {
    final t = AppLocalizations.of(context);
    String? msg;
    if (info.platform == UpdatePlatform.ios) {
      msg = t.updateNoticeIos;
    } else if (info.platform == UpdatePlatform.web) {
      msg = t.updateNoticeWeb;
    } else if (!info.hasDownloadableAsset) {
      msg = t.updateNoticeNoAssetForPlatform;
    } else if (info.capability == UpdateCapability.downloadAndGuide) {
      msg = t.updateNoticeMacos;
    }
    if (msg == null) return null;

    return Container(
      margin: const EdgeInsets.only(top: LaresSpacing.sm),
      padding: const EdgeInsets.all(LaresSpacing.sm),
      decoration: BoxDecoration(
        color: LaresColors.emberSoft,
        borderRadius: BorderRadius.circular(LaresRadii.sm),
      ),
      child: Text(msg, style: theme.textTheme.bodyMedium),
    );
  }

  Widget _releaseNotes(ThemeData theme, UpdateInfo info) {
    final notice = _platformNotice(theme, info);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          info.release.name,
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: LaresSpacing.xs),
        // 纯文本渲染 release body —— 刻意不引入 markdown 依赖
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 180),
          padding: const EdgeInsets.all(LaresSpacing.sm),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(LaresRadii.sm),
            border: Border.all(color: theme.dividerTheme.color ?? Colors.transparent),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              info.release.body.trim().isEmpty
                  ? AppLocalizations.of(context).updateNoReleaseNotes
                  : info.release.body.trim(),
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ),
        ?notice,
      ],
    );
  }

  Widget _progressBar(ThemeData theme, UpdateState state) {
    final p = state.progress;
    final indeterminate = p <= 0 || p > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(LaresRadii.sm),
          child: LinearProgressIndicator(
            value: indeterminate ? null : p,
            minHeight: 6,
            backgroundColor: theme.dividerTheme.color,
            valueColor: const AlwaysStoppedAnimation(LaresColors.ember),
          ),
        ),
        const SizedBox(height: LaresSpacing.xs),
        Text(
          indeterminate
              ? AppLocalizations.of(context).updateDownloading
              : '${(p * 100).toStringAsFixed(0)}%',
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }

  /// 如实展示完整性级别 —— 不夸大。
  Widget _integrityLine(ThemeData theme, UpdateState state) {
    final t = AppLocalizations.of(context);
    final text = switch (state.integrity) {
      IntegrityLevel.sizeAndPublishedSha256 => t.updateIntegrityFull,
      IntegrityLevel.sizeOnly => t.updateIntegritySizeOnly,
      IntegrityLevel.none => t.updateIntegrityNone,
    };
    return Text(
      text,
      style: theme.textTheme.bodyMedium?.copyWith(fontSize: 12),
    );
  }

  Widget _actions(ThemeData theme, UpdateState state) {
    final t = AppLocalizations.of(context);
    final info = state.info;
    final buttons = <Widget>[
      OutlinedButton.icon(
        onPressed: state.isBusy ? null : () => _service.check(),
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: Text(t.updateCheckNow),
      ),
    ];

    // 下载:仅在本平台确实能自助更新时出现,且永远是用户点出来的
    if (state.stage == UpdateStage.available &&
        info != null &&
        info.canSelfUpdate) {
      buttons.add(
        FilledButton.icon(
          onPressed: () => _service.download(),
          icon: const Icon(Icons.download_rounded, size: 18),
          label: Text(_downloadLabel(t, info)),
        ),
      );
    }

    if (state.stage == UpdateStage.readyToInstall) {
      buttons.add(
        FilledButton.icon(
          onPressed: _confirmInstall,
          icon: const Icon(Icons.install_desktop_rounded, size: 18),
          label: Text(
            info?.capability == UpdateCapability.downloadAndGuide
                ? t.updateRevealFolder
                : t.updateInstallNow,
          ),
        ),
      );
    }

    return Wrap(
      spacing: LaresSpacing.sm,
      runSpacing: LaresSpacing.sm,
      children: buttons,
    );
  }

  String _downloadLabel(AppLocalizations t, UpdateInfo info) {
    final size = info.asset?.size ?? 0;
    if (size <= 0) return t.updateDownload;
    final mb = size / (1024 * 1024);
    return t.updateDownloadWithSize(mb.toStringAsFixed(1));
  }

  /// 安装永远是**显式确认**的动作 —— 绝不自动执行。
  Future<void> _confirmInstall() async {
    final t = AppLocalizations.of(context);
    final info = _service.state.info;
    final isRestart = info?.capability == UpdateCapability.downloadAndInstall &&
        info?.platform == UpdatePlatform.windows;

    if (isRestart) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t.updateInstallConfirmTitle),
          content: Text(t.updateInstallConfirmBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.updateLater),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.updateInstallAndRestart),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    final outcome = await _service.install();
    if (!mounted) return;

    // Windows:助手脚本已在后台等待,现在必须退出以释放 exe 的文件锁。
    if (outcome.ok && outcome.requiresQuit) {
      final quitMsg = outcome.guidance == null
          ? t.updateQuitting
          : _noticeText(t, parseUpdateNotice(outcome.guidance!));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(quitMsg)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      _service.quitForUpdate();
      return;
    }

    // 成功看 guidance、失败看 message;两者都是安装器编码过的语义码。
    final raw = outcome.ok ? outcome.guidance : outcome.message;
    final notice = raw == null ? null : parseUpdateNotice(raw);
    final text = notice == null
        ? (outcome.ok ? t.updateInstallStarted : t.updateErrInstallFailed)
        : _noticeText(t, notice);

    // 多步指引用弹窗承载(SnackBar 放不下);判断依据是语义码而非换行符,
    // 因为换行结构会随语言变化。
    if (notice != null && _needsDialog(notice.code)) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t.updateNextStepsTitle),
          content: SingleChildScrollView(child: Text(text)),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(t.updateGotIt),
            ),
          ],
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Widget _autoCheckToggle(ThemeData theme) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _autoCheck,
        activeThumbColor: LaresColors.ember,
        title: Text(
          AppLocalizations.of(context).updateAutoCheckTitle,
          style: theme.textTheme.bodyLarge,
        ),
        subtitle: Text(
          AppLocalizations.of(context).updateAutoCheckSubtitle,
          style: theme.textTheme.bodyMedium,
        ),
        onChanged: (v) async {
          setState(() => _autoCheck = v);
          await _service.setAutoCheckEnabled(v);
        },
      );
}
