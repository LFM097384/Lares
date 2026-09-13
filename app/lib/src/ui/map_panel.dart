import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../state/location_share_stub.dart'
    if (dart.library.io) '../state/location_share.dart';
import '../state/room_controller.dart';
import '../theme/tokens.dart';

/// 位置共享地图(Snapchat 式):OpenStreetMap 底图 + 成员标记。
/// 无 API key;瓦片走 OSM 公共源(生产应自建/商用源,见 README)。
class MapPanel extends StatelessWidget {
  const MapPanel({
    super.key,
    required this.controller,
    required this.locationShare,
  });

  final RoomController controller;
  final LocationShareService locationShare;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final locs = controller.locations;
        final sharing = controller.sharingMyLocation;
        return Stack(
          children: [
            FlutterMap(
              options: MapOptions(
                initialCenter: locs.isEmpty
                    ? const LatLng(35.0, 105.0) // 默认中国视野
                    : LatLng(locs.values.first.lat, locs.values.first.lng),
                initialZoom: locs.isEmpty ? 3.5 : 13,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.lfm097384.lares',
                ),
                MarkerLayer(
                  markers: [
                    for (final e in locs.entries)
                      Marker(
                        point: LatLng(e.value.lat, e.value.lng),
                        width: 64,
                        height: 78,
                        child: _MemberPin(
                          name: e.value.name,
                          isMe: e.key == controller.userId,
                        ),
                      ),
                  ],
                ),
              ],
            ),
            // 共享开关浮层
            Positioned(
              left: LaresSpacing.md,
              right: LaresSpacing.md,
              bottom: LaresSpacing.md,
              child: Card(
                child: SwitchListTile(
                  secondary: Icon(
                    sharing ? Icons.my_location : Icons.location_searching,
                    color: sharing ? LaresColors.ember : null,
                  ),
                  title: Text(sharing ? '正在共享我的位置' : '共享我的位置'),
                  subtitle: Text(
                    sharing
                        ? '圈内成员每 30 秒刷新一次,关闭/出房即停'
                        : locs.isEmpty
                            ? '还没有成员在共享'
                            : '${locs.length} 位成员在共享',
                  ),
                  value: sharing,
                  onChanged: (v) async {
                    if (v) {
                      final ok = await locationShare.start();
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('此端暂不支持共享位置(或权限被拒)')),
                        );
                      }
                    } else {
                      await locationShare.stop();
                    }
                  },
                ),
              ),
            ),
            if (locs.isEmpty && !sharing)
              Positioned(
                top: LaresSpacing.lg,
                left: 0,
                right: 0,
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: LaresSpacing.lg,
                        vertical: LaresSpacing.sm,
                      ),
                      child: Text(
                        '打开下方开关,让圈友看到你在哪',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MemberPin extends StatelessWidget {
  const _MemberPin({required this.name, required this.isMe});

  final String name;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.colorScheme.surface,
            border: Border.all(
              color: isMe ? LaresColors.ember : LaresColors.statusFree,
              width: 3,
            ),
            boxShadow: const [
              BoxShadow(color: Colors.black45, blurRadius: 6),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            name.isEmpty ? '?' : name.characters.first,
            style: theme.textTheme.titleLarge?.copyWith(fontSize: 18),
          ),
        ),
        Container(
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            name,
            style: const TextStyle(color: Colors.white, fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
