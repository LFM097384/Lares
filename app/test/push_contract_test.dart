import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/platform/push_service.dart';

/// 推送三方对账:Dart 常量 ⇄ iOS 原生(Swift)⇄ 服务器(Node)⇄ entitlements。
///
/// 为什么需要:Swift 在 Windows / CI 的 Dart 测试里编译不了,服务器是另一个进程。
/// 这些字符串任何一处拼错都不会报错 —— 表现只是「通知没有加入按钮」
/// 「点了没反应」「服务器把注册当成未知消息丢掉」,只有真机上才看得出来。
///
/// 文件读不到直接失败(而不是跳过):跳过会让这道闸门在搬家/改名后悄悄失效。
String _read(String path) {
  final f = File(path);
  if (!f.existsSync()) {
    fail('契约文件不存在: $path(测试须在 app/ 目录下运行;文件被改名的话同步更新本测试)');
  }
  return f.readAsStringSync();
}

/// Swift 里 `"<value>"` 这样的字面量是否出现
bool _hasSwiftLiteral(String src, String value) => src.contains('"$value"');

void main() {
  final bridge = _read('ios/Runner/LaresPushBridge.swift');
  final appDelegate = _read('ios/Runner/AppDelegate.swift');
  final sceneDelegate = _read('ios/Runner/SceneDelegate.swift');
  final entitlements = _read('ios/Runner/Runner.entitlements');
  final pbxproj = _read('ios/Runner.xcodeproj/project.pbxproj');
  final server = _read('../server/src/index.js');

  group('Dart ⇄ Swift', () {
    test('通道名、方法名、回调名一致', () {
      for (final v in [
        PushService.channelName,
        PushService.methodRequestPermission,
        PushService.methodGetToken,
        PushService.methodPermissionStatus,
        PushService.methodGetInitialOpen,
        PushService.methodGetEnvironment,
        PushService.callbackOnToken,
        PushService.callbackOnOpen,
      ]) {
        expect(_hasSwiftLiteral(bridge, v), isTrue,
            reason: 'LaresPushBridge.swift 里找不到 "$v"');
      }
    });

    test('通知类别、按钮、payload 键一致', () {
      for (final v in [
        PushService.category,
        PushService.joinAction,
        PushService.openAction,
        PushService.payloadKey,
        PushService.payloadCircleId,
        PushService.payloadServer,
        PushService.payloadAction,
      ]) {
        expect(_hasSwiftLiteral(bridge, v), isTrue,
            reason: 'LaresPushBridge.swift 里找不到 "$v"');
      }
    });

    test('权限状态字符串是 Dart 认识的那几个', () {
      for (final v in [
        'notDetermined',
        'denied',
        'authorized',
        'provisional',
        'ephemeral',
      ]) {
        expect(_hasSwiftLiteral(bridge, v), isTrue, reason: v);
      }
      expect(_hasSwiftLiteral(bridge, 'sandbox'), isTrue);
      expect(_hasSwiftLiteral(bridge, 'production'), isTrue);
    });

    test('桥接真的接上了:AppDelegate 配置 + 转发,SceneDelegate 挂通道', () {
      expect(appDelegate, contains('LaresPushBridge.shared.configure('));
      expect(appDelegate, contains('didRegisterForRemoteNotificationsWithDeviceToken'));
      expect(appDelegate, contains('LaresPushBridge.shared.didRegister('));
      expect(appDelegate, contains('LaresPushBridge.shared.handle('));
      expect(appDelegate, contains('willPresent'));
      expect(appDelegate, contains('didReceive'));
      expect(sceneDelegate, contains('LaresPushBridge.shared.attach('));
    });

    test('新 Swift 文件已登记进 Runner target(否则 Xcode 不编译它)', () {
      // 引用、构建文件、Sources 阶段各一处,外加 group 里一处
      expect('LaresPushBridge.swift'.allMatches(pbxproj).length,
          greaterThanOrEqualTo(4));
      expect(pbxproj, contains('LaresPushBridge.swift in Sources'));
    });
  });

  group('Dart ⇄ 服务器', () {
    test('信令消息名与 provider 一致', () {
      for (final v in [
        PushService.msgRegister,
        PushService.msgUnregister,
        PushService.msgRegistered,
        PushService.msgUnregistered,
        PushService.msgError,
        PushService.providerApns,
      ]) {
        expect(server, contains("'$v'"), reason: 'server/src/index.js 里找不到 \'$v\'');
      }
    });

    test('APNs payload 的类别与 lares 段键名与客户端一致', () {
      expect(server, contains("category: '${PushService.category}'"));
      final lares = RegExp(r'lares:\s*\{([^\n]*)\}').firstMatch(server);
      expect(lares, isNotNull, reason: '服务器 payload 里找不到 lares: {…}');
      final body = lares!.group(1)!;
      expect(body, contains(PushService.payloadCircleId));
      expect(body, contains(PushService.payloadServer));
      expect(body, contains(PushService.payloadKind));
      expect(PushService.payloadKey, 'lares');
    });

    test('服务器接受的 env 正是原生报出的两种', () {
      expect(server, contains("'sandbox'"));
      expect(server, contains("'production'"));
    });
  });

  group('entitlements', () {
    test('有 aps-environment,且保留 App Group', () {
      expect(entitlements, contains('<key>aps-environment</key>'));
      expect(entitlements, contains('com.apple.security.application-groups'));
    });

    test('服务器要发 time-sensitive,就必须声明这个能力', () {
      expect(server, contains("'interruption-level': 'time-sensitive'"));
      expect(entitlements,
          contains('com.apple.developer.usernotifications.time-sensitive'));
    });
  });
}
