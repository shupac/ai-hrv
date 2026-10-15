import Foundation

/// Watches the rolling 60 s RMSSD for a large, sustained departure from the past hour's baseline.
struct ChangeDetector {
    struct Event: Equatable {
        var kind: Tag.Kind      // .drop or .rise
        var time: Date          // approximate onset
        var baseline: Double
        var current: Double
        var change: Double { current / baseline - 1 }
    }

    var dropThreshold = 0.35        // ≥35% below baseline
    var riseThreshold = 0.50        // ≥50% above baseline
    var sustain: TimeInterval = 120 // for this long
    var consistency = 0.85          // share of recent points beyond the threshold
    var baselineSpan: TimeInterval = 3600
    var baselineGap: TimeInterval = 300   // keep the onset out of the baseline
    var minBaseline: TimeInterval = 1200  // need ≥20 min of valid baseline
    var minRecentValid = 0.75
    var step: TimeInterval = 5

    private(set) var history: [(time: Date, rmssd: Double?)] = []
    private(set) var snoozedUntil: Date?

    mutating func snooze(until t: Date) {
        snoozedUntil = max(snoozedUntil ?? t, t)
    }

    mutating func add(_ rmssd: Double?, at now: Date) -> Event? {
        history.append((now, rmssd))
        let cutoff = now.addingTimeInterval(-baselineSpan)
        if let i = history.firstIndex(where: { $0.time > cutoff }), i > 0 { history.removeFirst(i) }
        if let s = snoozedUntil, now < s { return nil }

        let recentStart = now.addingTimeInterval(-sustain)
        let recent = history.filter { $0.time > recentStart }.compactMap(\.rmssd)
        guard Double(recent.count) >= minRecentValid * sustain / step else { return nil }

        let baseEnd = now.addingTimeInterval(-baselineGap)
        let base = history.filter { $0.time <= baseEnd }.compactMap(\.rmssd)
        guard Double(base.count) * step >= minBaseline else { return nil }
        let baseline = ArtifactFilter.median(base)
        guard baseline > 0 else { return nil }

        let n = Double(recent.count)
        let kind: Tag.Kind
        if Double(recent.filter { $0 <= baseline * (1 - dropThreshold) }.count) >= consistency * n {
            kind = .drop
        } else if Double(recent.filter { $0 >= baseline * (1 + riseThreshold) }.count) >= consistency * n {
            kind = .rise
        } else {
            return nil
        }
        return Event(kind: kind, time: recentStart, baseline: baseline, current: ArtifactFilter.median(recent))
    }
}
