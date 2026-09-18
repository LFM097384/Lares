/// 直连对话界面:一台服务器都没有时,靠互传一段连接码说上话。
///
/// ## 这个界面最难的地方是讲清楚流程
///
/// 握手要**一来一回两步**,而多数人没见过这种交互。
/// 所以界面按「你是先开口的那个,还是回应的那个」分成两条路,
/// 每一步只显示当前该做的一件事 —— 不把两步同时摊开。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../p2p/ice_store.dart';
import '../p2p/p2p_session.dart';
import '../theme/tokens.dart';

class P2PScreen extends StatefulWidget {
  const P2PScreen({super.key, required this.ice, this.onStartMesh});

  final IceStore ice;

  /// 启动多人直连(星形)。为空表示当前没有服务器信令,
  /// 只能做 1 对 1 的手动连接码交换。
  final VoidCallback? onStartMesh;

  @override
  State<P2PScreen> createState() => _P2PScreenState();
}

enum _Role { undecided, offerer, answerer }

class _P2PScreenState extends State<P2PScreen> {
  P2PSession? _session;
  _Role _role = _Role.undecided;
  final _input = TextEditingController();

  @override
  void dispose() {
    _session?.dispose();
    _input.dispose();
    super.dispose();
  }

  P2PSession _ensure() =>
      _session ??= P2PSession(ice: widget.ice.config)
        ..addListener(() => setState(() {}));

  Future<void> _startAsOfferer() async {
    setState(() => _role = _Role.offerer);
    await _ensure().createOffer();
  }

  Future<void> _paste() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    await _ensure().acceptRemoteCode(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _session;

    return Scaffold(
      appBar: AppBar(title: const Text('直连对话')),
      body: ListView(
        padding: const EdgeInsets.all(LaresSpacing.lg),
        children: [
          _Explainer(ice: widget.ice.config),
          const SizedBox(height: LaresSpacing.lg),
          if (_role == _Role.undecided) ...[
            _RoleCard(
              icon: Icons.outgoing_mail,
              title: '我先开口',
              body: '生成一段连接码发给对方,等对方回一段给你。',
              onTap: _startAsOfferer,
            ),
            const SizedBox(height: LaresSpacing.md),
            _RoleCard(
              icon: Icons.move_to_inbox_rounded,
              title: '对方发我码了',
              body: '把对方发来的连接码贴进来,生成一段回给他。',
              onTap: () => setState(() => _role = _Role.answerer),
            ),
            // 多人只在有服务器信令时给 —— 星形拓扑下 3 人也要建 2 条连接、
            // 交换 4 段码,手动传不现实。
            if (widget.onStartMesh != null) ...[
              const SizedBox(height: LaresSpacing.md),
              _RoleCard(
                icon: Icons.group_rounded,
                title: '圈里的人一起(最多 4 人)',
                body: '连接码由服务器转交,不用手动传。'
                    '会自动挑一个人转发声音 —— 优先挑电脑,'
                    '因为它插着电、网更稳。',
                onTap: () {
                  widget.onStartMesh!();
                  Navigator.pop(context);
                },
              ),
            ],
          ] else ...[
            if (s != null && s.phase == P2PPhase.gathering)
              const _Waiting(text: '正在准备连接信息…'),
            if (s?.localCode != null) _CodeBox(
              label: _role == _Role.offerer ? '① 把这段发给对方' : '② 把这段回给对方',
              code: s!.localCode!,
            ),
            if (_needsPaste(s)) ...[
              const SizedBox(height: LaresSpacing.lg),
              Text(
                _role == _Role.offerer ? '② 贴入对方回给你的码' : '① 贴入对方发来的码',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: LaresSpacing.sm),
              TextField(
                controller: _input,
                maxLines: 4,
                minLines: 2,
                decoration: InputDecoration(
                  hintText: 'LARES-…',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: '从剪贴板粘贴',
                    icon: const Icon(Icons.content_paste_rounded),
                    onPressed: () async {
                      final d = await Clipboard.getData('text/plain');
                      if (d?.text != null) _input.text = d!.text!;
                    },
                  ),
                ),
              ),
              const SizedBox(height: LaresSpacing.sm),
              FilledButton(onPressed: _paste, child: const Text('连接')),
            ],
            if (s != null) ...[
              const SizedBox(height: LaresSpacing.lg),
              _Status(session: s),
            ],
          ],
        ],
      ),
    );
  }

  /// 该不该显示粘贴框。
  ///
  /// 发起方:出了码之后才需要贴对方的回复。
  /// 应答方:一上来就要贴 —— 他手里已经有对方的码了。
  bool _needsPaste(P2PSession? s) {
    if (_role == _Role.answerer) return s?.localCode == null;
    return s != null && s.phase == P2PPhase.waitingForPeer;
  }
}

/// 开头那段说明。**必须**把代价讲在前面。
class _Explainer extends StatelessWidget {
  const _Explainer({required this.ice});
  final IceConfig ice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(LaresSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cable_rounded,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: LaresSpacing.sm),
                Text('不经过任何服务器', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: LaresSpacing.sm),
            Text(
              '你和对方互传一段连接码,声音就在两台设备之间直接走。\n'
              '连接码怎么传都行 —— 微信、短信、当面念都可以。',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: LaresSpacing.sm),
            // 这段不能省。做不到的事要说在前面,而不是等用户连不上再解释。
            Text(
              '⚠️ 只能一对一,而且这里没有文字、图片和加密标记 —— '
              '那些功能依赖服务器。\n'
              '另外约两三成的网络组合直连不了,'
              '${ice.turn == null ? '需要在设置里填一台中继服务器(TURN)' : '会走你配的中继服务器'}。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: LaresSpacing.lg,
            vertical: LaresSpacing.sm,
          ),
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(body),
          onTap: onTap,
        ),
      );
}

/// 连接码展示框。长码必须能一键复制 —— 手动选中一段 700 字的文本是灾难。
class _CodeBox extends StatelessWidget {
  const _CodeBox({required this.label, required this.code});

  final String label;
  final String code;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.titleMedium),
        const SizedBox(height: LaresSpacing.sm),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(LaresSpacing.md),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: LaresRadii.cardRadius,
          ),
          child: Text(
            code,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
            ),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: LaresSpacing.sm),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('连接码已复制,发给对方吧')),
                );
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('复制'),
            ),
            const SizedBox(width: LaresSpacing.sm),
            Text('${code.length} 字符',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                )),
          ],
        ),
      ],
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: LaresSpacing.md),
          Text(text),
        ],
      );
}

/// 状态条。失败时把原因摆出来,不让用户对着一个不动的界面猜。
class _Status extends StatelessWidget {
  const _Status({required this.session});
  final P2PSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (IconData icon, String text, Color color) = switch (session.phase) {
      P2PPhase.connected => (
          Icons.check_circle_rounded,
          '连上了,可以说话',
          theme.colorScheme.primary,
        ),
      P2PPhase.connecting => (
          Icons.sync_rounded,
          '正在连接…',
          theme.colorScheme.onSurfaceVariant,
        ),
      P2PPhase.waitingForPeer => (
          Icons.hourglass_empty_rounded,
          '等对方那边动作',
          theme.colorScheme.onSurfaceVariant,
        ),
      P2PPhase.failed => (
          Icons.error_outline_rounded,
          session.failure ?? '没能连上',
          theme.colorScheme.error,
        ),
      P2PPhase.closed => (
          Icons.call_end_rounded,
          '已断开',
          theme.colorScheme.onSurfaceVariant,
        ),
      _ => (
          Icons.circle_outlined,
          '',
          theme.colorScheme.onSurfaceVariant,
        ),
    };
    if (text.isEmpty) return const SizedBox.shrink();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: LaresSpacing.sm),
        Expanded(
          child: Text(text,
              style: theme.textTheme.bodyMedium?.copyWith(color: color)),
        ),
      ],
    );
  }
}
