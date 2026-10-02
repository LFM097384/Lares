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

// ── 专注学习(lares.focus):FamilyControls 屏蔽 ──
// 整段包在 LARES_FAMILY_CONTROLS 编译条件里:该标志默认不设,CI 不编译这里的任何代码,
// 也就不需要 com.apple.developer.family-controls 权限。申请与启用步骤见
// docs/focus-ios-family-controls.md。Dart 侧在 lares/family_controls 上拿到
// MissingPluginException 即视为「不可用」。
#if LARES_FAMILY_CONTROLS
import FamilyControls
import ManagedSettings

/// 通道 lares/family_controls:
/// - available → Bool(iOS 16+ 才为 true)
/// - authorize → Bool(请求 .individual 授权,用户拒绝则 FlutterError)
/// - shield    → Bool(屏蔽所有应用类别)
/// - unshield  → Bool(清除屏蔽)
///
/// 注册方式(调用处也必须包在 #if LARES_FAMILY_CONTROLS 里),
/// 放在 AppDelegate.didInitializeImplicitFlutterEngine 中:
///
///   #if LARES_FAMILY_CONTROLS
///   if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LaresFamilyControls") {
///     LaresFamilyControlsChannel.register(with: registrar.messenger())
///   }
///   #endif
final class LaresFamilyControlsChannel {
  static let channelName = "lares/family_controls"
  private static var channel: FlutterMethodChannel?

  static func register(with messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    ch.setMethodCallHandler { call, result in
      handle(call, result: result)
    }
    channel = ch
  }

  private static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "available":
      if #available(iOS 16.0, *) {
        result(true)
      } else {
        result(false)
      }
    case "authorize":
      guard #available(iOS 16.0, *) else {
        result(FlutterError(code: "family_controls", message: "requires iOS 16", details: nil))
        return
      }
      Task { @MainActor in
        do {
          try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
          result(true)
        } catch {
          result(FlutterError(code: "family_controls", message: error.localizedDescription, details: nil))
        }
      }
    case "shield":
      guard #available(iOS 16.0, *) else {
        result(FlutterError(code: "family_controls", message: "requires iOS 16", details: nil))
        return
      }
      // 屏蔽全部应用类别。注意:要把 Lares 自己排除在外,需要它的 ApplicationToken,
      // 而 token 只能由用户在 FamilyActivityPicker 里选出(无法凭 bundle id 构造),
      // 届时改为 .all(except: [laresToken])。
      let store = ManagedSettingsStore()
      store.shield.applicationCategories = .all(except: Set())
      result(true)
    case "unshield":
      guard #available(iOS 16.0, *) else {
        result(true)
        return
      }
      let store = ManagedSettingsStore()
      store.shield.applicationCategories = nil
      store.shield.applications = nil
      store.shield.webDomainCategories = nil
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
#endif
