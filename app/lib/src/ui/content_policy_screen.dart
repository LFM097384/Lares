import 'package:flutter/material.dart';

import '../moderation/consent_store.dart';
import '../moderation/content_policy_text.dart';
import '../moderation/report.dart' show kSupportEmail;
import '../theme/tokens.dart';

/// 「我已经读完」勾选框的文案。刻意与同意按钮分开 ——
/// 读完是一个动作,同意是另一个动作,合成一步就不再是明确的肯定动作。
const String _kReadConfirmLabel = '我已经读完上面的内容';

/// 内容规范页。首次启动的同意门和设置里的「再看一遍」共用这一个页面。
///
/// 审核指南 1.2 要的是**明确的肯定动作**(affirmative action),
/// 所以这里做成两步:读完 → 勾选 → 同意。勾选框默认不勾,
/// 同意按钮在勾上之前一直是禁用的 —— 不预勾、不默认同意。
class ContentPolicyScreen extends StatefulWidget {
  const ContentPolicyScreen({
    super.key,
    required this.onAccept,
    this.onDecline,
    this.showDecline = true,
  });

  /// 点「我已阅读并同意」时执行。落盘是异步的,所以返回 Future。
  final Future<void> Function() onAccept;

  /// 点「不同意」时执行;不传就不显示退路以外的行为。
  final VoidCallback? onDecline;

  /// 是否显示「不同意」。设置里「再看一遍」时为 false —— 那时人已经同意过了。
  final bool showDecline;

  @override
  State<ContentPolicyScreen> createState() => _ContentPolicyScreenState();
}

class _ContentPolicyScreenState extends State<ContentPolicyScreen> {
  /// **默认 false**。不要改成 true,也不要从任何地方预填 ——
  /// 预勾选的同意在 1.2 审核里等于没有同意。
  bool _readConfirmed = false;

  /// 落盘期间避免重复点击
  bool _accepting = false;

  Future<void> _accept() async {
    if (!_readConfirmed || _accepting) return;
    setState(() => _accepting = true);
    try {
      await widget.onAccept();
    } finally {
      if (mounted) setState(() => _accepting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 被 push 进来时(设置里「再看一遍」)给一个返回入口;
    // 作为启动门时它是 home,canPop 为 false,不显示 AppBar。
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      appBar: canPop ? AppBar() : null,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            // 桌面端别把正文拉成一行几百字,读起来累
            constraints: const BoxConstraints(
              maxWidth: LaresBreakpoints.desktop,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(LaresSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    kContentPolicyTitle,
                    style: theme.textTheme.headlineMedium,
                  ),
                  const SizedBox(height: LaresSpacing.md),
                  Text(
                    kContentPolicySummary,
                    style: theme.textTheme.bodyLarge,
                  ),
                  const SizedBox(height: LaresSpacing.lg),
                  for (final point in kContentPolicyPoints)
                    Padding(
                      padding:
                          const EdgeInsets.only(bottom: LaresSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            point.title,
                            style: theme.textTheme.titleLarge,
                          ),
                          const SizedBox(height: LaresSpacing.sm),
                          Text(
                            point.body,
                            style: theme.textTheme.bodyLarge,
                          ),
                        ],
                      ),
                    ),
                  const Divider(),
                  // 第一步:确认读完。默认不勾。
                  CheckboxListTile(
                    value: _readConfirmed,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      _kReadConfirmLabel,
                      style: theme.textTheme.bodyLarge,
                    ),
                    onChanged: _accepting
                        ? null
                        : (v) => setState(() => _readConfirmed = v ?? false),
                  ),
                  const SizedBox(height: LaresSpacing.sm),
                  // 第二步:同意。没勾上之前一直禁用。
                  FilledButton(
                    onPressed:
                        (_readConfirmed && !_accepting) ? _accept : null,
                    child: const Text(kContentPolicyAgreeLabel),
                  ),
                  if (widget.showDecline) ...[
                    const SizedBox(height: LaresSpacing.xs),
                    TextButton(
                      onPressed: _accepting ? null : widget.onDecline,
                      child: const Text(kContentPolicyDeclineLabel),
                    ),
                  ],
                  const SizedBox(height: LaresSpacing.md),
                  Text(
                    '这份规范随时可以在「设置 → 社区内容规范」里再看一遍。\n'
                    '有疑问或要举报,发邮件到 $kSupportEmail,我们 24 小时内回复。',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 首次启动/规范更新后的拦截门。同意之前不放行到 [child]。
class ContentPolicyGate extends StatelessWidget {
  const ContentPolicyGate({
    super.key,
    required this.consent,
    required this.child,
  });

  final ConsentStore consent;
  final Widget child;

  /// 「不同意」时的处理。
  ///
  /// 刻意**不退出 App**:iOS 上没有干净的退出方式,`exit(0)` 这类做法
  /// 会被 Apple 当作异常终止直接拒审(HIG 明确说 App 不应自行退出)。
  /// 所以这里只是平静地说明「要用圈子就得同意」,然后停在规范页上 ——
  /// 用户想走可以自己回到主屏幕,这是系统该管的事,不是 App 该替他做的决定。
  Future<void> _explainDecline(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('要用圈子,得先同意这份规范'),
        content: const Text(
          '这里是大家一起说话的地方,规范是底线,没法跳过。\n'
          '你可以先关掉 App 再想想,想好了随时回来。',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('再看一遍'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: consent,
      builder: (context, _) {
        if (consent.accepted) return child;
        return ContentPolicyScreen(
          onAccept: consent.accept,
          showDecline: true,
          onDecline: () => _explainDecline(context),
        );
      },
    );
  }
}
