import UserNotifications

/// Notifications about the strap itself, as opposed to HRV changes (see `ChangePrompter`).
enum StrapAlerts {
    /// Sent even in quiet hours: recording has stopped until the user acts.
    static func pairingLost(device: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Strap pairing lost"
        content.body = "Forget \(device ?? "the strap") in Bluetooth settings and pair it again."
        content.sound = .default
        // A fixed identifier, so a repeat replaces the earlier one instead of stacking.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "strap.pairingLost", content: content, trigger: nil))
    }
}

/// Keeps a "no data" notification scheduled a few minutes ahead. Each packet pushes it back, so it only
/// fires when data stops, for any reason. A timer can't do this: the app doesn't run once packets stop.
final class NoDataAlert {
    static let after: TimeInterval = 10 * 60
    static let rescheduleEvery: TimeInterval = 30
    private static let id = "strap.noData"

    private var lastScheduled: Date?

    func dataArrived(at now: Date) {
        guard Self.needsReschedule(last: lastScheduled, now: now) else { return }
        lastScheduled = now
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.id])
        let content = UNMutableNotificationContent()
        content.title = "No heart-rate data"
        content.body = "Nothing from the strap for \(Int(Self.after / 60)) minutes."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.after, repeats: false)
        center.add(UNNotificationRequest(identifier: Self.id, content: content, trigger: trigger))
    }

    func cancel() {
        lastScheduled = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.id])
    }

    static func needsReschedule(last: Date?, now: Date) -> Bool {
        last.map { now.timeIntervalSince($0) >= rescheduleEvery } ?? true
    }
}
