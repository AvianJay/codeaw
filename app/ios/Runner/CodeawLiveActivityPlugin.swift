import ActivityKit
import Flutter
import UIKit

final class CodeawLiveActivityPlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private var manager: Any?

  init(channel: FlutterMethodChannel) { self.channel = channel }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "codeaw/live_activity", binaryMessenger: registrar.messenger())
    let plugin = CodeawLiveActivityPlugin(channel: channel)
    registrar.addMethodCallDelegate(plugin, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard #available(iOS 16.2, *) else {
      result(["supported": false, "authorized": false]); return
    }
    Task { @MainActor in
      let controller: CodeawActivityManager
      if let existing = manager as? CodeawActivityManager { controller = existing }
      else { controller = CodeawActivityManager(channel: channel); manager = controller }
      let params = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "status": result(controller.status())
      case "sync": result(await controller.sync(params))
      case "endAll":
        await controller.endAll(hostKey: params["hostKey"] as? String)
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}

@available(iOS 16.2, *)
@MainActor
final class CodeawActivityManager {
  private let channel: FlutterMethodChannel
  private var tokenTasks: [String: Task<Void, Never>] = [:]
  private var stateTasks: [String: Task<Void, Never>] = [:]
  private var dismissed = Set<String>()
  private var endedByApp = Set<String>()

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    for activity in Activity<CodeawActivityAttributes>.activities { observe(activity) }
  }

  private func identity(_ attributes: CodeawActivityAttributes) -> String {
    "\(attributes.hostKey)/\(attributes.sessionId)/\(attributes.turnId)"
  }

  private func tokenInfo(_ activity: Activity<CodeawActivityAttributes>, token: Data? = nil) -> [String: Any] {
    var data: [String: Any] = ["activityId": activity.id, "hostKey": activity.attributes.hostKey,
      "sessionId": activity.attributes.sessionId, "turnId": activity.attributes.turnId]
    if let value = token ?? activity.pushToken {
      data["pushToken"] = value.map { String(format: "%02x", $0) }.joined()
    }
    return data
  }

  func status() -> [String: Any] {
    let active = Activity<CodeawActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
    return ["supported": true, "authorized": ActivityAuthorizationInfo().areActivitiesEnabled,
      "activities": active.map { tokenInfo($0) },
      "tokens": active.filter { $0.pushToken != nil }.map { tokenInfo($0) }]
  }

  private func observe(_ activity: Activity<CodeawActivityAttributes>) {
    if tokenTasks[activity.id] != nil { return }
    tokenTasks[activity.id] = Task { [weak self] in
      for await token in activity.pushTokenUpdates {
        guard let self else { return }
        self.channel.invokeMethod("token", arguments: self.tokenInfo(activity, token: token))
      }
    }
    stateTasks[activity.id] = Task { [weak self] in
      for await state in activity.activityStateUpdates {
        guard let self else { return }
        if state == .dismissed || state == .ended {
          if !self.endedByApp.contains(activity.id) { self.dismissed.insert(self.identity(activity.attributes)) }
          self.endedByApp.remove(activity.id)
          self.channel.invokeMethod("ended", arguments: self.tokenInfo(activity))
          self.tokenTasks.removeValue(forKey: activity.id)?.cancel()
          self.stateTasks.removeValue(forKey: activity.id)?.cancel()
          return
        }
      }
    }
  }

  func sync(_ params: [String: Any]) async -> [String: Any] {
    guard let hostKey = params["hostKey"] as? String, let sessionId = params["sessionId"] as? String else { return [:] }
    let turnId = params["turnId"] as? String
    let idle = params["state"] as? String == "idle"
    let activities = Activity<CodeawActivityAttributes>.activities.filter {
      $0.attributes.hostKey == hostKey && $0.attributes.sessionId == sessionId &&
      ($0.activityState == .active || $0.activityState == .stale)
    }
    let now = Date().timeIntervalSince1970 * 1000
    let state = CodeawActivityAttributes.ContentState(
      project: String((params["project"] as? String ?? "專案").prefix(60)),
      agent: String((params["agent"] as? String ?? "AI").prefix(30)),
      state: params["state"] as? String ?? "running", phase: params["phase"] as? String ?? "thinking",
      summary: String((params["summary"] as? String ?? "正在思考…").prefix(180)),
      startedAt: (params["startedAt"] as? NSNumber)?.doubleValue ?? activities.first?.content.state.startedAt ?? now,
      endedAt: idle ? (params["endedAt"] as? NSNumber)?.doubleValue ?? now : nil,
      updatedAt: (params["updatedAt"] as? NSNumber)?.doubleValue ?? now)
    let content = ActivityContent(state: state, staleDate: idle ? nil : Date().addingTimeInterval(120))
    if idle {
      for activity in activities where turnId == nil || activity.attributes.turnId == turnId {
        await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(60)))
      }
      return [:]
    }
    guard let turnId else { return [:] }
    let attributes = CodeawActivityAttributes(hostKey: hostKey, sessionId: sessionId, turnId: turnId)
    if dismissed.contains(identity(attributes)) { return [:] }
    if !ActivityAuthorizationInfo().areActivitiesEnabled { return ["error": "請在 iPhone 設定允許 Codeaw 的即時動態"] }
    for old in activities where old.attributes.turnId != turnId { await old.end(nil, dismissalPolicy: .immediate) }
    if let activity = activities.first(where: { $0.attributes.turnId == turnId }) {
      await activity.update(content)
      observe(activity)
      return ["tokens": activity.pushToken == nil ? [] : [tokenInfo(activity)]]
    }
    // iOS allows in-app starts only in the foreground. Resume triggers a fresh snapshot.
    guard UIApplication.shared.applicationState == .active else { return ["deferred": true] }
    if Activity<CodeawActivityAttributes>.activities.filter({ $0.activityState == .active || $0.activityState == .stale }).count >= 4 { return [:] }
    do {
      let push = params["usePush"] as? Bool == true
      let activity: Activity<CodeawActivityAttributes>
      do { activity = try Activity.request(attributes: attributes, content: content, pushType: push ? .token : nil) }
      catch {
        // Side-loading profiles can lack aps-environment. Local Live Activities still work.
        if !push { throw error }
        activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
      }
      observe(activity)
      return ["tokens": activity.pushToken == nil ? [] : [tokenInfo(activity)]]
    } catch { return ["error": "iOS 無法開始即時動態，請檢查系統設定與安裝時保留的 Widget extension"] }
  }

  func endAll(hostKey: String?) async {
    for activity in Activity<CodeawActivityAttributes>.activities where hostKey == nil || activity.attributes.hostKey == hostKey {
      endedByApp.insert(activity.id)
      await activity.end(nil, dismissalPolicy: .immediate)
    }
  }
}
