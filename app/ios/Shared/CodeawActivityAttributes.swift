import ActivityKit
import Foundation

@available(iOS 16.2, *)
struct CodeawActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var title: String?
    var backgroundUpdates: Bool?
    var locationUpdates: Bool?
    var project: String
    var agent: String
    var state: String
    var phase: String
    var summary: String
    // Unix milliseconds, identical to the bridge's payload (not Codable Date's epoch).
    var startedAt: Double
    var endedAt: Double?
    var updatedAt: Double
  }

  let hostKey: String
  let sessionId: String
  let turnId: String
}
