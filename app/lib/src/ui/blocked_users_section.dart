import 'package:flutter/material.dart';

import '../moderation/block_store.dart';
import '../theme/tokens.dart';

/// 屏蔽名单列表区域的最大高度。名单可能很长,给一个有界高度让 ListView 能滚,
/// 否则 Column 里放不下就直接溢出。没有对应的 token,故在此声明。
const double _kBlockedListMaxHeight = 320;

/// 面板里的空状态文案。
///
/// 提成公开常量是因为它的开头与入口 tile 的副标题「还没有屏蔽任何人」重合 ——
/// 测试里用子串去找会同时命中两个 widget。有了这个常量,断言可以精确匹配整句。
const String kBlockedUsersEmptyHint = '还没有屏蔽任何人。\n'
    '在房间里点一下成员,或长按他发的某条消息,就能屏蔽他;'
    '屏蔽之后你不会再收到对方的任何内容。';

/// 设置页的「已屏蔽的人」区块(App Store 审核指南 1.2:UGC 必须能屏蔽滥用者)。
///
/// 形状刻意与 [ServerSettingsSection] 一致:一个下钻 ListTile,点开一个底部面板。
/// 单独成文件同样是为了不把多人在改的 settings_sheet.dart 撑大。
class BlockedUsersSection extends StatelessWidget {
  const BlockedUsersSection({super.key, required this.blocks});

  final BlockStore blocks;

  @override
  Widget build(BuildContext context) {
    final count = blocks.count;
    return ListTile(
      leading: const Icon(Icons.block_rounded),
      title: const Text('已屏蔽的人'),
      subtitle: Text(count == 0 ? '还没有屏蔽任何人' : '共 $count 人'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => showBlockedUsersSheet(context, blocks: blocks),
    );
  }
}

/// 屏蔽名单:逐条解除 / 全部解除
Future<void> showBlockedUsersSheet(
  BuildContext context, {
  required BlockStore blocks,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => ListenableBuilder(
      listenable: blocks,
      builder: (context, _) {
        final ids = blocks.blockedIds.toList(growable: false);
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
                  child: Text('已屏蔽的人',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (ids.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: LaresSpacing.lg,
                      vertical: LaresSpacing.sm,
                    ),
                    child: Text(
                      kBlockedUsersEmptyHint,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                else ...[
                  // 只存 id、只认 id:昵称随时能改,拿昵称当键等于没屏蔽。
                  // 这里如实显示存下来的 id,也让人看得出屏蔽是钉在身份上的。
                  Padding(
                    padding: const EdgeInsets.fromLTRB(LaresSpacing.lg, 0,
                        LaresSpacing.lg, LaresSpacing.sm),
                    child: Text(
                      '我们只记下对方的身份 ID,不记昵称 —— 昵称能改,ID 不能。',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxHeight: _kBlockedListMaxHeight,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: ids.length,
                      itemBuilder: (context, i) {
                        final id = ids[i];
                        return ListTile(
                          leading: const Icon(Icons.person_off_outlined),
                          title: Text(id),
                          trailing: TextButton(
                            onPressed: () => blocks.unblock(id),
                            child: const Text('解除'),
                          ),
                        );
                      },
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.layers_clear_rounded),
                    title: const Text('全部解除'),
                    subtitle: const Text('清空整份名单,之后又能收到他们的内容'),
                    onTap: () => _confirmClearAll(ctx, blocks),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// 清空是不可撤销的,先问一句
Future<void> _confirmClearAll(BuildContext context, BlockStore blocks) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('全部解除屏蔽?'),
      content: const Text('名单会被清空,这些人发的内容又会出现在你这边。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('算了'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('全部解除'),
        ),
      ],
    ),
  );
  if (ok == true) await blocks.clear();
}
