import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'room_controller.dart';

/// 位置共享服务(Snapchat 式,产品反馈):
/// 用户显式开启后,在房期间每 30s(或移动 >50m)上报一次;
/// 关闭/出房立即停止。位置只经服务端转发,不落盘。
class LocationShareService {
  LocationShareService({required RoomController room}) : _room = room {
    _room.addListener(_onRoomChanged);
  }

  final RoomController _room;
  StreamSubscription<Position>? _posSub;
  Timer? _throttle;
  Position? _pending;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  static const _minInterval = Duration(seconds: 30);

  bool get sharing => _room.sharingMyLocation;

  /// 开启共享(含权限申请)。返回 false 表示权限被拒。
  Future<bool> start() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return false;
      }
      // 先报一次当前位置(超时兜底:用最后已知位置,避免无 GPS 时永久等待)
      var pos = await Geolocator.getLastKnownPosition();
      pos ??= await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 8),
        ),
      );
      _room.reportLocation(pos.latitude, pos.longitude);
      _lastSent = DateTime.now();
      _room.setSharingMyLocation(true);
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium, // 省电优先
          distanceFilter: 50,
        ),
      ).listen(_onPosition);
      return true;
    } catch (e) {
      debugPrint('[lares] 定位启动失败: $e');
      return false;
    }
  }

  Future<void> stop() async {
    await _posSub?.cancel();
    _posSub = null;
    _throttle?.cancel();
    _pending = null;
    _room.setSharingMyLocation(false);
  }

  void _onPosition(Position pos) {
    _pending = pos;
    final since = DateTime.now().difference(_lastSent);
    if (since >= _minInterval) {
      _flush();
    } else {
      // 节流:移动再快也 30s 一报
      _throttle ??= Timer(_minInterval - since, _flush);
    }
  }

  void _flush() {
    _throttle?.cancel();
    _throttle = null;
    final pos = _pending;
    if (pos == null) return;
    _pending = null;
    _lastSent = DateTime.now();
    _room.reportLocation(pos.latitude, pos.longitude);
  }

  void _onRoomChanged() {
    // 出房自动停止共享
    if (!_room.isInRoom && sharing) stop();
  }

  Future<void> dispose() async {
    _room.removeListener(_onRoomChanged);
    await stop();
  }
}
