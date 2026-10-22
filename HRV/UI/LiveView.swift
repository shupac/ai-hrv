import SwiftUI

struct LiveView: View {
    @Environment(AppModel.self) private var model
    /// Time captured when the tag sheet opens, so the tag marks that moment.
    @State private var tagTime: Date?
    @State private var confirmation: String?

    var body: some View {
        @Bindable var live = model.live
        ScrollView {
            VStack(spacing: 16) {
                statusLine
                Picker("Window", selection: $live.window) {
                    ForEach(HRVWindow.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                HRVChart(points: model.live.series, tags: model.store.tags)
                    .frame(height: 240)
                HRVChart(points: model.live.series, metric: .heartRate, tags: model.store.tags, showTagLabels: false)
                    .frame(height: 140)
                if !model.motion.buckets.isEmpty {
                    motionCharts
                }
                tagButton
            }
            .padding()
        }
        .sheet(isPresented: Binding(get: { tagTime != nil }, set: { if !$0 { tagTime = nil } })) {
            if let time = tagTime {
                TagEditor(title: time.formatted(date: .omitted, time: .shortened), initial: nil) { label in
                    if let label { tag(label, at: time) }
                }
            }
        }
    }

    /// One compact line: current values, or why there's no HRV yet.
    private var statusLine: some View {
        let r = model.live.current
        return HStack(spacing: 16) {
            if model.ble.state != .connected {
                Text(model.ble.state.label).foregroundStyle(.secondary)
            } else if model.live.noRR {
                Text("Strap doesn't send RR intervals").foregroundStyle(.orange)
            } else if let rmssd = r.rmssd {
                Text("\(Int(rmssd.rounded())) ms").font(.title.bold())
            } else {
                Text(r.message).foregroundStyle(.secondary)
            }
            Spacer()
            if let bpm = model.live.bpm {
                Label("\(bpm)", systemImage: "heart.fill").foregroundStyle(.red)
            }
            if model.ble.state == .connected, !model.live.noRR {
                Label("\(Int((r.artifactFraction * 100).rounded()))%", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(r.artifactFraction > HRVCalculator.maxArtifactFraction ? .orange : .secondary)
            }
        }
        .font(.title3)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var motionCharts: some View {
        let m = model.motion
        let series = model.live.series
        // Same time range as the HRV chart above, so they line up.
        let first = series.first?.time ?? m.buckets.first!.time
        let last = series.last?.time ?? m.buckets.last!.time
        let domain = first < last ? first...last : last.addingTimeInterval(-60)...last
        return VStack(alignment: .leading, spacing: 12) {
            if let current = m.current {
                Text(current.summary).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            MotionChart(buckets: m.buckets, step: LiveMotion.tick, metric: .state,
                        postureChanges: m.postureChanges, domain: domain)
                .frame(height: 70)
            MotionChart(buckets: m.buckets, step: LiveMotion.tick, metric: .movement, domain: domain)
                .frame(height: 120)
            MotionChart(buckets: m.buckets, step: LiveMotion.tick, metric: .tilt,
                        postureChanges: m.postureChanges, domain: domain)
                .frame(height: 120)
        }
    }

    private var tagButton: some View {
        VStack(spacing: 8) {
            Button { tagTime = Date() } label: {
                Label("Tag what's happening", systemImage: "tag").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            if let confirmation {
                Text(confirmation).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tag(_ label: String, at time: Date) {
        model.tag(label, at: time)
        let msg = "Tagged “\(label)” at \(time.formatted(date: .omitted, time: .shortened))"
        confirmation = msg
        Task {
            try? await Task.sleep(for: .seconds(3))
            if confirmation == msg { confirmation = nil }
        }
    }
}
