import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// 轻状态(设计.md §3.3):代替「在线/离线」二元状态
enum MemberStatus {
  free('随时聊', LaresColors.statusFree),
  busy('在忙', LaresColors.statusBusy),
  ears('耳朵在', LaresColors.statusEars),
  away('有事先走', LaresColors.statusAway);

  const MemberStatus(this.label, this.color);
  final String label;
  final Color color;

  static MemberStatus fromWire(String? wire) => switch (wire) {
        'busy' => MemberStatus.busy,
        'ears' => MemberStatus.ears,
        'away' => MemberStatus.away,
        _ => MemberStatus.free,
      };

  String get wire => name;
}

/// 房间里的一位成员(按 userId 聚合,多端在线只显示一次)
class Member {
  const Member({
    required this.userId,
    required this.name,
    required this.status,
    this.deviceCount = 1,
    this.platform = '',
    this.latencyMs = -1,
    this.emoji,
    this.bio,
    this.joinedAt,
  });

  final String userId;
  final String name;
  final MemberStatus status;
  final int deviceCount;

  /// 这个人用的什么平台(windows/macos/linux/android/ios/web)。
  /// 多人直连时选主机要用:桌面端优先扛转发。
  final String platform;

  /// 这个人到信令服务器的往返延迟(毫秒)。-1 = 未知。
  /// 同样是选主机的输入 —— 所有人看到同一份数据,才能算出同一个主机。
  final int latencyMs;

  /// 头像 emoji(一个字素簇)。null = 没设,头像球显示名字首字。
  final String? emoji;

  /// 一句话签名(≤40 字素簇)。null = 没写。
  final String? bio;

  /// 这次进房的时刻(服务器时钟,ms epoch)。老服务器不发 → null。
  final int? joinedAt;

  /// 桌面端。插着电、连着 WiFi、上行更稳,适合当主机。
  bool get isDesktop =>
      platform == 'windows' || platform == 'macos' || platform == 'linux';

  /// [emoji] / [bio]:null = 不动,空串 = 清掉。
  Member copyWith({
    String? name,
    MemberStatus? status,
    int? deviceCount,
    String? platform,
    int? latencyMs,
    String? emoji,
    String? bio,
    int? joinedAt,
  }) =>
      Member(
        userId: userId,
        name: name ?? this.name,
        status: status ?? this.status,
        deviceCount: deviceCount ?? this.deviceCount,
        platform: platform ?? this.platform,
        latencyMs: latencyMs ?? this.latencyMs,
        emoji: emoji == null ? this.emoji : (emoji.isEmpty ? null : emoji),
        bio: bio == null ? this.bio : (bio.isEmpty ? null : bio),
        joinedAt: joinedAt ?? this.joinedAt,
      );

  factory Member.fromWire(Map<String, dynamic> json) => Member(
        userId: json['userId'] as String? ?? '',
        name: json['name'] as String? ?? '圈友',
        status: MemberStatus.fromWire(json['status'] as String?),
        deviceCount: (json['deviceCount'] as num?)?.toInt() ?? 1,
        platform: json['platform'] as String? ?? '',
        // 老服务器不发这个字段 -> -1(未知),选主机时按最差处理
        latencyMs: (json['latencyMs'] as num?)?.toInt() ?? -1,
        // 资料字段:服务器只在非空时才带;空串一律当没设
        emoji: _nonEmpty(json['emoji']),
        bio: _nonEmpty(json['bio']),
        joinedAt: (json['joinedAt'] as num?)?.toInt(),
      );

  static String? _nonEmpty(Object? v) =>
      v is String && v.trim().isNotEmpty ? v : null;
}

/// 房间连接状态机
enum RoomPhase {
  idle, // 未进房
  joining, // 一键进房中(目标 ≤1.5s)
  inRoom, // 已进房
  error,
}
