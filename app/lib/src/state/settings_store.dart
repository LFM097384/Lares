import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_credential.dart';
import '../net/server_profile.dart';
import '../rtc/rtc_service.dart' show NoiseSuppressionMode, AudioTuning;

/// 设置(§2.2 耗电与流量透明度、防打扰),本地持久化。
class SettingsStore extends ChangeNotifier {
  SettingsStore._();

  static const _kWifiOnlyHq = 'lares.wifiOnlyHq';
  static const _kDndStart = 'lares.dndStart'; // -1 = 未设置
  static const _kDndEnd = 'lares.dndEnd';
  static const _kSignalingOverride = 'lares.signalingOverride';
  static const _kNoiseMode = 'lares.noiseMode';
  static const _kServerProfiles = 'lares.serverProfiles';

  /// 仅 WiFi 下高音质(移动网络自动降码率省流量)
  bool wifiOnlyHq = true;

  /// 免打扰时段(小时 0-23,-1 表示不启用);跨零点时段支持
  int dndStartHour = -1;
  int dndEndHour = -1;

  /// 信令地址覆盖(真机联调:局域网 IP 常变,不用重打包;改动后重启 App 生效)
  String? signalingOverride;

  /// 降噪档位:off / standard(WebRTC APM)/ enhanced(Krisp,平台不支持时自动回落)
  NoiseSuppressionMode noiseMode = NoiseSuppressionMode.standard;

  /// 具名服务器档案(标签 + 地址 + 鉴权配置,选一个生效)。
  ///
  /// 取代单一的 signalingOverride:主人有两套部署(自建 VPS / LiveKit Cloud + 自建信令)
  /// 要来回切。老的 signalingOverride 仍然保留并在 load() 里自动迁移过来。
  ///
  /// ⚠️ 明文存储警告:令牌与圈口令都存在 shared_preferences 里,
  /// 在 Android/iOS/Windows/Web 上**都是明文**(XML / plist / 本地文件 / localStorage)。
  /// 这不是安全存储,拿到设备文件即可读出。本轮不引入 secure storage 依赖,
  /// 如实标注;设置页也向用户明说了这一点。
  ServerProfiles serverProfiles = ServerProfiles.empty;

  /// 当前生效的服务器档案(没有档案时为 null,调用方回落到编译期默认地址)
  ServerProfile? get activeProfile => serverProfiles.active;

  /// 当前生效的信令地址;没有档案时回落到老的 signalingOverride
  String? get effectiveSignalingUrl =>
      serverProfiles.active?.url ?? signalingOverride;

  /// 取某个圈子当前该用的凭据(供 SignalingClient 的 CredentialSource 回调)
  AuthCredential credentialFor(String? circleId) =>
      serverProfiles.active?.credentialFor(circleId) ?? AuthCredential.none;

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
    // 服务器档案:没存过就从老的 signalingOverride 迁移一份过来,别让人丢设置
    final rawProfiles = prefs.getString(_kServerProfiles);
    if (rawProfiles == null) {
      final migrated = ServerProfiles.migrateLegacy(s.signalingOverride);
      s.serverProfiles = migrated;
      if (migrated.profiles.isNotEmpty) {
        await prefs.setString(_kServerProfiles, migrated.encode());
      }
    } else {
      s.serverProfiles = ServerProfiles.decode(rawProfiles);
    }
    return s;
  }

  /// 整体替换档案集合(增删改选都走这里,保证持久化与通知一致)
  Future<void> setServerProfiles(ServerProfiles value) async {
    serverProfiles = value;
    // 与老字段保持同步:老代码路径(main.dart 回落)仍读 signalingOverride
    signalingOverride = value.active?.url ?? signalingOverride;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kServerProfiles, value.encode());
  }

  /// 新增或更新一个档案(按 id 覆盖),并可顺手设为当前
  Future<void> upsertProfile(ServerProfile profile, {bool activate = false}) {
    final list = <ServerProfile>[];
    var replaced = false;
    for (final p in serverProfiles.profiles) {
      if (p.id == profile.id) {
        list.add(profile);
        replaced = true;
      } else {
        list.add(p);
      }
    }
    if (!replaced) list.add(profile);
    return setServerProfiles(ServerProfiles(
      profiles: list,
      activeId: activate ? profile.id : serverProfiles.activeId,
    ));
  }

  Future<void> removeProfile(String id) {
    final list = [
      for (final p in serverProfiles.profiles)
        if (p.id != id) p,
    ];
    return setServerProfiles(ServerProfiles(
      profiles: list,
      activeId: serverProfiles.activeId == id
          ? (list.isEmpty ? null : list.first.id)
          : serverProfiles.activeId,
    ));
  }

  Future<void> setActiveProfile(String id) =>
      setServerProfiles(serverProfiles.copyWith(activeId: id));

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
