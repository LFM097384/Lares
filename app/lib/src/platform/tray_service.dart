import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

import '../config.dart';

/// 桌面托盘入口(设计.md §4.2):macOS 菜单栏 / Windows 托盘常驻图标,
/// 点击即一键进房,这是桌面端「常驻挂机」的核心体验。
class TrayService with TrayListener {
  TrayService({required this.onEnterRoom, required this.onShowWindow});

  /// 点了「进入圈子」
  final VoidCallback onEnterRoom;

  /// 点了「显示主窗口」
  final VoidCallback onShowWindow;

  bool _ready = false;

  Future<void> init() async {
    if (!LaresConfig.isDesktop || _ready) return;
    _ready = true;
    trayManager.addListener(this);
    try {
      // 图标为运行时文件路径;缺失时不阻塞 App(资源待设计系统补齐)
      await trayManager.setIcon(
        Platform.isWindows ? 'assets/tray/icon.ico' : 'assets/tray/icon.png',
      );
    } catch (e) {
      debugPrint('[tray] 图标缺失,跳过: $e');
    }
    await _rebuildMenu(inRoom: false);
  }

  /// 根据是否在房间更新菜单文案
  Future<void> _rebuildMenu({required bool inRoom}) async {
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'enter', label: inRoom ? '离开圈子' : '进入圈子'),
      MenuItem(key: 'show', label: '显示主窗口'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '退出 Lares'),
    ]));
  }

  Future<void> setInRoom(bool inRoom) async {
    if (!_ready) return;
    await _rebuildMenu(inRoom: inRoom);
    await trayManager.setToolTip(inRoom ? 'Lares · 在圈子里' : 'Lares');
  }

  @override
  void onTrayIconMouseDown() {
    // 点图标 = 一键进房(设计.md §3.1:direct 进房,无二次确认)
    onEnterRoom();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'enter':
        onEnterRoom();
      case 'show':
        onShowWindow();
      case 'quit':
        trayManager.destroy();
        exit(0);
    }
  }

  Future<void> dispose() async {
    if (!_ready) return;
    trayManager.removeListener(this);
    await trayManager.destroy();
  }
}
