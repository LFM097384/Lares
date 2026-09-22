/// 改昵称的**唯一**保存路径。
///
/// ## 为什么要有这个文件
///
/// 改名有两个入口:主屏头像旁的编辑按钮、设置页「我」分组里的那一行。
/// 它们曾经各写各的保存逻辑,于是漂移了 —— 主屏那个写死
/// `maxLength: 12`,设置页按 24 走。同一个字段两套上限,
/// 用户从哪个口子进去决定他能起多长的名字,这不是设计,是事故。
///
/// 把「保存」收成一个函数之后,漂移就没有立足之地了:上限只有一处
/// ([maxNicknameGraphemes]),截断只有一处([capNickname]),
/// 落盘也只有一处。对话框长什么样各自去管,那是外观,不是规则。
library;

import '../state/identity.dart';
import '../state/room_controller.dart';

/// 保存昵称:截断 → 广播给圈里的人 → 落盘。
///
/// [raw] 是用户原样输入的文字,不必预先 trim 或截断 —— 那正是这里要做的。
/// 返回真正生效的那个名字;输入去掉空白后为空时返回 null 且**什么都不做**
/// (不广播、不落盘)。
///
/// ⚠️ 落盘的必须是**截断后**的值,不能是 `raw`。
/// 否则下次启动会加载回一个超长的名字,而 `rename()` 会再把它截短 ——
/// 于是「存的」和「用的」永远差一截,名字每次启动都自己变一下。
Future<String?> saveMyNickname(RoomController controller, String raw) async {
  final name = capNickname(raw);
  if (name.isEmpty) return null;
  // 先 rename 再落盘:rename 是纯内存 + 发帧,不会失败;
  // 落盘要等平台通道。顺序反过来的话,用户要多等一个来回才看到名字变。
  controller.rename(name);
  await Identity.saveName(name);
  return name;
}
