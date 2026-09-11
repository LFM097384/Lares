import SwiftUI
import WidgetKit

/// Lares 主屏幕 Widget:圈子名 + 在线状态,点一下直接进房(设计.md §3.2-1)。
/// 数据由 Flutter 侧经 home_widget 写入 App Group UserDefaults。
///
/// Xcode 接入步骤(需 Mac):
/// 1. File > New > Target > Widget Extension,命名 LaresWidget,去掉 Live Activity
/// 2. Runner 与 LaresWidget 都打开 App Groups:group.com.example.lares_app
/// 3. 将本文件加入 LaresWidget target
private let appGroup = "group.com.example.lares_app"

struct LaresEntry: TimelineEntry {
  let date: Date
  let circleName: String
  let presenceText: String
}

struct LaresProvider: TimelineProvider {
  private func readEntry() -> LaresEntry {
    let defaults = UserDefaults(suiteName: appGroup)
    return LaresEntry(
      date: Date(),
      circleName: defaults?.string(forKey: "circle_name") ?? "我们的圈",
      presenceText: defaults?.string(forKey: "presence_text") ?? "暂无人在,进去等等看?"
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

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(entry.circleName)
        .font(.system(size: 17, weight: .bold))
        .foregroundStyle(textPrimary)
      Text(entry.presenceText)
        .font(.system(size: 13))
        .foregroundStyle(ember)
      Spacer(minLength: 4)
      Text("点一下,进圈 →")
        .font(.system(size: 12))
        .foregroundStyle(textSecondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .containerBackground(bg, for: .widget)
    .widgetURL(URL(string: "lares://join"))
  }
}

@main
struct LaresWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "LaresWidget", provider: LaresProvider()) { entry in
      LaresWidgetView(entry: entry)
    }
    .configurationDisplayName("一键进圈")
    .description("显示圈子在线状态,点一下直接进房")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
