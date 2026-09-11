import 'package:shared_preferences/shared_preferences.dart';

/// 本地身份:MVP 无账号体系,userId/deviceId 本地生成并持久化。
/// 后续接入真实账号时只需替换本类的 load()。
class Identity {
  Identity({required this.userId, required this.deviceId, required this.name});

  final String userId;
  final String deviceId;
  final String name;

  static const _kUserId = 'lares.userId';
  static const _kDeviceId = 'lares.deviceId';
  static const _kName = 'lares.name';

  static Future<Identity> load() async {
    final prefs = await SharedPreferences.getInstance();
    var userId = prefs.getString(_kUserId);
    var deviceId = prefs.getString(_kDeviceId);
    if (userId == null) {
      userId = 'u_${_randId()}';
      await prefs.setString(_kUserId, userId);
    }
    if (deviceId == null) {
      deviceId = 'd_${_randId()}';
      await prefs.setString(_kDeviceId, deviceId);
    }
    return Identity(
      userId: userId,
      deviceId: deviceId,
      name: prefs.getString(_kName) ?? '我',
    );
  }

  static Future<void> saveName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kName, name);
  }

  static String _randId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    return now.toRadixString(36);
  }
}
