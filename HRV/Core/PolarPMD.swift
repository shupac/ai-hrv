import CoreBluetooth
import Foundation

/// One accelerometer sample in mG. `sensorTime` is the strap's clock in ns since 2000-01-01 UTC.
struct AccSample: Equatable {
    var sensorTime: UInt64
    var x: Int32
    var y: Int32
    var z: Int32
}

/// One PMD data notification. `timestamp` is the sensor time of the last sample.
struct AccFrame: Equatable {
    var timestamp: UInt64
    var samples: [AccSample]

    /// Phone time of a sample, anchoring the frame's last sample at the time it was received.
    /// The strap's clock isn't synced to the phone, so only differences between sensor times are used.
    func date(of sample: AccSample, receivedAt: Date) -> Date {
        receivedAt.addingTimeInterval(-Double(timestamp &- sample.sensorTime) / 1e9)
    }
}

/// Polar Measurement Data (PMD) protocol, accelerometer only.
/// Reference: polar-ble-sdk, technical_documentation/online_measurement.pdf and the iOS sources.
enum PolarPMD {
    static let service = CBUUID(string: "FB005C80-02E7-F387-1CAD-8ACD2D8DF0C8")
    static let controlPoint = CBUUID(string: "FB005C81-02E7-F387-1CAD-8ACD2D8DF0C8")
    static let data = CBUUID(string: "FB005C82-02E7-F387-1CAD-8ACD2D8DF0C8")

    static let accType: UInt8 = 2
    static let getSettingsOp: UInt8 = 1
    static let startOp: UInt8 = 2
    static let stopOp: UInt8 = 3

    /// Reading the control point returns 0x0F followed by a bitmask of supported measurement types.
    static func supportsAccelerometer(features: Data) -> Bool {
        let b = [UInt8](features)
        return b.count >= 2 && b[0] == 0x0F && b[1] & 0x04 != 0
    }

    static let getAccSettings = Data([getSettingsOp, accType])

    // MARK: - Control point

    /// Response to a control point command: F0, op code, measurement type, status, [more, parameters…].
    struct Response: Equatable {
        static let success: UInt8 = 0
        static let alreadyInState: UInt8 = 6

        var opCode: UInt8
        var measurementType: UInt8
        var status: UInt8
        var parameters: Data

        init?(_ data: Data) {
            let b = [UInt8](data)
            guard b.count >= 4, b[0] == 0xF0 else { return nil }
            opCode = b[1]
            measurementType = b[2]
            status = b[3]
            parameters = b.count > 5 ? Data(b[5...]) : Data()
        }
    }

    enum Setting: UInt8 {
        case sampleRate = 0, resolution, range, rangeMilliUnit, channels, factor
    }

    private static let settingSizes: [UInt8: Int] = [0: 2, 1: 2, 2: 2, 3: 4, 4: 1, 5: 4]

    /// Parses settings as [type, count, value…]… with little-endian values. Stops at an unknown type.
    static func parseSettings(_ data: Data) -> [Setting: [UInt32]] {
        let b = [UInt8](data)
        var result: [Setting: [UInt32]] = [:]
        var i = 0
        while i + 2 <= b.count, let size = settingSizes[b[i]] {
            let type = Setting(rawValue: b[i])!
            let count = Int(b[i + 1])
            i += 2
            guard i + count * size <= b.count else { break }
            result[type] = (0..<count).map { n in uint(b, at: i + n * size, size: size) }
            i += count * size
        }
        return result
    }

    struct AccSettings: Equatable {
        var sampleRate: Int
        var resolution: Int
        var range: Int
        var channels: Int?

        /// Lowest sample rate of at least 25 Hz (enough for posture and movement), highest resolution,
        /// and range 8 G when offered, so running doesn't clip.
        init?(available: [Setting: [UInt32]]) {
            guard let rates = available[.sampleRate], !rates.isEmpty,
                  let resolutions = available[.resolution], let maxResolution = resolutions.max(),
                  let ranges = available[.range], let maxRange = ranges.max() else { return nil }
            sampleRate = Int(rates.filter { $0 >= 25 }.min() ?? rates.max()!)
            resolution = Int(maxResolution)
            range = ranges.contains(8) ? 8 : Int(maxRange)
            channels = available[.channels]?.max().map(Int.init)
        }

        var startCommand: Data {
            var d = Data([startOp, accType])
            func add(_ s: Setting, _ v: Int, size: Int) {
                d.append(contentsOf: [s.rawValue, 1])
                for k in 0..<size { d.append(UInt8((v >> (8 * k)) & 0xFF)) }
            }
            add(.sampleRate, sampleRate, size: 2)
            add(.resolution, resolution, size: 2)
            add(.range, range, size: 2)
            if let channels { add(.channels, channels, size: 1) }
            return d
        }
    }

    /// Conversion factor from a start response, 1 when the strap doesn't send one (H10).
    static func factor(fromStartParameters params: Data) -> Float {
        guard let bits = parseSettings(params)[.factor]?.first else { return 1 }
        return Float(bitPattern: bits)
    }

    // MARK: - Data frames

    /// Parses an ACC notification: type, 8-byte timestamp, frame type, content.
    /// `previousTimestamp` is the last frame's timestamp on this connection (0 if none).
    static func parseAccFrame(_ data: Data, previousTimestamp: UInt64, sampleRate: Int, factor: Float) -> AccFrame? {
        let b = [UInt8](data)
        guard b.count >= 10, b[0] & 0x3F == accType else { return nil }
        let timestamp = UInt64(uint(b, at: 1, size: 4)) | UInt64(uint(b, at: 5, size: 4)) << 32
        let compressed = b[9] & 0x80 != 0
        let frameType = b[9] & 0x7F
        let content = Array(b[10...])

        // Raw frames are in mG (types 0–2 are 8/16/24-bit). Compressed frames are scaled by the factor;
        // compressed type 0 is in G. Same as Polar's AccData.
        let values: [[Int32]]
        var scale: Double?
        if compressed {
            guard frameType <= 1,
                  let decoded = decodeDeltaFrames(content, channels: 3, resolution: 16) else { return nil }
            values = decoded
            scale = frameType == 0 ? Double(factor) * 1000 : factor == 1 ? nil : Double(factor)
        } else {
            guard frameType <= 2 else { return nil }
            let size = Int(frameType) + 1
            guard !content.isEmpty, content.count % (3 * size) == 0 else { return nil }
            values = stride(from: 0, to: content.count, by: 3 * size).map { i in
                (0..<3).map { c in int(content, at: i + c * size, size: size) }
            }
        }
        let mG: (Int32) -> Int32 = { v in scale.map { Int32((Double(v) * $0).rounded()) } ?? v }

        let times = sampleTimes(count: values.count, last: timestamp, previous: previousTimestamp, sampleRate: sampleRate)
        let samples = zip(values, times).map { v, t in AccSample(sensorTime: t, x: mG(v[0]), y: mG(v[1]), z: mG(v[2])) }
        return AccFrame(timestamp: timestamp, samples: samples)
    }

    /// Delta-compressed content: a reference sample (`channels` × resolution bytes), then blocks of
    /// [bit width, sample count, packed little-endian signed deltas]. Each delta adds to the previous sample.
    /// Returns nil for a truncated or malformed frame.
    static func decodeDeltaFrames(_ b: [UInt8], channels: Int, resolution: Int) -> [[Int32]]? {
        let refSize = (resolution + 7) / 8
        guard b.count >= channels * refSize else { return nil }
        var samples = [(0..<channels).map { int(b, at: $0 * refSize, size: refSize) }]
        var i = channels * refSize
        while i < b.count {
            guard i + 2 <= b.count else { return nil }
            let width = Int(b[i]), count = Int(b[i + 1])
            i += 2
            let bits = width * count * channels
            let length = (bits + 7) / 8
            guard width > 0, width <= 32, i + length <= b.count else { return nil }
            let deltas = unpackSigned(Array(b[i..<i + length]), width: width, count: count * channels)
            i += length
            for n in 0..<count {
                let last = samples[samples.count - 1]
                samples.append((0..<channels).map { c in last[c] &+ deltas[n * channels + c] })
            }
        }
        return samples
    }

    /// Reads `count` signed values of `width` bits, packed LSB first.
    static func unpackSigned(_ b: [UInt8], width: Int, count: Int) -> [Int32] {
        (0..<count).map { n in
            var v: UInt32 = 0
            for k in 0..<width {
                let bit = n * width + k
                if b[bit / 8] >> (bit % 8) & 1 != 0 { v |= 1 << k }
            }
            // Sign-extend from `width` bits.
            let shift = 32 - width
            return Int32(bitPattern: v << shift) >> shift
        }
    }

    /// Sensor times for a frame's samples; the last one is the frame timestamp. Spacing comes from the
    /// time since the previous frame, or from the sample rate for the first frame or after a gap.
    static func sampleTimes(count: Int, last: UInt64, previous: UInt64, sampleRate: Int) -> [UInt64] {
        let nominal = 1e9 / Double(max(sampleRate, 1))
        var delta = nominal
        if previous > 0, previous < last {
            let measured = Double(last - previous) / Double(count)
            if measured < 2 * nominal { delta = measured }
        }
        // Offsets from `last`: sensor times in ns are too large for Double to hold exactly.
        return (0..<count).map { n in
            let offset = UInt64((delta * Double(count - 1 - n)).rounded())
            return offset > last ? 0 : last - offset
        }
    }

    // MARK: - Bytes

    private static func uint(_ b: [UInt8], at i: Int, size: Int) -> UInt32 {
        (0..<size).reduce(0) { $0 | UInt32(b[i + $1]) << (8 * $1) }
    }

    private static func int(_ b: [UInt8], at i: Int, size: Int) -> Int32 {
        let shift = 32 - 8 * size
        return Int32(bitPattern: uint(b, at: i, size: size) << shift) >> shift
    }
}
