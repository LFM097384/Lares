import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 屏蔽名单(App Store 审核指南 1.2:UGC 必须能屏蔽滥用者),本地持久化。
///
/// **为什么键是 userId 而不是昵称**:
/// 昵称(`ChatMessage.senderName`)是用户随时能改的显示名,拿它当键等于没屏蔽 ——
/// 对方改个名字就重新出现在你眼前,审核同学也一定会这么试。
/// `userId`(`app/lib/src/state/identity.dart` 生成的 `u_xxxxxxx`,
/// 同时也是 LiveKit 的 `participant.identity`)是设备级稳定标识,改昵称不影响它。
/// 所以这里存的、比对的、落盘的,全程只认 userId。
///
/// 存的是一个 [Set]:查询 O(1),且天然不会有重复项。
class BlockStore extends ChangeNotifier {
  BlockStore._();

  static const _kBlocked = 'lares.blockedIds';

  /// 被屏蔽的 userId 集合。私有,外部只能拿只读视图。
  final Set<String> _blocked = <String>{};

  static Future<BlockStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = BlockStore._();
    final raw = prefs.getStringList(_kBlocked) ?? const <String>[];
    // 顺手洗掉空串:旧存档/手改存档里混进空值的话,
    // 下游一个 isBlocked('') 就可能把所有人都屏蔽掉。
    for (final id in raw) {
      if (id.trim().isNotEmpty) s._blocked.add(id);
    }
    return s;
  }

  /// 是否屏蔽了某人。空/纯空白 id 一律返回 false ——
  /// 防御性的:消息头里的 sid 解析失败时是空串,绝不能因此「屏蔽所有人」。
  bool isBlocked(String userId) {
    if (userId.trim().isEmpty) return false;
    return _blocked.contains(userId);
  }

  /// 只读视图,给设置页列表渲染用
  Set<String> get blockedIds => Set<String>.unmodifiable(_blocked);

  int get count => _blocked.length;

  /// 屏蔽某人。空 id 或已在名单里都是静默 no-op:
  /// 不通知、不落盘,免得 UI 白闪一下。
  Future<void> block(String userId) async {
    if (userId.trim().isEmpty) return;
    if (!_blocked.add(userId)) return; // add 返回 false 表示本来就有
    notifyListeners();
    await _save();
  }

  /// 解除屏蔽。不在名单里就什么也不做。
  Future<void> unblock(String userId) async {
    if (!_blocked.remove(userId)) return;
    notifyListeners();
    await _save();
  }

  /// 清空名单(设置页的「全部解除」)
  Future<void> clear() async {
    if (_blocked.isEmpty) return;
    _blocked.clear();
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kBlocked, _blocked.toList(growable: false));
  }
}
