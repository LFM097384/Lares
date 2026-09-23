import Flutter
import UIKit

/// 深链入口:lares://join(一键进房)、lares://circle/<id>?name=X(邀请进圈)。
/// 与 Android MainActivity 同一 MethodChannel 协议("join" / "circle|<id>|<name>")。
class SceneDelegate: FlutterSceneDelegate, FlutterStreamHandler {
  private let channelName = "lares/deeplink"
  private let eventsName = "lares/deeplink/events"
  private var methodChannel: FlutterMethodChannel?
  private var eventSink: FlutterEventSink?
  private var pendingPayload: String?
  private var widgetActionChannel: FlutterMethodChannel?

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    setupChannels()
    // 冷启动带链接
    if let url = connectionOptions.urlContexts.first?.url {
      handle(url: url)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let url = URLContexts.first?.url, url.scheme == "lares" else {
      super.scene(scene, openURLContexts: URLContexts)
      return
    }
    handle(url: url)
  }

  private func setupChannels() {
    guard methodChannel == nil,
          let controller = window?.rootViewController as? FlutterViewController else { return }
    let engine = controller.engine
    let mc = FlutterMethodChannel(name: channelName, binaryMessenger: engine.binaryMessenger)
    mc.setMethodCallHandler { [weak self] call, result in
      if call.method == "consumeLink" {
        result(self?.pendingPayload)
        self?.pendingPayload = nil
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    methodChannel = mc
    let ec = FlutterEventChannel(name: eventsName, binaryMessenger: engine.binaryMessenger)
    ec.setStreamHandler(self)
    setupWidgetAction(messenger: engine.binaryMessenger)
    // 推送通知的 Dart 桥(token、权限、点通知进圈)。状态在单例里,活得比 scene 久。
    LaresPushBridge.shared.attach(messenger: engine.binaryMessenger)
  }

  /// 小组件麦克风按钮(ToggleMuteIntent)-> Dart 的桥。
  ///
  /// 只在这里注入 handler:有 Flutter 引擎才可能有房间、才可能开麦。
  /// 冷启动到后台(系统为执行 intent 拉起进程、却没有连接任何 scene)时
  /// handler 为 nil,intent 会如实把小组件写回「不在房」。
  private func setupWidgetAction(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "lares/widget_action", binaryMessenger: messenger)
    widgetActionChannel = channel
    // 弱引用 self:scene 被销毁后 handler 自动失效,intent 会走 .noApp。
    // (刻意不 override sceneDidDisconnect 去清它 —— 没有 Mac 验证
    // FlutterSceneDelegate 是否实现了这个可选方法,写错 override 就是 CI 编译失败。)
    LaresWidgetBridge.toggleHandler = { [weak self] circleId, done in
      guard let self = self, let channel = self.widgetActionChannel else {
        done(.noApp)
        return
      }
      channel.invokeMethod("toggleMute", arguments: ["circleId": circleId]) { reply in
        if let map = reply as? [String: Any],
           let inRoom = map["inRoom"] as? Bool,
           let muted = map["muted"] as? Bool {
          done(.state(inRoom: inRoom, muted: muted, circleId: map["circleId"] as? String ?? ""))
        } else if (reply as? NSObject) == FlutterMethodNotImplemented {
          // Dart 侧还没注册处理器(同意内容规范之前 WidgetService 不初始化):
          // 那时连进圈都不许,更不可能在房。
          done(.noApp)
        } else {
          // FlutterError 或意料之外的回包:不知道真相,不覆盖。
          done(.unknown)
        }
      }
    }
  }


  private func handle(url: URL) {
    switch url.host {
    case "join":
      pendingPayload = "join"
      eventSink?("join")
    case "circle":
      let id = url.pathComponents.dropFirst().first ?? ""
      guard !id.isEmpty else { return }
      let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "name" })?.value ?? "朋友的圈"
      pendingPayload = "circle|\(id)|\(name)"
      eventSink?(pendingPayload)
    default:
      break
    }
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
