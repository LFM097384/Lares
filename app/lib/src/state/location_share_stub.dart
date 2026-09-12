import 'room_controller.dart';

/// Web 端位置共享:geolocator_web 与 WASM 不兼容(启动崩溃,实测),
/// Web 端暂不提供位置共享;原生端见 location_share.dart。
class LocationShareService {
  LocationShareService({required RoomController room});

  bool get sharing => false;

  /// 始终返回 false:Web 端不可用
  Future<bool> start() async => false;

  Future<void> stop() async {}

  Future<void> dispose() async {}
}
