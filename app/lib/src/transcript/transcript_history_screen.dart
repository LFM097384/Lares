/// 「转写记录」页:新 → 旧,滚到底加载更早的;圈主可清空。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../theme/tokens.dart';
import 'transcript_models.dart';

class TranscriptHistoryScreen extends StatefulWidget {
  const TranscriptHistoryScreen({
    super.key,
    required this.history,
    required this.circleName,
    this.encrypted = false,
    this.onClear,
    this.pageSize = 50,
  });

  final TranscriptHistory history;
  final String circleName;

  /// E2EE 圈:顶部注明「只存在这台设备上」。
  final bool encrypted;

  /// 圈主才有;null = 不显示「清空记录」。抛异常 = 失败。
  final Future<void> Function()? onClear;
  final int pageSize;

  @override
  State<TranscriptHistoryScreen> createState() =>
      _TranscriptHistoryScreenState();
}

class _TranscriptHistoryScreenState extends State<TranscriptHistoryScreen> {
  final List<TranscriptEntry> _items = [];
  Object? _cursor;
  bool _more = false;
  bool _loading = false;
  Object? _error;

  /// 每次整表重载 +1,丢弃过期的在途请求结果。
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    widget.history.addListener(_reload);
    unawaited(_reload());
  }

  @override
  void dispose() {
    widget.history.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final gen = ++_gen;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await widget.history.page(limit: widget.pageSize);
      if (!mounted || gen != _gen) return;
      setState(() {
        _items
          ..clear()
          ..addAll(p.items);
        _cursor = p.cursor;
        _more = p.more;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_more) return;
    final gen = _gen;
    setState(() => _loading = true);
    try {
      final p =
          await widget.history.page(cursor: _cursor, limit: widget.pageSize);
      if (!mounted || gen != _gen) return;
      final seen = {for (final e in _items) e.dedupeKey};
      setState(() {
        _items.addAll(p.items.where((e) => !seen.contains(e.dedupeKey)));
        _cursor = p.cursor;
        _more = p.more;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context).transcriptLoadError)));
    }
  }

  Future<void> _confirmClear() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(t.transcriptClearConfirmTitle),
        content: Text(widget.encrypted
            ? t.transcriptClearConfirmBodyE2ee
            : t.transcriptClearConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(t.commonCancel),
          ),
          TextButton(
            key: const ValueKey('transcript-clear-confirm'),
            onPressed: () => Navigator.pop(dctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(dctx).colorScheme.error),
            child: Text(t.transcriptClearConfirm),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.onClear!();
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(t.transcriptCleared)));
      await _reload();
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(t.transcriptClearFailed)));
    }
  }

  String _when(BuildContext context, int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final ml = MaterialLocalizations.of(context);
    final now = DateTime.now();
    final time = ml.formatTimeOfDay(TimeOfDay.fromDateTime(d),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
    final sameDay =
        d.year == now.year && d.month == now.month && d.day == now.day;
    return sameDay ? time : '${ml.formatShortDate(d)} $time';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.transcriptTitle),
        actions: [
          if (widget.onClear != null)
            PopupMenuButton<String>(
              key: const ValueKey('transcript-menu'),
              onSelected: (_) => _confirmClear(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'clear',
                  child: Text(t.transcriptClear),
                ),
              ],
            ),
        ],
      ),
      body: Builder(builder: (context) {
        if (_error != null && _items.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(t.transcriptLoadError, style: theme.textTheme.bodyLarge),
                const SizedBox(height: LaresSpacing.md),
                TextButton(onPressed: _reload, child: Text(t.transcriptRetry)),
              ],
            ),
          );
        }
        if (_items.isEmpty && _loading) {
          return const Center(child: CircularProgressIndicator());
        }
        final header = widget.encrypted
            ? Padding(
                padding: const EdgeInsets.fromLTRB(LaresSpacing.lg,
                    LaresSpacing.md, LaresSpacing.lg, LaresSpacing.sm),
                child: Row(
                  children: [
                    const Icon(Icons.lock_rounded, size: 16),
                    const SizedBox(width: LaresSpacing.sm),
                    Expanded(
                      child: Text(t.transcriptLocalOnlyNote,
                          style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              )
            : null;
        if (_items.isEmpty) {
          return Column(
            children: [
              ?header,
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(LaresSpacing.lg),
                    child: Text(t.transcriptEmpty,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge),
                  ),
                ),
              ),
            ],
          );
        }
        final extra = (header != null ? 1 : 0);
        return RefreshIndicator(
          onRefresh: _reload,
          child: ListView.builder(
            key: const ValueKey('transcript-list'),
            itemCount: extra + _items.length + (_more ? 1 : 0),
            itemBuilder: (context, i) {
              if (header != null && i == 0) return header;
              final idx = i - extra;
              if (idx >= _items.length) {
                return Padding(
                  padding: const EdgeInsets.all(LaresSpacing.md),
                  child: Center(
                    child: _loading
                        ? const CircularProgressIndicator()
                        : TextButton(
                            key: const ValueKey('transcript-load-more'),
                            onPressed: _loadMore,
                            child: Text(t.transcriptLoadMore),
                          ),
                  ),
                );
              }
              final e = _items[idx];
              return ListTile(
                title: Text(
                  '${e.name} · ${_when(context, e.startedAt)}',
                  style: theme.textTheme.labelMedium,
                ),
                subtitle: SelectableText(e.text,
                    style: theme.textTheme.bodyLarge),
              );
            },
          ),
        );
      }),
    );
  }
}
