import ActivityKit
import Foundation

/// Live Activity shown on the Lock Screen, Dynamic Island, and (macOS 26+) the Mac menu bar.
struct HRVActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var rmssd: Int?
        var bpm: Int?
        /// Shown instead of HRV when there's no valid value ("Collecting", "Reconnecting…").
        var note: String?
        var window: String
        var updated: Date
    }
}
