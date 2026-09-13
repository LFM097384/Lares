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
}

struct LaresProvider: TimelineProvider {
  private func readEntry() -> LaresEntry {
    // App Group 不可用(免费签名侧载)时 defaults 为 nil,或取不到我们写的键
    let defaults = UserDefaults(suiteName: appGroup)
    let name = defaults?.string(forKey: "circle_name")
    let presence = defaults?.string(forKey: "presence_text")
    // 键不存在时 object(forKey:) 返回 nil,可与「确实写了 false」区分开
    let hasPrimary = defaults?.object(forKey: "has_primary") as? Bool

    return LaresEntry(
      date: Date(),
      // 读不到共享数据:用中性占位,不冒用任何具体圈名(避免显示陈旧信息)
      circleName: name ?? "炉灵",
      presenceText: presence ?? "点一下,进你的主圈子",
      hasPrimary: hasPrimary
    )
  }

  func placeholder(in context: Context) -> LaresEntry { readEntry() }

  func getSnapshot(in context: Context, completion: @escaping (LaresEntry) -> Void) {
    completion(readEntry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<LaresEntry>) -> Void) {
    // 数据由 App 主动 reloadTimelines 驱动;兜底每小时自刷一次
    let entry = readEntry()
    let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date())!
    completion(Timeline(entries: [entry], policy: .after(next)))
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
  private var actionText: String {
    entry.hasPrimary == false ? "点一下,建个圈 →" : "点一下,进圈 →"
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
      Text(actionText)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(textSecondary)
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
    .configurationDisplayName("炉灵")
    .description("显示主圈子在线状态,点一下一键加入主圈子")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
