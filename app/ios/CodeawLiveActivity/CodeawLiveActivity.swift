import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CodeawActivityBundle: WidgetBundle {
  var body: some Widget { CodeawLiveActivity() }
}

struct CodeawLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: CodeawActivityAttributes.self) { context in
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: symbol(context)).font(.title3).foregroundStyle(tint(context))
          .frame(width: 34, height: 34).background(tint(context).opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(chatTitle(context.state)).font(.headline).lineLimit(1).privacySensitive()
            Spacer(minLength: 8)
            elapsed(context.state).font(.subheadline).frame(maxWidth: 76, alignment: .trailing)
          }
          HStack(spacing: 5) {
            Circle().fill(tint(context)).frame(width: 5, height: 5)
            Text("\(context.state.project) · \(agentName(context.state.agent)) · \(label(context))")
              .font(.caption).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
          }
          Text(context.isStale ? "打開 Codeaw 同步最新狀態" : context.state.summary)
            .font(context.state.phase == "command" ? .system(.caption, design: .monospaced) : .caption)
            .lineLimit(2).privacySensitive()
          if context.state.backgroundUpdates != true && context.state.endedAt == nil {
            lastSync(context.state)
          }
        }
      }
      .padding(14)
      .activityBackgroundTint(Color(red: 0.06, green: 0.08, blue: 0.12))
      .activitySystemActionForegroundColor(.white)
      .foregroundStyle(.white)
      .widgetURL(sessionURL(context.attributes.sessionId))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label(chatTitle(context.state), systemImage: "text.bubble.fill").font(.caption).lineLimit(1).privacySensitive()
        }
        DynamicIslandExpandedRegion(.trailing) {
          elapsed(context.state).font(.caption).frame(maxWidth: 76)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 5) {
            Label(label(context), systemImage: symbol(context)).font(.caption).foregroundStyle(tint(context))
            Text(context.isStale ? "打開 Codeaw 同步最新狀態" : context.state.summary)
              .font(context.state.phase == "command" ? .system(.caption, design: .monospaced) : .caption)
              .lineLimit(2).privacySensitive()
            if context.state.backgroundUpdates != true && context.state.endedAt == nil {
              lastSync(context.state)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      } compactLeading: {
        Image(systemName: symbol(context)).foregroundStyle(tint(context))
      } compactTrailing: {
        elapsed(context.state).font(.caption2).frame(width: 48)
      } minimal: {
        Image(systemName: symbol(context)).foregroundStyle(tint(context))
      }
      .widgetURL(sessionURL(context.attributes.sessionId))
      .keylineTint(tint(context))
    }
  }

  @ViewBuilder
  private func elapsed(_ state: CodeawActivityAttributes.ContentState) -> some View {
    let start = Date(timeIntervalSince1970: state.startedAt / 1000)
    if let ended = state.endedAt {
      let seconds = max(0, Int((ended - state.startedAt) / 1000))
      Text(String(format: "%d:%02d", seconds / 60, seconds % 60)).monospacedDigit()
    } else {
      // The system animates this timer while the app is suspended; no polling required.
      Text(timerInterval: start...max(start, start.addingTimeInterval(8 * 3600)), countsDown: false)
        .monospacedDigit().minimumScaleFactor(0.7)
    }
  }

  private func chatTitle(_ state: CodeawActivityAttributes.ContentState) -> String {
    let title = state.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return title.isEmpty ? state.project : title
  }

  private func lastSync(_ state: CodeawActivityAttributes.ContentState) -> some View {
    HStack(spacing: 3) {
      Text(state.locationUpdates == true ? "背景定位同步 · 上次" : "本機同步 · 上次")
      Text(Date(timeIntervalSince1970: state.updatedAt / 1000), style: .time)
    }.font(.caption2).foregroundStyle(.secondary)
  }

  private func symbol(_ context: ActivityViewContext<CodeawActivityAttributes>) -> String {
    if context.isStale { return "wifi.slash" }
    return ["thinking": "sparkles", "command": "terminal.fill", "tool": "wrench.and.screwdriver.fill",
      "responding": "text.bubble.fill", "attention": "hand.raised.fill", "completed": "checkmark.circle.fill",
      "cancelled": "stop.circle.fill", "error": "exclamationmark.triangle.fill", "disconnected": "wifi.slash"][context.state.phase] ?? "sparkles"
  }

  private func label(_ context: ActivityViewContext<CodeawActivityAttributes>) -> String {
    if context.isStale { return "更新已暫停" }
    return ["thinking": "思考中", "command": "執行指令", "tool": "使用工具", "responding": "正在回覆",
      "attention": "需要你的回覆", "completed": "已完成", "cancelled": "已停止", "error": "執行失敗", "disconnected": "桌面已離線"][context.state.phase] ?? "工作中"
  }

  private func tint(_ context: ActivityViewContext<CodeawActivityAttributes>) -> Color {
    if context.isStale { return .gray }
    switch context.state.phase {
    case "attention": return .orange
    case "error": return .red
    case "completed": return .green
    case "cancelled", "disconnected": return .gray
    default: return .cyan
    }
  }

  private func agentName(_ value: String) -> String {
    ["codex": "Codex", "claude": "Claude", "gemini": "Gemini", "antigravity": "Antigravity"][value] ?? value.capitalized
  }

  private func sessionURL(_ id: String) -> URL? {
    URL(string: "codeaw://session/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id))
  }
}
