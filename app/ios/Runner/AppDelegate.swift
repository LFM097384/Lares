import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 通知中心的 delegate 必须在这里、在 return 之前设好:
    // 冷启动时点通知的那次 didReceive,系统只投给启动完成时已就位的 delegate。
    // 设成 self(而不是 LaresPushBridge)是为了让 FlutterAppDelegate 继续把
    // 不属于我们的通知转发给插件 —— 它本身就是 UNUserNotificationCenterDelegate
    // (FlutterAppLifeCycleProvider 协议继承自它,见 FlutterPlugin.h)。
    LaresPushBridge.shared.configure(delegate: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  // ── 推送 ──
  // 以下四个方法 FlutterAppDelegate 都有实现(FlutterAppDelegate.mm,转发给插件),
  // 所以这里是 override;都调 super,插件照样收得到。
  // 属于我们的通知(payload 带 lares.circleId)自己处理、不再转给插件:
  // completionHandler 只能调一次,两边都调会被系统判为错误。

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    LaresPushBridge.shared.didRegister(deviceToken: deviceToken)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    // 拿不到 token(模拟器、缺 aps-environment 权限、没网):没有 token 就不上报,
    // Dart 侧什么都不发 —— 不需要额外的失败通道。
    NSLog("[LaresPush] register failed: \(error.localizedDescription)")
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    guard LaresPushBridge.isOurs(notification) else {
      super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
      return
    }
    // App 就在前台:圈子列表上已经看得到谁在,再弹一条横幅是打扰。
    completionHandler([])
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    guard LaresPushBridge.isOurs(response.notification) else {
      super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
      return
    }
    LaresPushBridge.shared.handle(response: response)
    completionHandler()
  }
}
