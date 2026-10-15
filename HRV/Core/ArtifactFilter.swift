import Foundation

/// Classifies RR intervals as valid or artifact.
///
/// A beat is valid when it's physiologically plausible and within `maxDeviation`
/// of the median of recently accepted beats. That rejects missed beats (≈2× RR),
/// extra/ectopic beats (short + compensatory long) and noise spikes.
/// Until a reference exists (start-up, after a gap, or after a sustained shift),
/// beats are rejected until three consecutive beats agree with each other.
struct ArtifactFilter {
    var minRR: Double = 300      // 200 bpm
    var maxRR: Double = 2000     // 30 bpm
    var maxDeviation: Double = 0.20
    var referenceSize = 5
    var seedSize = 3

    private var reference: [Double] = []
    private var pending: [Double] = []

    mutating func reset() {
        reference.removeAll()
        pending.removeAll()
    }

    mutating func classify(_ rr: Double, contact: Bool? = nil) -> Bool {
        guard rr >= minRR, rr <= maxRR, contact != false else {
            pending.removeAll()
            return false
        }

        if !reference.isEmpty {
            let m = Self.median(reference)
            if abs(rr - m) / m <= maxDeviation {
                reference.append(rr)
                if reference.count > referenceSize { reference.removeFirst() }
                pending.removeAll()
                return true
            }
        }

        // Rejected (or no reference yet). If the last few rejected beats agree with
        // each other, the rhythm has genuinely shifted: adopt them as the new reference.
        pending.append(rr)
        if pending.count > seedSize { pending.removeFirst() }
        if pending.count == seedSize, Self.agree(pending, tolerance: maxDeviation) {
            reference = pending
            pending.removeAll()
        }
        return false
    }

    static func agree(_ xs: [Double], tolerance: Double) -> Bool {
        let m = median(xs)
        return xs.allSatisfy { abs($0 - m) / m <= tolerance }
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
