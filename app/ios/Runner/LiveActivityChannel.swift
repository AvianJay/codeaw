import ActivityKit
import Flutter
import UIKit

/// `codeaw/live_activity`: shows the tracked conversation as a Live Activity on the Lock
/// Screen and in the Dynamic Island. Dart arms the content while the app is visible; the
/// activity is requested as the scene resigns active, the last moment ActivityKit accepts
/// a request, and ended once the app is active again.
enum LiveActivityChannel {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "codeaw/live_activity", binaryMessenger: messenger)
    guard #available(iOS 16.2, *) else {
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "support": result(["available": false, "allowed": false])
        case "show", "openSettings": result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      }
      return
    }
    let controller = LiveActivityController.shared
    channel.setMethodCallHandler { call, result in controller.handle(call, result: result) }
  }
}

@available(iOS 16.2, *)
private final class LiveActivityController {
  static let shared = LiveActivityController()

  private var armed: [String: Any]?
  private var activity: Activity<CodeawActivityAttributes>?
  private var refresh: Timer?
  private var backgroundTask = UIBackgroundTaskIdentifier.invalid
  private var observers: [NSObjectProtocol] = []

  private init() {
    let center = NotificationCenter.default
    // No queue: the request has to happen before the scene has actually resigned.
    observers = [
      center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: nil) { [weak self] _ in
        self?.start()
      },
      center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
        self?.keepRunning()
      },
      center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: nil) { [weak self] _ in
        self?.end()
      },
    ]
    // Left over from a run that was killed while one was shown.
    for leftover in Activity<CodeawActivityAttributes>.activities {
      Task { await leftover.end(nil, dismissalPolicy: .immediate) }
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "support":
      result(["available": true, "allowed": ActivityAuthorizationInfo().areActivitiesEnabled])
    case "show":
      show(call.arguments as? [String: Any])
      result(nil)
    case "openSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func show(_ content: [String: Any]?) {
    armed = content
    guard let activity else { return }
    guard let content, content["sessionId"] as? String == activity.attributes.sessionId else {
      end()
      return
    }
    update(activity, with: content)
  }

  private func start() {
    guard activity == nil, let content = armed, let sessionId = content["sessionId"] as? String,
      ActivityAuthorizationInfo().areActivitiesEnabled
    else { return }
    let attributes = CodeawActivityAttributes(
      sessionId: sessionId,
      agent: content["agent"] as? String ?? "",
      link: content["link"] as? String ?? "codeaw://"
    )
    guard let started = try? Activity.request(attributes: attributes, content: Self.content(content), pushType: nil) else {
      return
    }
    activity = started
    // Each update pushes the stale date out, so the activity only reads as stale once iOS
    // has suspended the app and nothing can update it any more.
    refresh = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
      guard let self, let activity = self.activity, let content = self.armed else { return }
      self.update(activity, with: content)
    }
  }

  /// iOS suspends the app soon after it leaves; this buys some time for more updates.
  private func keepRunning() {
    guard activity != nil, backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "codeaw.live-activity") { [weak self] in
      self?.endBackgroundTask()
    }
  }

  private func end() {
    refresh?.invalidate()
    refresh = nil
    guard let activity else {
      endBackgroundTask()
      return
    }
    self.activity = nil
    Task {
      await activity.end(nil, dismissalPolicy: .immediate)
      DispatchQueue.main.async { self.endBackgroundTask() }
    }
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  private func update(_ activity: Activity<CodeawActivityAttributes>, with content: [String: Any]) {
    let next = Self.content(content)
    Task { await activity.update(next) }
  }

  private static func content(_ c: [String: Any]) -> ActivityContent<CodeawActivityAttributes.ContentState> {
    let steps = c["steps"] as? [String] ?? []
    let state = CodeawActivityAttributes.ContentState(
      title: c["title"] as? String ?? "",
      phase: c["phase"] as? String ?? "running",
      detail: c["detail"] as? String ?? "",
      startedAt: (c["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
      done: steps.filter { $0 == "completed" }.count,
      total: steps.count
    )
    return ActivityContent(state: state, staleDate: Date().addingTimeInterval(45))
  }
}
