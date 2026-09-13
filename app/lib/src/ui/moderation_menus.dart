import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../chat/chat_message.dart';
import '../moderation/block_store.dart';
import '../moderation/report.dart';
import '../state/models.dart';
import '../state/room_controller.dart';
import '../theme/tokens.dart';

// ── 就地常量 ──
// tokens.dart 只收录颜色/圆角/间距/断点,没有「输入上限」这类内容约束,
// 所以本文件用到的几个数值一律在此就地定义,而不是散落在 build 里
// (与 chat_panel.dart 的做法一致)。

/// 补充说明最多写几行,再多就框内滚动。
/// 三行足够说清「他刚才说了什么」,更多会把选项列表挤出屏幕。
const int _noteMaxLines = 3;

/// 补充说明的字数上限。举报正文靠分类与摘录承载,自由文本只是补一句,
/// 500 字足够描述一次滥用,也不至于让邮件正文长到没人愿意读。
const int _noteMaxLength = 500;

/// 提交成功后的回执文案。审核员会逐字核对这句承诺,别改动。
const String _reportAcceptedNotice = '已提交,我们会在 24 小时内处理';

/// 举报的送达方式。生产实现是 [deliverReport],测试可注入假实现。
typedef ReportDelivery = Future<void> Function(ReportDraft draft);

/// 把举报正文复制到剪贴板。
///
/// 它既是 [deliverReport] 的**兜底**,也单独保留为可用路径:
/// `Clipboard` 来自 flutter/services,是 Flutter 自带的
/// (home_screen.dart 复制邀请链接走的就是同一个 API)。
Future<void> deliverReportToClipboard(ReportDraft draft) =>
    Clipboard.setData(ClipboardData(text: buildReportBody(draft)));

/// 默认送达实现:拉起系统邮件 App,**失败则退回剪贴板**。
///
/// 为什么一定要兜底而不是直接抛错:`launchUrl` 失败是很常见的正常情况 ——
/// 设备上没配任何邮件账号、模拟器没装邮件 App、企业设备禁用了 mailto,
/// 都会让它返回 false 或抛异常。举报是 Guideline 1.2 的必查项,
/// 这条路**任何情况下都不能变成死路**:哪怕邮件拉不起来,
/// 正文也已经躺在剪贴板里,对话框还会把收件地址摊出来给用户看。
///
/// 顺带一提,剪贴板这一步是**无条件先做**的,不是只在失败时做。
/// 因为有些平台上 `launchUrl` 返回 true 却什么也没发生(静默失败),
/// 那种情况下用户手里至少还有内容可粘贴。
Future<void> deliverReport(ReportDraft draft) async {
  await deliverReportToClipboard(draft);
  try {
    await launchUrl(
      buildReportMailtoUri(draft),
      mode: LaunchMode.externalApplication,
    );
  } catch (e) {
    // 吞掉是刻意的:邮件拉不起来不该让举报流程报错中断,
    // 正文已经在剪贴板里,对话框会告诉用户往哪儿发。
    debugPrint('[lares] 拉起邮件 App 失败,已退回剪贴板: $e');
  }
}

/// 长按/点按成员头像后的处置菜单(App Store 审核指南 1.2:UGC 必须能屏蔽与举报)。
///
/// [member] 应当**不是**自己 —— 屏蔽/举报/请出自己都没有意义,调用方负责过滤。
/// [onKick] 为空时不渲染「请出房间」那一行:与其摆一个点不动的入口,不如不摆。
/// [delivery] 只给测试注入假实现用,生产代码留空走 [deliverReportToClipboard]。
Future<void> showMemberModerationSheet(
  BuildContext context, {
  required RoomController controller,
  required BlockStore blocks,
  required Member member,
  VoidCallback? onKick,
  ReportDelivery? delivery,
}) {
  final bool blocked = blocks.isBlocked(member.userId);
  return showModalBottomSheet<void>(
    context: context,
    builder: (BuildContext ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _TargetHeader(name: member.name, userId: member.userId),
          if (blocked)
            ListTile(
              leading: const Icon(Icons.person_add_alt_1_rounded),
              title: const Text('解除屏蔽'),
              subtitle: const Text('他的声音和消息会重新出现'),
              onTap: () async {
                Navigator.pop(ctx);
                await blocks.unblock(member.userId);
              },
            )
          else
            ListTile(
              leading: const Icon(Icons.block_rounded),
              title: const Text('屏蔽这个人'),
              subtitle: const Text('听不到他的声音,也不再显示他的消息'),
              onTap: () async {
                Navigator.pop(ctx);
                await blocks.block(member.userId);
              },
            ),
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: const Text('举报'),
            subtitle: const Text('把情况告诉我们,24 小时内处理'),
            onTap: () async {
              // 先关菜单再办事,并且用**外层** context ——
              // ctx 随菜单一起消失,拿它去开对话框会撞 deactivated widget。
              Navigator.pop(ctx);
              await showReportFlow(
                context,
                blocks: blocks,
                targetUserId: member.userId,
                targetName: member.name,
                circleId: controller.circleId ?? '',
                reporterUserId: controller.userId,
                delivery: delivery,
              );
            },
          ),
          if (onKick != null)
            ListTile(
              leading: const Icon(Icons.logout_rounded),
              title: const Text('请出房间'),
              subtitle: const Text('对方可以稍后再进来,不是封禁'),
              onTap: () {
                Navigator.pop(ctx);
                onKick();
              },
            ),
        ],
      ),
    ),
  );
}

/// 长按一条别人发的消息后的处置菜单。
///
/// [message] 应当满足 `!message.isMine`:屏蔽/举报自己没有意义。
/// 屏蔽键认的是 [ChatMessage.senderId] 而**不是** `senderName` ——
/// 昵称随时能改,拿它当键等于没屏蔽(见 block_store.dart 的长注释)。
Future<void> showMessageModerationSheet(
  BuildContext context, {
  required BlockStore blocks,
  required ChatMessage message,
  required String reporterUserId,
  required String circleId,
  ReportDelivery? delivery,
}) {
  final bool blocked = blocks.isBlocked(message.senderId);
  return showModalBottomSheet<void>(
    context: context,
    builder: (BuildContext ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _TargetHeader(name: message.senderName, userId: message.senderId),
          if (blocked)
            ListTile(
              leading: const Icon(Icons.person_add_alt_1_rounded),
              title: const Text('解除屏蔽'),
              subtitle: const Text('他的声音和消息会重新出现'),
              onTap: () async {
                Navigator.pop(ctx);
                await blocks.unblock(message.senderId);
              },
            )
          else
            ListTile(
              leading: const Icon(Icons.block_rounded),
              title: const Text('屏蔽这个人'),
              subtitle: const Text('听不到他的声音,也不再显示他的消息'),
              onTap: () async {
                Navigator.pop(ctx);
                await blocks.block(message.senderId);
              },
            ),
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: const Text('举报这条消息'),
            subtitle: const Text('把情况告诉我们,24 小时内处理'),
            onTap: () async {
              Navigator.pop(ctx);
              // 图片消息的 text 是 null,摘录自然是空串 —— 那就干脆传 null,
              // 让 buildReportBody 整行省掉,而不是留一个「消息摘录: 」的空标签。
              final String excerpt = excerptForReport(message.text);
              await showReportFlow(
                context,
                blocks: blocks,
                targetUserId: message.senderId,
                targetName: message.senderName,
                circleId: circleId,
                reporterUserId: reporterUserId,
                messageId: message.id,
                messageExcerpt: excerpt.isEmpty ? null : excerpt,
                delivery: delivery,
              );
            },
          ),
        ],
      ),
    ),
  );
}

/// 举报流程:选分类 → 可选补充说明 → 送达 → 回执 → 顺手问一句要不要屏蔽。
///
/// 三条刻意的设计:
///  1. **什么都不预选**。预选一个分类等于替用户签了字,既不诚实也过不了审核;
///     提交键在选定之前一直是灰的。
///  2. **送达走可注入的 [ReportDelivery]**,默认是 [deliverReport]:
///     拉起邮件 App,同时无条件把正文塞进剪贴板兜底。举报是 1.2 的必查项,
///     这条路任何情况下都不能变成死路。
///  3. **举报完顺手问屏蔽**。举报是「告诉我们」,屏蔽是「我不想再看见他」,
///     两件事都得做用户才真正解脱;但已经屏蔽过的就别再问第二遍。
Future<void> showReportFlow(
  BuildContext context, {
  required BlockStore blocks,
  required String targetUserId,
  required String targetName,
  required String circleId,
  required String reporterUserId,
  String? messageId,
  String? messageExcerpt,
  ReportDelivery? delivery,
}) async {
  ReportReason? reason;
  final TextEditingController note = TextEditingController();
  try {
    final bool? submitted = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setState) {
          final ThemeData theme = Theme.of(ctx);
          return AlertDialog(
            title: Text('举报「$targetName」'),
            // 七个分类 + 输入框在矮窗口里放不下,内容自己滚,
            // 别让对话框顶穿屏幕(与 server_settings_section.dart 同款做法)。
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    '挑一条最贴近的。我们会看完再回你。',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: LaresSpacing.sm),
                  // 用 RadioGroup 祖先统一管组值,而不是给每个 RadioListTile
                  // 传 groupValue/onChanged —— 后两个参数在 Flutter 3.32 之后
                  // 已标 @Deprecated,用了就是一条 deprecated_member_use 警告。
                  // groupValue 初值为 null,所以**一个都不选中**。
                  RadioGroup<ReportReason>(
                    groupValue: reason,
                    onChanged: (ReportReason? picked) =>
                        setState(() => reason = picked),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (final ReportReason r in ReportReason.values)
                          RadioListTile<ReportReason>(
                            value: r,
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(r.label),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: LaresSpacing.sm),
                  TextField(
                    controller: note,
                    minLines: 1,
                    maxLines: _noteMaxLines,
                    maxLength: _noteMaxLength,
                    keyboardType: TextInputType.multiline,
                    style: theme.textTheme.bodyLarge,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '补充说明(可不填)',
                      hintStyle: theme.textTheme.bodyMedium,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(LaresRadii.md),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('算了'),
              ),
              FilledButton(
                // 没选分类就一直灰着。这是「不替用户做选择」的硬保证,
                // 审核员会实测这一点。
                onPressed:
                    reason == null ? null : () => Navigator.pop(ctx, true),
                child: const Text('提交举报'),
              ),
            ],
          );
        },
      ),
    );

    // await 之后 context 可能已经不在树上了(use_build_context_synchronously)
    if (!context.mounted) return;
    if (submitted != true) return;
    final ReportReason? picked = reason;
    if (picked == null) return; // 理论上不可达:没选就提交不了

    final ReportDraft draft = ReportDraft(
      targetUserId: targetUserId,
      targetName: targetName,
      circleId: circleId,
      timestamp: DateTime.now(),
      reason: picked,
      note: note.text,
      reporterUserId: reporterUserId,
      messageId: messageId,
      messageExcerpt: messageExcerpt,
    );

    // 信使必须在 await 之前就捏在手里:送达之后再去 of(context) 就晚了
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await (delivery ?? deliverReport)(draft);
    messenger.showSnackBar(
      const SnackBar(content: Text(_reportAcceptedNotice)),
    );

    if (!context.mounted) return;
    await _showDeliveryInstructions(context);

    // 已经屏蔽过的就别再问一遍 —— 问了只会显得我们没记住
    if (!context.mounted) return;
    if (blocks.isBlocked(targetUserId)) return;
    await _suggestBlock(context, blocks: blocks, targetUserId: targetUserId);
  } finally {
    note.dispose();
  }
}

/// 送达说明。刻意做成**常驻对话框**而不是一条会自己溜走的 SnackBar:
/// 用户可能还要手动点发送,这是必须看清并照做的一步,三秒后消失的提示等于没说。
/// 邮箱用 SelectableText,任何平台都能手动复制。
///
/// 文案要同时对两种结果成立:邮件 App 被拉起来了(多数情况),
/// 以及没拉起来只剩剪贴板(设备没配邮箱等)。所以不写死「已复制,请粘贴」——
/// 那在邮件已经弹出来的时候会让人莫名其妙。
Future<void> _showDeliveryInstructions(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext ctx) {
      final ThemeData theme = Theme.of(ctx);
      return AlertDialog(
        title: const Text('最后一步:把邮件发出来'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '我们已经帮你把举报写好并打开邮件。确认后点发送即可。\n'
              '要是邮件没有自动打开,内容也已经放进剪贴板了 —— '
              '手动新建一封,粘贴后发到:',
            ),
            const SizedBox(height: LaresSpacing.md),
            SelectableText(
              kSupportEmail,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: LaresSpacing.md),
            Text(
              '收到后 24 小时内处理完,结果也回这个邮箱。',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      );
    },
  );
}

/// 举报之后顺手问一句要不要屏蔽。
Future<void> _suggestBlock(
  BuildContext context, {
  required BlockStore blocks,
  required String targetUserId,
}) async {
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: const Text('顺手屏蔽他?'),
      content: const Text('屏蔽后你不会再听到他的声音,也不会看到他的消息。'),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('不用了'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('屏蔽'),
        ),
      ],
    ),
  );
  if (ok == true) await blocks.block(targetUserId);
}

/// 菜单顶部的「你要处置的是谁」。
///
/// 副标题刻意露出稳定 id:昵称能改,id 不能 —— 让用户(和审核员)
/// 一眼确认屏蔽认的是这个 id,而不是某个随时会变的显示名。
class _TargetHeader extends StatelessWidget {
  const _TargetHeader({required this.name, required this.userId});

  final String name;
  final String userId;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListTile(
      leading: const Icon(Icons.person_outline_rounded),
      title: Text(name, style: theme.textTheme.titleLarge),
      subtitle: Text(
        userId.isEmpty ? '拿不到身份标识' : userId,
        style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
      ),
    );
  }
}
