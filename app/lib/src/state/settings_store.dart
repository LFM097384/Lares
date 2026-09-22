// Locale 来自 dart:ui,而 foundation.dart 并**没有**把它再导出
// (只导出了 PlatformDispatcher / VoidCallback / Brightness 这几个)。
// 只 show Locale 是能编译的最窄写法 —— 不为一个类型把整个
// package:flutter/widgets.dart 拉进存储层。
import 'dart:ui' show Locale;

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

/// 界面语言。
///
/// ⚠️ **顺序永远不许调整,新值只许往后加。**
/// 它是按 `.index`(序数)持久化的 —— 跟 `NoiseSuppressionMode` 同一套做法。
/// 把 zh 和 en 换个位置,不会有任何编译错误、任何测试失败,
/// 但**所有已经手动选过语言的老用户下次启动会变成另一种语言**,
/// 而他们什么都没做。这类事故没有任何征兆,只能靠这条注释拦住。
///
/// 刻意**不带任何显示用的字符串**:本项目的 l10n 规约是「模型只存语义键,
/// 翻译发生在 UI 层」。真在这里挂一个 `label`,它要么写死中文、
/// 要么逼着存储层去拿 BuildContext,两条都是错的。
enum AppLanguage { system, zh, en }

class SettingsStore extends ChangeNotifier {
  SettingsStore._();

  static const _kWifiOnlyHq = 'lares.wifiOnlyHq';
  static const _kDndStart = 'lares.dndStart'; // -1 = 未设置
  static const _kDndEnd = 'lares.dndEnd';
  static const _kSignalingOverride = 'lares.signalingOverride';
  static const _kNoiseMode = 'lares.noiseMode';
  static const _kServerProfiles = 'lares.serverProfiles';
  static const _kAppLanguage = 'lares.appLanguage';

  /// 仅 WiFi 下高音质(移动网络自动降码率省流量)
  bool wifiOnlyHq = true;

  /// 免打扰时段(小时 0-23,-1 表示不启用);跨零点时段支持
  int dndStartHour = -1;
  int dndEndHour = -1;

  /// 信令地址覆盖(真机联调:局域网 IP 常变,不用重打包;改动后重启 App 生效)
  String? signalingOverride;

  /// 降噪档位:off / standard(WebRTC APM)/ enhanced(Krisp,平台不支持时自动回落)
  NoiseSuppressionMode noiseMode = NoiseSuppressionMode.standard;

  /// 界面语言。默认跟随系统 —— 绝大多数人装上就该是对的,不该先去设置里挑一次。
  AppLanguage appLanguage = AppLanguage.system;

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
    // 同样 clamp:老版本若存过越界序号(或枚举将来缩短过),
    // 直接取下标会 RangeError 崩在启动路径上 —— 比语言不对严重得多。
    final langIndex = prefs.getInt(_kAppLanguage) ?? AppLanguage.system.index;
    s.appLanguage =
        AppLanguage.values[langIndex.clamp(0, AppLanguage.values.length - 1)];
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

    // ⚠️ 把过期的局域网地址迁到编译进来的那个。
    //
    // `effectiveSignalingUrl` 里**本地存的地址优先于编译值**,这本来是
    // 对的(用户自建服务器就得能覆盖)。但它会让一类升级彻底失效:
    //
    // 2026-09-12 到 09-22,CI 变量被设成联调用的 `ws://10.0.0.185:8787`,
    // 那段时间装过 App 的设备把这个地址存进了本地档案。后来 CI 改回
    // 公网地址、发了新构建 —— 没用,**本地存的旧地址依然优先**,
    // 移动网络下连不上局域网 IP,界面报「对方端口没有开放」。
    //
    // 只迁移明显失效的:局域网/本机地址,且编译值是公网。
    // 用户自己填的公网自建地址不会被碰。
    final compiled = LaresConfig.signalingUrl;
    if (!_isPrivateHost(compiled)) {
      var changed = false;
      final fixed = <ServerProfile>[];
      for (final p in s.serverProfiles.profiles) {
        if (_isPrivateHost(p.url)) {
          fixed.add(p.copyWith(url: compiled, label: compiled));
          changed = true;
        } else {
          fixed.add(p);
        }
      }
      if (s.signalingOverride != null &&
          _isPrivateHost(s.signalingOverride!)) {
        s.signalingOverride = null; // 让它回落到编译值
        changed = true;
      }
      if (changed) {
        s.serverProfiles = ServerProfiles(
          profiles: fixed,
          activeId: s.serverProfiles.activeId,
        );
        await prefs.setString(_kServerProfiles, s.serverProfiles.encode());
        if (s.signalingOverride == null) {
          await prefs.remove(_kSignalingOverride);
        }
      }
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
      // 写完立刻读回验证。
      //
      // ⚠️ 这一步不是多余的。`flutter_secure_storage` 在 iOS 上
      // **不一定抛异常** —— Keychain 可能返回非 0 状态码而插件只是
      // 静默返回。于是「写成功」是假的,下次读出来是 null,
      // 客户端拿空口令去连 → 4401 → 界面再要口令 → 用户以为自己输错了。
      //
      // Windows 走 DPAPI 几乎不会失败,所以这个 bug 只在 iOS 上现形 ——
      // 「Windows 能进、iOS 不能」的真正来源。
      for (final e in active.circlePasscodes.entries) {
        if (e.value.isEmpty) continue;
        final back = await _vault.read(vaultKeyForPasscode(e.key));
        if (back != e.value) {
          lastSecretError = 'keychain_verify_failed:${e.key}';
          debugPrint('[lares] 口令写入后读回不一致(圈 ${e.key}) —— '
              '安全存储可能不可用');
          notifyListeners();
          return;
        }
      }
      lastSecretError = null;
    } catch (err) {
      // 写不进去是真问题,但不该让保存整体失败(URL、鉴权模式这些还是该存下)。
      //
      // ⚠️ 只 debugPrint 等于没说 —— release 构建里它什么都不做。
      // 记成状态让 UI 能读到,否则用户只会看到「口令不对」,
      // 而真相是「口令根本没存进去」。
      lastSecretError = err.toString();
      debugPrint('[lares] 凭据写入安全存储失败: $err');
      notifyListeners();
    }
  }

  /// 最近一次凭据落盘失败的原因;正常时为 null。
  ///
  /// 存在的意义是让「存不进去」这件事**可见**。它曾经只进 debugPrint,
  /// 而 release 版里 debugPrint 是空操作 —— 于是 iOS 上 Keychain
  /// 不可用时,用户只会反复看到「口令不对」,永远不知道真正发生了什么。
  String? lastSecretError;

  /// 切到某个信令地址 —— 已有该地址的档案就激活它,没有就建一个。
  ///
  /// 给邀请链接用:链接里带 `server=` 时,被邀请的人不该先手动去设置里
  /// 换服务器(他根本不知道要做这一步)。朋友的圈子多半在朋友的服务器上,
  /// 而地址不是秘密,所以链接带上它、这里自动切过去。
  ///
  /// **复用已有档案而不是每次新建**:否则每点一次邀请链接就多一条
  /// 同地址的档案,而它们各自存着口令 —— 用户会看到一堆重复项,
  /// 且不知道哪条才是在用的。
  Future<void> switchToServer(String url) async {
    final v = ServerProfile.validateUrl(url);
    if (!v.isValid) return; // 链接里的地址不合法就当没带,别把好的配置换坏
    final normalized = v.normalized!;

    final existing = serverProfiles.profiles
        .where((p) => p.url == normalized)
        .firstOrNull;
    if (existing != null) {
      if (serverProfiles.activeId == existing.id) return; // 已经在用了
      await setServerProfiles(ServerProfiles(
        profiles: serverProfiles.profiles,
        activeId: existing.id,
      ));
      return;
    }

    // 新建。鉴权模式给 circle —— 邀请链接指向的圈子几乎必然要口令,
    // 而 none 模式下口令根本不会被读到(见 credentialFor 的 switch)。
    final id = serverProfiles.newId();
    await setServerProfiles(ServerProfiles(
      profiles: [
        ...serverProfiles.profiles,
        ServerProfile(
          id: id,
          // 标签用地址本身:比一个翻译过的「朋友的服务器」更有信息量,
          // 也不需要在存储层依赖 BuildContext。
          label: normalized,
          url: normalized,
          authMode: AuthMode.circle,
        ),
      ],
      activeId: id,
    ));
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

  Future<void> setAppLanguage(AppLanguage value) async {
    appLanguage = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kAppLanguage, value.index);
  }

  /// 传给 `MaterialApp.locale` 的值。
  ///
  /// ⚠️ `system` 必须映射成 **null**,而不是「去读一下设备语言再传进来」。
  /// 传 null 时 Flutter 用的是 `_resolvedLocale` —— 它由
  /// `platformDispatcher.locales`(**整个列表**,不是第一项)经同一个
  /// `localeResolutionCallback` 算出来的,于是系统语言不受支持时会命中
  /// 我们那条 `return const Locale('en')` 兜底。
  ///
  /// 若改成传设备 locale,就等于把「跟随系统」降级成「跟随系统语言的第一项」:
  /// 用户系统里排第二的中文会被无视,而 App Store 主语言回落英文这条规矩
  /// 也会绕过 Flutter 自己的多语言协商。两者都是静默的行为退化。
  Locale? get preferredLocale => switch (appLanguage) {
        AppLanguage.system => null,
        AppLanguage.zh => const Locale('zh'),
        AppLanguage.en => const Locale('en'),
      };

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

/// 这个地址是不是局域网/本机 —— 发布构建里出现就是配置事故的残留。
///
/// 判据故意宽松:宁可多迁一个(反正会换成编译进来的公网地址),
/// 也不要把用户困在一个连不上的地址上。
bool _isPrivateHost(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  if (host.isEmpty) return false;
  if (host == 'localhost' || host == '127.0.0.1' || host == '::1') return true;
  if (host.startsWith('10.')) return true;
  if (host.startsWith('192.168.')) return true;
  // 172.16.0.0/12
  final m = RegExp(r'^172\.(\d+)\.').firstMatch(host);
  if (m != null) {
    final second = int.tryParse(m.group(1)!) ?? 0;
    if (second >= 16 && second <= 31) return true;
  }
  return false;
}
