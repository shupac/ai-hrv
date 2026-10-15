import Charts
import SwiftUI

/// Line chart of RMSSD (or mean HR) over time with tag markers; gaps in data break the line.
struct HRVChart: View {
    enum Metric { case rmssd, heartRate }

    var points: [HRVPoint]
    var metric: Metric = .rmssd
    var tags: [Tag] = []
    var showTagLabels = true
    /// When non-nil, dragging on the chart selects a time.
    var selection: Binding<Date?>?

    var body: some View {
        let chart = Chart {
            ForEach(points) { p in
                if let v = value(p) {
                    LineMark(x: .value("Time", p.time), y: .value(label, v),
                             series: .value("Segment", p.segment))
                        .foregroundStyle(metric == .rmssd ? Color.accentColor : Color.red)
                        .interpolationMethod(.monotone)
                }
            }
            ForEach(visibleTags) { t in
                RuleMark(x: .value("Tag", t.time))
                    .foregroundStyle(color(t).opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        if showTagLabels {
                            Text(t.label ?? (t.kind == .drop ? "▼" : "▲"))
                                .font(.caption2)
                                .foregroundStyle(color(t))
                                .lineLimit(1)
                        }
                    }
            }
            if let time = selection?.wrappedValue {
                RuleMark(x: .value("Selected", time))
                    .foregroundStyle(.primary.opacity(0.4))
            }
        }
        .chartYAxisLabel(metric == .rmssd ? "RMSSD (ms)" : "HR (bpm)")
        .chartYScale(domain: .automatic(includesZero: metric == .rmssd))
        .chartXScale(domain: xDomain)
        .overlay {
            if points.allSatisfy({ value($0) == nil }) {
                Text("No data yet").font(.footnote).foregroundStyle(.secondary)
            }
        }

        if let selection {
            chart.chartXSelection(value: selection)
        } else {
            chart
        }
    }

    private var xDomain: ClosedRange<Date> {
        guard let first = points.first?.time, let last = points.last?.time, first < last else {
            let now = Date()
            return now.addingTimeInterval(-60)...now
        }
        return first...last
    }

    private var visibleTags: [Tag] {
        let d = xDomain
        return tags.filter { d.contains($0.time) }
    }

    private var label: String { metric == .rmssd ? "RMSSD" : "HR" }

    private func value(_ p: HRVPoint) -> Double? {
        metric == .rmssd ? p.rmssd : p.meanHR
    }

    private func color(_ t: Tag) -> Color {
        switch t.kind {
        case .manual: .blue
        case .drop: .orange
        case .rise: .green
        }
    }
}
