// 主屏小组件的「麦克风」按钮:iOS 17+ 交互式小组件(Button(intent:))。
//
// ⚠️ 本文件同时编进 **Runner** 与 **LaresWidget** 两个 target
// (见 ios/add_widget_target.rb 第 2 步)。原因:
//   - 小组件要用这个类型来构造按钮 —— 它得在 widget extension 里;
//   - 它遵循 LiveActivityIntent,系统会在 **App 进程**里执行 perform()
//     (而不是在小组件进程里),App 进程里也必须有这个类型。
//   Apple 原话:「if the app intent's openAppWhenRun property is true, or if the
//   intent conforms to AudioPlaybackIntent, ForegroundContinuableIntent,
//   LiveActivityIntent, or PushToTalkTransmissionIntent, the system performs the
//   app intent in the app's process」,并要求「add your custom app intent to your
//   app target」。
//   https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
//   https://developer.apple.com/documentation/appintents/liveactivityintent
//
// ## 为什么选 LiveActivityIntent,而不是别的
//
// - 普通 AppIntent:在小组件进程里跑,够不着 Flutter 引擎,也就够不着真正的麦克风。
// - openAppWhenRun = true:会把 App 拉到前台 —— 违背「不打开 App」这条需求。
// - AudioRecordingIntent:iOS 18+,且要求配一个 Live Activity 显示录音状态。
// - AudioPlaybackIntent:语义是「播放」,拿它开麦克风名不副实,审核有风险。
// - ForegroundContinuableIntent:iOS 26 已弃用,而且它的用途是「需要时切到前台」。
// LiveActivityIntent 是唯一一个「在 App 进程里跑、且不打开 App」的 iOS 17 选项。
// 它并不强制本 intent 真的去更新某个 Live Activity(Apple 开发者论坛 DTS
// 在 thread 812949 里确认过它就是「后台跑、不开 App」)。
//
// ## 从后台开麦的风险(必须真机验证,见交付报告)
//
// Apple 的规则是「录音必须在前台**开始**」:
//   https://developer.apple.com/forums/thread/751866
// 已在前台开始的录音可以借 UIBackgroundModes=audio 在后台**继续**:
//   https://developer.apple.com/forums/thread/770556
// 而后台**新启动**录音除 CallKit / LiveCommunicationKit / PushToTalk 外会被隐私策略挡住:
//   https://developer.apple.com/forums/thread/816408
// LiveKit 默认 stopAudioCaptureOnMute = true,即「静音 = 停止采集」,
// 那么在后台「取消静音」就是一次后台新启动采集,很可能失败(cannotStartRecording)。
//
// 本实现的兜底(fail-safe):
//   1. 不论成败,写回小组件的都是 Dart 侧 RTC 层回报的**真实**状态 ——
//      开不成,按钮就仍显示「静音中」,绝不显示成「麦克风开着」。
//   2. 静音方向永远可以执行(停止采集不受上述限制)。
//   3. 等 Dart 回话超时(8 秒)时**不写任何状态**:此刻不知道真相,
//      就不去覆盖;Dart 做完后会自己把真实状态写进来并刷新小组件。
//   4. App 进程里没有 Flutter 引擎在接(冷启动到后台、同意前)时,
//      写「不在房」—— 没有进程能执行开麦,按钮就不该在。

import AppIntents
import Foundation
import WidgetKit

/// 小组件 <-> App 的共享约定。键名与 Dart 侧 `WidgetService.dataKeys` 逐字一致
/// (test/widget_bridge_contract_test.dart 会读本文件比对)。
enum LaresWidgetBridge {
  static let appGroup = "group.com.lfm097384.lares"
  static let widgetKind = "LaresWidget"

  /// 多久没心跳就当成「不在房」。与 Dart `WidgetService.staleAfterSeconds` 一致。
  static let staleAfterSeconds: TimeInterval = 150

  /// 等 Dart 回话的上限。闲时挂起后开麦要重连媒体,几秒是正常的。
  static let replyTimeoutSeconds: TimeInterval = 8

  enum Outcome {
    /// Dart 回报了切换之后的真实状态
    case state(inRoom: Bool, muted: Bool, circleId: String)
    /// App 进程里没有能接这件事的 Flutter 引擎(或它还没注册处理器)
    case noApp
    /// 问了但不知道结果(超时 / Dart 侧出错)—— 不要写任何东西
    case unknown
  }

  /// 由 Runner 的 SceneDelegate 在 Flutter 引擎就绪后注入。
  /// 小组件进程里它永远是 nil —— 但 LiveActivityIntent 不在小组件进程里执行。
  /// 只在主线程读写。
  static var toggleHandler: ((String, @escaping (Outcome) -> Void) -> Void)?

  static func requestToggle(circleId: String) async -> Outcome {
    await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
      DispatchQueue.main.async {
        guard let handler = toggleHandler else {
          cont.resume(returning: .noApp)
          return
        }
        // 回话与超时都在主线程上落地,所以一个普通的 Bool 就够防重入。
        var settled = false
        handler(circleId) { outcome in
          DispatchQueue.main.async {
            if settled { return }
            settled = true
            cont.resume(returning: outcome)
          }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + replyTimeoutSeconds) {
          if settled { return }
          settled = true
          cont.resume(returning: .unknown)
        }
      }
    }
  }

  static func writeRoomState(inRoom: Bool, muted: Bool, circleId: String) {
    guard let defaults = UserDefaults(suiteName: appGroup) else { return }
    // 与 Dart 侧同一写法:毫秒时间戳存成字符串。
    let stamp = String(Int64(Date().timeIntervalSince1970 * 1000))
    defaults.set(stamp, forKey: "state_updated_at")
    defaults.set(inRoom, forKey: "in_room")
    defaults.set(muted, forKey: "muted")
    defaults.set(circleId, forKey: "room_circle_id")
  }
}

@available(iOS 17.0, *)
struct ToggleMuteIntent: LiveActivityIntent {
  // 这个 intent 只给小组件按钮用,不出现在快捷指令 / Spotlight 里:
  // 「替我开麦」不该是一个能被自动化随手调起的动作。
  static var title: LocalizedStringResource = "Toggle microphone"
  static var isDiscoverable: Bool = false

  /// 小组件显示的是哪个圈子的在房状态。Dart 侧核对与此刻所在的圈子一致才执行。
  @Parameter(title: "Circle")
  var circleId: String

  init() {}

  init(circleId: String) {
    self.circleId = circleId
  }

  func perform() async throws -> some IntentResult {
    switch await LaresWidgetBridge.requestToggle(circleId: circleId) {
    case let .state(inRoom, muted, id):
      LaresWidgetBridge.writeRoomState(inRoom: inRoom, muted: muted, circleId: id)
    case .noApp:
      // 没有 App 进程在接:不假装成功,小组件回落到「不在房」。
      LaresWidgetBridge.writeRoomState(inRoom: false, muted: true, circleId: "")
    case .unknown:
      // 不知道真相就不覆盖;Dart 做完会自己写回并刷新。
      break
    }
    WidgetCenter.shared.reloadTimelines(ofKind: LaresWidgetBridge.widgetKind)
    return .result()
  }
}
