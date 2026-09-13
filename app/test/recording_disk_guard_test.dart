import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/recording/disk_guard.dart';

/// 在 [dir] 下造一个 [size] 字节、修改时间为 [ageDays] 天前的文件。
///
/// 修改时间必须显式设置:靠"先写 A 再写 B"来制造新旧差异在快速测试里不可靠 ——
/// 两次写入可能落在同一个文件系统时间戳刻度上,排序就成了随机的。
File makeFile(
  Directory dir, {
  required String name,
  required int size,
  double ageDays = 0,
  DateTime? now,
}) {
  final File f = File('${dir.path}${Platform.pathSeparator}$name');
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(List<int>.filled(size, 65));
  final DateTime base = now ?? DateTime.now();
  f.setLastModifiedSync(
    base.subtract(Duration(milliseconds: (ageDays * 86400000).round())),
  );
  return f;
}

int totalBytes(Directory dir) {
  int t = 0;
  for (final FileSystemEntity e in dir.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (e is File) t += e.statSync().size;
  }
  return t;
}

Set<String> namesIn(Directory dir) {
  final Set<String> out = <String>{};
  for (final FileSystemEntity e in dir.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (e is File) out.add(e.uri.pathSegments.last);
  }
  return out;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('lares_diskguard_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('总量上限', () {
    test('超出上限时从最旧的开始删,直到降到水位线以下', () async {
      final DateTime now = DateTime.now();
      // 5 个 1000 字节文件 = 5000;上限 3000 -> 水位线 2700,
      // 因此要删到 ≤2700,即删掉 3 个最旧的(剩 2000)。
      for (int i = 0; i < 5; i++) {
        makeFile(
          tmp,
          name: 'f$i.jsonl',
          size: 1000,
          ageDays: (5 - i).toDouble(),
          now: now,
        );
      }

      const DiskGuard guard = DiskGuard(
        policy: RetentionPolicy(
          maxTotalBytes: 3000,
          maxAge: Duration(days: 3650),
        ),
      );
      final CleanupReport r = await guard.enforce(tmp, now: now);

      expect(r.deletedCount, 3);
      expect(r.reclaimedBytes, 3000);
      expect(r.remainingBytes, 2000);
      expect(totalBytes(tmp), lessThanOrEqualTo(guard.policy.highWaterBytes));
      // 留下的必须是最新的两个
      expect(namesIn(tmp), <String>{'f3.jsonl', 'f4.jsonl'});
      expect(r.failedCount, 0);
    });

    test('清理后的占用降到水位线以下,不与事前预判形成死区', () async {
      final DateTime now = DateTime.now();
      for (int i = 0; i < 10; i++) {
        makeFile(
          tmp,
          name: 'f$i.bin',
          size: 100,
          ageDays: (10 - i).toDouble(),
          now: now,
        );
      }

      const DiskGuard guard = DiskGuard(
        policy: RetentionPolicy(
          maxTotalBytes: 1000,
          maxAge: Duration(days: 3650),
        ),
      );
      await guard.enforce(tmp, now: now);

      // 清理刚跑完,预判必须认为"还能再写一点",否则录音会永久卡死。
      expect(await guard.wouldExceed(tmp, 0), isFalse);
    });

    test('未超上限的目录被完全保留,一个文件都不动', () async {
      final DateTime now = DateTime.now();
      for (int i = 0; i < 4; i++) {
        makeFile(
          tmp,
          name: 'f$i.bin',
          size: 100,
          ageDays: i.toDouble(),
          now: now,
        );
      }
      final Set<String> before = namesIn(tmp);

      const DiskGuard guard = DiskGuard(
        policy: RetentionPolicy(
          maxTotalBytes: 1000000,
          maxAge: Duration(days: 3650),
        ),
      );
      final CleanupReport r = await guard.enforce(tmp, now: now);

      expect(r.deletedCount, 0);
      expect(r.reclaimedBytes, 0);
      expect(r.didAnything, isFalse);
      expect(namesIn(tmp), equals(before));
      expect(r.remainingBytes, 400);
    });

    test('子目录里的文件同样参与统计与清理', () async {
      final DateTime now = DateTime.now();
      makeFile(tmp, name: 'c1${Platform.pathSeparator}old.jsonl',
          size: 2000, ageDays: 10, now: now);
      makeFile(tmp, name: 'c2${Platform.pathSeparator}new.jsonl',
          size: 1000, ageDays: 1, now: now);

      const DiskGuard guard = DiskGuard(
        policy: RetentionPolicy(
          maxTotalBytes: 1500,
          maxAge: Duration(days: 3650),
        ),
      );
      final CleanupReport r = await guard.enforce(tmp, now: now);

      expect(r.deletedCount, 1);
      expect(namesIn(tmp), <String>{'new.jsonl'});
    });
  });

  group('保留窗', () {
    test('超龄文件一律删除,与总量是否超标无关', () async {
      final DateTime now = DateTime.now();
      makeFile(tmp, name: 'old.jsonl', size: 10, ageDays: 40, now: now);
      makeFile(tmp, name: 'fresh.jsonl', size: 10, ageDays: 2, now: now);

      // 上限极大,绝不会因为总量触发删除;删除只能来自保留窗。
      const DiskGuard guard = DiskGuard(
        policy: RetentionPolicy(
          maxTotalBytes: 1 << 30,
          maxAge: Duration(days: 30),
        ),
      );
      final CleanupReport r = await guard.enforce(tmp, now: now);

      expect(r.deletedCount, 1);
      expect(namesIn(tmp), <String>{'fresh.jsonl'});
      expect(r.deletedPaths.single, contains('old'));
    });

    test('恰好在保留窗边缘内侧的文件被保留', () async {
      final DateTime now = DateTime.now();
      makeFile(tmp, name: 'edge.jsonl', size: 10, ageDays: 29.5, now: now);

      const DiskGuard guard = DiskGuard(
        policy: RetentionPolicy(
          maxTotalBytes: 1 << 30,
          maxAge: Duration(days: 30),
        ),
      );
      await guard.enforce(tmp, now: now);
      expect(namesIn(tmp), contains('edge.jsonl'));
    });

    test('两条规则叠加:先删超龄,再按总量补删', () async {
      final DateTime now = DateTime.now();
      makeFile(tmp, name: 'ancient.bin', size: 500, ageDays: 100, now: now);
      makeFile(tmp, name: 'old.bin', size: 500, ageDays: 5, now: now);
      makeFile(tmp, name: 'mid.bin', size: 500, ageDays: 3, now: now);
      makeFile(tmp, name: 'new.bin', size: 500, ageDays: 1, now: now);

      // 上限 1200 -> 水位线 1080。
      const DiskGuard guard = DiskGuard(
        policy: RetentionPolicy(
          maxTotalBytes: 1200,
          maxAge: Duration(days: 30),
        ),
      );
      final CleanupReport r = await guard.enforce(tmp, now: now);

      // ancient 因超龄被删(与总量无关),剩 1500 仍高于水位线 1080,
      // 于是再按总量补删最旧的 old,降到 1000 <= 1080 为止。
      expect(r.deletedCount, 2);
      expect(namesIn(tmp), <String>{'mid.bin', 'new.bin'});
      expect(r.remainingBytes, 1000);
    });
  });

  group('活动文件保护', () {
    test('正在写入的文件即使最旧、即使超标也绝不删除', () async {
      final DateTime now = DateTime.now();
      final File active = makeFile(
        tmp,
        name: 'active.jsonl',
        size: 5000,
        ageDays: 99, // 最旧
        now: now,
      );
      makeFile(tmp, name: 'other.jsonl', size: 1000, ageDays: 1, now: now);

      const DiskGuard guard = DiskGuard(
        policy: RetentionPolicy(maxTotalBytes: 100, maxAge: Duration(days: 30)),
      );
      final CleanupReport r = await guard.enforce(
        tmp,
        activeFile: active,
        now: now,
      );

      expect(active.existsSync(), isTrue, reason: '活动文件被删了,这是必须避免的陷阱');
      expect(namesIn(tmp), <String>{'active.jsonl'});
      expect(r.deletedCount, 1);
      // 活动文件撑着,剩余量必然仍高于上限 —— 这是正确且预期的结果
      expect(r.remainingBytes, greaterThan(100));
    });

    test('活动文件超龄也不删', () async {
      final DateTime now = DateTime.now();
      final File active = makeFile(
        tmp,
        name: 'active.jsonl',
        size: 10,
        ageDays: 999,
        now: now,
      );

      const DiskGuard guard = DiskGuard(
        policy: RetentionPolicy(
          maxTotalBytes: 1 << 30,
          maxAge: Duration(days: 30),
        ),
      );
      final CleanupReport r = await guard.enforce(
        tmp,
        activeFile: active,
        now: now,
      );

      expect(active.existsSync(), isTrue);
      expect(r.deletedCount, 0);
    });

    test('活动文件传相对路径/混用分隔符也能被正确识别', () async {
      final DateTime now = DateTime.now();
      final File active = makeFile(
        tmp,
        name: 'sub${Platform.pathSeparator}active.jsonl',
        size: 5000,
        ageDays: 99,
        now: now,
      );
      // 刻意用反斜杠/正斜杠混写的等价路径
      final File alias = File(active.path.replaceAll('\\', '/'));

      const DiskGuard guard = DiskGuard(
        policy: RetentionPolicy(maxTotalBytes: 1, maxAge: Duration(days: 30)),
      );
      await guard.enforce(tmp, activeFile: alias, now: now);

      expect(active.existsSync(), isTrue, reason: '路径未归一化导致活动文件被误删');
    });
  });

  group('事前预判', () {
    test('wouldExceed 与真实清理行为一致', () async {
      final DateTime now = DateTime.now();
      makeFile(tmp, name: 'a.bin', size: 800, ageDays: 1, now: now);

      const DiskGuard guard = DiskGuard(
        policy: RetentionPolicy(
          maxTotalBytes: 1000,
          maxAge: Duration(days: 30),
        ),
      );
      // 水位线 = 1000 * 0.9 = 900
      expect(await guard.currentBytes(tmp), 800);
      expect(await guard.wouldExceed(tmp, 50), isFalse); // 850 <= 900
      expect(await guard.wouldExceed(tmp, 200), isTrue); // 1000 > 900

      // 真写进去之后,清理确实会动手
      makeFile(tmp, name: 'b.bin', size: 200, ageDays: 0, now: now);
      final CleanupReport r = await guard.enforce(tmp, now: now);
      expect(r.didAnything, isTrue);
    });

    test('同步版预判与异步版口径一致', () async {
      const DiskGuard guard = DiskGuard(
        policy: RetentionPolicy(
          maxTotalBytes: 1000,
          maxAge: Duration(days: 30),
        ),
      );
      expect(guard.wouldExceedGiven(800, 50), isFalse);
      expect(guard.wouldExceedGiven(800, 200), isTrue);
      expect(guard.policy.highWaterBytes, 900);
    });

    test('空目录不超标', () async {
      const DiskGuard guard = DiskGuard();
      expect(await guard.currentBytes(tmp), 0);
      expect(await guard.wouldExceed(tmp, 1024), isFalse);
    });

    test('不存在的目录返回空报告而不是抛异常', () async {
      final Directory missing = Directory(
        '${tmp.path}${Platform.pathSeparator}nope',
      );
      const DiskGuard guard = DiskGuard();
      expect(await guard.currentBytes(missing), 0);
      expect(await guard.enforce(missing), CleanupReport.empty);
    });
  });

  group('值类型语义与默认值', () {
    test('RetentionPolicy 默认值符合文档承诺(2 GiB / 30 天)', () {
      const RetentionPolicy p = RetentionPolicy();
      expect(p.maxTotalBytes, 2 * 1024 * 1024 * 1024);
      expect(p.maxAge, const Duration(days: 30));
      expect(p.highWaterRatio, 0.9);
      expect(p.highWaterBytes, lessThan(p.maxTotalBytes));
    });

    test('RetentionPolicy 相等性与 copyWith', () {
      const RetentionPolicy a = RetentionPolicy();
      expect(a, equals(const RetentionPolicy()));
      expect(a.hashCode, equals(const RetentionPolicy().hashCode));
      expect(a.copyWith(maxTotalBytes: 1).maxTotalBytes, 1);
      expect(a.copyWith(maxTotalBytes: 1).maxAge, a.maxAge);
      expect(a, isNot(equals(a.copyWith(maxAge: const Duration(days: 7)))));
      expect(a.toString(), contains('maxAge'));
    });

    test('CleanupReport 是值类型', () {
      expect(CleanupReport.empty, equals(CleanupReport.empty));
      expect(CleanupReport.empty.didAnything, isFalse);
      expect(CleanupReport.empty.toString(), contains('deletedCount: 0'));
    });
  });
}
