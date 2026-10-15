import Foundation

enum HRVWindow: Int, CaseIterable, Identifiable {
    case s30 = 30
    case s60 = 60
    case m5 = 300

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }
    var label: String {
        switch self {
        case .s30: "30s"
        case .s60: "60s"
        case .m5: "5m"
        }
    }
    /// Minimum valid successive-difference pairs for a trustworthy RMSSD.
    var minPairs: Int { self == .s30 ? 20 : 40 }
}

struct HRVResult: Equatable {
    enum Status: Equatable {
        case ok
        case collecting(have: TimeInterval, need: TimeInterval)
        case tooManyArtifacts
        case notEnoughCleanBeats
    }

    var status: Status
    var rmssd: Double?          // ms, only when status == .ok
    var meanHR: Double?         // bpm from valid beats
    var validPairs: Int
    var artifactFraction: Double

    /// For tight spaces like the Live Activity.
    var shortMessage: String {
        switch status {
        case .ok: ""
        case .collecting: "Collecting…"
        case .tooManyArtifacts: "Too many artifacts"
        case .notEnoughCleanBeats: "Weak signal"
        }
    }

    var message: String {
        switch status {
        case .ok: ""
        case let .collecting(have, need): "Collecting… \(Int(have))/\(Int(need)) s"
        case .tooManyArtifacts: "Too many artifacts (\(Int((artifactFraction * 100).rounded()))%)"
        case .notEnoughCleanBeats: "Not enough clean beats"
        }
    }
}

/// One point of an HRV time series. `segment` changes across gaps so charts break the line.
struct HRVPoint: Identifiable, Equatable {
    var time: Date
    var rmssd: Double?
    var meanHR: Double?
    var segment: Int
    var id: Date { time }
}

enum HRVCalculator {
    static let minCoverage = 0.70
    static let maxArtifactFraction = 0.20
    static let fillFraction = 0.90

    /// RMSSD over the beats whose time falls in (end - window, end].
    /// `beats` must be sorted by time.
    static func compute(_ beats: [Beat], window: HRVWindow, endingAt end: Date) -> HRVResult {
        let start = end.addingTimeInterval(-window.seconds)
        let lo = firstIndex(in: beats, after: start)
        let hi = firstIndex(in: beats, after: end)
        return compute(beats[lo..<hi], window: window)
    }

    static func compute(_ w: ArraySlice<Beat>, window: HRVWindow) -> HRVResult {
        let total = w.count
        let invalid = w.reduce(0) { $0 + ($1.valid ? 0 : 1) }
        let artifactFraction = total == 0 ? 0 : Double(invalid) / Double(total)
        let span = w.reduce(0) { $0 + $1.rr } / 1000

        var sumSq = 0.0, pairs = 0, coveredMs = 0.0
        var validRRSum = 0.0, validCount = 0
        var prev: Beat?
        for b in w {
            if b.valid { validRRSum += b.rr; validCount += 1 }
            if let p = prev, p.valid, b.valid, !b.afterGap {
                let d = b.rr - p.rr
                sumSq += d * d
                pairs += 1
                coveredMs += b.rr
            }
            prev = b
        }
        let meanHR = validCount > 0 ? 60000 / (validRRSum / Double(validCount)) : nil

        func result(_ s: HRVResult.Status, _ rmssd: Double? = nil) -> HRVResult {
            HRVResult(status: s, rmssd: rmssd, meanHR: meanHR, validPairs: pairs, artifactFraction: artifactFraction)
        }

        if span < window.seconds * fillFraction {
            return result(.collecting(have: span, need: window.seconds))
        }
        if artifactFraction > maxArtifactFraction {
            return result(.tooManyArtifacts)
        }
        if pairs < window.minPairs || coveredMs / 1000 < window.seconds * minCoverage {
            return result(.notEnoughCleanBeats)
        }
        return result(.ok, (sumSq / Double(pairs)).squareRoot())
    }

    /// Rolling RMSSD sampled every `step` seconds across [from, to].
    static func series(_ beats: [Beat], window: HRVWindow, from: Date, to: Date, step: TimeInterval = 5) -> [HRVPoint] {
        guard from <= to else { return [] }
        var points: [HRVPoint] = []
        var segment = 0
        var lastWasValue = false
        var t = from
        while t <= to {
            let r = compute(beats, window: window, endingAt: t)
            if r.rmssd == nil, lastWasValue { segment += 1 }
            lastWasValue = r.rmssd != nil
            points.append(HRVPoint(time: t, rmssd: r.rmssd, meanHR: r.meanHR, segment: segment))
            t = t.addingTimeInterval(step)
        }
        return points
    }

    /// Index of the first beat with time > date (binary search).
    static func firstIndex(in beats: [Beat], after date: Date) -> Int {
        var lo = 0, hi = beats.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if beats[mid].time <= date { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
