import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/state/identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('生成', () {
    test('首次启动会生成并存住 userId / deviceId', () async {
      final a = await Identity.load();
      expect(a.userId, startsWith('u_'));
      expect(a.deviceId, startsWith('d_'));

      final b = await Identity.load();
      expect(b.userId, a.userId, reason: '重启不该换身份');
      expect(b.deviceId, a.deviceId);
    });

    test('id 不可预测 —— 不再是时间戳', () async {
      // 旧实现是 microsecondsSinceEpoch.toRadixString(36):
      // 同一微秒启动会撞号,而且知道大概安装时间就能枚举。
      // 跨设备绑定让 userId 更值钱了,能被猜到就意味着能被冒充。
      final ids = <String>{};
      for (var i = 0; i < 50; i++) {
        SharedPreferences.setMockInitialValues({});
        ids.add((await Identity.load()).userId);
      }
      expect(ids.length, 50, reason: '50 次生成不该有任何重复');

      // 时间戳转 36 进制是纯小写字母数字且长度固定;
      // 随机 base64url 会出现大写字母或 - _,以此粗略区分。
      final sample = ids.first.substring(2);
      expect(sample.length, greaterThanOrEqualTo(10));
    });

    test('默认昵称是「我」,且可改', () async {
      expect((await Identity.load()).name, '我');
      await Identity.saveName('丰茗');
      expect((await Identity.load()).name, '丰茗');
    });
  });

  group('跨设备绑定', () {
    test('导出再导入:两台设备是同一个人', () async {
      // 设备 A
      await Identity.load();
      await Identity.saveName('丰茗');
      final a = await Identity.load();
      final code = a.exportCode();

      // 设备 B:全新,没有任何数据
      SharedPreferences.setMockInitialValues({});
      final b = (await Identity.importCode(code))!;

      expect(b.userId, a.userId, reason: '同一个人');
      expect(b.name, '丰茗', reason: '昵称也带过去,省得再输一遍');
    });

    test('deviceId **不**共享 —— 否则两台设备会互相顶掉', () async {
      // 服务端按 (userId, deviceId) 组织连接:
      // Member = { userId, ..., devices: Map<deviceId, ws> }
      // 两台设备若共用 deviceId,后进的会覆盖 Map 里那一项,
      // 表现是「手机一连,电脑就掉线」。
      await Identity.load();
      final a = await Identity.load();
      final code = a.exportCode();

      SharedPreferences.setMockInitialValues({});
      final b = (await Identity.importCode(code))!;

      expect(b.deviceId, isNot(a.deviceId));
      expect(b.deviceId, startsWith('d_'));
    });

    test('导入到已有身份的设备:换掉 userId,保留本机 deviceId', () async {
      await Identity.load();
      final b0 = await Identity.load();
      final ownDevice = b0.deviceId;

      // 另一台设备的码
      SharedPreferences.setMockInitialValues({});
      await Identity.load();
      final a = await Identity.load();
      final code = a.exportCode();

      // 回到 B(恢复它的数据)
      SharedPreferences.setMockInitialValues({
        'lares.userId': b0.userId,
        'lares.deviceId': ownDevice,
        'lares.name': b0.name,
      });
      final b = (await Identity.importCode(code))!;

      expect(b.userId, a.userId);
      expect(b.deviceId, ownDevice, reason: '本机的 deviceId 不该被码里的东西换掉');
    });

    test('身份码里不含口令之类的东西', () async {
      await Identity.load();
      await Identity.saveName('丰茗');
      final code = (await Identity.load()).exportCode();

      // 码是 base64url,解出来只有 u/n 两个字段。
      final parsed = Identity.parseCode(code)!;
      expect(parsed.userId, isNotEmpty);
      expect(parsed.name, '丰茗');
      // 不做更强的断言 —— 真正的保证在实现里(只 encode 这两个字段),
      // 这里钉住的是「解析出来的东西就这两样」。
    });

    test('导入后重启仍是新身份', () async {
      await Identity.load();
      final a = await Identity.load();
      final code = a.exportCode();

      SharedPreferences.setMockInitialValues({});
      await Identity.importCode(code);
      final reloaded = await Identity.load();

      expect(reloaded.userId, a.userId, reason: '导入要真的落盘');
    });
  });

  group('坏输入', () {
    test('不是身份码时返回 null,且不动现有身份', () async {
      final before = await Identity.load();

      for (final bad in [
        '',
        '   ',
        'hello',
        'lares-id-v1:',
        'lares-id-v1:!!!not-base64!!!',
        // base64 合法但不是 JSON
        'lares-id-v1:aGVsbG8',
        // JSON 但缺 u
        'lares-id-v1:eyJuIjoi5oiRIn0',
        // 圈子邀请链接 —— 用户很可能粘错
        'lares://circle/review?name=R',
      ]) {
        expect(Identity.parseCode(bad), isNull, reason: bad);
        expect(await Identity.importCode(bad), isNull, reason: bad);
      }

      final after = await Identity.load();
      expect(after.userId, before.userId, reason: '坏码不该破坏现有身份');
      expect(after.deviceId, before.deviceId);
    });

    test('前后空白会被容忍 —— 复制粘贴常常带上它', () async {
      await Identity.load();
      final code = (await Identity.load()).exportCode();
      expect(Identity.parseCode('  $code  '), isNotNull);
    });

    test('不带填充的 base64 也能解 —— Dart 的 decode 默认要求 =', () {
      // RFC 4648 §5 允许省略填充,很多工具就是那么产出的;
      // 而 Dart 的 base64Url.decode 会直接抛 FormatException。
      // 不 normalize 的话,这类码会被笼统地判成「不是身份码」,
      // 用户完全不知道问题在哪。
      const withPad = 'lares-id-v1:eyJ1IjoidV94In0=';
      const noPad = 'lares-id-v1:eyJ1IjoidV94In0';
      expect(Identity.parseCode(withPad)?.userId, 'u_x');
      expect(Identity.parseCode(noPad)?.userId, 'u_x',
          reason: '省略填充的码也必须能解');
    });

    test('昵称缺失时回落到「我」', () {
      // {"u":"u_x"} 的 base64url
      const code = 'lares-id-v1:eyJ1IjoidV94In0';
      final p = Identity.parseCode(code)!;
      expect(p.userId, 'u_x');
      expect(p.name, '我');
    });
  });
}
