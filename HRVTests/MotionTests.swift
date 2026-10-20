import Foundation
import Testing
@testable import HRV

/// One-second frames at 25 Hz, each received at the time of its last sample.
private func frames(from start: Date, seconds: Int, _ value: (TimeInterval) -> SIMD3<Double>) -> [MotionFrame] {
    (0..<seconds).map { k in
        let times = (0..<25).map { Double(k) + Double($0) / 25 }
        return MotionFrame(received: start.addingTimeInterval(times.last!),
                           firstSensorTime: UInt64(times.first! * 1e9), lastSensorTime: UInt64(times.last! * 1e9),
                           samples: times.map { t in
                               let v = value(t)
                               return (Int16(v.x.rounded()), Int16(v.y.rounded()), Int16(v.z.rounded()))
                           })
    }
}

private let noon = DayKey.date("2026-10-20")!.addingTimeInterval(12 * 3600)
private let upright = SIMD3<Double>(-1000, 0, 0)
/// Breathing-sized wobble, well under the movement threshold.
private func still(_ g: SIMD3<Double>) -> (TimeInterval) -> SIMD3<Double> {
    { t in g + SIMD3(5 * sin(2 * .pi * 0.25 * t), 3 * sin(2 * .pi * 1.1 * t), 0) }
}
/// Steps at 1.8 Hz (108 steps/min) on top of upright gravity.
private func walking(_ t: TimeInterval) -> SIMD3<Double> {
    upright + SIMD3(250 * sin(2 * .pi * 1.8 * t), 60 * sin(2 * .pi * 0.9 * t), 40 * cos(2 * .pi * 1.8 * t))
}

struct MotionFileTests {
    @Test func roundTrip() throws {
        let fs = frames(from: noon, seconds: 3, walking)
        var data = MotionFile.header
        for f in fs { data += MotionFile.encode(f) }
        #expect(data.count == 8 + 3 * (27 + 25 * 6))
        let decoded = try #require(MotionFile.decode(data))
        #expect(decoded == fs)
        // A record cut short by a crash is dropped; the rest survives.
        #expect(MotionFile.decode(data.dropLast(10)) == Array(fs.prefix(2)))
    }

    @Test func rejectsForeignOrNewerFiles() {
        #expect(MotionFile.decode(Data("epoch_ms,rr_ms\n".utf8)) == nil)
        #expect(MotionFile.decode(Data("HRVM".utf8) + Data([2, 0, 0, 0])) == nil)
        #expect(MotionFile.decode(MotionFile.header) == [])
    }

    @Test func fromAccFrameClampsAndKeepsSensorTimes() {
        let acc = AccFrame(timestamp: 2_000_000_000, samples: [
            AccSample(sensorTime: 1_000_000_000, x: 40000, y: -12, z: 1000),
            AccSample(sensorTime: 2_000_000_000, x: 0, y: -40000, z: 999),
        ])
        let f = MotionFrame(acc, receivedAt: noon)
        #expect(f.samples.map(\.x) == [Int16.max, 0])
        #expect(f.samples.map(\.y) == [-12, Int16.min])
        #expect(f.sampleTimes == [noon.addingTimeInterval(-1), noon])
    }

    @Test func recorderWritesPerDayAndDeleteDayRemovesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DayStore(root: root)
        let fs = frames(from: noon, seconds: 2, still(upright))
        let tomorrow = frames(from: noon.addingTimeInterval(86400), seconds: 1, still(upright))
        for f in fs + tomorrow { store.motion.append(f) }
        store.flush()
        #expect(store.motion.load(day: "2026-10-20") == fs)
        #expect(store.motion.load(day: "2026-10-21") == tomorrow)
        // Motion files don't show up as days of their own.
        #expect(store.days.isEmpty)

        store.deleteDay("2026-10-21")
        #expect(!FileManager.default.fileExists(atPath: store.motionURL(day: "2026-10-21").path))
        #expect(store.motion.load(day: "2026-10-20") == fs)
    }
}
