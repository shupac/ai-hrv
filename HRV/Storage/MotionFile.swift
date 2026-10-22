import Foundation

/// One stored accelerometer frame: the phone time it arrived, the strap's sensor times of its first and
/// last sample, and the samples in mG. Samples within a frame are evenly spaced (as `PolarPMD` produces them).
struct MotionFrame: Equatable {
    var received: Date
    var firstSensorTime: UInt64
    var lastSensorTime: UInt64
    var samples: [(x: Int16, y: Int16, z: Int16)]

    init(received: Date, firstSensorTime: UInt64, lastSensorTime: UInt64, samples: [(x: Int16, y: Int16, z: Int16)]) {
        self.received = received
        self.firstSensorTime = firstSensorTime
        self.lastSensorTime = lastSensorTime
        self.samples = samples
    }

    init(_ frame: AccFrame, receivedAt: Date) {
        func clamp(_ v: Int32) -> Int16 { Int16(clamping: v) }
        self.init(received: receivedAt,
                  firstSensorTime: frame.samples.first?.sensorTime ?? frame.timestamp,
                  lastSensorTime: frame.samples.last?.sensorTime ?? frame.timestamp,
                  samples: frame.samples.map { (clamp($0.x), clamp($0.y), clamp($0.z)) })
    }

    /// Phone time of each sample, anchoring the last sample at the time the frame arrived.
    var sampleTimes: [Date] {
        let n = samples.count
        guard n > 1 else { return samples.isEmpty ? [] : [received] }
        let span = Double(lastSensorTime &- firstSensorTime) / 1e9
        return (0..<n).map { received.addingTimeInterval(-span * Double(n - 1 - $0) / Double(n - 1)) }
    }

    static func == (a: MotionFrame, b: MotionFrame) -> Bool {
        // Received time is stored to the millisecond.
        ms(a.received) == ms(b.received) && a.firstSensorTime == b.firstSensorTime && a.lastSensorTime == b.lastSensorTime
            && a.samples.elementsEqual(b.samples) { $0.x == $1.x && $0.y == $1.y && $0.z == $1.z }
    }

    private static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
}

/// Per-day accelerometer file, `Documents/days/YYYY-MM-DD.motion`. Little-endian binary:
///
///     header  "HRVM" · UInt16 version (1) · UInt16 reserved (0)
///     record  UInt8 type (1 = accelerometer frame) · Int64 received epoch ms ·
///             UInt64 first sensor ns · UInt64 last sensor ns · UInt16 count · count × (Int16 x, y, z) mG
///
/// Records are only appended. Gaps aren't marked: they show as a jump in received time.
/// Readers stop at a record type they don't know or a truncated record (e.g. after a crash mid-write).
enum MotionFile {
    static let magic = Data("HRVM".utf8)
    static let version: UInt16 = 1
    static let header = magic + le(version) + le(UInt16(0))
    static let frameRecord: UInt8 = 1

    static func encode(_ f: MotionFrame) -> Data {
        var d = Data(capacity: 27 + f.samples.count * 6)
        d.append(frameRecord)
        d += le(Int64((f.received.timeIntervalSince1970 * 1000).rounded()))
        d += le(f.firstSensorTime)
        d += le(f.lastSensorTime)
        d += le(UInt16(clamping: f.samples.count))
        for s in f.samples.prefix(Int(UInt16.max)) { d += le(s.x) + le(s.y) + le(s.z) }
        return d
    }

    /// Frames in file order, or nil if the header is missing or from a newer version.
    static func decode(_ data: Data) -> [MotionFrame]? {
        data.withUnsafeBytes { raw -> [MotionFrame]? in
            func read<T: FixedWidthInteger>(_ i: inout Int) -> T? {
                guard i + MemoryLayout<T>.size <= raw.count else { return nil }
                defer { i += MemoryLayout<T>.size }
                return T(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: T.self))
            }
            guard raw.count >= header.count, Data(raw[0..<4]) == magic else { return nil }
            var i = 4
            guard let v: UInt16 = read(&i), v <= version, let _: UInt16 = read(&i) else { return nil }
            var frames: [MotionFrame] = []
            while i < raw.count, raw[i] == frameRecord {
                i += 1
                guard let ms: Int64 = read(&i), let first: UInt64 = read(&i), let last: UInt64 = read(&i),
                      let count: UInt16 = read(&i), i + Int(count) * 6 <= raw.count else { break }
                var samples: [(x: Int16, y: Int16, z: Int16)] = []
                samples.reserveCapacity(Int(count))
                for _ in 0..<count {
                    let x: Int16 = read(&i)!, y: Int16 = read(&i)!, z: Int16 = read(&i)!
                    samples.append((x, y, z))
                }
                frames.append(MotionFrame(received: Date(timeIntervalSince1970: Double(ms) / 1000),
                                          firstSensorTime: first, lastSensorTime: last, samples: samples))
            }
            return frames
        }
    }

    private static func le<T: FixedWidthInteger>(_ v: T) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }
}

/// Appends accelerometer frames to the current day's motion file, buffered like the day CSV.
final class MotionRecorder {
    private let dir: URL
    private var handle: FileHandle?
    private(set) var currentDay: String?
    private var buffer = Data()
    private var lastFlush = Date()

    init(dir: URL) { self.dir = dir }

    func url(day: String) -> URL { dir.appendingPathComponent("\(day).motion") }

    func append(_ frame: MotionFrame) {
        let day = DayKey.key(for: frame.received)
        if day != currentDay { open(day) }
        buffer += MotionFile.encode(frame)
        if Date().timeIntervalSince(lastFlush) > 10 { flush() }
    }

    func flush() {
        lastFlush = Date()
        guard !buffer.isEmpty, let handle else { return }
        handle.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func load(day: String) -> [MotionFrame] {
        if day == currentDay { flush() }
        return (try? Data(contentsOf: url(day: day))).flatMap(MotionFile.decode) ?? []
    }

    func delete(day: String) {
        if day == currentDay {
            buffer.removeAll()
            try? handle?.close()
            handle = nil
            currentDay = nil
        }
        try? FileManager.default.removeItem(at: url(day: day))
    }

    private func open(_ day: String) {
        flush()
        try? handle?.close()
        let url = url(day: day)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: MotionFile.header,
                                           attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        currentDay = day
    }
}
