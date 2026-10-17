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
