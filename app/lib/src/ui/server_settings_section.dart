import 'package:flutter/material.dart';

import '../auth/auth_credential.dart';
import '../net/connection_test.dart';
import '../net/server_profile.dart';
import '../state/settings_store.dart';
import '../theme/tokens.dart';

/// 设置页的「服务器与口令」区块。
///
/// 单独成文件是为了不把共享的 settings_sheet.dart 撑大(那个文件多人在改)。
/// 设计取向:让一次打错的口令**当场可见**,而不是等到进房时莫名其妙地失败 ——
/// 所以「测试连接」是这一屏最重要的按钮。
class ServerSettingsSection extends StatelessWidget {
  const ServerSettingsSection({
    super.key,
    required this.settings,
    required this.userId,
    this.defaultUrl,
  });

  final SettingsStore settings;

  /// 本机 userId:HMAC 消息体的一部分,拨测时要用
  final String userId;

  /// 编译期内置地址(没有档案时显示它)
  final String? defaultUrl;

  @override
  Widget build(BuildContext context) {
    final active = settings.activeProfile;
    final count = settings.serverProfiles.profiles.length;
    return ListTile(
      leading: const Icon(Icons.dns_outlined),
      title: const Text('服务器与口令'),
      subtitle: Text(
        active == null
            ? '默认(打包内置)${defaultUrl == null ? '' : '\n$defaultUrl'}'
            : '${active.label} · ${active.url}\n'
                '${active.authMode.label}${count > 1 ? ' · 共 $count 个服务器' : ''}',
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => showServerProfilesSheet(
        context,
        settings: settings,
        userId: userId,
        defaultUrl: defaultUrl,
      ),
    );
  }
}

/// 服务器档案列表:切换 / 新增 / 编辑 / 删除
Future<void> showServerProfilesSheet(
  BuildContext context, {
  required SettingsStore settings,
  required String userId,
  String? defaultUrl,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final profiles = settings.serverProfiles.profiles;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: LaresSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      LaresSpacing.lg, 0, LaresSpacing.lg, LaresSpacing.sm),
                  child: Text('服务器',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (profiles.isEmpty)
                  ListTile(
                    leading: const Icon(Icons.check_circle_rounded),
                    title: const Text('默认(打包内置)'),
                    subtitle: Text(defaultUrl ?? '—'),
                  ),
                for (final p in profiles)
                  ListTile(
                    leading: Icon(
                      settings.serverProfiles.active?.id == p.id
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: settings.serverProfiles.active?.id == p.id
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    title: Text(p.label),
                    subtitle: Text('${p.url}\n${p.authMode.label}'),
                    isThreeLine: true,
                    trailing: IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: '编辑',
                      onPressed: () => _editProfile(ctx, settings, userId, p),
                    ),
                    onTap: () => settings.setActiveProfile(p.id),
                  ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.add_rounded),
                  title: const Text('添加服务器'),
                  onTap: () => _editProfile(ctx, settings, userId, null),
                ),
                // 明文存储:不粉饰,直接告诉用户
                Padding(
                  padding: const EdgeInsets.fromLTRB(LaresSpacing.lg,
                      LaresSpacing.sm, LaresSpacing.lg, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline_rounded,
                          size: 16,
                          color: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.color
                              ?.withValues(alpha: 0.7)),
                      const SizedBox(width: LaresSpacing.sm),
                      Expanded(
                        child: Text(
                          '口令以明文保存在本机设置里,不是加密存储。'
                          '别人拿到这台设备的文件就能读到 —— 共用设备请谨慎。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// 新增/编辑一个档案。地址、鉴权模式、凭据、测试连接都在这一页。
Future<void> _editProfile(
  BuildContext context,
  SettingsStore settings,
  String userId,
  ServerProfile? existing,
) async {
  final isNew = existing == null;
  final id = existing?.id ?? settings.serverProfiles.newId();
  final labelField =
      TextEditingController(text: existing?.label ?? '我的服务器');
  final urlField = TextEditingController(text: existing?.url ?? '');
  final tokenField = TextEditingController(text: existing?.token ?? '');
  // circle 模式:MVP 先管一个圈的口令(圈 id + 口令),够覆盖主人的两套部署
  final circleIdField = TextEditingController(
      text: existing?.circlePasscodes.keys.firstOrNull ?? '');
  final passField = TextEditingController(
      text: existing?.circlePasscodes.values.firstOrNull ?? '');

  var mode = existing?.authMode ?? AuthMode.none;
  String? urlError;
  ConnectionTestResult? testResult;
  var testing = false;
  // 服务端 challenge 广播的可用模式:拨测成功后据此裁剪选项,
  // 不给用户看这台服务器根本不收的模式
  List<String> serverModes = const [];

  ServerProfile compose(String url) => ServerProfile(
        id: id,
        label: labelField.text.trim().isEmpty
            ? '我的服务器'
            : labelField.text.trim(),
        url: url,
        authMode: mode,
        token: tokenField.text,
        circlePasscodes: {
          if (circleIdField.text.trim().isNotEmpty)
            circleIdField.text.trim(): passField.text,
        },
      );

  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        // 服务器说了自己收哪几种模式时,只显示那几种(外加 none)
        final allowed = serverModes.isEmpty
            ? AuthMode.values
            : [
                AuthMode.none,
                for (final m in AuthMode.values)
                  if (m != AuthMode.none && serverModes.contains(m.wire)) m,
              ];
        return AlertDialog(
          title: Text(isNew ? '添加服务器' : '编辑服务器'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: labelField,
                  decoration: const InputDecoration(
                    labelText: '名字',
                    hintText: '例:家里的 VPS',
                  ),
                ),
                const SizedBox(height: LaresSpacing.sm),
                TextField(
                  controller: urlField,
                  autofocus: isNew,
                  decoration: InputDecoration(
                    labelText: '地址',
                    hintText: 'wss://rtc.example.com:8444/ws',
                    errorText: urlError,
                  ),
                  onChanged: (_) => setState(() => urlError = null),
                ),
                const SizedBox(height: LaresSpacing.md),
                Row(
                  children: [
                    const Text('需要口令'),
                    const Spacer(),
                    DropdownButton<AuthMode>(
                      value: allowed.contains(mode) ? mode : AuthMode.none,
                      underline: const SizedBox.shrink(),
                      items: [
                        for (final m in allowed)
                          DropdownMenuItem(value: m, child: Text(m.label)),
                      ],
                      onChanged: (v) => setState(() {
                        if (v != null) mode = v;
                      }),
                    ),
                  ],
                ),
                if (mode == AuthMode.token)
                  TextField(
                    controller: tokenField,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '共享令牌',
                      hintText: '服务器的 LARES_AUTH_TOKEN',
                    ),
                  ),
                if (mode == AuthMode.circle) ...[
                  TextField(
                    controller: circleIdField,
                    decoration: const InputDecoration(
                      labelText: '圈子 ID',
                      hintText: 'home',
                    ),
                  ),
                  TextField(
                    controller: passField,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '圈口令'),
                  ),
                ],
                const SizedBox(height: LaresSpacing.md),
                // 这一屏最有价值的东西:当场告诉用户「到底通没通、口令对不对」
                Row(
                  children: [
                    OutlinedButton.icon(
                      icon: testing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.network_check_rounded, size: 18),
                      label: const Text('测试连接'),
                      onPressed: testing
                          ? null
                          : () async {
                              final v =
                                  ServerProfile.validateUrl(urlField.text);
                              if (!v.isValid) {
                                setState(() {
                                  urlError = v.error;
                                  testResult = null;
                                });
                                return;
                              }
                              setState(() {
                                testing = true;
                                urlError = null;
                                testResult = null;
                              });
                              final profile = compose(v.normalized!);
                              final r = await ConnectionTester().test(
                                url: profile.url,
                                credential: profile.credentialFor(
                                    circleIdField.text.trim()),
                                userId: userId,
                              );
                              if (!ctx.mounted) return;
                              setState(() {
                                testing = false;
                                testResult = r;
                                if (r.serverModes.isNotEmpty) {
                                  serverModes = r.serverModes;
                                }
                              });
                            },
                    ),
                  ],
                ),
                if (testResult != null)
                  Padding(
                    padding: const EdgeInsets.only(top: LaresSpacing.sm),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          testResult!.isOk
                              ? Icons.check_circle_rounded
                              : Icons.error_outline_rounded,
                          size: 18,
                          color: testResult!.isOk
                              ? LaresColors.statusFree
                              : LaresColors.ember,
                        ),
                        const SizedBox(width: LaresSpacing.sm),
                        Expanded(
                          child: Text(
                            testResult!.message,
                            style: Theme.of(ctx).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            if (!isNew)
              TextButton(
                onPressed: () async {
                  await settings.removeProfile(id);
                  if (ctx.mounted) Navigator.pop(ctx, false);
                },
                child: const Text('删除'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('算了'),
            ),
            FilledButton(
              onPressed: () async {
                final v = ServerProfile.validateUrl(urlField.text);
                if (!v.isValid) {
                  setState(() => urlError = v.error);
                  return;
                }
                await settings.upsertProfile(compose(v.normalized!),
                    activate: true);
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    ),
  );

  if (saved == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存,重启 App 生效')),
    );
  }
}
