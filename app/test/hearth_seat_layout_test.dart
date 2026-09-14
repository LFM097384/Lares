// 临时验证:用真实的 SeatLayout 代码跑出环容量表,确认与报告数字一致。
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import '../tool/hearth/hearth_state.dart';
import '../tool/hearth/layer_b_seats.dart';

void main() {
  test('ring capacities and splits', () {
    for (final Size canvas in <Size>[
      const Size(1280, 720),
      const Size(1600, 900),
    ]) {
      // ignore: avoid_print
      print('=== canvas ${canvas.width}x${canvas.height} ===');
      for (final int n in <int>[2, 5, 12, 20, 28]) {
        SeatLayout.debugClearCache();
        final List<HearthMember> ms = <HearthMember>[
          for (int i = 0; i < n; i++)
            HearthMember(id: 'u$i', name: 'N$i', seat: i),
        ];
        final Offset c = Offset(canvas.width / 2, canvas.height / 2);
        final SeatLayout l = SeatLayout.compute(
          members: ms,
          size: canvas,
          flameCenter: c,
        );
        // 最外沿:圆心 + 半径 + 头像半径 + 名字高
        double maxBottom = 0;
        double minTop = double.infinity;
        double maxRight = 0;
        for (final SeatPlacement s in l.seats) {
          final double cy = s.baseCenter.dy;
          maxBottom = maxBottom > cy + l.diameter / 2 + 40
              ? maxBottom
              : cy + l.diameter / 2 + 40;
          minTop = minTop < cy - l.diameter / 2 ? minTop : cy - l.diameter / 2;
          final double r = s.baseCenter.dx + l.orbBoxWidth / 2;
          maxRight = maxRight > r ? maxRight : r;
        }
        // ignore: avoid_print
        print('n=$n d=${l.diameter.toStringAsFixed(1)} '
            'base=${l.base.toStringAsFixed(1)} '
            'caps=${l.ringCaps} rings=${l.ringCount} '
            'R=${l.radii.map((double r) => r.toStringAsFixed(1)).toList()} '
            'split=${l.ringCounts} capacity=${l.capacity} '
            'overflow=${l.overflowCount} '
            'top=${minTop.toStringAsFixed(0)} '
            'bottom=${maxBottom.toStringAsFixed(0)}/${canvas.height} '
            'right=${maxRight.toStringAsFixed(0)}/${canvas.width}');
        expect(minTop, greaterThanOrEqualTo(0.0));
        expect(maxBottom, lessThanOrEqualTo(canvas.height));
        expect(maxRight, lessThanOrEqualTo(canvas.width));
      }
      // 紧凑模式 n=28
      SeatLayout.debugClearCache();
      final List<HearthMember> ms = <HearthMember>[
        for (int i = 0; i < 28; i++)
          HearthMember(id: 'u$i', name: 'N$i', seat: i),
      ];
      final SeatLayout l = SeatLayout.compute(
        members: ms,
        size: canvas,
        flameCenter: Offset(canvas.width / 2, canvas.height / 2),
        maxRings: 1,
      );
      // ignore: avoid_print
      print('n=28 COMPACT caps=${l.ringCaps} capacity=${l.capacity} '
          'shown=${l.seats.length - 1} chip=+${l.overflowCount}');
      expect(l.hasOverflow, isTrue);
    }
  });

  test('speaking never changes angle', () {
    SeatLayout.debugClearCache();
    final List<HearthMember> ms = <HearthMember>[
      for (int i = 0; i < 12; i++)
        HearthMember(id: 'u$i', name: 'N$i', seat: i),
    ];
    const Size canvas = Size(1280, 720);
    const Offset c = Offset(640, 360);
    final SeatLayout a =
        SeatLayout.compute(members: ms, size: canvas, flameCenter: c);
    // 让几个人说话,并打乱 list 顺序(模拟 speakingIds 变化)
    ms[3].speaking = true;
    ms[3].speech = 1.0;
    ms[7].speaking = true;
    ms[7].speech = 0.6;
    final List<HearthMember> shuffled = ms.reversed.toList();
    final SeatLayout b =
        SeatLayout.compute(members: shuffled, size: canvas, flameCenter: c);
    for (int i = 0; i < a.seats.length; i++) {
      expect(b.seats[i].memberId, a.seats[i].memberId);
      expect(b.seats[i].angle, a.seats[i].angle);
    }
  });
}
