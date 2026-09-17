/// ICE 配置(STUN / TURN)的持久化。
///
/// 这些地址**默认为空**,而且刻意不内置任何公共服务器 ——
/// 内置一个 Google STUN 就等于给「不依赖任何人」这件事悄悄开了个后门。
/// 要用就由用户自己填,填了才知道自己在依赖谁。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'p2p_session.dart';

class IceStore extends ChangeNotifier {
  IceStore._(this._config);

  static const _kStun = 'lares.p2p.stun';
  static const _kTurnUrl = 'lares.p2p.turnUrl';
  static const _kTurnUser = 'lares.p2p.turnUser';
  // TURN 口令算凭据,但它不像圈口令那样能派生出加密密钥,
  // 泄露的后果是「别人能蹭你的中继带宽」,不是「别人能听你说话」。
  // 所以存 prefs 就够,没必要动用 SecretVault 那套。
  static const _kTurnPass = 'lares.p2p.turnPass';

  IceConfig _config;
  IceConfig get config => _config;

  /// 有没有中继。没有的话,穿不过 NAT 就是彻底连不上 ——
  /// UI 要据此把话说在前面,而不是让用户连失败了才知道。
  bool get hasTurn => _config.turn != null;

  static Future<IceStore> load() async {
    final p = await SharedPreferences.getInstance();
    final stun = p.getStringList(_kStun) ?? const <String>[];
    final turnUrl = p.getString(_kTurnUrl) ?? '';
    final turnUser = p.getString(_kTurnUser) ?? '';
    final turnPass = p.getString(_kTurnPass) ?? '';
    return IceStore._(IceConfig(
      stunUrls: stun,
      // 三样缺一就不算配好 —— 半个 TURN 配置比没有更糟:
      // 它会让连接尝试挂在那儿等超时,而不是当场失败。
      turn: (turnUrl.isNotEmpty && turnUser.isNotEmpty && turnPass.isNotEmpty)
          ? TurnConfig(
              url: turnUrl,
              username: turnUser,
              credential: turnPass,
            )
          : null,
    ));
  }

  Future<void> setStun(List<String> urls) async {
    final cleaned = [
      for (final u in urls)
        if (u.trim().isNotEmpty) u.trim(),
    ];
    _config = IceConfig(stunUrls: cleaned, turn: _config.turn);
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kStun, cleaned);
  }

  Future<void> setTurn({
    required String url,
    required String username,
    required String credential,
  }) async {
    final u = url.trim();
    final n = username.trim();
    final c = credential.trim();
    _config = IceConfig(
      stunUrls: _config.stunUrls,
      turn: (u.isNotEmpty && n.isNotEmpty && c.isNotEmpty)
          ? TurnConfig(url: u, username: n, credential: c)
          : null,
    );
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kTurnUrl, u);
    await p.setString(_kTurnUser, n);
    await p.setString(_kTurnPass, c);
  }

  Future<void> clearTurn() =>
      setTurn(url: '', username: '', credential: '');
}
