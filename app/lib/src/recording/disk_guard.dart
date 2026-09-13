/// 磁盘增长策略:给 24/7 常驻的录音/转写目录设上限。
///
/// 这不是"锦上添花的清理功能" —— 一个常驻应用如果不限制落盘增长,
/// 它就是一个会慢慢填满用户硬盘的 bug,只是爆发得比较晚而已。
///
/// 目录由调用方注入,`dart:io` 之外不依赖任何插件,可在纯 VM 测试里对着
/// 临时目录跑。
library;

import 'dart:io';

// 只用 foundation 的 @immutable 注解(纯值语义标记),不引入任何平台通道依赖。
// 未选用 package:meta 是因为它不是本包的直接依赖(depend_on_referenced_packages)。
import 'package:flutter/foundation.dart';

/// 保留策略:总量上限 + 时间窗。
///
/// 两条规则是**并列**的,不是二选一:
/// - 时间窗回答"多久以前的东西我还想要",与磁盘多大无关;
/// - 总量上限回答"我最多愿意占多少磁盘",与内容多老无关。
/// 说得多的圈子会先撞上总量上限,说得少的圈子会先撞上时间窗。
@immutable
class RetentionPolicy {
  const RetentionPolicy({
    this.maxTotalBytes = 2 * 1024 * 1024 * 1024,
    this.maxAge = const Duration(days: 30),
  }) : assert(maxTotalBytes > 0, '总量上限必须为正');
  // 注意:这里**不能**断言 maxAge 为正。const 构造器里对 Duration 既不能用
  // 比较运算符(const_eval_type_num),也不能读 inMicroseconds
  // (const_eval_property_access) —— 而且报错点会落在**调用方**的
  // `const RetentionPolicy()` 上,而不是这一行,极难定位。
  // 时间窗的合法性改由 [DiskGuard.enforce] 在运行期断言。

  /// 总量上限,默认 **2 GiB**。
  ///
  /// 依据:16 kHz 单声道 int16 是 32 KB/s,即 ~115 MB/小时**纯语音**
  /// (VAD 已经把静音切掉了,真实占用远低于挂机时长)。2 GiB 约等于
  /// 17 小时有效说话量。对一个小圈子来说这是好几个月的量,
  /// 同时又不至于让用户觉得这软件在偷偷吃硬盘。转写稿(JSONL)体量
  /// 比音频小三个数量级,基本不参与竞争。
  final int maxTotalBytes;

  /// 保留窗,默认 **30 天**。
  ///
  /// 依据:转写稿的实际用途是"上周那事儿谁说的来着",跨月回溯几乎不发生。
  /// 定 30 天而不是 7 天,是为了容纳"出差两周回来再翻"这类真实节奏。
  final Duration maxAge;

  /// 触发清理的水位线,默认 90%。
  ///
  /// 卡在 100% 才清理会导致"每写一个文件就删一个文件"的抖动,
  /// 留 10% 余量让清理成为偶发的批量动作。
  double get highWaterRatio => 0.9;

  /// 达到这个字节数就该动手清理了。
  int get highWaterBytes => (maxTotalBytes * highWaterRatio).floor();

  RetentionPolicy copyWith({int? maxTotalBytes, Duration? maxAge}) {
    return RetentionPolicy(
      maxTotalBytes: maxTotalBytes ?? this.maxTotalBytes,
      maxAge: maxAge ?? this.maxAge,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RetentionPolicy &&
          other.maxTotalBytes == maxTotalBytes &&
          other.maxAge == maxAge;

  @override
  int get hashCode => Object.hash(maxTotalBytes, maxAge);

  @override
  String toString() =>
      'RetentionPolicy(maxTotalBytes: $maxTotalBytes, maxAge: $maxAge)';
}

/// 一次清理的结果。给日志/设置页用,让"东西被删了"这件事可见。
@immutable
class CleanupReport {
  const CleanupReport({
    required this.deletedCount,
    required this.reclaimedBytes,
    required this.remainingBytes,
    required this.deletedPaths,
    required this.failedCount,
  });

  /// 什么都没做的空结果。
  static const CleanupReport empty = CleanupReport(
    deletedCount: 0,
    reclaimedBytes: 0,
    remainingBytes: 0,
    deletedPaths: <String>[],
    failedCount: 0,
  );

  final int deletedCount;
  final int reclaimedBytes;

  /// 清理之后目录里还剩多少字节(不含被排除的活动文件之外的任何豁免)。
  final int remainingBytes;

  final List<String> deletedPaths;

  /// 删除失败的文件数(被其他进程占用、权限不足等)。
  ///
  /// 失败**不抛异常**:清理是尽力而为的后台维护,为了一个删不掉的文件
  /// 就让整轮清理崩掉,只会让磁盘继续涨。计数暴露出来供排查。
  final int failedCount;

  bool get didAnything => deletedCount > 0 || failedCount > 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CleanupReport &&
          other.deletedCount == deletedCount &&
          other.reclaimedBytes == reclaimedBytes &&
          other.remainingBytes == remainingBytes &&
          other.failedCount == failedCount &&
          listEquals(other.deletedPaths, deletedPaths);

  @override
  int get hashCode => Object.hash(
    deletedCount,
    reclaimedBytes,
    remainingBytes,
    failedCount,
    Object.hashAll(deletedPaths),
  );

  @override
  String toString() =>
      'CleanupReport(deletedCount: $deletedCount, '
      'reclaimedBytes: $reclaimedBytes, remainingBytes: $remainingBytes, '
      'failedCount: $failedCount)';
}

/// 磁盘增长守卫。
///
/// 提供**两套互补机制**,不要混淆:
/// - [enforce]:事后清理。扫目录、按策略删,回收已经占掉的空间。
///   它是异步的、有 IO 成本的,适合定时跑(例如每小时一次、或每次进房时)。
/// - [wouldExceed]:事前预判。在**写下一块音频之前**问一句"再写这么多会不会爆"。
///   它便宜,可以在录音热路径上频繁调用。爆了就停止采集(或降级为只转写不存音频),
///   而不是先写爆再删。
///
/// 只有事后清理是不够的:清理跑在下一个周期,而在这之前磁盘已经真的满了,
/// 写入会直接失败,甚至连转写稿都写不进去。只有事前预判也不够:它不回收空间,
/// 用不了多久就会永久卡在"不许再写"状态。两者必须都有。
///
/// ## 不变量:两套机制必须瞄准同一条线
///
/// **[wouldExceed] 判定的条件,必须恰好是 [enforce] 会动手处理的条件** ——
/// 二者都以 [RetentionPolicy.highWaterBytes](水位线)为界,而**不是**硬上限。
///
/// 这条不变量不能被拆开。曾经踩过的坑:预判按水位线(90%)喊停,清理却只清到
/// 硬上限(100%)。于是占用落在 90%~100% 这段区间时,预判说"别写了",
/// 清理却说"没超标,不用动" —— 录音被永久卡死,而磁盘一个字节也回收不了。
///
/// 清理**清到水位线而非硬上限**还有第二层用意:滞后。若只清到刚好压线,
/// 下一次写入立刻又超,每写一个文件就要删一个文件,清理退化成持续抖动。
/// 留出 10% 余量,清理才是偶发的批量动作。
///
/// 时间窗规则([RetentionPolicy.maxAge])与这条线**无关**:超龄文件无论
/// 磁盘多空都要删。
class DiskGuard {
  const DiskGuard({this.policy = const RetentionPolicy()});

  final RetentionPolicy policy;

  /// 统计目录当前占用(递归)。无法 stat 的条目按 0 计,不抛。
  Future<int> currentBytes(Directory dir) async {
    int total = 0;
    for (final _Entry e in await _scan(dir)) {
      total += e.size;
    }
    return total;
  }

  /// 事前预判:再写 [additionalBytes] 字节会不会越过水位线。
  ///
  /// 用水位线(默认上限的 90%)而不是硬上限,是为了给清理留出反应时间:
  /// 等真的贴着上限才喊停,清理还没跑完新数据就已经被拒了。
  ///
  /// 返回 true 的条件与 [enforce] 实际动手的条件**严格一致**,
  /// 见 [DiskGuard] 类文档里的不变量说明。
  Future<bool> wouldExceed(Directory dir, int additionalBytes) async {
    final int now = await currentBytes(dir);
    return now + additionalBytes > policy.highWaterBytes;
  }

  /// 同步版预判。热路径上已经知道当前占用时用它,避免重复扫目录。
  bool wouldExceedGiven(int currentTotalBytes, int additionalBytes) =>
      currentTotalBytes + additionalBytes > policy.highWaterBytes;

  /// 执行清理。
  ///
  /// 顺序:先按时间窗删过期的,再按总量**从旧到新**删,直到降到
  /// [RetentionPolicy.highWaterBytes](水位线,默认上限的 90%)以下 ——
  /// 注意目标是水位线而非硬上限,理由见下面第二轮循环处的注释。
  /// 先删过期的,是因为那批文件无论磁盘多空都不该留着;之后再看总量,
  /// 需要额外删的就少了。
  ///
  /// [activeFile] 是**正在写入**的文件,永远不删 —— 哪怕它最旧、哪怕删了它
  /// 就能立刻降到上限以下。这是个真实的坑:常驻应用刚启动、旧数据全在时,
  /// 最旧的往往恰恰是刚被追加过的当前会话文件;删掉它,用户会看到
  /// "正在进行的这场对话的转写稿凭空消失",而且录音进程还握着句柄,
  /// 在 Windows 上删除会直接失败或留下幽灵文件。
  ///
  /// [now] 可注入,便于测试构造"过期文件"而不必真的等 30 天。
  Future<CleanupReport> enforce(
    Directory dir, {
    File? activeFile,
    DateTime? now,
  }) async {
    // 时间窗的断言只能放在运行期:见 [RetentionPolicy] 构造器里的说明。
    assert(policy.maxAge > Duration.zero, '保留窗必须为正');
    if (!dir.existsSync()) return CleanupReport.empty;

    final DateTime at = now ?? DateTime.now();
    final String? activePath = activeFile == null
        ? null
        : _normalize(activeFile.path);

    final List<_Entry> entries = await _scan(dir);
    // 旧 -> 新。mtime 相同时按路径定序,保证结果可复现(否则目录枚举顺序
    // 在不同文件系统上不一致,测试会随机飘)。
    entries.sort((_Entry a, _Entry b) {
      final int c = a.modified.compareTo(b.modified);
      return c != 0 ? c : a.path.compareTo(b.path);
    });

    int total = 0;
    for (final _Entry e in entries) {
      total += e.size;
    }

    final List<String> deleted = <String>[];
    int reclaimed = 0;
    int failed = 0;
    final Duration maxAge = policy.maxAge;

    Future<bool> tryDelete(_Entry e) async {
      try {
        await e.file.delete();
      } catch (_) {
        failed++;
        return false;
      }
      deleted.add(e.path);
      reclaimed += e.size;
      total -= e.size;
      return true;
    }

    final List<_Entry> survivors = <_Entry>[];

    // 第一轮:时间窗。超龄的一律删,与总量无关。
    for (final _Entry e in entries) {
      if (activePath != null && e.path == activePath) continue;
      if (at.difference(e.modified) > maxAge) {
        await tryDelete(e);
      } else {
        survivors.add(e);
      }
    }

    // 第二轮:总量上限,从旧到新删到降下来为止。
    //
    // 目标是**水位线**而不是硬上限:清到刚好压线的话,下一次写入立刻又超,
    // 于是每写一个文件就要删一个文件,清理退化成持续抖动。更要命的是,
    // 那样会与 [wouldExceed] 产生一段死区 —— 占用落在水位线与硬上限之间时,
    // 预判说"别写了",清理却认为"没超标,不用动",录音就永久卡死。
    // 两个机制必须瞄准同一条线。
    for (final _Entry e in survivors) {
      if (total <= policy.highWaterBytes) break;
      await tryDelete(e);
    }

    return CleanupReport(
      deletedCount: deleted.length,
      reclaimedBytes: reclaimed,
      remainingBytes: total,
      deletedPaths: List<String>.unmodifiable(deleted),
      failedCount: failed,
    );
  }

  /// 递归枚举普通文件。
  ///
  /// 不跟随符号链接:跟随的话既可能被环形链接打死循环,也可能把清理动作
  /// 引到目录树之外去删别人的文件。
  Future<List<_Entry>> _scan(Directory dir) async {
    if (!dir.existsSync()) return <_Entry>[];
    final List<_Entry> out = <_Entry>[];
    await for (final FileSystemEntity e in dir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (e is! File) continue;
      try {
        final FileStat st = e.statSync();
        out.add(
          _Entry(
            file: e,
            path: _normalize(e.path),
            size: st.size,
            modified: st.modified,
          ),
        );
      } catch (_) {
        // stat 失败(文件刚好被删/无权限)就当它不存在,继续扫。
      }
    }
    return out;
  }

  /// 路径归一化,用于"活动文件"比对。
  ///
  /// 必须归一化:调用方传进来的可能是相对路径或混用分隔符,而枚举出来的
  /// 是绝对路径。字符串直接比会漏判,漏判的后果就是把正在写的文件删掉。
  /// Windows 上还要统一大小写(文件系统大小写不敏感)。
  static String _normalize(String path) {
    String p = File(path).absolute.path.replaceAll('\\', '/');
    if (Platform.isWindows) p = p.toLowerCase();
    return p;
  }
}

/// 扫描出来的一个文件条目(内部用)。
@immutable
class _Entry {
  const _Entry({
    required this.file,
    required this.path,
    required this.size,
    required this.modified,
  });

  final File file;
  final String path;
  final int size;
  final DateTime modified;
}
