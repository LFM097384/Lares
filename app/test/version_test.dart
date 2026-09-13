import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/update/version.dart';

/// 版本比较是自动更新的地基:判错方向会让全体用户装错包,或永远收不到更新。
/// 这里刻意把真实场景里会出现的形态全列出来。
void main() {
  group('LaresVersion.tryParse', () {
    test('GitHub tag 的 v 前缀被剥离', () {
      final v = LaresVersion.tryParse('v0.1.0');
      expect(v, isNotNull);
      expect(v!.major, 0);
      expect(v.minor, 1);
      expect(v.patch, 0);
      expect(v.raw, 'v0.1.0'); // 原样保留供 UI 展示
    });

    test('Flutter 的 +build 后缀被切掉且不参与比较', () {
      final v = LaresVersion.tryParse('0.1.0+1');
      expect(v!.build, '1');
      expect(v.display, '0.1.0'); // 展示不含 build
      // semver 明文规定 build 元数据不参与比较
      expect(LaresVersion.tryParse('0.1.0+9')! == LaresVersion.tryParse('0.1.0+1')!, isTrue);
    });

    test('预发布后缀按点拆段', () {
      expect(LaresVersion.tryParse('1.0.0-rc.2')!.preRelease, ['rc', '2']);
      expect(LaresVersion.tryParse('1.0.0-beta')!.isPreRelease, isTrue);
      expect(LaresVersion.tryParse('1.0.0')!.isPreRelease, isFalse);
    });

    test('缺省的 minor/patch 补 0', () {
      final v = LaresVersion.tryParse('v2');
      expect(v!.display, '2.0.0');
    });

    test('畸形输入返回 null 而不抛异常(畸形 tag 不能让 App 崩)', () {
      for (final bad in [
        null, '', '   ', 'v', 'abc', '1.x.0', 'v1.2.c', '..', '-1.0.0',
      ]) {
        expect(() => LaresVersion.tryParse(bad), returnsNormally,
            reason: '输入 $bad 不应抛异常');
        expect(LaresVersion.tryParse(bad), isNull, reason: '输入 $bad 应解析失败');
      }
    });
  });

  group('版本比较', () {
    test('0.10.0 > 0.9.0 —— 自动更新最经典的事故', () {
      // 字符串比较会判成小于('1' < '9'),必须是逐段数值比较
      expect(isNewerVersion('v0.10.0', 'v0.9.0'), isTrue);
      expect(isNewerVersion('v0.9.0', 'v0.10.0'), isFalse);
      // 同类:patch 段
      expect(isNewerVersion('1.0.10', '1.0.9'), isTrue);
      // 同类:major 段
      expect(isNewerVersion('10.0.0', '9.0.0'), isTrue);
    });

    test('预发布版小于同号正式版', () {
      expect(isNewerVersion('1.0.0', '1.0.0-beta'), isTrue);
      expect(isNewerVersion('1.0.0-beta', '1.0.0'), isFalse);
    });

    test('预发布之间逐段比较', () {
      expect(isNewerVersion('1.0.0-rc.2', '1.0.0-rc.1'), isTrue);
      expect(isNewerVersion('1.0.0-rc.10', '1.0.0-rc.2'), isTrue); // 数值而非字典序
      expect(isNewerVersion('1.0.0-beta', '1.0.0-alpha'), isTrue);
      // 数字段优先级低于文本段(semver 规则)
      expect(isNewerVersion('1.0.0-alpha', '1.0.0-1'), isTrue);
      // 段数多的更大
      expect(isNewerVersion('1.0.0-rc.1.1', '1.0.0-rc.1'), isTrue);
    });

    test('相同版本不触发更新', () {
      expect(isNewerVersion('v0.1.0', '0.1.0'), isFalse);
      expect(isNewerVersion('v0.1.0', '0.1.0+1'), isFalse); // build 不算差异
      expect(isNewerVersion('0.1.0+2', '0.1.0+1'), isFalse);
    });

    test('旧版本不触发更新', () {
      expect(isNewerVersion('v0.1.0', 'v0.2.0'), isFalse);
    });

    test('任一侧解析失败一律返回 false(宁可漏报不可误报)', () {
      expect(isNewerVersion('garbage', '0.1.0'), isFalse);
      expect(isNewerVersion('0.2.0', 'garbage'), isFalse);
      expect(isNewerVersion(null, '0.1.0'), isFalse);
      expect(isNewerVersion('0.2.0', null), isFalse);
    });

    test('排序自洽(compareTo 可用于 sort)', () {
      final vs = [
        '1.0.0', '0.9.0', '0.10.0', '1.0.0-rc.1', '1.0.0-beta', '2.0.0',
      ].map(LaresVersion.tryParse).whereType<LaresVersion>().toList()..sort();
      expect(vs.map((v) => v.display).toList(),
          ['0.9.0', '0.10.0', '1.0.0-beta', '1.0.0-rc.1', '1.0.0', '2.0.0']);
    });
  });
}
