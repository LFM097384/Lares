import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_credential.dart';
import '../config.dart';
import '../net/secret_migration.dart';
import '../net/secret_vault.dart';
import '../net/server_profile.dart';
import '../rtc/rtc_service.dart' show NoiseSuppressionMode, AudioTuning;

/// 设置(§2.2 耗电与流量透明度、防打扰),本地持久化。
/// 测试可把它设为 true,让 [SettingsStore.load] 走内存 vault。
///
/// 为什么需要这个开关:`flutter test` 里没有平台通道,
/// `flutter_secure_storage` 会**挂起**而不是报错 —— 症状是整个测试套件超时,
/// 且没有任何失败信息。踩过一次。
///
/// 没做成自动探测(读 `FLUTTER_TEST` 环境变量)是因为那要 `dart:io`,
/// 而这个文件要能在 Web 上编译。显式开关反而更直白。
@visibleForTesting
bool debugUseInMemoryVault = false;

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

  /// 按**指定服务器**取凭据(跨服务器 presence 用)。
  ///
  /// 与 [credentialFor] 的区别:那个只看当前选中的档案。
  /// 同时连多台服务器时,每条链路必须用**它自己那台**的口令认证 ——
  /// 拿甲服务器的口令去乙服务器,轻则 4401,重则(若两边恰好同口令)
  /// 让人误以为跨服务器是「一个身份」,而它根本不是。
  AuthCredential credentialForServer(String serverId, String? circleId) {
    for (final p in serverProfiles.profiles) {
      if (p.id == serverId) return p.credentialFor(circleId);
    }
    return AuthCredential.none;
  }

  /// 敏感值(令牌 / 圈口令)的权威存储。
  ///
  /// 这些东西**不再**写进 `shared_preferences` —— 那在所有平台上都是明文,
  /// 而 E2EE 的密钥由圈口令派生,口令泄露 = 密钥泄露。
  /// prefs 里只留「哪些圈子配过口令」这个事实,值本身归 vault。
  SecretVault _vault = InMemorySecretVault();

  /// vault 在本设备上是否真的可用(Linux 缺 libsecret、Web 没有系统安全存储
  /// 等情况下为 false)。UI 可以据此向用户说实话。
  bool vaultAvailable = false;

  static Future<SettingsStore> load({SecretVault? vault}) async {
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

    // ── 敏感值:迁移 + 从 vault 取回 ──
    //
    // 测试环境下不碰真实 vault:`flutter test` 里没有平台通道,
    // flutter_secure_storage 会挂起而不是报错(症状是整个测试套件超时,
    // 且**没有任何失败信息**)。踩过一次,别再让它发生。
    final v = vault ??
        (debugUseInMemoryVault
            ? InMemorySecretVault()
            : PlatformSecretVault());
    s.vaultAvailable = await probeSecretVault(v);
    // vault 不可用时退回内存实现:这次能用,重启就没了。
    // 那比悄悄写回明文好 —— 后者会让用户以为自己受保护。
    s._vault = s.vaultAvailable ? v : InMemorySecretVault();

    // 1) 老版本留下的明文口令,搬进 vault 再抹掉源。
    //    幂等:搬过的会被跳过;任何一条失败就整批不清源。
    final active = s.serverProfiles.active;
    if (active != null && s.vaultAvailable) {
      final plainPasses = <String, String>{
        for (final e in active.circlePasscodes.entries)
          if (e.value.isNotEmpty) e.key: e.value,
      };
      if (plainPasses.isNotEmpty || active.token.isNotEmpty) {
        final report = await migrateSecretsToVault(
          vault: s._vault,
          plaintextPasscodes: plainPasses,
          plaintextToken: active.token,
          // 清源 = 用不含敏感值的格式重写一遍 prefs。
          clearPlaintext: () async => prefs.setString(
            _kServerProfiles,
            s.serverProfiles.encode(),
          ),
        );
        if (report.didAnything) debugPrint('[lares] $report');
      }
    }

    // 2) 把 vault 里的值填回内存对象,供 UI 与鉴权使用。
    //    走到这里时 decode 已经为「配过口令的圈子」占位成空串。
    if (s.vaultAvailable) await s._hydrateFromVault();

    return s;
  }

  /// 从 vault 取回令牌与各圈口令,填进内存里的档案对象。
  ///
  /// 只填**当前生效**的那个档案 —— 其余档案在被选中时再填,
  /// 避免启动时把 vault 翻一遍(每次读都是一次平台通道往返)。
  Future<void> _hydrateFromVault() async {
    final active = serverProfiles.active;
    if (active == null) return;
    try {
      final token = await _vault.read(kVaultKeyToken) ?? active.token;
      final passes = <String, String>{};
      for (final id in active.circlePasscodes.keys) {
        final got = await _vault.read(vaultKeyForPasscode(id));
        // 读不到就保留内存里已有的值(可能是刚输入还没落盘的)
        passes[id] = got ?? active.circlePasscodes[id] ?? '';
      }
      final filled = active.copyWith(token: token, circlePasscodes: passes);
      serverProfiles = ServerProfiles(
        profiles: [
          for (final p in serverProfiles.profiles)
            if (p.id == filled.id) filled else p,
        ],
        activeId: serverProfiles.activeId,
      );
    } catch (e) {
      // 读不出来不该让 App 起不来 —— 退化成「没配过口令」,
      // 用户重新输一次即可,总好过白屏。
      debugPrint('[lares] 从安全存储取回凭据失败: $e');
    }
  }

  /// 整体替换档案集合(增删改选都走这里,保证持久化与通知一致)
  Future<void> setServerProfiles(ServerProfiles value) async {
    serverProfiles = value;
    // 与老字段保持同步:老代码路径(main.dart 回落)仍读 signalingOverride
    signalingOverride = value.active?.url ?? signalingOverride;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    // encode() 默认不含敏感值 —— 口令与令牌走下面的 vault。
    await prefs.setString(_kServerProfiles, value.encode());
    await _persistSecrets(value);
  }

  /// 把敏感值写进 vault。
  ///
  /// ⚠️ 删除也要处理:用户清空某个圈子的口令时,必须把 vault 里那条也删掉,
  /// 否则下次启动又会被 `_hydrateFromVault()` 填回来 —— 表现是
  /// 「明明删了,重启又回来了」。
  Future<void> _persistSecrets(ServerProfiles value) async {
    final active = value.active;
    if (active == null) return;
    try {
      if (active.token.isNotEmpty) {
        await _vault.write(kVaultKeyToken, active.token);
      } else {
        await _vault.delete(kVaultKeyToken);
      }
      for (final e in active.circlePasscodes.entries) {
        final key = vaultKeyForPasscode(e.key);
        if (e.value.isNotEmpty) {
          await _vault.write(key, e.value);
        } else {
          await _vault.delete(key);
        }
      }
    } catch (err) {
      // 写不进去是真问题,但不该让保存整体失败(URL、鉴权模式这些还是该存下)。
      // 说出来,别假装成功。
      debugPrint('[lares] 凭据写入安全存储失败: $err');
    }
  }

  /// 给某个圈子记一个口令,并保证它**真的会被用上**。
  ///
  /// ## 为什么不能只写 `circlePasscodes[circleId] = pass`
  ///
  /// 口令只在 `authMode == AuthMode.circle` 时才会被 [credentialFor] 读到
  /// (见 `ServerProfile.credentialFor` 的 switch)。于是有两种「写了等于没写」:
  ///
  /// 1. **一个档案都没有**(全新安装的绝大多数用户):`active` 为 null,
  ///    根本没有地方可写;
  /// 2. **档案存在但 authMode 是 none**:值存进去了,但取凭据时那条 case
  ///    直接返回 `AuthCredential.none`,口令一辈子不会被用到。
  ///
  /// 这两种情况恰恰就是本功能要解决的场景 —— 用户刚通过邀请链接加了个圈子。
  /// 静默无效比不提供输入框更糟:用户填了、按了重试、又被拒,
  /// 而界面没有任何线索说明为什么。所以这里**顺手把档案补齐**。
  ///
  /// ## 边界:绝不动用户显式配过的 token 模式
  ///
  /// `authMode == AuthMode.token` 表示用户(或运维)明确选了共享令牌那套。
  /// 把它改成 circle 会让一个本来能用的配置当场连不上
  /// —— 因为 circle 模式下 [AuthCredential.isComplete] 要求口令非空,
  /// 而 `SignalingClient.connect()` 对不完整的凭据**拒绝连接**。
  /// 所以 token 模式下只把口令存下来(将来切到 circle 模式即刻可用),
  /// 并返回 false 告诉调用方「存了,但这台服务器现在不吃这一套」。
  ///
  /// 返回值:口令是否会**立即生效**。false 时 UI 应当如实告知用户
  /// 还需要去设置里调整服务器配置,不要假装成功。
  Future<bool> setCirclePasscode(String circleId, String passcode) async {
    final id = circleId.trim();
    if (id.isEmpty) return false;

    final active = serverProfiles.active;

    // 情况 1:一个档案都没有 —— 就地建一个,地址用当前实际在用的那个。
    if (active == null) {
      final profileId = serverProfiles.newId();
      final created = ServerProfile(
        id: profileId,
        // 标签不走 ARB:这是存储层,不该依赖 BuildContext。
        // 用地址本身当名字,比一个翻译过的「我的服务器」更有信息量。
        label: effectiveSignalingUrl ?? LaresConfig.signalingUrl,
        url: effectiveSignalingUrl ?? LaresConfig.signalingUrl,
        authMode: AuthMode.circle,
        circlePasscodes: {id: passcode},
      );
      await setServerProfiles(ServerProfiles(
        profiles: [...serverProfiles.profiles, created],
        activeId: profileId,
      ));
      return true;
    }

    final merged = <String, String>{...active.circlePasscodes, id: passcode};

    // 情况 2:token 模式 —— 只存,不改模式(理由见上)。
    if (active.authMode == AuthMode.token) {
      await upsertProfile(active.copyWith(circlePasscodes: merged));
      return false;
    }

    // 情况 3:none 或已经是 circle。
    //
    // none -> circle 是安全的升级:none 意味着用户从没配过鉴权
    // (多半是本地开发默认值或迁移过来的老 signalingOverride),
    // 而此刻用户正在**亲手输入一个圈子口令**,意图不言自明。
    await upsertProfile(active.copyWith(
      authMode: AuthMode.circle,
      circlePasscodes: merged,
    ));
    return true;
  }

  /// 某个圈子当前存着的口令(没有则空串)。供 UI 预填输入框。
  String passcodeFor(String circleId) =>
      serverProfiles.active?.circlePasscodes[circleId] ?? '';

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
