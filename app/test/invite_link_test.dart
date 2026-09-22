import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/net/secret_vault.dart';
import 'package:lares_app/src/state/invite_link.dart';
import 'package:lares_app/src/state/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('解析', () {
    test('完整链接:圈子、名字、服务器、口令都读出来', () {
      final r = parseInviteLink(
        'lares://circle/review?name=Review&server=wss%3A%2F%2Fa.example.com%3A443%2Fws&pass=amber-cedar',
      )!;
      expect(r.circleId, 'review');
      expect(r.name, 'Review');
      expect(r.serverUrl, 'wss://a.example.com:443/ws');
      expect(r.passcode, 'amber-cedar');
      expect(r.hasServer, isTrue);
      expect(r.hasPasscode, isTrue);
    });

    test('只有圈子和名字(旧格式)仍然能用', () {
      // 向后兼容:此前发出去的链接不带 server/pass。
      final r = parseInviteLink('lares://circle/review?name=Review')!;
      expect(r.circleId, 'review');
      expect(r.name, 'Review');
      expect(r.serverUrl, isNull);
      expect(r.passcode, isNull);
      expect(r.hasServer, isFalse);
      expect(r.hasPasscode, isFalse);
    });

    test('裸圈子 id', () {
      final r = parseInviteLink('review')!;
      expect(r.circleId, 'review');
      expect(r.name, isNull);
      expect(r.hasServer, isFalse);
    });

    test('前后空白会被去掉 —— 粘贴常常带上它', () {
      expect(parseInviteLink('  review  ')!.circleId, 'review');
      expect(
        parseInviteLink(' lares://circle/review?name=X ')!.circleId,
        'review',
      );
    });

    test('解析不出圈子时返回 null', () {
      expect(parseInviteLink(''), isNull);
      expect(parseInviteLink('   '), isNull);
      expect(parseInviteLink('lares://circle/'), isNull);
      // 粘错了整段话:含空白的裸输入不是圈子 id
      expect(parseInviteLink('快进来 review 圈'), isNull);
    });

    test('空的查询参数当作没传', () {
      final r = parseInviteLink('lares://circle/review?name=&server=&pass=')!;
      expect(r.name, isNull);
      expect(r.serverUrl, isNull);
      expect(r.passcode, isNull);
    });

    test('中文名与特殊字符能还原', () {
      final link = buildInviteLink(circleId: 'home', name: '家人 & 我');
      final r = parseInviteLink(link)!;
      expect(r.circleId, 'home');
      expect(r.name, '家人 & 我');
    });
  });

  group('生成', () {
    test('默认不带口令 —— 口令进链接等于把 E2EE 密钥发出去', () {
      final link = buildInviteLink(
        circleId: 'review',
        name: 'Review',
        serverUrl: 'wss://a.example.com/ws',
      );
      expect(link, contains('server='));
      expect(link, isNot(contains('pass=')));
    });

    test('显式传口令时才带上', () {
      final link = buildInviteLink(
        circleId: 'review',
        name: 'Review',
        passcode: 'amber-cedar',
      );
      expect(link, contains('pass='));
    });

    test('生成的链接能被自己解析回来(往返一致)', () {
      const cases = [
        ('review', 'Review', 'wss://a.example.com:443/ws', 'p@ss word&=?'),
        ('home', '家人', null, null),
        ('x', 'A B', null, '带空格 的口令'),
      ];
      for (final (id, name, server, pass) in cases) {
        final link = buildInviteLink(
          circleId: id,
          name: name,
          serverUrl: server,
          passcode: pass,
        );
        final r = parseInviteLink(link)!;
        expect(r.circleId, id, reason: link);
        expect(r.name, name, reason: link);
        expect(r.serverUrl, server, reason: link);
        expect(r.passcode, pass, reason: link);
      }
    });

    test('口令里的 & 和 = 不会把链接切坏', () {
      // 这是最容易出错的一类:不转义的话 pass=a&b 会被当成两个参数。
      final link = buildInviteLink(
        circleId: 'c',
        name: 'N',
        passcode: 'a&b=c',
      );
      expect(parseInviteLink(link)!.passcode, 'a&b=c');
    });
  });

  group('switchToServer:链接带地址时自动切过去', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('没有任何档案时,建一个并激活', () async {
      final s = await SettingsStore.load(vault: InMemorySecretVault());
      await s.switchToServer('wss://friend.example.com:8444/ws');

      final active = s.serverProfiles.active;
      expect(active, isNotNull);
      expect(active!.url, 'wss://friend.example.com:8444/ws');
      // circle 模式:邀请链接指向的圈子几乎必然要口令,
      // 而 none 模式下口令根本不会被 credentialFor 读到。
      expect(active.authMode.name, 'circle');
    });

    test('同一地址点第二次:复用已有档案,不重复建', () async {
      final s = await SettingsStore.load(vault: InMemorySecretVault());
      await s.switchToServer('wss://friend.example.com/ws');
      final firstId = s.serverProfiles.activeId;
      final count = s.serverProfiles.profiles.length;

      await s.switchToServer('wss://friend.example.com/ws');

      expect(s.serverProfiles.profiles.length, count,
          reason: '每点一次链接就多一条同地址档案,用户会看到一堆重复项');
      expect(s.serverProfiles.activeId, firstId);
    });

    test('非法地址不动现有配置 —— 别把好的换坏', () async {
      final s = await SettingsStore.load(vault: InMemorySecretVault());
      await s.switchToServer('wss://good.example.com/ws');
      final before = s.serverProfiles.active!.url;

      await s.switchToServer('这不是地址');

      expect(s.serverProfiles.active!.url, before);
    });
  });
}