import Flutter
import UIKit
import UserNotifications

/// 推送通知(APNs)<-> Dart 的桥。协议与 lib/src/platform/push_service.dart 的常量一一对应,
/// 改名字要两边一起改 —— test/push_contract_test.dart 会逐个字符串比对。
///
/// 为什么是单例、而不是挂在 SceneDelegate 上:
/// - 设备 token 与通知点击都从 **AppDelegate** 进来(UIApplicationDelegate /
///   UNUserNotificationCenterDelegate),那时 scene 可能还没连上、Flutter 引擎也还没建;
/// - 冷启动时点通知,didReceive 早于 Dart 能收消息,必须有个活得比 scene 久的地方先存着。
///
/// 刻意**不用 CallKit**、不开 remote-notification 后台模式:
/// 这只是一条普通的可见通知,点了才进圈;后台静默唤醒不是我们要的,也要额外审核理由。
final class LaresPushBridge: NSObject {
  static let shared = LaresPushBridge()

  // ── 协议常量(与 Dart 侧 PushService 同名常量对应)──
  static let channelName = "lares/push"
  static let categoryId = "LARES_JOIN"
  static let joinActionId = "JOIN"
  /// 点通知正文(而不是按钮)时报给 Dart 的 action 名
  static let openActionName = "open"
  /// APNs payload 里我们自己的那一段:{ lares: { circleId, server?, kind } }
  static let payloadKey = "lares"

  private var channel: FlutterMethodChannel?
  private var token: String?
  /// 用户点了通知、但 Dart 还没接手的那一次打开。
  /// 冷启动、以及同意内容规范之前(Dart 侧还没注册处理器)都会停在这里,
  /// 由 Dart 初始化时调 getInitialOpen 取走。只留最近的一次:点了两条通知,要去的是后点的那个圈。
  private var pendingOpen: [String: Any]?

  private override init() {
    super.init()
  }

  /// 在 AppDelegate.didFinishLaunching 里调用(必须在它 return 之前:
  /// 冷启动点通知的那次 didReceive,系统只会投给启动完成时已经就位的 delegate)。
  func configure(delegate: UNUserNotificationCenterDelegate) {
    let center = UNUserNotificationCenter.current()
    center.delegate = delegate
    registerCategory(center)
    // 之前已经授权过的,每次启动都重新要一次 token:token 会变(重装、换机、系统恢复),
    // 而服务端只认最新的那个。没授权过的不在这里问 —— 何时问由 Dart 决定(首次进房后)。
    center.getNotificationSettings { settings in
      if LaresPushBridge.isGranted(settings.authorizationStatus) {
        DispatchQueue.main.async {
          UIApplication.shared.registerForRemoteNotifications()
        }
      }
    }
  }

  /// 「加入」按钮。
  ///
  /// ⚠️ setNotificationCategories 是**整体替换**,不是追加。flutter_foreground_task 在
  /// iOS 上启动前台服务时也会调它(BackgroundService.swift),会把我们的分类冲掉;
  /// 目前那个服务在 Dart 侧只在 Android 启动(foreground_service.dart),所以不冲突。
  /// 将来若在 iOS 上启用它,这里要改成先 getNotificationCategories 再合并。
  private func registerCategory(_ center: UNUserNotificationCenter) {
    let zh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    let join = UNNotificationAction(
      identifier: LaresPushBridge.joinActionId,
      title: zh ? "加入" : "Join",
      // .foreground:按了要把 App 拉到前台 —— 进房需要 Flutter 引擎和麦克风,后台做不到。
      options: [.foreground]
    )
    let category = UNNotificationCategory(
      identifier: LaresPushBridge.categoryId,
      actions: [join],
      intentIdentifiers: [],
      options: []
    )
    center.setNotificationCategories([category])
  }

  /// 在 SceneDelegate.setupChannels() 里调用:那时才有 Flutter 引擎。
  func attach(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: LaresPushBridge.channelName, binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "requestPermission":
        self.requestPermission(result)
      case "getToken":
        result(self.token)
      case "permissionStatus":
        UNUserNotificationCenter.current().getNotificationSettings { settings in
          let name = LaresPushBridge.statusName(settings.authorizationStatus)
          DispatchQueue.main.async { result(name) }
        }
      case "getInitialOpen":
        result(self.pendingOpen)
        self.pendingOpen = nil
      case "getEnvironment":
        // 与 Runner.entitlements 的 aps-environment 对应:Debug 构建走开发描述文件,
        // 拿到的是 sandbox token;发往错误环境的 token 会被 APNs 拒绝(BadDeviceToken)。
        #if DEBUG
        result("sandbox")
        #else
        result("production")
        #endif
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
    // token 可能早于引擎到达(启动时的 registerForRemoteNotifications):补报一次。
    if let t = token {
      ch.invokeMethod("onToken", arguments: t)
    }
  }

  private func requestPermission(_ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
      DispatchQueue.main.async {
        if granted {
          UIApplication.shared.registerForRemoteNotifications()
        }
        result(granted)
      }
    }
  }

  // MARK: - 由 AppDelegate 转进来

  func didRegister(deviceToken: Data) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    DispatchQueue.main.async {
      self.token = hex
      self.channel?.invokeMethod("onToken", arguments: hex)
    }
  }

  /// 这条通知是不是我们发的。只认 payload 里的 lares.circleId:
  /// 分类名是展示层的东西,判断归属要看数据本身。
  static func isOurs(_ notification: UNNotification) -> Bool {
    return circleId(in: notification.request.content.userInfo) != nil
  }

  private static func circleId(in userInfo: [AnyHashable: Any]) -> String? {
    guard let lares = userInfo[payloadKey] as? [String: Any],
          let id = lares["circleId"] as? String, !id.isEmpty else { return nil }
    return id
  }

  /// 用户对我们的通知做了什么。划掉(dismiss)不算打开,什么都不做。
  func handle(response: UNNotificationResponse) {
    let action: String
    switch response.actionIdentifier {
    case LaresPushBridge.joinActionId:
      action = LaresPushBridge.joinActionId
    case UNNotificationDefaultActionIdentifier:
      action = LaresPushBridge.openActionName
    default:
      return
    }
    let userInfo = response.notification.request.content.userInfo
    guard let id = LaresPushBridge.circleId(in: userInfo) else { return }
    var open: [String: Any] = ["circleId": id, "action": action]
    if let lares = userInfo[LaresPushBridge.payloadKey] as? [String: Any],
       let server = lares["server"] as? String, !server.isEmpty {
      open["server"] = server
    }
    DispatchQueue.main.async {
      // 先存再报:Dart 没接手(还没注册处理器、引擎还没起)时不能丢。
      self.pendingOpen = open
      guard let ch = self.channel else { return }
      ch.invokeMethod("onOpen", arguments: open) { reply in
        // Dart 确实处理了才清掉缓冲;没实现(同意内容规范之前)就留给 getInitialOpen。
        if (reply as? NSObject) == FlutterMethodNotImplemented { return }
        if reply is FlutterError { return }
        // 只清「还是这一次」的缓冲:回包到之前用户可能又点了另一条通知。
        if let pending = self.pendingOpen,
           pending["circleId"] as? String == id,
           pending["action"] as? String == action {
          self.pendingOpen = nil
        }
      }
    }
  }

  private static func isGranted(_ status: UNAuthorizationStatus) -> Bool {
    switch status {
    case .authorized, .provisional, .ephemeral:
      return true
    default:
      return false
    }
  }

  private static func statusName(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .denied: return "denied"
    case .authorized: return "authorized"
    case .provisional: return "provisional"
    case .ephemeral: return "ephemeral"
    @unknown default: return "denied"
    }
  }
}
