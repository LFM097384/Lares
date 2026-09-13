import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/auth/auth_credential.dart';
import 'package:lares_app/src/net/server_profile.dart';

void main() {
  group('信令地址校验', () {
    test('生产地址:显式非标端口 + /ws 路径原样保留', () {
      final r = ServerProfile.validateUrl('wss://rtc.example.com:8444/ws');
      expect(r.isValid, isTrue);
      expect(r.normalized, 'wss://rtc.example.com:8444/ws');
    });

    test('局域网联调地址:ws + IP + 端口', () {
      final r = ServerProfile.validateUrl('ws://10.0.0.185:8787');
      expect(r.isValid, isTrue);
      expect(r.normalized, 'ws://10.0.0.185:8787');
    });

    test('不写端口时不自作主张补默认端口', () {
      final r = ServerProfile.validateUrl('wss://rtc.example.com/ws');
      expect(r.isValid, isTrue);
      expect(r.normalized, 'wss://rtc.example.com/ws');
      expect(r.normalized, isNot(contains(':443')));
    });

    test('首尾空格自动去掉(手机上复制粘贴常带)', () {
      final r = ServerProfile.validateUrl('  wss://a.com:9000/ws  ');
      expect(r.normalized, 'wss://a.com:9000/ws');
    });

    test('http/https 是最常见手误,给出可照做的提示', () {
      final r = ServerProfile.validateUrl('https://rtc.example.com:8444/ws');
      expect(r.isValid, isFalse);
      expect(r.error, contains('wss://'));

      final r2 = ServerProfile.validateUrl('http://rtc.example.com/ws');
      expect(r2.isValid, isFalse);
      expect(r2.error, contains('ws://'));
    });

    test('其它 scheme 明确拒绝,而不是含糊失败', () {
      final r = ServerProfile.validateUrl('ftp://a.com');
      expect(r.isValid, isFalse);
      expect(r.error, contains('ftp'));
    });

    test('缺 scheme 时提示补 ws://', () {
      final r = ServerProfile.validateUrl('rtc.example.com:8444/ws');
      expect(r.isValid, isFalse);
      expect(r.error, isNotNull);
    });

    test('空地址被拒', () {
      expect(ServerProfile.validateUrl('').isValid, isFalse);
      expect(ServerProfile.validateUrl('   ').isValid, isFalse);
      expect(ServerProfile.validateUrl('').error, '地址不能为空');
    });

    test('缺主机名被拒', () {
      final r = ServerProfile.validateUrl('wss://');
      expect(r.isValid, isFalse);
      expect(r.error, contains('主机名'));
    });
  });

  group('档案凭据', () {
    test('token 模式取全局令牌', () {
      const p = ServerProfile(
        id: 'p1',
        label: 'VPS',
        url: 'wss://a.com/ws',
        authMode: AuthMode.token,
        token: 'tk',
      );
      final c = p.credentialFor('home');
      expect(c.mode, AuthMode.token);
      expect(c.token, 'tk');
      expect(c.isComplete, isTrue);
    });

    test('circle 模式按圈取口令,不同圈不同口令', () {
      const p = ServerProfile(
        id: 'p1',
        label: 'VPS',
        url: 'wss://a.com/ws',
        authMode: AuthMode.circle,
        circlePasscodes: {'home': 'h-pass', 'work': 'w-pass'},
      );
      expect(p.credentialFor('home').passcode, 'h-pass');
      expect(p.credentialFor('work').passcode, 'w-pass');
      // 没配口令的圈子:凭据不完整,客户端据此不去连
      expect(p.credentialFor('other').isComplete, isFalse);
    });

    test('none 模式返回空凭据', () {
      const p = ServerProfile(id: 'p1', label: 'x', url: 'ws://a/ws');
      expect(p.credentialFor('home'), AuthCredential.none);
    });
  });

  group('档案集合序列化', () {
    test('编码解码往返无损', () {
      const profiles = ServerProfiles(
        profiles: [
          ServerProfile(
            id: 'p1',
            label: '家里的 VPS',
            url: 'wss://rtc.example.com:8444/ws',
            authMode: AuthMode.circle,
            circlePasscodes: {'home': '开门'},
          ),
          ServerProfile(
            id: 'p2',
            label: 'LiveKit Cloud',
            url: 'wss://cloud.example.com/ws',
            authMode: AuthMode.token,
            token: 'tk',
          ),
        ],
        activeId: 'p2',
      );
      final back = ServerProfiles.decode(profiles.encode());

      expect(back.profiles, hasLength(2));
      expect(back.activeId, 'p2');
      expect(back.active!.label, 'LiveKit Cloud');
      expect(back.profiles.first.circlePasscodes['home'], '开门');
      expect(back.profiles.first.authMode, AuthMode.circle);
      expect(back.profiles.first.url, 'wss://rtc.example.com:8444/ws');
    });

    test('存坏了当作空,不崩', () {
      expect(ServerProfiles.decode('{ not json').profiles, isEmpty);
      expect(ServerProfiles.decode('').profiles, isEmpty);
      expect(ServerProfiles.decode(null).profiles, isEmpty);
      expect(ServerProfiles.decode('[1,2,3]').profiles, isEmpty);
    });

    test('单条坏档案被丢弃,其它档案照常还原', () {
      const good = ServerProfiles(
        profiles: [ServerProfile(id: 'p1', label: 'a', url: 'ws://a/ws')],
        activeId: 'p1',
      );
      final raw = good.encode().replaceFirst(
          '"profiles":[', '"profiles":[{"label":"缺 url"},');
      final back = ServerProfiles.decode(raw);
      expect(back.profiles, hasLength(1));
      expect(back.profiles.single.id, 'p1');
    });

    test('activeId 失效时兜底用第一个,不会忽然掉回默认服务器', () {
      const s = ServerProfiles(
        profiles: [ServerProfile(id: 'p1', label: 'a', url: 'ws://a/ws')],
        activeId: 'gone',
      );
      expect(s.active!.id, 'p1');
    });

    test('空集合没有 active,调用方回落到编译期默认地址', () {
      expect(ServerProfiles.empty.active, isNull);
    });

    test('newId 不与现有 id 冲突', () {
      const s = ServerProfiles(
        profiles: [
          ServerProfile(id: 'p1', label: 'a', url: 'ws://a/ws'),
          ServerProfile(id: 'p2', label: 'b', url: 'ws://b/ws'),
        ],
        activeId: 'p1',
      );
      expect(s.newId(), isNot('p1'));
      expect(s.newId(), isNot('p2'));
    });
  });

  group('老设置迁移', () {
    test('老的单条 signalingOverride 被搬进档案并设为当前', () {
      final s = ServerProfiles.migrateLegacy('ws://10.0.0.185:8787');
      expect(s.profiles, hasLength(1));
      expect(s.active, isNotNull);
      expect(s.active!.url, 'ws://10.0.0.185:8787');
      expect(s.active!.label, '我的服务器');
      // 老版本没有鉴权概念,迁过来自然是 none
      expect(s.active!.authMode, AuthMode.none);
    });

    test('从没设过覆盖地址:迁移出空集合,继续用打包内置地址', () {
      expect(ServerProfiles.migrateLegacy(null).profiles, isEmpty);
      expect(ServerProfiles.migrateLegacy('').profiles, isEmpty);
      expect(ServerProfiles.migrateLegacy('   ').profiles, isEmpty);
    });

    test('迁移后的档案能正常序列化持久化', () {
      final s = ServerProfiles.migrateLegacy('wss://a.com:8444/ws');
      final back = ServerProfiles.decode(s.encode());
      expect(back.active!.url, 'wss://a.com:8444/ws');
    });
  });
}
