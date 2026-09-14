import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/auth/auth_credential.dart';
import 'package:lares_app/src/net/secret_vault.dart';
import 'package:lares_app/src/net/server_profile.dart';
import 'package:lares_app/src/state/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `SettingsStore` 与 `SecretVault` 的接线测试。
///
/// 核心契约:**口令不进明文 prefs,但重启之后还能读回来。**
/// 这两件事必须同时成立 —— 只做到前者是把用户的口令弄丢,
/// 只做到后者等于没改。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('口令写入后:prefs 里没有明文,vault 里有', () async {
    final vault = InMemorySecretVault();
    final s = await SettingsStore.load(vault: vault);

    await s.setServerProfiles(const ServerProfiles(
      profiles: [
        ServerProfile(
          id: 'p1',
          label: '家里',
          url: 'wss://rtc.example.com:8444/ws',
          authMode: AuthMode.circle,
          circlePasscodes: {'home': '开门吧'},
        ),
      ],
      activeId: 'p1',
    ));

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('lares.serverProfiles') ?? '';
    expect(raw, isNot(contains('开门吧')), reason: '口令不得落进明文 prefs');
    expect(raw, contains('home'), reason: '但要记下哪个圈子配过口令');
    expect(await vault.read(vaultKeyForPasscode('home')), '开门吧');
  });

  test('重启之后口令仍能读回来(同一个 vault)', () async {
    final vault = InMemorySecretVault();
    final s1 = await SettingsStore.load(vault: vault);
    await s1.setServerProfiles(const ServerProfiles(
      profiles: [
        ServerProfile(
          id: 'p1',
          label: '家里',
          url: 'wss://x/ws',
          authMode: AuthMode.circle,
          circlePasscodes: {'home': '开门吧'},
        ),
      ],
      activeId: 'p1',
    ));

    // 模拟重启:同一份 prefs + 同一个 vault,重新 load
    final s2 = await SettingsStore.load(vault: vault);
    expect(s2.credentialFor('home').passcode, '开门吧');
  });

  test('清空口令要连 vault 里那条一起删 —— 否则重启又回来了', () async {
    final vault = InMemorySecretVault();
    final s = await SettingsStore.load(vault: vault);
    const base = ServerProfile(
      id: 'p1',
      label: '家里',
      url: 'wss://x/ws',
      authMode: AuthMode.circle,
      circlePasscodes: {'home': '开门吧'},
    );
    await s.setServerProfiles(
      const ServerProfiles(profiles: [base], activeId: 'p1'),
    );
    expect(await vault.read(vaultKeyForPasscode('home')), '开门吧');

    // 用户清空了口令
    await s.setServerProfiles(ServerProfiles(
      profiles: [base.copyWith(circlePasscodes: const {'home': ''})],
      activeId: 'p1',
    ));
    expect(await vault.read(vaultKeyForPasscode('home')), isNull,
        reason: '删了就得真删,否则下次启动被 hydrate 填回来');
  });

  test('老版本的明文口令会被搬进 vault 并从 prefs 抹掉', () async {
    // 造一份「老格式」:口令直接躺在 JSON 里
    const legacy = ServerProfiles(
      profiles: [
        ServerProfile(
          id: 'p1',
          label: '家里',
          url: 'wss://x/ws',
          authMode: AuthMode.circle,
          token: '老令牌',
          circlePasscodes: {'home': '老口令'},
        ),
      ],
      activeId: 'p1',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'lares.serverProfiles': legacy.encode(includeSecrets: true),
    });

    final vault = InMemorySecretVault();
    final s = await SettingsStore.load(vault: vault);

    // 搬进 vault 了
    expect(await vault.read(vaultKeyForPasscode('home')), '老口令');
    expect(await vault.read(kVaultKeyToken), '老令牌');
    // 内存里仍然用得上
    expect(s.credentialFor('home').passcode, '老口令');
    // 明文源被抹掉
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('lares.serverProfiles') ?? '';
    expect(raw, isNot(contains('老口令')));
    expect(raw, isNot(contains('老令牌')));
  });

  test('vault 不可用时退回内存:能用但不持久,且如实标注', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final s = await SettingsStore.load(vault: _BrokenVault());
    expect(s.vaultAvailable, isFalse,
        reason: 'UI 要据此向用户说实话,不能假装安全');
  });
}

/// 模拟平台不支持安全存储(Linux 缺 libsecret、Web 等)。
class _BrokenVault implements SecretVault {
  @override
  Future<String?> read(String key) async => throw UnimplementedError();
  @override
  Future<void> write(String key, String value) async =>
      throw UnimplementedError();
  @override
  Future<void> delete(String key) async => throw UnimplementedError();
  @override
  Future<Map<String, String>> readAll() async => throw UnimplementedError();
}
