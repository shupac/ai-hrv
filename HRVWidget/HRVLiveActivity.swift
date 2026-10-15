import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HRVWidgetBundle: WidgetBundle {
    var body: some Widget {
        HRVLiveActivity()
    }
}

struct HRVLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HRVActivityAttributes.self) { context in
            LockScreenView(state: context.state, stale: context.isStale)
                .padding()
        } dynamicIsland: { context in
            let s = context.state
            let stale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BPMLabel(bpm: stale ? nil : s.bpm).font(.title3)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HRVValue(state: s, stale: stale).font(.title3.bold())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(caption(s, stale: stale)).font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                BPMLabel(bpm: stale ? nil : s.bpm)
            } compactTrailing: {
                HRVValue(state: s, stale: stale, compact: true)
            } minimal: {
                HRVValue(state: s, stale: stale, compact: true)
            }
        }
    }
}

private func caption(_ s: HRVActivityAttributes.ContentState, stale: Bool) -> String {
    if stale { return "No recent data" }
    if let note = s.note, s.rmssd == nil { return note }
    return "RMSSD · \(s.window) window"
}

struct LockScreenView: View {
    var state: HRVActivityAttributes.ContentState
    var stale: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HRVValue(state: state, stale: stale).font(.system(size: 34, weight: .bold, design: .rounded))
                Text(caption(state, stale: stale)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                BPMLabel(bpm: stale ? nil : state.bpm).font(.title2.weight(.semibold))
                Text(state.updated, style: .time).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct HRVValue: View {
    var state: HRVActivityAttributes.ContentState
    var stale: Bool
    var compact = false

    var body: some View {
        if let v = state.rmssd, !stale {
            Text(compact ? "\(v)ms" : "\(v) ms").monospacedDigit()
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}

struct BPMLabel: View {
    var bpm: Int?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "heart.fill").foregroundStyle(.red)
            Text(bpm.map(String.init) ?? "—").monospacedDigit()
        }
    }
}
