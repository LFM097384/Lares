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
          let controller = window?.rootViewController as? FlutterViewController,
          let engine = controller.engine else { return }
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
