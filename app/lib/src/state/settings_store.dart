import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rtc/rtc_service.dart' show NoiseSuppressionMode, AudioTuning;

/// 设置(§2.2 耗电与流量透明度、防打扰),本地持久化。
class SettingsStore extends ChangeNotifier {
  SettingsStore._();

  static const _kWifiOnlyHq = 'lares.wifiOnlyHq';
  static const _kDndStart = 'lares.dndStart'; // -1 = 未设置
  static const _kDndEnd = 'lares.dndEnd';
  static const _kSignalingOverride = 'lares.signalingOverride';
  static const _kNoiseMode = 'lares.noiseMode';

  /// 仅 WiFi 下高音质(移动网络自动降码率省流量)
  bool wifiOnlyHq = true;

  /// 免打扰时段(小时 0-23,-1 表示不启用);跨零点时段支持
  int dndStartHour = -1;
  int dndEndHour = -1;

  /// 信令地址覆盖(真机联调:局域网 IP 常变,不用重打包;改动后重启 App 生效)
  String? signalingOverride;

  /// 降噪档位:off / standard(WebRTC APM)/ enhanced(Krisp,平台不支持时自动回落)
  NoiseSuppressionMode noiseMode = NoiseSuppressionMode.standard;

  static Future<SettingsStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = SettingsStore._();
    s.wifiOnlyHq = prefs.getBool(_kWifiOnlyHq) ?? true;
    s.dndStartHour = prefs.getInt(_kDndStart) ?? -1;
    s.dndEndHour = prefs.getInt(_kDndEnd) ?? -1;
    s.signalingOverride = prefs.getString(_kSignalingOverride);
    // clamp:防止旧版本存了越界的枚举序号导致崩溃
    final modeIndex = prefs.getInt(_kNoiseMode) ?? NoiseSuppressionMode.standard.index;
    s.noiseMode = NoiseSuppressionMode
        .values[modeIndex.clamp(0, NoiseSuppressionMode.values.length - 1)];
    return s;
  }

  Future<void> setNoiseMode(NoiseSuppressionMode value) async {
    noiseMode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kNoiseMode, value.index);
  }

  /// 供 RoomController 传给 rtc.join()
  AudioTuning get audioTuning => AudioTuning(mode: noiseMode);

  Future<void> setSignalingOverride(String? url) async {
    signalingOverride = (url == null || url.trim().isEmpty) ? null : url.trim();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (signalingOverride == null) {
      await prefs.remove(_kSignalingOverride);
    } else {
      await prefs.setString(_kSignalingOverride, signalingOverride!);
    }
  }

  bool get dndEnabled => dndStartHour >= 0 && dndEndHour >= 0;

  /// 当前是否处于免打扰时段(支持 22:00-7:00 跨零点)
  bool get inDndNow {
    if (!dndEnabled) return false;
    final h = DateTime.now().hour;
    if (dndStartHour == dndEndHour) return true; // 全天
    return dndStartHour < dndEndHour
        ? (h >= dndStartHour && h < dndEndHour)
        : (h >= dndStartHour || h < dndEndHour);
  }

  Future<void> setWifiOnlyHq(bool value) async {
    wifiOnlyHq = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kWifiOnlyHq, value);
  }

  Future<void> setDnd(int startHour, int endHour) async {
    dndStartHour = startHour;
    dndEndHour = endHour;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kDndStart, startHour);
    await prefs.setInt(_kDndEnd, endHour);
  }
}
