/// 「另一台设备也用这个身份」:导出 / 导入身份码。
///
/// ## 为什么跨设备值得单独做
///
/// 服务端的成员模型本来就是「一个人、多台设备」——
/// `server/src/index.js:230`:
/// `Member = { userId, name, status, devices: Map<deviceId, ws> }`,
/// 注释写着「一个用户可多端在线」。
///
/// 所以电脑和手机用同一个 `userId` 时会被正确合并成一个人。
/// 缺的只是把 userId 从一台设备搬到另一台的办法 —— 这个块提供它。
///
/// ⚠️ `deviceId` **不共享**。两台设备若共用它,服务端的 `devices` Map
/// 会把后进的覆盖掉,表现是「手机一连,电脑就掉线」。
/// [Identity.importCode] 保证了这一点(只换 userId 与昵称)。
///
/// ## 为什么这里没有改昵称那一行了
///
/// 曾经有过 —— 它和设置页「我」分组里的改名行是同一件事的两份实现,
/// 而且是**更差**的那一份:它 `maxLength: 24` 按 UTF-16 code unit 算
/// (一个 emoji 顶两格,还可能从代理对中间截断),又只调
/// `Identity.saveName` 而不经过 `controller.rename()` ——
/// 于是改完的名字在重连之前**传不到别人那里**。
///
/// 现在昵称只剩 `settings_sheet.dart` 里那一行,保存只走
/// `saveMyNickname()`(截断按字素簇 + 广播 + 落盘)。这里不再重复实现,
/// 也不要再加回来:一个字段两条保存路径,迟早会漂移。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/gen/app_localizations.dart';
import '../state/identity.dart';
import '../state/room_controller.dart';
import '../theme/tokens.dart';

/// 跨设备身份那一行。刻意做成**单独一行**而不是一整个 SettingsGroup ——
/// 它和改昵称、选语言同属「关于我」,理应待在同一个分组里。
/// 自带一个组是当初两个分组并存时留下的痕迹,已经合并掉了。
class IdentityCodeTile extends StatelessWidget {
  const IdentityCodeTile({super.key, required this.controller});

  /// 身份三要素的来源。
  ///
  /// 刻意从 controller 现取而不是接一个 `Identity` 快照:
  /// `controller.userName` 是改名之后**立刻**更新的那个值,
  /// 而启动时 load 出来的 `Identity.name` 只是一张快照 ——
  /// 用后者会导出一个「名字还是旧的」的身份码。
  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListTile(
      leading: const Icon(Icons.devices_rounded),
      title: Text(t.settingsSameIdentity),
      subtitle: Text(t.settingsSameIdentitySub),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => showIdentityCodeDialog(context, controller),
    );
  }
}

/// 身份码对话框:上半段给出去,下半段粘进来。
///
/// 导入成功后**只提示重启,不做任何热切换** —— 理由写在
/// [_importIdentity] 里,那不是偷懒,是目前唯一诚实的做法。
Future<void> showIdentityCodeDialog(
  BuildContext context,
  RoomController controller,
) {
  final code = Identity(
    userId: controller.userId,
    deviceId: controller.deviceId,
    name: controller.userName,
  ).exportCode();
  final inputField = TextEditingController();

  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final t = AppLocalizations.of(ctx);
      return AlertDialog(
        title: Text(t.settingsSameIdentity),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.settingsIdentityExportTitle),
              const SizedBox(height: LaresSpacing.xs),
              Text(
                t.settingsIdentityExportBody,
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: LaresSpacing.sm),
              SelectableText(
                code,
                style: Theme.of(ctx)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontFamily: 'monospace'),
              ),
              const SizedBox(height: LaresSpacing.xs),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text(t.commonCopied)),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: Text(t.commonCopy),
                ),
              ),
              const Divider(height: LaresSpacing.lg),
              Text(t.settingsIdentityImportTitle),
              const SizedBox(height: LaresSpacing.xs),
              TextField(
                controller: inputField,
                decoration: InputDecoration(
                  hintText: t.settingsIdentityImportHint,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.commonClose),
          ),
          FilledButton(
            onPressed: () => _importIdentity(ctx, inputField.text),
            child: Text(t.settingsIdentityImportAction),
          ),
        ],
      );
    },
  );
}

/// 导入身份码:落盘,然后**老实告诉用户要重启**。
///
/// ⚠️ 这里刻意**不做**热切换,下面是原因,别当成 TODO 顺手「修好」。
///
/// `userId` 在 `main.dart` 启动时就被分发给了六个长生命周期对象:
/// `SignalingClient`、`RoomController`(字段是 `final`)、`P2PMesh.myUserId`、
/// `PresencePool.userId`,以及聊天与主屏小组件两个服务。
/// 它还是两处**协议级**事实的一部分:
///
/// 1. 鉴权证明 —— `AuthProof.build(credential:, nonce:, userId:)`,
///    证明是按当次 nonce 现算的,userId 是被签进去的消息体;
/// 2. 服务端的成员表按 userId 建索引(`Member.devices` 是它的下级)。
///
/// 就算把这六处全改成可变的,旧 userId 在服务端的登记也要等旧 socket
/// 断开才消失,而用户此刻可能正在房间里 —— 那条 LiveKit 媒体会话的
/// token 是用旧身份换来的,换不掉。做一个「看起来切换了、实际半生不熟」
/// 的热切换,比直说「重开一次」要糟得多:后者用户照做就一定对,
/// 前者会让人以为已经生效,然后在某个说不清的时刻发现两台设备还是两个人。
///
/// 所以:落盘是真的(下次启动一定是新身份),提示也是真的。
Future<void> _importIdentity(BuildContext ctx, String raw) async {
  final t = AppLocalizations.of(ctx);
  final imported = await Identity.importCode(raw);
  if (!ctx.mounted) return;
  if (imported == null) {
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(content: Text(t.settingsIdentityImportBad)),
    );
    return;
  }
  Navigator.pop(ctx);
  ScaffoldMessenger.of(ctx).showSnackBar(
    // 用 SnackBar 而不是又弹一个对话框:这句话没有「要做的选择」,
    // 只有一件要知道的事。但它比普通提示重要,所以给足停留时间。
    SnackBar(
      content: Text(t.settingsIdentityImportRestart),
      duration: const Duration(seconds: 8),
    ),
  );
}
