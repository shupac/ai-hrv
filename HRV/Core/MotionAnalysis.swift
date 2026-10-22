import Foundation

/// What the body was doing in one second, best guess from the chest accelerometer.
/// Sitting and standing both read as upright: the torso is vertical either way.
enum MotionState: String, CaseIterable {
    case running, walking, active, still, upright, reclined, lying

    var label: String {
        switch self {
        case .running: "Running"
        case .walking: "Walking"
        case .active: "Moving"
        case .still: "Still"
        case .upright: "Upright"
        case .reclined: "Reclined"
        case .lying: "Lying"
        }
    }

    var isMoving: Bool { self == .running || self == .walking || self == .active }
}

/// Signals for one second of accelerometer data.
struct MotionSecond: Equatable {
    var time: Date              // start of the second
    var gravity: SIMD3<Double>  // mean acceleration vector, mG: mostly gravity, so it gives orientation
    var movement: Double        // RMS deviation from the mean vector, mG
    var cadence: Double?        // steps/min, when moving and the last 4 s repeat with a step-like period
    var tilt: Double?           // degrees between `gravity` and the day's upright orientation
    var state: MotionState
}

struct MotionDay {
    var seconds: [MotionSecond]
    /// Unit gravity vector of the day's most common still orientation, taken to be upright.
    var upright: SIMD3<Double>?
    var postureChanges: [Date]
}

/// Raw samples → per-second signals → labels. All thresholds are first guesses, to be checked against
/// recorded days; they only label motion and don't change any HRV value.
enum MotionAnalysis {
    static let activeMovement = 30.0      // mG RMS: more than breathing and typing
    static let walkingMovement = 80.0     // mG RMS, with a step cadence
    static let runningMovement = 400.0    // mG RMS
    static let runningCadence = 140.0     // steps/min
    static let minPeriodicity = 0.4       // autocorrelation at the step period
    static let cadenceRange = 80.0...200.0
    static let reclinedTilt = 30.0        // degrees from upright
    static let lyingTilt = 60.0
    static let postureChangeAngle = 30.0  // degrees between orientations 10 s apart
    static let clusterAngle = 20.0        // still minutes this close count as the same orientation
    static let minSamplesPerSecond = 5

    static func analyze(_ frames: [MotionFrame]) -> MotionDay {
        analyze(seconds: seconds(frames))
    }

    /// Adds tilt and posture labels to seconds as `seconds(_:)` returns them.
    static func analyze(seconds: [MotionSecond]) -> MotionDay {
        var secs = seconds
        let up = upright(secs)
        if let up { applyTilt(&secs, upright: up) }
        return MotionDay(seconds: secs, upright: up, postureChanges: postureChanges(secs))
    }

    /// Bins samples into whole seconds, then labels movement. Without an upright reference, still seconds are `.still`.
    /// Frames are in arrival order; a sample that lands in an earlier second (arrival jitter) joins the current one.
    /// One pass with running sums, since a day is about 2 million samples and app builds are unoptimised.
    static func seconds(_ frames: [MotionFrame]) -> [MotionSecond] {
        struct Bin { var second: Int; var start: Int; var n = 0; var sx = 0.0, sy = 0.0, sz = 0.0, sq = 0.0 }
        var bins: [Bin] = []
        var magnitude: [Double] = []   // every sample, in bin order, for cadence
        magnitude.reserveCapacity(frames.reduce(0) { $0 + $1.samples.count })
        for f in frames {
            let n = f.samples.count
            let end = f.received.timeIntervalSince1970
            let dt = n > 1 ? Double(f.lastSensorTime &- f.firstSensorTime) / 1e9 / Double(n - 1) : 0
            for (i, s) in f.samples.enumerated() {
                let sec = Int((end - dt * Double(n - 1 - i)).rounded(.down))
                if bins.isEmpty || sec > bins[bins.count - 1].second {
                    bins.append(Bin(second: sec, start: magnitude.count))
                }
                let x = Double(s.x), y = Double(s.y), z = Double(s.z)
                let q = x * x + y * y + z * z
                let k = bins.count - 1
                bins[k].n += 1
                bins[k].sx += x; bins[k].sy += y; bins[k].sz += z; bins[k].sq += q
                magnitude.append(q.squareRoot())
            }
        }

        var out: [MotionSecond] = []
        out.reserveCapacity(bins.count)
        for (i, bin) in bins.enumerated() where bin.n >= minSamplesPerSecond {
            let n = Double(bin.n)
            let mean = SIMD3(bin.sx / n, bin.sy / n, bin.sz / n)
            // RMS deviation from the mean vector: E|a|² − |E a|².
            let movement = max(0, bin.sq / n - length2(mean)).squareRoot()
            // Cadence over this second and the three before it, if they're contiguous. Only needed for walking.
            var cadence: Double?
            if movement >= walkingMovement, i >= 3, bins[i - 3].second == bin.second - 3,
               bins[(i - 3)...i].allSatisfy({ $0.n >= minSamplesPerSecond }) {
                cadence = stepCadence(Array(magnitude[bins[i - 3].start..<(bin.start + bin.n)]), duration: 4)
            }
            let state: MotionState
            if let c = cadence {
                state = c >= runningCadence && movement >= runningMovement ? .running : .walking
            } else if movement >= activeMovement {
                state = .active
            } else {
                state = .still
            }
            out.append(MotionSecond(time: Date(timeIntervalSince1970: Double(bin.second)), gravity: mean,
                                    movement: movement, cadence: cadence, tilt: nil, state: state))
        }
        return out
    }

    /// Steps/min from the autocorrelation of acceleration magnitude, if it repeats strongly enough.
    static func stepCadence(_ magnitude: [Double], duration: TimeInterval) -> Double? {
        let n = magnitude.count
        let rate = Double(n) / duration
        let minLag = Int((rate * 60 / cadenceRange.upperBound).rounded(.down))
        let maxLag = Int((rate * 60 / cadenceRange.lowerBound).rounded(.up))
        guard minLag >= 1, maxLag < n / 2 else { return nil }
        let mean = magnitude.reduce(0, +) / Double(n)
        let x = magnitude.map { $0 - mean }
        let variance = x.reduce(0) { $0 + $1 * $1 } / Double(n)
        guard variance > 0 else { return nil }
        var best = (lag: 0, r: -1.0)
        for lag in minLag...maxLag {
            var sum = 0.0
            for t in 0..<(n - lag) { sum += x[t] * x[t + lag] }
            let r = sum / Double(n - lag) / variance
            if r > best.r { best = (lag, r) }
        }
        guard best.r >= minPeriodicity else { return nil }
        let c = 60 * rate / Double(best.lag)
        return cadenceRange.contains(c) ? c : nil
    }

    /// The day's most common still orientation: the per-minute still direction with the most still time
    /// within `clusterAngle` of it, averaged with those neighbours. Assumes the strap is mostly worn upright,
    /// so a day spent mostly lying down gets lying as its reference.
    static func upright(_ secs: [MotionSecond]) -> SIMD3<Double>? {
        var minutes: [Int: (sum: SIMD3<Double>, n: Int)] = [:]
        for s in secs where s.state == .still && length(s.gravity) > 0 {
            let m = Int((s.time.timeIntervalSince1970 / 60).rounded(.down))
            let e = minutes[m] ?? (SIMD3(), 0)
            minutes[m] = (e.sum + normalize(s.gravity), e.n + 1)
        }
        let candidates = minutes.values.filter { length($0.sum) > 0 }.map { (dir: normalize($0.sum), n: $0.n) }
        guard candidates.reduce(0, { $0 + $1.n }) >= 60 else { return nil }
        // Compare cosines rather than angles: this is quadratic in the number of still minutes.
        let minCos = cos(clusterAngle * .pi / 180)
        func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool { (a * b).sum() >= minCos }
        let support = candidates.map { c in candidates.reduce(0) { near($1.dir, c.dir) ? $0 + $1.n : $0 } }
        let best = candidates[support.indices.max { support[$0] < support[$1] }!].dir
        let sum = candidates.reduce(SIMD3<Double>()) { near($1.dir, best) ? $0 + $1.dir * Double($1.n) : $0 }
        return normalize(sum)
    }

    static func applyTilt(_ secs: inout [MotionSecond], upright: SIMD3<Double>) {
        for i in secs.indices {
            let tilt = angle(secs[i].gravity, upright)
            secs[i].tilt = tilt
            if secs[i].state == .still {
                secs[i].state = tilt >= lyingTilt ? .lying : tilt >= reclinedTilt ? .reclined : .upright
            }
        }
    }

    /// Times where the 5 s average orientation differs from the one 10 s earlier by more than
    /// `postureChangeAngle`, at most one per 30 s. Marked where the newest window starts to differ.
    static func postureChanges(_ secs: [MotionSecond]) -> [Date] {
        var bySecond: [Int: SIMD3<Double>] = [:]
        for s in secs { bySecond[Int(s.time.timeIntervalSince1970)] = s.gravity }
        func smoothed(_ t: Int) -> SIMD3<Double>? {
            let vs = (t - 4...t).compactMap { bySecond[$0] }
            return vs.count >= 4 ? vs.reduce(SIMD3<Double>(), +) / Double(vs.count) : nil
        }
        var out: [Date] = []
        var last: Int?
        for s in secs {
            let t = Int(s.time.timeIntervalSince1970)
            guard last.map({ t - $0 >= 30 }) ?? true, let now = smoothed(t), let before = smoothed(t - 10) else { continue }
            if angle(now, before) > postureChangeAngle {
                out.append(Date(timeIntervalSince1970: Double(t - 2)))
                last = t
            }
        }
        return out
    }

    static func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let la = length(a), lb = length(b)
        guard la > 0, lb > 0 else { return 0 }
        let c = max(-1, min(1, (a * b).sum() / (la * lb)))
        return acos(c) * 180 / .pi
    }

    private static func length2(_ v: SIMD3<Double>) -> Double { (v * v).sum() }
    private static func length(_ v: SIMD3<Double>) -> Double { length2(v).squareRoot() }
    private static func normalize(_ v: SIMD3<Double>) -> SIMD3<Double> { v / length(v) }
}

/// Chart-sized summary of a span of seconds.
struct MotionBucket: Identifiable, Equatable {
    var time: Date
    var movement: Double        // mean of the seconds' movement
    var tilt: Double?
    var state: MotionState      // most common state; ties go to the more active one
    var segment: Int            // increments after a gap, so lines break
    var id: Date { time }
}

extension MotionDay {
    func buckets(step: TimeInterval) -> [MotionBucket] {
        var out: [MotionBucket] = []
        var group: [MotionSecond] = []
        var segment = 0
        var lastKey: Int?
        func close() {
            guard let first = group.first else { return }
            let tilts = group.compactMap(\.tilt)
            var counts: [MotionState: Int] = [:]
            for s in group { counts[s.state, default: 0] += 1 }
            let state = MotionState.allCases.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? .still
            let key = Int((first.time.timeIntervalSince1970 / step).rounded(.down))
            out.append(MotionBucket(time: Date(timeIntervalSince1970: Double(key) * step + step / 2),
                                    movement: group.reduce(0) { $0 + $1.movement } / Double(group.count),
                                    tilt: tilts.isEmpty ? nil : tilts.reduce(0, +) / Double(tilts.count),
                                    state: state, segment: segment))
            group.removeAll()
        }
        for s in seconds {
            let key = Int((s.time.timeIntervalSince1970 / step).rounded(.down))
            if key != lastKey {
                close()
                if let lastKey, key > lastKey + 1 { segment += 1 }
                lastKey = key
            }
            group.append(s)
        }
        close()
        return out
    }

    /// Per-second signals as CSV, for checking the labels elsewhere.
    func csv() -> String {
        var s = "epoch_s,state,movement_mg,cadence_spm,tilt_deg,gx_mg,gy_mg,gz_mg\n"
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
        for m in seconds {
            s += "\(Int(m.time.timeIntervalSince1970)),\(m.state.rawValue),\(f(m.movement)),\(f(m.cadence)),"
                + "\(f(m.tilt)),\(f(m.gravity.x)),\(f(m.gravity.y)),\(f(m.gravity.z))\n"
        }
        return s
    }
}
