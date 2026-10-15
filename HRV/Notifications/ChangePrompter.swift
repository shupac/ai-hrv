import CoreMotion
import Foundation
import UserNotifications

/// Turns detected HRV changes into timeline tags and "what just happened?" notifications
/// that can be answered from the Lock Screen.
final class ChangePrompter: NSObject, UNUserNotificationCenterDelegate {
    static let category = "hrv.change"
    static let replyAction = "reply"
    static let quickReplies = ["Meeting / call", "Conversation", "Moving", "Nothing special"]
    static let cooldown: TimeInterval = 45 * 60
    static let quietHours = (start: 22, end: 7)

    private let store: DayStore
    private let motion = CMMotionActivityManager()

    init(store: DayStore) {
        self.store = store
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        var actions: [UNNotificationAction] = [
            UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply…", options: [],
                                          textInputButtonTitle: "Save", textInputPlaceholder: "What's happening?")
        ]
        actions += Self.quickReplies.enumerated().map { i, label in
            UNNotificationAction(identifier: "quick.\(i)", title: label, options: [])
        }
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: actions, intentIdentifiers: [], options: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Returns false when the change is explained by physical movement (caller snoozes briefly).
    func handle(_ e: ChangeDetector.Event) async -> Bool {
        if await isMoving(since: e.time.addingTimeInterval(-120)) { return false }
        let tag = await MainActor.run { store.addTag(nil, at: e.time, kind: e.kind, change: e.change) }
        if !Self.isQuietHours(Date()) { notify(e, tagID: tag.id) }
        return true
    }

    private func notify(_ e: ChangeDetector.Event, tagID: UUID) {
        let pct = Int(abs(e.change * 100).rounded())
        let content = UNMutableNotificationContent()
        content.title = e.kind == .drop ? "HRV dropped \(pct)%" : "HRV rose \(pct)%"
        content.body = "\(Int(e.baseline.rounded())) → \(Int(e.current.rounded())) ms over the last few minutes, "
            + "compared with your past hour. What's happening?"
        content.categoryIdentifier = Self.category
        content.sound = .default
        content.userInfo = ["tagID": tagID.uuidString]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: tagID.uuidString, content: content, trigger: nil))
    }

    private func isMoving(since start: Date) async -> Bool {
        guard CMMotionActivityManager.isActivityAvailable() else { return false }
        return await withCheckedContinuation { cont in
            motion.queryActivityStarting(from: start.addingTimeInterval(-600), to: Date(), to: .main) { activities, _ in
                // The last activity that began before `start` is still in effect at `start`.
                let acts = activities ?? []
                let inEffect = acts.last { $0.startDate <= start }
                let relevant = (inEffect.map { [$0] } ?? []) + acts.filter { $0.startDate > start }
                let moving = relevant.contains {
                    ($0.walking || $0.running || $0.cycling) && $0.confidence != .low
                }
                cont.resume(returning: moving)
            }
        }
    }

    static func isQuietHours(_ date: Date) -> Bool {
        let h = Calendar.current.component(.hour, from: date)
        return h >= quietHours.start || h < quietHours.end
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard let idString = response.notification.request.content.userInfo["tagID"] as? String,
              let id = UUID(uuidString: idString) else { return }
        var label: String?
        if let text = response as? UNTextInputNotificationResponse {
            label = text.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if response.actionIdentifier.hasPrefix("quick."),
                  let i = Int(response.actionIdentifier.dropFirst(6)), Self.quickReplies.indices.contains(i) {
            label = Self.quickReplies[i]
        }
        guard let label, !label.isEmpty else { return }
        // Save before completionHandler: the app may be suspended right after.
        if Thread.isMainThread {
            store.updateTag(id, label: label)
        } else {
            DispatchQueue.main.sync { store.updateTag(id, label: label) }
        }
    }
}
