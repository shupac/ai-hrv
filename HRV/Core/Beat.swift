import Foundation

/// A single RR interval, time-stamped at the beat that ends it.
struct Beat: Equatable {
    var time: Date
    var rr: Double          // ms
    var valid: Bool
    /// A discontinuity (disconnect, missing data) precedes this beat,
    /// so it must not be paired with the previous beat.
    var afterGap: Bool
}

/// Turns raw measurements into filtered, time-stamped beats.
///
/// RR intervals carry no timestamps of their own. We advance a running beat clock
/// by each RR and re-anchor it to the packet arrival time when it drifts or after a gap.
struct BeatProcessor {
    var filter = ArtifactFilter()
    private var lastBeatTime: Date?
    private var gapPending = true
    /// Re-anchor to wall-clock when the beat clock disagrees by more than this.
    var maxDrift: TimeInterval = 2.0

    mutating func markGap() {
        gapPending = true
        filter.reset()
    }

    mutating func process(_ m: HeartRateMeasurement, receivedAt arrival: Date) -> [Beat] {
        let rrs = m.rrIntervalsMs
        guard !rrs.isEmpty else { return [] }

        let total = rrs.reduce(0, +) / 1000
        var t: Date
        if let last = lastBeatTime, !gapPending,
           abs(last.addingTimeInterval(total).timeIntervalSince(arrival)) <= maxDrift {
            t = last
        } else {
            // Back-fill so the last beat lands on the arrival time, never before the previous beat.
            t = arrival.addingTimeInterval(-total)
            if let last = lastBeatTime, t < last { t = last }
        }

        var beats: [Beat] = []
        for rr in rrs {
            t = t.addingTimeInterval(rr / 1000)
            let valid = filter.classify(rr, contact: m.contactDetected)
            beats.append(Beat(time: t, rr: rr, valid: valid, afterGap: gapPending))
            gapPending = false
        }
        lastBeatTime = t
        return beats
    }
}
