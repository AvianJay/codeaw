import ActivityKit
import Foundation

/// A conversation tracked in the background. Compiled into both the app and the
/// CodeawLiveActivity extension, which ActivityKit pairs up by this type.
@available(iOS 16.1, *)
struct CodeawActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var title: String
    /// `running`, `approval` or `offline`.
    var phase: String
    var detail: String
    var startedAt: Date?
    /// Completed and total entries of the agent's plan; 0 when there is none.
    var done: Int
    var total: Int
  }

  var sessionId: String
  var agent: String
  /// `codeaw://session/<id>`, opened by tapping the activity.
  var link: String
}
