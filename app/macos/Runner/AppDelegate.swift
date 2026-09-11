import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate, FlutterStreamHandler {
  private var methodChannel: FlutterMethodChannel?
  private var eventSink: FlutterEventSink?
  private var pendingPayload: String?

  // 托盘常驻(§4.2):关窗不退出,挂机到菜单栏;退出走托盘菜单
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    setupChannels()
  }

  /// 深链入口:lares://join、lares://circle/<id>?name=X(与 Android/iOS 同协议)
  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      handle(url: url)
    }
  }

  private func setupChannels() {
    guard methodChannel == nil,
          let controller = mainFlutterWindow?.contentViewController as? FlutterViewController
    else { return }
    let engine = controller.engine
    let mc = FlutterMethodChannel(name: "lares/deeplink", binaryMessenger: engine.binaryMessenger)
    mc.setMethodCallHandler { [weak self] call, result in
      if call.method == "consumeLink" {
        result(self?.pendingPayload)
        self?.pendingPayload = nil
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    methodChannel = mc
    let ec = FlutterEventChannel(name: "lares/deeplink/events", binaryMessenger: engine.binaryMessenger)
    ec.setStreamHandler(self)
  }

  private func handle(url: URL) {
    guard url.scheme == "lares" else { return }
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
