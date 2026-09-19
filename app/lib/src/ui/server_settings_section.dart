import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../auth/auth_credential.dart';
import '../net/biometric_gate.dart';
import '../net/connection_test.dart';
import '../net/server_profile.dart';
import '../state/settings_store.dart';
import '../theme/tokens.dart';

/// [AuthMode] 的显示名。
///
/// 按本地化规范,enum 只留标识(`wire` 仍是唯一的序列化值),
/// 翻译查表放在 UI 层 —— 不把 BuildContext 传进 auth 模型层。
///
/// 注意:`AuthMode.label`(中文硬编码)目前仍存在于 auth_credential.dart,
/// 还有 connection_test.dart / signaling_client.dart 两处在用它。
/// 那两个文件不属于本批次,等它们本地化后 `label` 即可删除。
String authModeLabel(BuildContext context, AuthMode mode) {
  final t = AppLocalizations.of(context);
  return switch (mode) {
    AuthMode.none => t.settingsAuthModeNone,
    AuthMode.token => t.settingsAuthModeToken,
    AuthMode.circle => t.settingsAuthModeCircle,
  };
}

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
    final t = AppLocalizations.of(context);
    final active = settings.activeProfile;
    final count = settings.serverProfiles.profiles.length;
    return ListTile(
      leading: const Icon(Icons.dns_outlined),
      title: Text(t.settingsServer),
      subtitle: Text(
        active == null
            ? '${t.settingsServerBuiltIn}${defaultUrl == null ? '' : '\n$defaultUrl'}'
            : '${active.label} · ${active.url}\n'
                '${authModeLabel(context, active.authMode)}'
                '${count > 1 ? ' · ${t.settingsServerCount(count)}' : ''}',
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
        final t = AppLocalizations.of(context);
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
                  child: Text(t.settingsServerListTitle,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (profiles.isEmpty)
                  ListTile(
                    leading: const Icon(Icons.check_circle_rounded),
                    title: Text(t.settingsServerBuiltIn),
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
                    subtitle: Text(
                        '${p.url}\n${authModeLabel(context, p.authMode)}'),
                    isThreeLine: true,
                    trailing: IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: t.settingsServerEdit,
                      onPressed: () => _editProfile(ctx, settings, userId, p),
                    ),
                    onTap: () => settings.setActiveProfile(p.id),
                  ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.add_rounded),
                  title: Text(t.settingsServerAdd),
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
                          t.settingsServerPlaintextWarning,
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
  ServerProfile? existing, {
  BiometricGate? gate,
}) async {
  final isNew = existing == null;

  // 打开一个**已有**且**存了敏感值**的档案前,先验一次本机身份。
  //
  // 为什么只在这种情况下验:
  // - 新建档案里没有任何东西可偷,验了纯属添堵;
  // - 没填令牌也没填口令的旧档案同理。
  // 日常进房、聊天一律不验 —— 这道闸门防的是「别人拿起你解锁着的手机
  // 翻出圈子口令」,不是防有备而来的攻击者(那是安全存储那层的事)。
  final bool hasSecrets = existing != null &&
      (existing.token.isNotEmpty || existing.circlePasscodes.isNotEmpty);
  if (hasSecrets) {
    final BiometricGate g = gate ?? LocalAuthGate();
    final ok = await g.authenticate(
        AppLocalizations.of(context).settingsServerBiometricReason);
    if (!ok) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                AppLocalizations.of(context).settingsServerBiometricFailed),
          ),
        );
      }
      return;
    }
  }
  if (!context.mounted) return;
  final defaultLabel = AppLocalizations.of(context).settingsServerDefaultLabel;
  final id = existing?.id ?? settings.serverProfiles.newId();
  final labelField = TextEditingController(text: existing?.label ?? defaultLabel);
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
            ? defaultLabel
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
        final t = AppLocalizations.of(ctx);
        // 服务器说了自己收哪几种模式时,只显示那几种(外加 none)
        final allowed = serverModes.isEmpty
            ? AuthMode.values
            : [
                AuthMode.none,
                for (final m in AuthMode.values)
                  if (m != AuthMode.none && serverModes.contains(m.wire)) m,
              ];
        return AlertDialog(
          title: Text(
              isNew ? t.settingsServerAdd : t.settingsServerEditTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: labelField,
                  decoration: InputDecoration(
                    labelText: t.settingsServerName,
                    hintText: t.settingsServerNameHint,
                  ),
                ),
                const SizedBox(height: LaresSpacing.sm),
                TextField(
                  controller: urlField,
                  autofocus: isNew,
                  decoration: InputDecoration(
                    labelText: t.settingsServerUrl,
                    // 示例地址本身不是自然语言,两种语言共用
                    hintText: 'wss://rtc.example.com:8444/ws',
                    errorText: urlError,
                  ),
                  onChanged: (_) => setState(() => urlError = null),
                ),
                const SizedBox(height: LaresSpacing.md),
                Row(
                  children: [
                    Text(t.settingsServerAuthLabel),
                    const Spacer(),
                    DropdownButton<AuthMode>(
                      value: allowed.contains(mode) ? mode : AuthMode.none,
                      underline: const SizedBox.shrink(),
                      items: [
                        for (final m in allowed)
                          DropdownMenuItem(
                              value: m, child: Text(authModeLabel(ctx, m))),
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
                    decoration: InputDecoration(
                      labelText: t.settingsAuthModeToken,
                      hintText: t.settingsServerTokenHint,
                    ),
                  ),
                if (mode == AuthMode.circle) ...[
                  TextField(
                    controller: circleIdField,
                    decoration: InputDecoration(
                      labelText: t.settingsServerCircleId,
                      // 圈子 id 的示例值,不是自然语言
                      hintText: 'home',
                    ),
                  ),
                  TextField(
                    controller: passField,
                    obscureText: true,
                    decoration: InputDecoration(
                        labelText: t.settingsServerCirclePasscode),
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
                      label: Text(t.settingsServerTest),
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
                child: Text(t.settingsServerDelete),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.commonCancel),
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
              child: Text(t.settingsServerSave),
            ),
          ],
        );
      },
    ),
  );

  if (saved == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).settingsServerSaved),
      ),
    );
  }
}
