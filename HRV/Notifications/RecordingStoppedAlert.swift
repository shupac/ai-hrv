import UserNotifications

/// Keeps a "recording stopped" notification scheduled a minute ahead. Each packet pushes it back, so it fires
/// whenever data stops, for any reason: strap off, out of range, pairing lost, Bluetooth off or the app swiped
/// away. A timer can't do this: the app doesn't run once packets stop.
final class RecordingStoppedAlert {
    static let after: TimeInterval = 60
    static let rescheduleEvery: TimeInterval = 15
    private static let id = "strap.stopped"

    private var lastScheduled: Date?

    func dataArrived(at now: Date) {
        guard Self.needsReschedule(last: lastScheduled, now: now) else { return }
        lastScheduled = now
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.id])
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped"
        content.body = "No data from the strap."
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
