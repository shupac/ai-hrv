import CoreBluetooth
import Foundation
import Observation

/// One connection event. Holds no heart-rate or beat data.
struct ConnectionEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case connected, disconnected, connectFailed, bluetoothOff, restored }

    var id = UUID()
    var time: Date
    var kind: Kind
    var device: String?
    /// The app disconnected on purpose (forget or switch strap).
    var requested = false
    var errorDomain: String?
    var errorCode: Int?
    var errorDescription: String?
    /// On `connected`: seconds since the strap dropped out.
    var downtime: TimeInterval?

    var line: String {
        var parts = [Date.ISO8601FormatStyle(timeZone: .current).format(time), kind.rawValue]
        if let device { parts.append(device) }
        if requested { parts.append("requested") }
        if let errorDomain, let errorCode { parts.append("\(errorDomain) \(errorCode): \(errorDescription ?? "")") }
        if let downtime { parts.append("after \(Int(downtime.rounded())) s") }
        return parts.joined(separator: " · ")
    }
}

/// Turns raw connection callbacks into log events. Pure, so it can be tested without CoreBluetooth.
struct ConnectionMonitor {
    private(set) var disconnectedSince: Date?
    /// The strap's pairing keys no longer match; stays set until it connects again, so repeats don't re-alert.
    private(set) var pairingLost = false

    /// iOS reports these when the strap and phone no longer share pairing keys.
    static func isPairingError(_ error: Error?) -> Bool {
        guard let ns = error as NSError?, ns.domain == CBErrorDomain else { return false }
        return [CBError.Code.peerRemovedPairingInformation, .encryptionTimedOut].map(\.rawValue).contains(ns.code)
    }

    /// The user re-paired or chose another strap.
    mutating func reset() {
        pairingLost = false
    }

    mutating func handle(_ kind: ConnectionEvent.Kind, device: String?, error: Error? = nil,
                         requested: Bool = false, at now: Date) -> ConnectionEvent {
        var event = ConnectionEvent(time: now, kind: kind, device: device, requested: requested)
        if let error {
            let ns = error as NSError
            event.errorDomain = ns.domain
            event.errorCode = ns.code
            event.errorDescription = ns.localizedDescription
        }
        if !requested, Self.isPairingError(error) { pairingLost = true }
        switch kind {
        case .connected:
            pairingLost = false
            event.downtime = disconnectedSince.map { now.timeIntervalSince($0) }
            disconnectedSince = nil
        case .disconnected, .bluetoothOff:
            disconnectedSince = requested ? nil : disconnectedSince ?? now
        case .connectFailed, .restored:
            break
        }
        return event
    }
}

/// The newest connection events, kept in Documents/connection-log.json across launches.
@Observable
final class ConnectionLog {
    static let limit = 500

    private(set) var events: [ConnectionEvent] = []
    @ObservationIgnored private let url: URL

    init(root: URL? = nil) {
        let root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("connection-log.json")
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([ConnectionEvent].self, from: data) {
            events = saved
        }
    }

    func append(_ event: ConnectionEvent) {
        events.append(event)
        if events.count > Self.limit { events.removeFirst(events.count - Self.limit) }
        // Events are rare, so rewriting the whole file is fine.
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    var text: String {
        events.map(\.line).joined(separator: "\n")
    }
}
