import ActivityKit
import Foundation

/// Keeps one Live Activity showing current HRV/HR. It can only be started while the app is
/// in the foreground, but it's updated from the background as strap data arrives.
final class LiveActivityController {
    typealias State = HRVActivityAttributes.ContentState

    static let minInterval: TimeInterval = 10   // don't spam ActivityKit (it throttles anyway)
    static let staleAfter: TimeInterval = 90    // shows "No recent data" if updates stop

    private var activity: Activity<HRVActivityAttributes>?
    private var lastUpdate: Date?

    init() {
        activity = Activity<HRVActivityAttributes>.activities.first { $0.activityState == .active }
    }

    /// Call while in the foreground. No-op if one is already running.
    func start(with state: State) {
        if let activity, activity.activityState == .active { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for old in Activity<HRVActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        activity = try? Activity.request(attributes: HRVActivityAttributes(), content: content(state), pushType: nil)
        lastUpdate = Date()
    }

    func update(_ state: State, force: Bool = false) {
        guard let activity, activity.activityState == .active else { return }
        let now = Date()
        if !force, let last = lastUpdate, now.timeIntervalSince(last) < Self.minInterval { return }
        lastUpdate = now
        let c = content(state)
        Task { await activity.update(c) }
    }

    func end() {
        activity = nil
        let all = Activity<HRVActivityAttributes>.activities
        Task {
            for a in all { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// For when the app is swiped away. iOS only reports that while the app is running (the strap
    /// wakes it about every second) and gives it a few seconds, so this blocks briefly.
    func endBeforeTermination() {
        let all = Activity<HRVActivityAttributes>.activities
        guard !all.isEmpty else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for a in all { await a.end(nil, dismissalPolicy: .immediate) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    private func content(_ s: State) -> ActivityContent<State> {
        ActivityContent(state: s, staleDate: s.updated.addingTimeInterval(Self.staleAfter))
    }
}
