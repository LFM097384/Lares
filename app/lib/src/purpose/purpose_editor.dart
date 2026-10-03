/// 用途的代码编辑器:等宽 JSON + 行号 + 即时校验 + 分享码导入 / 复制。
///
/// 「应用」把校验通过的 Map pop 出去;真正发给服务器由调用方做
/// (建圈时要等登记好,圈主设置里直接应用)。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/gen/app_localizations.dart';
import '../theme/tokens.dart';
import 'purpose_code.dart';
import 'purpose_flow.dart';
import 'purpose_schema.dart';

/// 打开编辑器,返回校验通过的用途 JSON;null = 算了。
Future<Map<String, dynamic>?> openPurposeEditor(
  BuildContext context, {
  Map<String, dynamic>? initial,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<Map<String, dynamic>>(
      builder: (_) => PurposeEditorPage(initial: initial),
    ),
  );
}

class PurposeEditorPage extends StatefulWidget {
  const PurposeEditorPage({
    super.key,
    this.initial,
    this.debounce = const Duration(milliseconds: 300),
  });

  /// 预填的 JSON;null 用模板(以闲聊为底)。
  final Map<String, dynamic>? initial;

  /// 即时校验的防抖。
  final Duration debounce;

  @override
  State<PurposeEditorPage> createState() => _PurposeEditorPageState();
}

class _PurposeEditorPageState extends State<PurposeEditorPage> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  Timer? _debounce;
  List<PurposeIssue> _issues = const [];
  Map<String, dynamic>? _valid;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final init =
        widget.initial ?? purposeTemplate(AppLocalizations.of(context));
    _text.text = prettyPurposeJson(init);
    _validateNow();
    _text.addListener(_onChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String _lastText = '';

  void _onChanged() {
    if (_text.text == _lastText) return; // 只是光标动了
    _debounce?.cancel();
    // 改动中先把「应用」锁住,免得应用了旧的校验结果
    if (_valid != null) setState(() => _valid = null);
    _debounce = Timer(widget.debounce, () {
      if (mounted) setState(_validateNow);
    });
  }

  void _validateNow() {
    _lastText = _text.text;
    final r = validatePurposeText(_text.text);
    _issues = r.issues;
    _valid = r.purpose;
  }

  void _setText(String s) {
    _debounce?.cancel();
    _text.text = s;
    setState(_validateNow);
  }

  void _format() {
    final r = validatePurposeText(_text.text);
    if (r.issues.any((i) => i.code == PurposeIssueCode.syntax)) {
      _snack(AppLocalizations.of(context).purposeEditorFormatFailed);
      return;
    }
    // 语法对就能排版(结构错也照排,方便看)
    final decoded = r.purpose ?? _tryDecode(_text.text);
    if (decoded != null) _setText(prettyPurposeJson(decoded));
  }

  Object? _tryDecode(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  void _snack(String s) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _import() async {
    final m = await showPurposeImportDialog(context, preview: false);
    if (m == null || !mounted) return;
    _setText(prettyPurposeJson(m));
  }

  Future<void> _copyCode() async {
    final v = _valid;
    if (v == null) return;
    final code = encodePurposeCode(v);
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    await showPurposeCodeDialog(context, code);
  }

  void _jumpTo(PurposeIssue i) {
    final line = i.line;
    if (line == null) return;
    final lines = _text.text.split('\n');
    var off = 0;
    for (var k = 0; k < line - 1 && k < lines.length; k++) {
      off += lines[k].length + 1;
    }
    off += ((i.column ?? 1) - 1).clamp(0, 1 << 20);
    off = off.clamp(0, _text.text.length);
    _focus.requestFocus();
    _text.selection = TextSelection.collapsed(offset: off);
    // 粗略滚到那一行
    const lineHeight = 13 * 1.4;
    if (_scroll.hasClients) {
      final target = ((line - 3) * lineHeight).clamp(
        0.0,
        _scroll.position.maxScrollExtent,
      );
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final ok = _valid != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.purposeEditorTitle),
        actions: [
          IconButton(
            key: const ValueKey('purpose-editor-format'),
            tooltip: t.purposeEditorFormat,
            icon: const Icon(Icons.format_align_left_rounded),
            onPressed: _format,
          ),
          IconButton(
            key: const ValueKey('purpose-editor-import'),
            tooltip: t.purposeEditorImport,
            icon: const Icon(Icons.download_rounded),
            onPressed: _import,
          ),
          IconButton(
            key: const ValueKey('purpose-editor-copy'),
            tooltip: t.purposeEditorCopyCode,
            icon: const Icon(Icons.qr_code_rounded),
            onPressed: ok ? _copyCode : null,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                children: [
                  // 行号栏底色铺满整个编辑区高度(不随文字长短戛然而止)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: _gutterWidth,
                    child: ColoredBox(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.4),
                    ),
                  ),
                  SingleChildScrollView(
                    controller: _scroll,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 行号(出错的行号染成错误色)
                        ListenableBuilder(
                          listenable: _text,
                          builder: (context, _) {
                            final n = '\n'.allMatches(_text.text).length + 1;
                            final bad = {
                              for (final i in _issues)
                                if (i.line != null) i.line!,
                            };
                            final base = kPurposeMonoStyle.copyWith(
                              color: theme.hintColor,
                            );
                            return SizedBox(
                              width: _gutterWidth,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  0,
                                  12,
                                  LaresSpacing.sm,
                                  12,
                                ),
                                child: Text.rich(
                                  TextSpan(
                                    style: base,
                                    children: [
                                      for (var i = 1; i <= n; i++)
                                        TextSpan(
                                          text: i == n ? '$i' : '$i\n',
                                          style: bad.contains(i)
                                              ? TextStyle(
                                                  color:
                                                      theme.colorScheme.error,
                                                  fontWeight: FontWeight.w600,
                                                )
                                              : null,
                                        ),
                                    ],
                                  ),
                                  textAlign: TextAlign.right,
                                ),
                              ),
                            );
                          },
                        ),
                        Expanded(
                          child: TextField(
                            key: const ValueKey('purpose-editor-field'),
                            controller: _text,
                            focusNode: _focus,
                            maxLines: null,
                            minLines: 12,
                            keyboardType: TextInputType.multiline,
                            autocorrect: false,
                            enableSuggestions: false,
                            smartQuotesType: SmartQuotesType.disabled,
                            smartDashesType: SmartDashesType.disabled,
                            style: kPurposeMonoStyle,
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              isCollapsed: true,
                              contentPadding: EdgeInsets.all(12),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: _issues.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(
                        LaresSpacing.md,
                        LaresSpacing.sm + 4,
                        LaresSpacing.md,
                        LaresSpacing.sm,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            ok
                                ? Icons.check_circle_outline_rounded
                                : Icons.more_horiz_rounded,
                            size: 18,
                            color: ok
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: LaresSpacing.sm),
                          Expanded(
                            child: Text(
                              ok
                                  ? t.purposeEditorValid
                                  : t.purposeEditorChecking,
                              key: const ValueKey('purpose-editor-status'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView(
                      key: const ValueKey('purpose-editor-issues'),
                      shrinkWrap: true,
                      children: [
                        for (final i in _issues)
                          ListTile(
                            dense: true,
                            // 图标与上面状态行 / 编辑区左缘对齐,不留 ListTile 默认的大空白
                            minLeadingWidth: 18,
                            horizontalTitleGap: LaresSpacing.sm,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: LaresSpacing.md,
                            ),
                            leading: Icon(
                              Icons.error_outline_rounded,
                              size: 18,
                              color: theme.colorScheme.error,
                            ),
                            title: Text(purposeIssueMessage(t, i)),
                            subtitle: Text(
                              i.line == null
                                  ? i.path
                                  : '${i.path} · ${t.purposeEditorLine(i.line!)}',
                              style: kPurposeMonoStyle.copyWith(fontSize: 11),
                            ),
                            onTap: i.line == null ? null : () => _jumpTo(i),
                          ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LaresSpacing.md,
                0,
                LaresSpacing.md,
                LaresSpacing.md,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(t.commonCancel),
                  ),
                  const SizedBox(width: LaresSpacing.sm),
                  FilledButton(
                    key: const ValueKey('purpose-editor-apply'),
                    onPressed: ok ? () => Navigator.pop(context, _valid) : null,
                    child: Text(t.purposeEditorApply),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 行号栏宽:四位行号(32 KB 上限内到不了五位)+ 右侧留白。
const double _gutterWidth = 44;
