import SwiftUI

/// Strap status, battery, and choosing/forgetting a strap.
struct StrapView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ble = model.ble
        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Strap", value: ble.deviceName ?? "None")
                    LabeledContent("Connection") {
                        HStack(spacing: 6) {
                            Circle().fill(statusColor(ble.state)).frame(width: 8, height: 8)
                            Text(ble.state.label)
                        }
                    }
                    LabeledContent("Battery") {
                        if let b = ble.battery {
                            Label("\(b)%", systemImage: batterySymbol(b))
                                .foregroundStyle(b <= 20 ? .red : .secondary)
                        } else {
                            Text(ble.state == .connected ? "Not reported" : "—")
                        }
                    }
                    LabeledContent("Last data") {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(ble.lastPacket.map { ago($0) } ?? "—").monospacedDigit()
                        }
                    }
                    if let bpm = model.live.bpm {
                        LabeledContent("Heart rate", value: "\(bpm) bpm")
                    }
                }

                let others = ble.devices.filter { $0.id != ble.savedDeviceID }
                let hr = others.filter(\.isHeartRate)
                let other = others.filter { !$0.isHeartRate }
                Section {
                    if hr.isEmpty {
                        Text("Searching… make sure the strap is worn (it wakes on skin contact).")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(hr) { deviceRow($0) }
                } header: {
                    Text(ble.savedDeviceID == nil ? "Heart-rate monitors" : "Switch to another strap")
                }
                if !other.isEmpty {
                    Section("Other Bluetooth devices") {
                        ForEach(other) { deviceRow($0) }
                    }
                }

                if ble.savedDeviceID != nil {
                    Section {
                        Button("Forget this strap", role: .destructive) { model.forgetStrap() }
                    } footer: {
                        Text("The app reconnects to the saved strap automatically whenever it's in range, including in the background.")
                    }
                }

                Section {
                    NavigationLink("Connection log") { ConnectionLogView(log: ble.log) }
                }

                Section {} footer: {
                    Text(BuildInfo.current.line()).monospacedDigit().lineLimit(1).textSelection(.enabled)
                }
            }
            .navigationTitle("Strap")
        }
    }

    private func deviceRow(_ d: HeartRateManager.Device) -> some View {
        Button {
            model.ble.connect(to: d.id)
        } label: {
            HStack {
                Text(d.name)
                Spacer()
                Text(d.alreadyConnected ? "Connected to iPhone" : d.rssi.map { "\($0) dBm" } ?? "")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        return s < 60 ? "\(s) s ago" : date.formatted(date: .omitted, time: .shortened)
    }

    private func batterySymbol(_ b: Int) -> String {
        switch b {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// Connect, disconnect and failure events, newest first, for diagnosing dropouts.
struct ConnectionLogView: View {
    let log: ConnectionLog

    var body: some View {
        List(log.events.reversed()) { e in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title(e))
                    Spacer()
                    Text(e.time.formatted(date: .abbreviated, time: .standard))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                if let code = e.errorCode, let domain = e.errorDomain {
                    Text("\(domain) \(code): \(e.errorDescription ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if log.events.isEmpty { ContentUnavailableView("No events", systemImage: "list.bullet") }
        }
        .navigationTitle("Connection log")
        .toolbar {
            ShareLink(item: log.text)
                .disabled(log.events.isEmpty)
        }
    }

    private func title(_ e: ConnectionEvent) -> String {
        var t = switch e.kind {
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case .connectFailed: "Connect failed"
        case .bluetoothOff: "Bluetooth off"
        case .restored: "Relaunched by iOS"
        }
        if e.requested { t += " (by app)" }
        if let d = e.downtime { t += " after \(Duration.seconds(d.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))" }
        return t
    }
}
