import SwiftUI

@Observable
final class AppModel {
    let ble = HeartRateManager()
    let store = DayStore()
    let live: LiveSession
    let prompter: ChangePrompter
    let activity = LiveActivityController()

    init() {
        live = LiveSession(store: store)
        prompter = ChangePrompter(store: store)
        ble.onMeasurement = { [unowned self] m, date in
            live.handle(m, at: date)
            // Covers the app sitting in the foreground past the ~8 h limit.
            if UIApplication.shared.applicationState == .active { startLiveActivity() }
            activity.update(activityState())
        }
        ble.onDisconnect = { [unowned self] in
            live.handleDisconnect()
            // It can't be restarted from the background, so it returns the next time the app is opened.
            activity.end()
        }
        live.onChange = { [prompter] event in await prompter.handle(event) }
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification,
                                               object: nil, queue: nil) { [activity] _ in
            activity.endBeforeTermination()
        }
    }

    /// Starts the Live Activity if needed; only possible while the app is in the foreground.
    func startLiveActivity() {
        activity.start(with: activityState())
    }

    /// The Live Activity is only shown while the strap is connected; the first packet starts it.
    func appBecameActive() {
        if ble.state == .connected { startLiveActivity() } else { activity.end() }
    }

    private func activityState(note: String? = nil) -> LiveActivityController.State {
        let r = live.current
        let connected = note == nil
        return .init(rmssd: connected ? r.rmssd.map { Int($0.rounded()) } : nil,
                     bpm: connected ? live.bpm : nil,
                     note: note ?? (live.noRR ? "No RR data" : r.rmssd == nil ? r.shortMessage : nil),
                     window: live.window.label,
                     updated: Date())
    }

    func tag(_ label: String, at time: Date = Date()) {
        store.addTag(label, at: time)
        if Date().timeIntervalSince(time) < 120 { live.didTagManually(at: time) }
    }
}

enum AppTab { case live, history, strap }

@main
struct HRVApp: App {
    @State private var model = AppModel()
    @State private var tab: AppTab = .live
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            // All tabs stay alive so scroll and navigation state survive switching.
            ZStack {
                page(.live) { LiveView() }
                page(.history) { HistoryView() }
                page(.strap) { StrapView() }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { TabBar(selection: $tab) }
            .environment(model)
            .onChange(of: tab) { old, new in
                if new == .strap { model.ble.startScan() }
                if old == .strap { model.ble.stopScan() }
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Keep the screen awake while the app is in front.
            UIApplication.shared.isIdleTimerDisabled = phase == .active
            if phase == .active { model.appBecameActive() }
            if phase != .active { model.store.flush() }
        }
    }

    private func page<V: View>(_ t: AppTab, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .opacity(tab == t ? 1 : 0)
            .allowsHitTesting(tab == t)
            .accessibilityHidden(tab != t)
    }
}

/// A plain, opaque bottom bar: takes its own space instead of floating over content.
struct TabBar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: AppTab

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                item(.live, "Live") { Image(systemName: "waveform.path.ecg") }
                item(.history, "History") { Image(systemName: "calendar") }
                item(.strap, strapLabel) { strapIcon }
            }
            .padding(.top, 6)
            .padding(.bottom, 2)
        }
        .background(.background)
    }

    private func item<Icon: View>(_ t: AppTab, _ label: String, @ViewBuilder icon: () -> Icon) -> some View {
        Button { selection = t } label: {
            VStack(spacing: 3) {
                icon().font(.system(size: 21)).frame(height: 26)
                Text(label).font(.caption2.weight(.medium)).monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selection == t ? Color.accentColor : Color.secondary)
    }

    private var strapLabel: String {
        if model.ble.state == .connected, let b = model.ble.battery { return "Strap \(b)%" }
        return "Strap"
    }

    private var strapIcon: some View {
        Image(systemName: "heart.circle")
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(statusColor(model.ble.state))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                    .offset(x: 3, y: -1)
            }
    }
}

func statusColor(_ s: HeartRateManager.State) -> Color {
    switch s {
    case .connected: .green
    case .connecting, .reconnecting, .scanning: .orange
    default: .red
    }
}
