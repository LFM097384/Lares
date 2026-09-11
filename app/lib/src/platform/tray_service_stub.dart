/// Web 端托盘:无操作实现(io 端见 tray_service.dart)。
class TrayService {
  TrayService({required this.onEnterRoom, required this.onShowWindow});

  final void Function() onEnterRoom;
  final void Function() onShowWindow;

  Future<void> init() async {}

  Future<void> setInRoom(bool inRoom) async {}

  Future<void> dispose() async {}
}
