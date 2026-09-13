/// 版本号解析与比较(自动更新的地基)。
///
/// 为什么要单独一层:字符串比较会把 "0.10.0" 判成小于 "0.9.0"(因为 '1' < '9'),
/// 这是自动更新最经典的事故。这里做的是**逐段数值比较**。
///
/// 支持的形态(都来自本项目真实场景):
/// - GitHub tag:`v0.1.0`(带 `v` 前缀)
/// - Flutter pubspec:`0.1.0+1`(`+build` 元数据)
/// - 预发布:`1.0.0-beta`、`1.0.0-rc.2`
///
/// 语义遵循 semver 2.0.0 的核心规则:
/// 1. 先比 major/minor/patch(数值);
/// 2. 主版本相同时,**有预发布后缀的小于没有的**(1.0.0-beta < 1.0.0);
/// 3. 两边都有预发布时,按点分段比较(数字段按数值、其余按 ASCII,数字段 < 文本段);
/// 4. `+build` 元数据**完全不参与比较**(semver 明文规定)。
library;

/// 一个已解析的版本号。解析失败时用 [LaresVersion.tryParse] 得到 null,
/// 绝不抛异常——更新检查里任何一个畸形 tag 都不该让 App 崩掉。
class LaresVersion implements Comparable<LaresVersion> {
  const LaresVersion({
    required this.major,
    required this.minor,
    required this.patch,
    this.preRelease = const [],
    this.build,
    required this.raw,
  });

  final int major;
  final int minor;
  final int patch;

  /// 预发布标识按 `.` 拆开后的段,如 `1.0.0-rc.2` -> ['rc', '2']。空表示正式版。
  final List<String> preRelease;

  /// `+` 之后的构建元数据。**不参与比较**,仅用于展示。
  final String? build;

  /// 原始字符串(用于 UI 原样展示)。
  final String raw;

  bool get isPreRelease => preRelease.isNotEmpty;

  /// 宽松解析:容忍 `v` / `V` 前缀、前后空白、缺省的 minor/patch(`v1` -> 1.0.0)。
  /// 任何无法解析为「至少一个数字段」的输入都返回 null。
  static LaresVersion? tryParse(String? input) {
    if (input == null) return null;
    final raw = input.trim();
    if (raw.isEmpty) return null;

    var s = raw;
    // 去掉 v/V 前缀(GitHub tag 惯例:v0.1.0)
    if (s.length > 1 && (s[0] == 'v' || s[0] == 'V')) {
      s = s.substring(1);
    }
    if (s.isEmpty) return null;

    // 先切 build 元数据(+ 之后一律不参与比较)
    String? build;
    final plus = s.indexOf('+');
    if (plus >= 0) {
      build = s.substring(plus + 1);
      s = s.substring(0, plus);
    }

    // 再切预发布(第一个 - 之后)
    List<String> pre = const [];
    final dash = s.indexOf('-');
    if (dash >= 0) {
      final preRaw = s.substring(dash + 1);
      s = s.substring(0, dash);
      // 空预发布段(如 "1.0.0-")视为无预发布,不报错
      pre = preRaw.isEmpty
          ? const []
          : preRaw.split('.').where((e) => e.isNotEmpty).toList(growable: false);
    }

    final parts = s.split('.');
    if (parts.isEmpty) return null;

    // 逐段必须是纯数字;缺省段补 0。任何一段非法 -> 整体解析失败。
    int? numAt(int i) {
      if (i >= parts.length) return 0;
      final p = parts[i].trim();
      if (p.isEmpty) return i == 0 ? null : 0;
      if (!_digitsOnly(p)) return null;
      return int.tryParse(p);
    }

    final major = numAt(0);
    final minor = numAt(1);
    final patch = numAt(2);
    if (major == null || minor == null || patch == null) return null;

    return LaresVersion(
      major: major,
      minor: minor,
      patch: patch,
      preRelease: pre,
      build: build,
      raw: raw,
    );
  }

  static bool _digitsOnly(String s) {
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c < 0x30 || c > 0x39) return false;
    }
    return true;
  }

  @override
  int compareTo(LaresVersion other) {
    // 1) 数值比较主版本三元组 —— 这条保证 0.10.0 > 0.9.0
    var c = major.compareTo(other.major);
    if (c != 0) return c;
    c = minor.compareTo(other.minor);
    if (c != 0) return c;
    c = patch.compareTo(other.patch);
    if (c != 0) return c;

    // 2) 有预发布 < 无预发布(1.0.0-beta < 1.0.0)
    if (preRelease.isEmpty && other.preRelease.isEmpty) return 0;
    if (preRelease.isEmpty) return 1;
    if (other.preRelease.isEmpty) return -1;

    // 3) 逐段比较预发布标识
    final n = preRelease.length < other.preRelease.length
        ? preRelease.length
        : other.preRelease.length;
    for (var i = 0; i < n; i++) {
      final a = preRelease[i];
      final b = other.preRelease[i];
      final aNum = _digitsOnly(a) ? int.tryParse(a) : null;
      final bNum = _digitsOnly(b) ? int.tryParse(b) : null;
      if (aNum != null && bNum != null) {
        c = aNum.compareTo(bNum);
        if (c != 0) return c;
      } else if (aNum != null) {
        return -1; // 数字段优先级低于文本段
      } else if (bNum != null) {
        return 1;
      } else {
        c = a.compareTo(b);
        if (c != 0) return c;
      }
    }
    // 段数多的更大(1.0.0-rc.1 < 1.0.0-rc.1.1)
    return preRelease.length.compareTo(other.preRelease.length);
  }

  bool operator >(LaresVersion other) => compareTo(other) > 0;
  bool operator <(LaresVersion other) => compareTo(other) < 0;
  bool operator >=(LaresVersion other) => compareTo(other) >= 0;
  bool operator <=(LaresVersion other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      other is LaresVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease.join('.'));

  /// 规范化展示:`0.10.0` / `1.0.0-rc.2`(不含 build 元数据)
  String get display {
    final base = '$major.$minor.$patch';
    return preRelease.isEmpty ? base : '$base-${preRelease.join('.')}';
  }

  @override
  String toString() => display;
}

/// 便捷入口:`latest` 是否严格新于 `current`。
///
/// 任一侧解析失败时返回 false —— 「看不懂的版本号」绝不触发更新提示,
/// 这是安全的失败方向(宁可漏报,不可误报让用户去装一个未知的包)。
bool isNewerVersion(String? latest, String? current) {
  final l = LaresVersion.tryParse(latest);
  final c = LaresVersion.tryParse(current);
  if (l == null || c == null) return false;
  return l > c;
}
