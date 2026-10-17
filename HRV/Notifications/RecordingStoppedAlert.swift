import UserNotifications

/// Keeps a "recording stopped" notification scheduled a minute ahead. Each packet pushes it back, so it fires
/// whenever data stops, for any reason: strap off, out of range, pairing lost, Bluetooth off or the app swiped
/// away. A timer can't do this: the app doesn't run once packets stop.
/// When data comes back after it fired, a "Recording resumed" notification replaces it.
final class RecordingStoppedAlert {
    static let after: TimeInterval = 60
    static let rescheduleEvery: TimeInterval = 15
    private static let id = "strap.stopped"
    private static let resumedID = "strap.resumed"
    private static let lastScheduledKey = "recordingStopped.lastScheduled"

    /// Persisted so a relaunch after the app was swiped away still knows the alert fired.
    private var lastScheduled: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastScheduledKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastScheduledKey) }
    }

    func dataArrived(at now: Date) {
        let last = lastScheduled
        guard Self.needsReschedule(last: last, now: now) else { return }
        lastScheduled = now
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.id])
        if let gap = Self.stoppedFor(last: last, now: now) { postResumed(after: gap) }
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped"
        content.body = "No data from the strap."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.after, repeats: false)
        center.add(UNNotificationRequest(identifier: Self.id, content: content, trigger: trigger))
    }

    private func postResumed(after gap: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Recording resumed"
        content.body = "Data is back after \(Duration.seconds(gap.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)))."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.resumedID, content: content, trigger: nil))
    }

    func cancel() {
        lastScheduled = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.id])
    }

    /// Roughly how long data was missing (to within `rescheduleEvery`), if the "stopped" alert fired.
    /// It fires `after` seconds past the last reschedule.
    static func stoppedFor(last: Date?, now: Date) -> TimeInterval? {
        guard let last, now.timeIntervalSince(last) >= after else { return nil }
        return now.timeIntervalSince(last)
    }

    static func needsReschedule(last: Date?, now: Date) -> Bool {
        last.map { now.timeIntervalSince($0) >= rescheduleEvery } ?? true
    }
}
