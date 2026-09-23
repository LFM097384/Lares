// 显式 import Foundation:下面用到的 NSLocalizedString 是 Foundation 的**全局函数**,
// 不是类型。SwiftUI 顺带带进来的 Date/URL/UserDefaults 能用,不代表全局函数也一定在作用域内;
// 这一行是零成本的保险,少了它编译期才会报错,而本项目没有 Mac 可以提前验证。
import Foundation
import SwiftUI
import WidgetKit

/// Lares 主屏幕 Widget:**主圈子**名 + 在线状态,点一下一键加入主圈子(设计.md §3.2-1)。
/// 数据由 Flutter 侧(WidgetService)经 home_widget 写入 App Group UserDefaults。
///
/// 优雅降级(重要):产品负责人目前用**免费 Apple 签名**侧载,App Group 数据共享
/// 可能不可用。因此本 Widget 在读不到共享数据时,不显示任何可能过期的圈子名,
/// 而是退回中性占位文案 + 原样的 `lares://join` 深链 —— 点击行为**永远有效**,
/// 因为目标圈子是 App 进房时读 CircleStore.primaryCircle 解析的,不依赖本侧数据。
///
/// Xcode 接入步骤(需 Mac):
/// 1. File > New > Target > Widget Extension,命名 LaresWidget,去掉 Live Activity
/// 2. Runner 与 LaresWidget 都打开 App Groups:group.com.lfm097384.lares
/// 3. 将本文件加入 LaresWidget target
private let appGroup = "group.com.lfm097384.lares"

struct LaresEntry: TimelineEntry {
  let date: Date
  let circleName: String
  let presenceText: String
  /// 是否有主圈子。共享数据不可用时为 nil =「不知道」,UI 据此显示中性文案。
  let hasPrimary: Bool?
  /// 此刻是否在主圈子的房间里(且心跳没过期)。false 时不显示麦克风按钮。
  let inRoom: Bool
  /// 麦克风是否静音。只在 inRoom 时有意义;读不到一律当静音 ——
  /// 宁可显示「静音中」,也不能把一个不知道状态的麦克风画成开着。
  let muted: Bool
  /// 在房的圈子 id,随切换请求带回 Dart 核对。
  let roomCircleId: String
}

struct LaresProvider: TimelineProvider {
  /// 在房状态何时过期(App 被杀后没人会来写 in_room=false,靠心跳时间戳自己判断)。
  /// 不在房或读不到时为 nil。
  private func roomStaleAt(_ defaults: UserDefaults?) -> Date? {
    guard let raw = defaults?.string(forKey: "state_updated_at"),
          let ms = Double(raw) else { return nil }
    return Date(timeIntervalSince1970: ms / 1000)
      .addingTimeInterval(LaresWidgetBridge.staleAfterSeconds)
  }

  /// [at] 是这一条 entry 的显示时刻:时间线里「过期之后」那一条要按那一刻判断。
  private func readEntry(at date: Date = Date()) -> LaresEntry {
    // App Group 不可用(免费签名侧载)时 defaults 为 nil,或取不到我们写的键
    let defaults = UserDefaults(suiteName: appGroup)
    let name = defaults?.string(forKey: "circle_name")
    let presence = defaults?.string(forKey: "presence_text")
    // 键不存在时 object(forKey:) 返回 nil,可与「确实写了 false」区分开
    let hasPrimary = defaults?.object(forKey: "has_primary") as? Bool

    // 在房:三个条件缺一不可 —— 写的是 true、心跳没过期、读得到圈子 id。
    let wroteInRoom = (defaults?.object(forKey: "in_room") as? Bool) ?? false
    let fresh = roomStaleAt(defaults).map { date < $0 } ?? false
    let roomId = defaults?.string(forKey: "room_circle_id") ?? ""
    let inRoom = wroteInRoom && fresh && !roomId.isEmpty
    let muted = (defaults?.object(forKey: "muted") as? Bool) ?? true

    return LaresEntry(
      date: date,
      // 读不到共享数据:用中性占位,不冒用任何具体圈名(避免显示陈旧信息)
      //
      // 这里必须显式 NSLocalizedString:兜底值最终交给 `Text(entry.circleName)`,
      // 而 `Text(变量)` 走的是非本地化重载(只有 `Text("字面量")` 才当 LocalizedStringKey),
      // 写死中文的话英文机上会直接看到中文 —— Android 侧早就按语言分了 values/values-zh。
      circleName: name ?? NSLocalizedString("widget.fallbackTitle", comment: "读不到共享数据时的圈子名占位"),
      presenceText: presence ?? NSLocalizedString("widget.fallbackPresence", comment: "读不到共享数据时的在线状态占位"),
      hasPrimary: hasPrimary,
      inRoom: inRoom,
      muted: inRoom ? muted : true,
      roomCircleId: inRoom ? roomId : ""
    )
  }

  func placeholder(in context: Context) -> LaresEntry { readEntry() }

  func getSnapshot(in context: Context, completion: @escaping (LaresEntry) -> Void) {
    completion(readEntry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<LaresEntry>) -> Void) {
    // 数据由 App 主动 reloadTimelines 驱动;兜底每小时自刷一次
    let now = Date()
    let entry = readEntry(at: now)
    var entries = [entry]
    // 在房时预排一条「心跳过期那一刻」的 entry(届时显示为不在房)。
    // App 被杀后没人会来 reload,这条预排的 entry 让麦克风按钮
    // 到点自己消失,而不必指望系统的刷新预算。
    if entry.inRoom, let staleAt = roomStaleAt(UserDefaults(suiteName: appGroup)), staleAt > now {
      entries.append(readEntry(at: staleAt))
    }
    let next = Calendar.current.date(byAdding: .hour, value: 1, to: now)!
    completion(Timeline(entries: entries, policy: .after(next)))
  }
}

struct LaresWidgetView: View {
  let entry: LaresEntry

  // 设计系统色(与 app/lib/src/theme/tokens.dart 一致)
  private let bg = Color(red: 0x1C / 255, green: 0x19 / 255, blue: 0x22 / 255)
  private let ember = Color(red: 0xFF / 255, green: 0x8A / 255, blue: 0x5C / 255)
  private let textPrimary = Color(red: 0xF2 / 255, green: 0xEE / 255, blue: 0xE9 / 255)
  private let textSecondary = Color(red: 0x9A / 255, green: 0x93 / 255, blue: 0xA3 / 255)

  /// 主操作文案:确知没有圈子时引导建圈,其余一律「进圈」
  ///
  /// 同样得显式 NSLocalizedString —— 结果经 `Text(actionText)` 渲染,
  /// 传的是 String 变量而非字面量,SwiftUI 不会替我们查表。
  /// 键与 Android 的 widget_action_open / widget_action_join 一一对应。
  private var actionText: String {
    entry.hasPrimary == false
      ? NSLocalizedString("widget.actionCreate", comment: "没有主圈子时的主操作:引导建圈")
      : NSLocalizedString("widget.actionJoin", comment: "主操作:进入主圈子")
  }

  /// 麦克风按钮上的状态文案。键与 Android 的 widget_mic_on / widget_mic_muted 一一对应。
  private var micText: String {
    entry.muted
      ? NSLocalizedString("widget.micMuted", comment: "在房时麦克风按钮:当前静音")
      : NSLocalizedString("widget.micOn", comment: "在房时麦克风按钮:当前麦克风开着")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 4) {
        // 主圈子标记:确知有主圈子才点亮(与 App 内圈子列表标记一致)
        if entry.hasPrimary == true {
          Image(systemName: "flame.fill")
            .font(.system(size: 12))
            .foregroundStyle(ember)
        }
        Text(entry.circleName)
          .font(.system(size: 17, weight: .bold))
          .foregroundStyle(textPrimary)
          .lineLimit(1)
      }
      Text(entry.presenceText)
        .font(.system(size: 13))
        .foregroundStyle(ember)
        .lineLimit(2)
      Spacer(minLength: 4)
      if entry.inRoom, #available(iOS 17.0, *) {
        // 在房:麦克风按钮。点它不打开 App(ToggleMuteIntent 在 App 进程后台执行),
        // 点按钮之外的地方仍走 widgetURL 打开 App。
        // 文案只描述**真实状态**(「麦克风开着」/「静音中」),不写成「点我开麦」——
        // 这里的首要职责是如实告诉人「你现在能不能被听见」。
        Button(intent: ToggleMuteIntent(circleId: entry.roomCircleId)) {
          HStack(spacing: 6) {
            Image(systemName: entry.muted ? "mic.slash.fill" : "mic.fill")
              .font(.system(size: 13, weight: .semibold))
            Text(micText)
              .font(.system(size: 12, weight: .semibold))
              .lineLimit(1)
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .foregroundStyle(entry.muted ? textPrimary : bg)
          .background(
            Capsule().fill(entry.muted ? textSecondary.opacity(0.25) : ember)
          )
        }
        .buttonStyle(.plain)
      } else {
        // 不在房(或 iOS 16 及以下没有交互式小组件):保持原样,点一下打开 App 进圈。
        Text(actionText)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(textSecondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .containerBackground(bg, for: .widget)
    // 深链不带圈子 id:App 侧解析主圈子。共享数据不可用也照样能一键进圈。
    .widgetURL(URL(string: "lares://join"))
  }
}

@main
struct LaresWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "LaresWidget", provider: LaresProvider()) { entry in
      LaresWidgetView(entry: entry)
    }
    // 这两行出现在「添加小组件」的选择器里 —— 审核员和用户都会看到,
    // 必须随系统语言变。SwiftUI 把字面量当 LocalizedStringKey,
    // 会去查本 target 的 Localizable.strings;查不到就原样显示键名,
    // 所以键名本身也写成可读的英文,万一漏了本地化也不会露出乱码。
    .configurationDisplayName("widget.displayName")
    .description("widget.description")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
