import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/update/version.dart';

void main() {
  group('版本解析', () {
    test('去 v 前缀 / 补齐缺省段', () {
      expect(LaresVersion.tryParse('v0.1.0')!.display, '0.1.0');
      expect(LaresVersion.tryParse('V1.2.3')!.display, '1.2.3');
      expect(LaresVersion.tryParse('  v2.0.0  ')!.display, '2.0.0');
      expect(LaresVersion.tryParse('v1')!.display, '1.0.0');
      expect(LaresVersion.tryParse('1.5')!.display, '1.5.0');
    });

    test('+build 元数据被剥离,不进入展示', () {
      final v = LaresVersion.tryParse('0.1.0+1')!;
      expect(v.display, '0.1.0');
      expect(v.build, '1');
    });

    test('预发布后缀按点拆段', () {
      final v = LaresVersion.tryParse('1.0.0-rc.2')!;
      expect(v.preRelease, ['rc', '2']);
      expect(v.isPreRelease, isTrue);
      expect(v.display, '1.0.0-rc.2');
    });

    test('畸形输入返回 null 而不抛异常', () {
      for (final bad in <String?>[
        null,
        '',
        '   ',
        'v',
        'abc',
        'v.x.y',
        '1.2.x',
        'not-a-version',
        '💥',
      ]) {
        expect(
          () => LaresVersion.tryParse(bad),
          returnsNormally,
          reason: '输入 $bad 不应抛异常',
        );
        expect(LaresVersion.tryParse(bad), isNull, reason: '输入 $bad 应解析失败');
      }
    });
  });

  group('版本比较(核心回归)', () {
    // 这是自动更新最经典的事故:字符串比较下 "0.10.0" < "0.9.0"
    test('v0.10.0 严格新于 v0.9.0', () {
      expect(isNewerVersion('v0.10.0', 'v0.9.0'), isTrue);
      expect(isNewerVersion('v0.9.0', 'v0.10.0'), isFalse);
    });

    test('更多逐段数值比较', () {
      expect(isNewerVersion('v1.0.0', 'v0.99.99'), isTrue);
      expect(isNewerVersion('v0.2.10', 'v0.2.9'), isTrue);
      expect(isNewerVersion('v0.10.1', 'v0.10.0'), isTrue);
      expect(isNewerVersion('v2.0.0', 'v10.0.0'), isFalse);
      expect(isNewerVersion('v1.20.0', 'v1.3.0'), isTrue);
    });

    test('1.0.0 新于 1.0.0-beta(正式版 > 预发布)', () {
      expect(isNewerVersion('1.0.0', '1.0.0-beta'), isTrue);
      expect(isNewerVersion('1.0.0-beta', '1.0.0'), isFalse);
    });

    test('预发布之间按 semver 规则比较', () {
      expect(isNewerVersion('1.0.0-rc.2', '1.0.0-rc.1'), isTrue);
      expect(isNewerVersion('1.0.0-beta', '1.0.0-alpha'), isTrue);
      expect(isNewerVersion('1.0.0-rc.10', '1.0.0-rc.9'), isTrue);
      // 数字段优先级低于文本段
      expect(isNewerVersion('1.0.0-alpha.beta', '1.0.0-alpha.1'), isTrue);
      // 段数多的更大
      expect(isNewerVersion('1.0.0-rc.1.1', '1.0.0-rc.1'), isTrue);
    });

    test('版本相等:含 v 前缀与 +build 差异都不算更新', () {
      expect(isNewerVersion('v0.1.0', '0.1.0'), isFalse);
      expect(isNewerVersion('v0.1.0', '0.1.0+1'), isFalse);
      expect(isNewerVersion('v0.1.0+99', '0.1.0+1'), isFalse);
      expect(LaresVersion.tryParse('1.0.0+5'), LaresVersion.tryParse('1.0.0+9'));
    });

    test('build 元数据完全不参与比较', () {
      final a = LaresVersion.tryParse('1.0.0+100')!;
      final b = LaresVersion.tryParse('1.0.0+2')!;
      expect(a.compareTo(b), 0);
    });

    test('任一侧无法解析时判定为「无更新」(安全的失败方向)', () {
      expect(isNewerVersion('garbage', '0.1.0'), isFalse);
      expect(isNewerVersion('v9.9.9', 'garbage'), isFalse);
      expect(isNewerVersion(null, '0.1.0'), isFalse);
    });

    test('排序稳定性:一组版本升序排列符合预期', () {
      final versions = [
        'v1.0.0',
        'v0.9.0',
        'v1.0.0-beta',
        'v0.10.0',
        'v0.1.0+1',
        'v1.0.0-rc.1',
      ].map((e) => LaresVersion.tryParse(e)!).toList()..sort();

      expect(
        versions.map((e) => e.display).toList(),
        ['0.1.0', '0.9.0', '0.10.0', '1.0.0-beta', '1.0.0-rc.1', '1.0.0'],
      );
    });
  });
}
