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
  });

  final String userId;
  final String name;
  final MemberStatus status;
  final int deviceCount;

  Member copyWith({MemberStatus? status, int? deviceCount}) => Member(
        userId: userId,
        name: name,
        status: status ?? this.status,
        deviceCount: deviceCount ?? this.deviceCount,
      );

  factory Member.fromWire(Map<String, dynamic> json) => Member(
        userId: json['userId'] as String? ?? '',
        name: json['name'] as String? ?? '圈友',
        status: MemberStatus.fromWire(json['status'] as String?),
        deviceCount: (json['deviceCount'] as num?)?.toInt() ?? 1,
      );
}

/// 房间连接状态机
enum RoomPhase {
  idle, // 未进房
  joining, // 一键进房中(目标 ≤1.5s)
  inRoom, // 已进房
  error,
}
