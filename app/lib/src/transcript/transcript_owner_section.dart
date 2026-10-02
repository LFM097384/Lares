/// 圈主控件:「转写记录」开关 + 机器人 token 管理。
///
/// 只拿回调,不直接依赖 RoomController / 信令 —— 测试直接注入。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/gen/app_localizations.dart';
import '../theme/tokens.dart';
import 'transcript_service.dart';

/// 圈主的「转写记录」开关。
class TranscriptOwnerSwitch extends StatefulWidget {
  const TranscriptOwnerSwitch({
    super.key,
    required this.on,
    required this.e2ee,
    required this.onSet,
  });

  /// 当前是否开着(服务器权威)。
  final bool on;

  /// 本圈是否端到端加密(决定开启时的告知内容)。
  final bool e2ee;

  /// 发 circle_transcript_set 并等回执;抛 [TranscriptOpException] = 失败。
  final Future<void> Function(bool on) onSet;

  @override
  State<TranscriptOwnerSwitch> createState() => _TranscriptOwnerSwitchState();
}

class _TranscriptOwnerSwitchState extends State<TranscriptOwnerSwitch> {
  bool _busy = false;
  bool? _optimistic;

  @override
  void didUpdateWidget(covariant TranscriptOwnerSwitch old) {
    super.didUpdateWidget(old);
    if (old.on != widget.on) _optimistic = null;
  }

  Future<bool> _confirmE2ee() async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(t.transcriptE2eeWarnTitle),
        content: Text(t.transcriptE2eeWarnBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(t.commonCancel),
          ),
          TextButton(
            key: const ValueKey('transcript-e2ee-confirm'),
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(t.transcriptE2eeWarnConfirm),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final value = _optimistic ?? widget.on;
    return SwitchListTile(
      key: const ValueKey('owner-transcript-switch'),
      secondary: const Icon(Icons.subject_rounded),
      title: Text(t.transcriptTitle),
      subtitle: Text(widget.e2ee
          ? t.transcriptOwnerSwitchDescE2ee
          : t.transcriptOwnerSwitchDesc),
      isThreeLine: true,
      value: value,
      onChanged: _busy
          ? null
          : (v) async {
              // E2EE 圈打开:语音要出本机去识别 —— 必须先说清楚。
              if (v && widget.e2ee && !await _confirmE2ee()) return;
              if (!mounted) return;
              final messenger = ScaffoldMessenger.of(this.context);
              setState(() {
                _busy = true;
                _optimistic = v;
              });
              try {
                await widget.onSet(v);
              } catch (e) {
                if (!mounted) return;
                setState(() => _optimistic = null);
                messenger.showSnackBar(SnackBar(
                    content: Text(e is TranscriptOpException &&
                            e.reason == 'not_owner'
                        ? t.homeOwnerErrNotOwner
                        : t.homeOwnerErrGeneric)));
              } finally {
                if (mounted) setState(() => _busy = false);
              }
            },
    );
  }
}

/// 机器人 token 的后端(由 [TranscriptService] 提供;测试注入假实现)。
abstract interface class BotTokenApi {
  Future<List<BotTokenInfo>> list();
  Future<BotTokenCreated> create(String name);
  Future<void> revoke(String id);
}

/// 绑定到某个圈子的 [TranscriptService]。
class ServiceBotTokenApi implements BotTokenApi {
  ServiceBotTokenApi(this.service, this.circleId);
  final TranscriptService service;
  final String circleId;
  @override
  Future<List<BotTokenInfo>> list() => service.listBotTokens(circleId);
  @override
  Future<BotTokenCreated> create(String name) =>
      service.createBotToken(circleId, name);
  @override
  Future<void> revoke(String id) => service.revokeBotToken(circleId, id);
}

/// 起名对话框:自己持有输入控制器,随路由一起销毁(退场动画期间仍有效)。
class _BotNameDialog extends StatefulWidget {
  const _BotNameDialog();
  @override
  State<_BotNameDialog> createState() => _BotNameDialogState();
}

class _BotNameDialogState extends State<_BotNameDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(t.botTokenCreateTitle),
      content: TextField(
        key: const ValueKey('bot-token-name'),
        controller: _ctrl,
        autofocus: true,
        maxLength: 32,
        decoration: InputDecoration(hintText: t.botTokenNameHint),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.commonCancel),
        ),
        TextButton(
          key: const ValueKey('bot-token-create-confirm'),
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: Text(t.botTokenCreate),
        ),
      ],
    );
  }
}

/// 机器人管理页:列表 / 新建(token 只显示一次)/ 吊销。
class BotTokensScreen extends StatefulWidget {
  const BotTokensScreen({super.key, required this.api, this.e2ee = false});

  final BotTokenApi api;

  /// E2EE 圈:机器人读不到也发不了(服务器回 409),页顶说明。
  final bool e2ee;

  @override
  State<BotTokensScreen> createState() => _BotTokensScreenState();
}

class _BotTokensScreenState extends State<BotTokensScreen> {
  List<BotTokenInfo>? _items;
  bool _error = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = false);
    try {
      final items = await widget.api.list();
      if (!mounted) return;
      setState(() => _items = items);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = true);
    }
  }

  Future<void> _create() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _BotNameDialog(),
    );
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _busy = true);
    BotTokenCreated created;
    try {
      created = await widget.api.create(name);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(t.homeOwnerErrGeneric)));
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _items = [...?_items, created.info];
    });
    await _showTokenOnce(created);
  }

  Future<void> _showTokenOnce(BotTokenCreated c) async {
    final t = AppLocalizations.of(context);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dctx) => AlertDialog(
        title: Text(t.botTokenCreatedTitle(c.info.name)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.botTokenShownOnce),
            const SizedBox(height: LaresSpacing.md),
            SelectableText(
              c.token,
              key: const ValueKey('bot-token-value'),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            key: const ValueKey('bot-token-copy'),
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: Text(t.commonCopy),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await Clipboard.setData(ClipboardData(text: c.token));
              messenger.showSnackBar(SnackBar(content: Text(t.commonCopied)));
            },
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: Text(t.commonDone),
          ),
        ],
      ),
    );
  }

  Future<void> _revoke(BotTokenInfo b) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(t.botTokenRevokeTitle(b.name)),
        content: Text(t.botTokenRevokeBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(t.commonCancel),
          ),
          TextButton(
            key: const ValueKey('bot-token-revoke-confirm'),
            onPressed: () => Navigator.pop(dctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(dctx).colorScheme.error),
            child: Text(t.botTokenRevoke),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.api.revoke(b.id);
      if (!mounted) return;
      setState(() => _items = [...?_items]..removeWhere((x) => x.id == b.id));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(t.homeOwnerErrGeneric)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: Text(t.botTokensTitle)),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('bot-token-add'),
        onPressed: _busy ? null : _create,
        icon: const Icon(Icons.add_rounded),
        label: Text(t.botTokenCreate),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(LaresSpacing.lg),
            child: Text(
              widget.e2ee ? t.botTokensDescE2ee : t.botTokensDesc,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (_error)
            ListTile(
              title: Text(t.transcriptLoadError),
              trailing: TextButton(
                  onPressed: _load, child: Text(t.transcriptRetry)),
            )
          else if (items == null)
            const Padding(
              padding: EdgeInsets.all(LaresSpacing.lg),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (items.isEmpty)
            ListTile(title: Text(t.botTokensEmpty))
          else
            for (final b in items)
              ListTile(
                leading: const Icon(Icons.smart_toy_outlined),
                title: Text(b.name),
                subtitle: b.createdAt == null
                    ? null
                    : Text(MaterialLocalizations.of(context).formatShortDate(
                        DateTime.fromMillisecondsSinceEpoch(b.createdAt!))),
                trailing: IconButton(
                  tooltip: t.botTokenRevoke,
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => _revoke(b),
                ),
              ),
        ],
      ),
    );
  }
}
