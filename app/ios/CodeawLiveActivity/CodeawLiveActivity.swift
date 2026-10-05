import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CodeawWidgets: WidgetBundle {
  var body: some Widget {
    CodeawLiveActivity()
  }
}

/// A conversation tracked in the background, on the Lock Screen and in the Dynamic Island.
struct CodeawLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: CodeawActivityAttributes.self) { context in
      LockScreenView(context: context)
        .widgetURL(URL(string: context.attributes.link))
    } dynamicIsland: { context in
      let status = Status(context)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label(context.attributes.agent, systemImage: status.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.tint)
            .lineLimit(1)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Elapsed(state: context.state, width: 64)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            Text(context.state.title).font(.headline).lineLimit(1)
            Text(status.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            Steps(state: context.state, tint: status.tint)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } compactLeading: {
        Image(systemName: status.symbol).foregroundStyle(status.tint)
      } compactTrailing: {
        if context.state.phase == "approval" {
          Text("待批准").font(.caption2).foregroundStyle(status.tint)
        } else if context.state.total > 0 {
          Text("\(context.state.done)/\(context.state.total)").font(.caption2.monospacedDigit())
        } else if !context.isStale {
          Elapsed(state: context.state, width: 44).font(.caption2)
        }
      } minimal: {
        Image(systemName: status.symbol).foregroundStyle(status.tint)
      }
      .widgetURL(URL(string: context.attributes.link))
      .keylineTint(status.tint)
    }
  }
}

private struct Status {
  let symbol: String
  let tint: Color
  let detail: String

  init(_ context: ActivityViewContext<CodeawActivityAttributes>) {
    // Stale: iOS suspended the app, so this is the last state it saw.
    if context.isStale {
      symbol = "pause.circle.fill"
      tint = .gray
      detail = "App 在背景已暫停更新，點一下查看最新進度"
      return
    }
    switch context.state.phase {
    case "approval":
      symbol = "hand.raised.fill"
      tint = .orange
    case "offline":
      symbol = "wifi.slash"
      tint = .gray
    default:
      symbol = "terminal.fill"
      tint = Color(red: 0.059, green: 0.616, blue: 0.541)
    }
    detail = context.state.detail
  }
}

private struct LockScreenView: View {
  let context: ActivityViewContext<CodeawActivityAttributes>

  var body: some View {
    let status = Status(context)
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: status.symbol).foregroundStyle(status.tint)
        Text(context.attributes.agent)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 8)
        Elapsed(state: context.state, width: 72)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Text(context.state.title).font(.headline).lineLimit(1)
      Text(status.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
      Steps(state: context.state, tint: status.tint)
    }
    .padding(16)
  }
}

/// Time spent on the turn, kept ticking by the system without app updates.
private struct Elapsed: View {
  let state: CodeawActivityAttributes.ContentState
  let width: CGFloat

  var body: some View {
    if let startedAt = state.startedAt {
      // Timer text is laid out at its widest; keep it from crowding the rest.
      Text(startedAt, style: .timer)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: width, alignment: .trailing)
    }
  }
}

/// Progress through the agent's plan, when it has one.
private struct Steps: View {
  let state: CodeawActivityAttributes.ContentState
  let tint: Color

  var body: some View {
    if state.total > 0 {
      HStack(spacing: 8) {
        ProgressView(value: Double(state.done), total: Double(state.total)).tint(tint)
        Text("\(state.done)/\(state.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }
    }
  }
}
