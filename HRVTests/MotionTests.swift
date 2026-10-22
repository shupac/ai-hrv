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

struct MotionAnalysisTests {
    @Test func stillUprightThenLying() {
        let lying = SIMD3<Double>(0, 0, -1000)
        let fs = frames(from: noon, seconds: 300, still(upright))
            + frames(from: noon.addingTimeInterval(300), seconds: 120, still(lying))
        let day = MotionAnalysis.analyze(fs)
        let up = try! #require(day.upright)
        #expect(MotionAnalysis.angle(up, upright) < 1)
        #expect(day.seconds.count == 420)
        #expect(day.seconds.prefix(300).allSatisfy { $0.state == .upright && $0.movement < 10 })
        #expect(day.seconds.suffix(110).allSatisfy { $0.state == .lying && abs(($0.tilt ?? 0) - 90) < 2 })
        #expect(day.postureChanges.count == 1)
        let change = try! #require(day.postureChanges.first)
        #expect(abs(change.timeIntervalSince(noon.addingTimeInterval(300))) < 6)
    }

    @Test func uprightIsTheMostCommonOrientationNotTheAverage() throws {
        let reclined = SIMD3<Double>(-500, 0, -866)     // 60° from upright
        let fs = frames(from: noon, seconds: 240, still(upright))
            + frames(from: noon.addingTimeInterval(240), seconds: 180, still(reclined))
            + frames(from: noon.addingTimeInterval(420), seconds: 180, still(SIMD3(0, 0, -1000)))
        let up = try #require(MotionAnalysis.analyze(fs).upright)
        #expect(MotionAnalysis.angle(up, upright) < 2)
    }

    @Test func walkingHasCadence() throws {
        let day = MotionAnalysis.analyze(frames(from: noon, seconds: 120, still(upright))
            + frames(from: noon.addingTimeInterval(120), seconds: 60, walking))
        let walk = day.seconds.suffix(55)
        #expect(walk.allSatisfy { $0.state == .walking })
        let cadence = try #require(walk.first?.cadence)
        #expect(abs(cadence - 108) < 8)
        #expect(day.postureChanges.isEmpty)
    }

    @Test func irregularMovementIsActiveNotWalking() {
        // A deterministic jumble: large but without a repeating period.
        var seed: UInt64 = 42
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53) * 2 - 1
        }
        let jumble = (0..<(60 * 25)).map { _ in SIMD3(next(), next(), next()) * 200 }
        let fs = frames(from: noon, seconds: 60) { t in upright + jumble[min(jumble.count - 1, Int((t * 25).rounded()))] }
        let secs = MotionAnalysis.seconds(fs)
        #expect(secs.allSatisfy { $0.state == .active })
    }

    @Test func noReferenceWithoutEnoughStillTime() {
        let day = MotionAnalysis.analyze(frames(from: noon, seconds: 30, still(upright)))
        #expect(day.upright == nil)
        #expect(day.seconds.allSatisfy { $0.state == .still && $0.tilt == nil })
    }

    @Test func bucketsBreakAtGapsAndPickTheCommonState() {
        let fs = frames(from: noon, seconds: 120, still(upright))
            + frames(from: noon.addingTimeInterval(120), seconds: 40, walking)
            + frames(from: noon.addingTimeInterval(600), seconds: 60, still(upright))
        let buckets = MotionAnalysis.analyze(fs).buckets(step: 60)
        #expect(buckets.map(\.state) == [.upright, .upright, .walking, .upright])
        #expect(buckets.map(\.segment) == [0, 0, 0, 1])
    }

    @Test func stepCadenceNeedsARepeatingSignal() {
        let flat = [Double](repeating: 1000, count: 100)
        #expect(MotionAnalysis.stepCadence(flat, duration: 4) == nil)
        let steps = (0..<100).map { 1000 + 200 * sin(2 * .pi * 2.0 * Double($0) / 25) }
        #expect(abs((MotionAnalysis.stepCadence(steps, duration: 4) ?? 0) - 120) < 6)
    }
}

struct LiveMotionTests {
    @Test func keepsSecondsAndLabelsTheCurrentOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = LiveMotion(store: DayStore(root: root))
        for f in frames(from: noon, seconds: 120, still(upright)) + frames(from: noon.addingTimeInterval(120), seconds: 30, walking) {
            live.handle(f)
        }
        let current = try #require(live.current)
        #expect(current.state == .walking)
        #expect(abs(current.time.timeIntervalSince(noon.addingTimeInterval(148))) < 1.5)
        // Five-second buckets over the 150 s so far.
        #expect((29...31).contains(live.buckets.count))
        #expect(live.buckets.first?.state == .upright)

        live.handleDisconnect()
        #expect(live.current == nil)
    }
}
