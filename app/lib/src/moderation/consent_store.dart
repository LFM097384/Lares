import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内容规范 / EULA 的同意状态,本地持久化。
///
/// 存的是**版本号(int)而不是 bool**:规范文本以后要改,
/// 只要把 [currentPolicyVersion] 加一,所有人下次启动就会重新被问一遍。
/// 存成 bool 的话,老用户会永远停在他们当初同意的那份旧文本上。
///
/// 键里没写过值(或写的是 0)= 从来没同意过。
class ConsentStore extends ChangeNotifier {
  ConsentStore._();

  static const _kAccepted = 'lares.contentPolicyAcceptedVersion';

  /// 当前内容规范的版本。改动 content_policy_text.dart 的实质条款时,这里加一。
  static const int currentPolicyVersion = 1;

  int _acceptedVersion = 0;

  /// 用户同意过的规范版本;0 表示从未同意。
  int get acceptedVersion => _acceptedVersion;

  /// 是否已经同意了「当前这一版」规范。
  bool get accepted => _acceptedVersion >= currentPolicyVersion;

  static Future<ConsentStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = ConsentStore._();
    s._acceptedVersion = prefs.getInt(_kAccepted) ?? 0;
    return s;
  }

  /// 记下「同意了当前版本」。
  Future<void> accept() async {
    _acceptedVersion = currentPolicyVersion;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kAccepted, currentPolicyVersion);
  }

  /// 撤回同意,回到从未同意的状态(测试用,也给调试入口留一个口子)。
  Future<void> revoke() async {
    _acceptedVersion = 0;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kAccepted, 0);
  }
}
