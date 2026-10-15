import Foundation

/// One Heart Rate Measurement (0x2A37) notification.
struct HeartRateMeasurement: Equatable {
    var bpm: Int
    /// nil when the strap doesn't report skin contact.
    var contactDetected: Bool?
    var energyExpended: Int?
    var rrIntervalsMs: [Double]
}

enum HeartRateParser {
    /// Parses a 0x2A37 payload per the Bluetooth Heart Rate Service spec.
    static func parse(_ data: Data) -> HeartRateMeasurement? {
        let b = [UInt8](data)
        guard b.count >= 2 else { return nil }
        let flags = b[0]
        var i = 1

        let bpm: Int
        if flags & 0x01 != 0 {
            guard b.count >= i + 2 else { return nil }
            bpm = Int(b[i]) | Int(b[i + 1]) << 8
            i += 2
        } else {
            bpm = Int(b[i])
            i += 1
        }

        let contactSupported = flags & 0x04 != 0
        let contact: Bool? = contactSupported ? (flags & 0x02 != 0) : nil

        var energy: Int?
        if flags & 0x08 != 0 {
            guard b.count >= i + 2 else { return nil }
            energy = Int(b[i]) | Int(b[i + 1]) << 8
            i += 2
        }

        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while i + 1 < b.count {
                let raw = Int(b[i]) | Int(b[i + 1]) << 8
                rr.append(Double(raw) * 1000.0 / 1024.0)
                i += 2
            }
        }

        return HeartRateMeasurement(bpm: bpm, contactDetected: contact, energyExpended: energy, rrIntervalsMs: rr)
    }
}
