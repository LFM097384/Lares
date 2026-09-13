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

  String _currentVersion = '…';
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
      if (mounted) setState(() => _currentVersion = '未知');
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

  Widget _header(ThemeData theme) => Row(
        children: [
          Icon(
            Icons.system_update_alt_rounded,
            color: LaresColors.ember,
            size: 20,
          ),
          const SizedBox(width: LaresSpacing.sm),
          Text('版本与更新', style: theme.textTheme.titleLarge),
          const Spacer(),
          Text('当前 v$_currentVersion', style: theme.textTheme.bodyMedium),
        ],
      );

  Widget _statusLine(ThemeData theme, UpdateState state) {
    final (text, color) = switch (state.stage) {
      UpdateStage.idle => ('还没检查过更新。', null),
      UpdateStage.checking => ('正在检查…', null),
      UpdateStage.upToDate => ('已是最新版本。', LaresColors.statusFree),
      UpdateStage.available => (
          '发现新版本 v${state.info?.latestDisplay ?? ''}',
          LaresColors.ember,
        ),
      UpdateStage.downloading => ('正在下载更新包…', null),
      UpdateStage.readyToInstall => ('下载完成,可以安装了。', LaresColors.statusFree),
      UpdateStage.failed => (state.reason ?? '检查失败。', theme.colorScheme.error),
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

  /// 平台无法自助更新时的解释(iOS / Web / 缺包)。
  Widget? _platformNotice(ThemeData theme, UpdateInfo info) {
    String? msg;
    if (info.platform == UpdatePlatform.ios) {
      msg = 'iOS 无法在 App 内更新。若用 TestFlight 安装,请到 TestFlight 更新;'
          '若是免费签名侧载,签名 7 天到期后需要用电脑重新侧载新版本 .ipa。';
    } else if (info.platform == UpdatePlatform.web) {
      msg = 'Web 版随服务端更新:强制刷新页面(Ctrl/Cmd + Shift + R)即可。';
    } else if (!info.hasDownloadableAsset) {
      msg = '这个版本没有为当前平台提供可下载的安装包,'
          '请到 GitHub Releases 页面手动获取。';
    } else if (info.capability == UpdateCapability.downloadAndGuide) {
      msg = 'macOS 需要你手动把新版本拖进「应用程序」完成替换,下载后会自动打开访达。';
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
                  ? '(这个版本没有写更新说明)'
                  : info.release.body.trim(),
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ),
        if (notice != null) notice,
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
          indeterminate ? '下载中…' : '${(p * 100).toStringAsFixed(0)}%',
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }

  /// 如实展示完整性级别 —— 不夸大。
  Widget _integrityLine(ThemeData theme, UpdateState state) {
    final text = switch (state.integrity) {
      IntegrityLevel.sizeAndPublishedSha256 =>
        '完整性:文件大小一致,且 SHA-256 与发布说明中公布的校验和匹配。',
      IntegrityLevel.sizeOnly =>
        '完整性:仅核对了文件大小与 GitHub 声明一致(发布说明未提供校验和,'
            '无法验证内容真伪;传输安全依赖 HTTPS)。',
      IntegrityLevel.none => '完整性:未能校验(发布信息未提供大小)。',
    };
    return Text(
      text,
      style: theme.textTheme.bodyMedium?.copyWith(fontSize: 12),
    );
  }

  Widget _actions(ThemeData theme, UpdateState state) {
    final info = state.info;
    final buttons = <Widget>[
      OutlinedButton.icon(
        onPressed: state.isBusy ? null : () => _service.check(),
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text('立即检查'),
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
          label: Text(_downloadLabel(info)),
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
                ? '打开所在文件夹'
                : '立即安装',
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

  String _downloadLabel(UpdateInfo info) {
    final size = info.asset?.size ?? 0;
    if (size <= 0) return '下载更新';
    final mb = size / (1024 * 1024);
    return '下载更新 (${mb.toStringAsFixed(1)} MB)';
  }

  /// 安装永远是**显式确认**的动作 —— 绝不自动执行。
  Future<void> _confirmInstall() async {
    final info = _service.state.info;
    final isRestart = info?.capability == UpdateCapability.downloadAndInstall &&
        info?.platform == UpdatePlatform.windows;

    if (isRestart) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('现在安装更新?'),
          content: const Text(
            'Lares 会关闭,替换程序文件后自动重新启动。\n'
            '如果你正在圈子里说话,会先断开连接。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('安装并重启'),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(outcome.guidance ?? '正在退出以完成更新…')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      _service.quitForUpdate();
      return;
    }

    final text = outcome.ok
        ? (outcome.guidance ?? '已开始安装。')
        : (outcome.message ?? '安装失败。');

    if (outcome.guidance != null && outcome.guidance!.contains('\n')) {
      // 多步指引(macOS)用弹窗,信息量大,SnackBar 放不下
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('接下来这样做'),
          content: SingleChildScrollView(child: Text(text)),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
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
        title: Text('启动时检查更新', style: theme.textTheme.bodyLarge),
        subtitle: Text(
          '静默检查,发现新版本才提示;安装永远需要你点确认。',
          style: theme.textTheme.bodyMedium,
        ),
        onChanged: (v) async {
          setState(() => _autoCheck = v);
          await _service.setAutoCheckEnabled(v);
        },
      );
}
