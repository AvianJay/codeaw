import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CodeawActivityBundle: WidgetBundle {
  var body: some Widget { CodeawLiveActivity() }
}

/// What one state of a chat looks like: computed once, used by every presentation.
private struct Look {
  let symbol: String
  let label: String
  /// The state in a word, for the narrow side of the island. Nil while work is running: the timer goes there.
  let short: String?
  let tint: Color
  let title: String
  /// Project and agent, where details are shown.
  let origin: String
  let detail: String
  let monospaced: Bool

  private static let accent = Color(red: 0.56, green: 0.61, blue: 1.0)
  private static let amber = Color(red: 1.0, green: 0.66, blue: 0.16)
  private static let green = Color(red: 0.25, green: 0.84, blue: 0.45)
  private static let red = Color(red: 1.0, green: 0.36, blue: 0.33)
  private static let quiet = Color(white: 0.64)

  init(_ context: ActivityViewContext<CodeawActivityAttributes>) {
    let state = context.state
    let phase = state.phase
    let ended = state.endedAt != nil
    // Waiting for an answer stays true however old the last update is; running work may have moved on.
    let paused = context.isStale && !ended && phase != "attention"

    switch phase {
    case "attention": symbol = "hand.raised.fill"; label = "需要你的回覆"; short = "待回覆"; tint = Look.amber
    case "completed": symbol = "checkmark.circle.fill"; label = "已完成"; short = "完成"; tint = Look.green
    case "error": symbol = "exclamationmark.triangle.fill"; label = "執行失敗"; short = "失敗"; tint = Look.red
    case "cancelled": symbol = "stop.circle.fill"; label = "已停止"; short = "已停止"; tint = Look.quiet
    case "disconnected": symbol = "wifi.slash"; label = "電腦已離線"; short = "離線"; tint = Look.quiet
    default:
      if paused {
        symbol = "pause.circle.fill"; label = "更新已暫停"; short = "已暫停"; tint = Look.quiet
      } else {
        switch phase {
        case "command": symbol = "terminal.fill"; label = "執行指令"
        case "tool": symbol = "wrench.and.screwdriver.fill"; label = "使用工具"
        case "responding": symbol = "text.bubble.fill"; label = "正在回覆"
        default: symbol = "sparkles"; label = "思考中"
        }
        short = nil
        tint = Look.accent
      }
    }

    let name = state.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    title = name.isEmpty ? state.project : name
    let agent = Look.agentName(state.agent)
    // With details hidden the app sends its own name for both; once is enough.
    let project = state.project == title ? "" : state.project
    origin = [project, agent].filter { !$0.isEmpty }.joined(separator: " · ")
    detail = paused ? "點一下回到 Codeaw 同步" : state.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    monospaced = !paused && phase == "command"
  }

  private static func agentName(_ value: String) -> String {
    let known = ["codex": "Codex", "claude": "Claude", "gemini": "Gemini", "antigravity": "Antigravity", "opencode": "OpenCode"]
    if let name = known[value.lowercased()] { return name }
    // Agent ids such as "pi-acp" read better without the transport.
    let trimmed = value.replacingOccurrences(of: "-acp", with: "")
    if trimmed.isEmpty { return "" }
    return String(trimmed.prefix(1)).uppercased() + String(trimmed.dropFirst())
  }
}

struct CodeawLiveActivity: Widget {
  private static let backdrop = Color(red: 0.063, green: 0.071, blue: 0.094)
  private static let primary = Color.white
  private static let secondary = Color.white.opacity(0.62)

  var body: some WidgetConfiguration {
    ActivityConfiguration(for: CodeawActivityAttributes.self) { context in
      lockScreen(context, Look(context))
        .activityBackgroundTint(CodeawLiveActivity.backdrop.opacity(0.94))
        .activitySystemActionForegroundColor(.white)
        .widgetURL(sessionURL(context.attributes.sessionId))
    } dynamicIsland: { context in
      let look = Look(context)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          tile(look, size: 36).padding(.leading, 2)
        }
        DynamicIslandExpandedRegion(.trailing) {
          elapsed(context.state)
            .font(.system(size: 17, weight: .medium, design: .rounded))
            .foregroundStyle(look.tint)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 74, minHeight: 36, alignment: .trailing)
            .padding(.trailing, 2)
        }
        DynamicIslandExpandedRegion(.center) {
          Text(look.label)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(look.tint)
            .lineLimit(1)
            .frame(minHeight: 36)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 3) {
            Text(look.title)
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(CodeawLiveActivity.primary)
              .lineLimit(1)
              .privacySensitive()
            if !look.detail.isEmpty { detail(look, lines: 2) }
            if !look.origin.isEmpty {
              Text(look.origin)
                .font(.system(size: 12))
                .foregroundStyle(CodeawLiveActivity.secondary)
                .lineLimit(1)
                .privacySensitive()
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 4)
          .padding(.bottom, 2)
        }
      } compactLeading: {
        Image(systemName: look.symbol)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(look.tint)
          .padding(.leading, 2)
      } compactTrailing: {
        compactStatus(context.state, look)
      } minimal: {
        Image(systemName: look.symbol)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(look.tint)
      }
      .widgetURL(sessionURL(context.attributes.sessionId))
      .keylineTint(look.tint)
    }
  }

  /// The Lock Screen card, also shown as a banner on phones without a Dynamic Island.
  private func lockScreen(_ context: ActivityViewContext<CodeawActivityAttributes>, _ look: Look) -> some View {
    HStack(alignment: .center, spacing: 12) {
      tile(look, size: 42)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(look.title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(CodeawLiveActivity.primary)
            .lineLimit(1)
            .privacySensitive()
          Spacer(minLength: 4)
          elapsed(context.state)
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(CodeawLiveActivity.secondary)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 70, alignment: .trailing)
        }
        HStack(spacing: 6) {
          Text(look.label)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(look.tint)
            .layoutPriority(1)
          if !look.origin.isEmpty {
            Text(look.origin)
              .font(.system(size: 13))
              .foregroundStyle(CodeawLiveActivity.secondary)
              .privacySensitive()
          }
        }
        .lineLimit(1)
        if !look.detail.isEmpty { detail(look, lines: 2) }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
  }

  private func tile(_ look: Look, size: CGFloat) -> some View {
    Image(systemName: look.symbol)
      .font(.system(size: size * 0.44, weight: .semibold))
      .foregroundStyle(look.tint)
      .frame(width: size, height: size)
      .background(look.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
  }

  private func detail(_ look: Look, lines: Int) -> some View {
    Text(look.detail)
      .font(.system(size: 13, weight: .regular, design: look.monospaced ? .monospaced : .default))
      .foregroundStyle(Color.white.opacity(0.84))
      .lineLimit(lines)
      .multilineTextAlignment(.leading)
      .privacySensitive()
  }

  /// The narrow right side of the island: the running time, or the outcome in a word.
  @ViewBuilder
  private func compactStatus(_ state: CodeawActivityAttributes.ContentState, _ look: Look) -> some View {
    if let word = look.short {
      Text(word)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(look.tint)
        .lineLimit(1)
        .padding(.trailing, 2)
    } else {
      elapsed(state)
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .foregroundStyle(look.tint)
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 50, alignment: .trailing)
        .padding(.trailing, 2)
    }
  }

  @ViewBuilder
  private func elapsed(_ state: CodeawActivityAttributes.ContentState) -> some View {
    let start = Date(timeIntervalSince1970: state.startedAt / 1000)
    if let ended = state.endedAt {
      Text(duration(max(0, Int((ended - state.startedAt) / 1000)))).monospacedDigit()
    } else {
      // The system counts this up by itself, also while the app is not running.
      Text(timerInterval: start...max(start, start.addingTimeInterval(24 * 3600)), countsDown: false)
        .monospacedDigit()
        .minimumScaleFactor(0.7)
        .lineLimit(1)
    }
  }

  private func duration(_ seconds: Int) -> String {
    seconds >= 3600
      ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
      : String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  private func sessionURL(_ id: String) -> URL? {
    URL(string: "codeaw://session/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id))
  }
}
