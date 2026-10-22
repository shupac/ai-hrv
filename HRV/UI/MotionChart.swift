import Charts
import SwiftUI

extension MotionState {
    var color: Color {
        switch self {
        case .running: .red
        case .walking: .orange
        case .active: .yellow
        case .still: .gray
        case .upright: .teal
        case .reclined: .indigo
        case .lying: .purple
        }
    }
}

extension MotionSecond {
    /// E.g. "Walking · 108 spm · 182 mG · tilt 4°".
    var summary: String {
        var parts = [state.label]
        if let c = cadence { parts.append("\(Int(c.rounded())) spm") }
        parts.append("\(Int(movement.rounded())) mG")
        if let t = tilt { parts.append("tilt \(Int(t.rounded()))°") }
        return parts.joined(separator: " · ")
    }
}

/// Day charts of the accelerometer signals: a band of labels, movement intensity, or tilt from upright.
struct MotionChart: View {
    enum Metric { case state, movement, tilt }

    var buckets: [MotionBucket]
    var step: TimeInterval
    var metric: Metric
    var postureChanges: [Date] = []
    var domain: ClosedRange<Date>
    var selection: Binding<Date?>?

    var body: some View {
        let chart = Chart {
            marks
            changes
            if let time = selection?.wrappedValue {
                RuleMark(x: .value("Selected", time)).foregroundStyle(.primary.opacity(0.4))
            }
        }
        .chartXScale(domain: domain)
        .chartForegroundStyleScale(domain: MotionState.allCases.map(\.label), range: MotionState.allCases.map(\.color))
        .chartLegend(metric == .state ? .visible : .hidden)
        .modifier(YAxis(metric: metric))
        .clipped()

        if let selection {
            chart.chartXSelection(value: selection)
        } else {
            chart
        }
    }

    @ChartContentBuilder private var marks: some ChartContent {
        switch metric {
        case .state: stateMarks
        case .movement: movementMarks
        case .tilt: tiltMarks
        }
    }

    @ChartContentBuilder private var stateMarks: some ChartContent {
        ForEach(runs, id: \.start) { r in
            RectangleMark(xStart: .value("Start", r.start), xEnd: .value("End", r.end),
                          yStart: .value("", 0), yEnd: .value("", 1))
                .foregroundStyle(by: .value("State", r.state.label))
        }
    }

    @ChartContentBuilder private var movementMarks: some ChartContent {
        ForEach(buckets) { b in
            LineMark(x: .value("Time", b.time), y: .value("Movement", max(1, b.movement)),
                     series: .value("Segment", b.segment))
                .foregroundStyle(Color.orange)
        }
        threshold(MotionAnalysis.activeMovement, "moving")
        threshold(MotionAnalysis.walkingMovement, "walking")
    }

    @ChartContentBuilder private var tiltMarks: some ChartContent {
        ForEach(buckets.filter { $0.tilt != nil }) { b in
            LineMark(x: .value("Time", b.time), y: .value("Tilt", b.tilt ?? 0), series: .value("Segment", b.segment))
                .foregroundStyle(Color.indigo)
        }
        threshold(MotionAnalysis.reclinedTilt, "reclined")
        threshold(MotionAnalysis.lyingTilt, "lying")
    }

    @ChartContentBuilder private var changes: some ChartContent {
        ForEach(metric == .movement ? [] : visibleChanges, id: \.self) { t in
            RuleMark(x: .value("Posture change", t))
                .foregroundStyle(Color.primary.opacity(metric == .state ? 0.8 : 0.3))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
    }

    @ChartContentBuilder private func threshold(_ y: Double, _ label: String) -> some ChartContent {
        RuleMark(y: .value(label, y))
            .foregroundStyle(.secondary.opacity(0.5))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .annotation(position: .top, alignment: .leading, spacing: 0) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
    }

    /// Consecutive buckets with the same state, merged so a day draws a few hundred rectangles at most.
    private var runs: [(start: Date, end: Date, state: MotionState)] {
        var out: [(start: Date, end: Date, state: MotionState)] = []
        for b in buckets {
            let start = b.time.addingTimeInterval(-step / 2), end = b.time.addingTimeInterval(step / 2)
            if let last = out.last, last.state == b.state, abs(last.end.timeIntervalSince(start)) < 1 {
                out[out.count - 1].end = end
            } else {
                out.append((start, end, b.state))
            }
        }
        return out
    }

    private var visibleChanges: [Date] { postureChanges.filter { domain.contains($0) } }

    private struct YAxis: ViewModifier {
        var metric: Metric
        func body(content: Content) -> some View {
            switch metric {
            case .state:
                content.chartYAxis(.hidden).chartYScale(domain: 0...1)
            case .movement:
                content.chartYScale(domain: 1...2000, type: .log).chartYAxisLabel("Movement (mG)")
            case .tilt:
                content.chartYScale(domain: 0...180).chartYAxisLabel("Tilt (°)")
                    .chartYAxis { AxisMarks(values: [0, 30, 60, 90, 180]) }
            }
        }
    }
}

/// Raw x/y/z around a selected moment, with the per-second labels underneath.
struct MotionDetail: View {
    var frames: [MotionFrame]
    var seconds: [MotionSecond]
    var around: Date
    var span: TimeInterval = 30

    var body: some View {
        let range = around.addingTimeInterval(-span)...around.addingTimeInterval(span)
        let samples = points(in: range)
        let secs = seconds.filter { range.contains($0.time) }
        let current = seconds.last { $0.time <= around }
        VStack(alignment: .leading, spacing: 6) {
            if let current, around.timeIntervalSince(current.time) < 2 {
                Text(describe(current)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Chart {
                ForEach(samples, id: \.id) { p in
                    LineMark(x: .value("Time", p.time), y: .value("mG", p.value), series: .value("Axis", p.axis))
                        .foregroundStyle(by: .value("Axis", p.axis))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                RuleMark(x: .value("Selected", around)).foregroundStyle(.primary.opacity(0.4))
            }
            .chartXScale(domain: range)
            .chartForegroundStyleScale(domain: ["x", "y", "z"], range: [Color.red, .green, .blue])
            .chartYAxisLabel("mG")
            .frame(height: 160)
            .overlay { if samples.isEmpty { Text("No motion data").font(.footnote).foregroundStyle(.secondary) } }
            Chart {
                ForEach(runs(secs), id: \.start) { r in
                    RectangleMark(xStart: .value("Start", r.start), xEnd: .value("End", r.end),
                                  yStart: .value("", 0), yEnd: .value("", 1))
                        .foregroundStyle(r.state.color)
                }
            }
            .chartXScale(domain: range)
            .chartYAxis(.hidden)
            .chartXAxis(.hidden)
            .frame(height: 14)
        }
    }

    private func runs(_ secs: [MotionSecond]) -> [(start: Date, end: Date, state: MotionState)] {
        var out: [(start: Date, end: Date, state: MotionState)] = []
        for s in secs {
            if let last = out.last, last.state == s.state, last.end == s.time {
                out[out.count - 1].end = s.time.addingTimeInterval(1)
            } else {
                out.append((s.time, s.time.addingTimeInterval(1), s.state))
            }
        }
        return out
    }

    private struct Point { var id: Int; var time: Date; var value: Double; var axis: String }

    private func points(in range: ClosedRange<Date>) -> [Point] {
        var out: [Point] = []
        for f in frames where f.received >= range.lowerBound && f.received.addingTimeInterval(-5) <= range.upperBound {
            for (t, s) in zip(f.sampleTimes, f.samples) where range.contains(t) {
                let n = out.count
                out += [Point(id: n, time: t, value: Double(s.x), axis: "x"),
                        Point(id: n + 1, time: t, value: Double(s.y), axis: "y"),
                        Point(id: n + 2, time: t, value: Double(s.z), axis: "z")]
            }
        }
        return out
    }

    private func describe(_ s: MotionSecond) -> String {
        s.time.formatted(date: .omitted, time: .standard) + " · " + s.summary
    }
}
