import Foundation
import Testing
@testable import HRV

struct ParserTests {
    @Test func uint8HeartRateWithRR() throws {
        // flags 0x16: contact supported + detected, RR present; HR 72; RR 1024 → 1000 ms, 820 → ~800.8 ms
        let m = try #require(HeartRateParser.parse(Data([0x16, 72, 0x00, 0x04, 0x34, 0x03])))
        #expect(m.bpm == 72)
        #expect(m.contactDetected == true)
        #expect(m.rrIntervalsMs.count == 2)
        #expect(m.rrIntervalsMs[0] == 1000)
        #expect(abs(m.rrIntervalsMs[1] - 800.78) < 0.01)
    }

    @Test func uint16HeartRateWithEnergyAndRR() throws {
        // flags 0x19: HR uint16, energy present, RR present
        let m = try #require(HeartRateParser.parse(Data([0x19, 0x2C, 0x01, 0x10, 0x00, 0x00, 0x02])))
        #expect(m.bpm == 300)
        #expect(m.energyExpended == 16)
        #expect(m.contactDetected == nil)
        #expect(m.rrIntervalsMs == [500])
    }

    @Test func noRRAndNoContact() throws {
        let m = try #require(HeartRateParser.parse(Data([0x04, 60])))
        #expect(m.contactDetected == false)
        #expect(m.rrIntervalsMs.isEmpty)
    }

    @Test func malformedPackets() {
        #expect(HeartRateParser.parse(Data()) == nil)
        #expect(HeartRateParser.parse(Data([0x01])) == nil)
        #expect(HeartRateParser.parse(Data([0x01, 0x50])) == nil)
        // Trailing odd byte in the RR field is ignored.
        #expect(HeartRateParser.parse(Data([0x10, 60, 0x00, 0x04, 0x01]))?.rrIntervalsMs == [1000])
    }
}

struct FilterTests {
    @Test func warmUpThenAccept() {
        var f = ArtifactFilter()
        let results = [800, 810, 790, 805, 795].map { f.classify(Double($0)) }
        #expect(results == [false, false, false, true, true])
    }

    @Test func rejectsOutOfRangeEctopicAndMissedBeats() {
        var f = ArtifactFilter()
        for rr in [800.0, 800, 800, 800, 800] { _ = f.classify(rr) }
        #expect(f.classify(250) == false)      // out of range
        #expect(f.classify(500) == false)      // premature beat
        #expect(f.classify(1100) == false)     // compensatory pause
        #expect(f.classify(800) == true)
        #expect(f.classify(1600) == false)     // missed beat
        #expect(f.classify(810) == true)
        #expect(f.classify(800, contact: false) == false)
    }

    @Test func adaptsToSustainedShift() {
        var f = ArtifactFilter()
        for _ in 0..<5 { _ = f.classify(1000) }
        let shifted = (0..<5).map { _ in f.classify(600) }
        #expect(shifted == [false, false, false, true, true])
    }
}

struct CalculatorTests {
    /// Beats with given RRs, contiguous in time, ending at `end`.
    func makeBeats(_ rrs: [Double], valid: [Bool]? = nil, end: Date = Date(timeIntervalSince1970: 10_000)) -> [Beat] {
        var t = end.addingTimeInterval(-rrs.reduce(0, +) / 1000)
        return rrs.enumerated().map { i, rr in
            t = t.addingTimeInterval(rr / 1000)
            return Beat(time: t, rr: rr, valid: valid?[i] ?? true, afterGap: i == 0)
        }
    }

    @Test func knownRMSSD() throws {
        // Alternating 800/850 → every successive difference is 50 ms → RMSSD = 50.
        let rrs = (0..<90).map { $0 % 2 == 0 ? 800.0 : 850.0 }
        let beats = makeBeats(rrs)
        let r = HRVCalculator.compute(beats, window: .s60, endingAt: beats.last!.time)
        #expect(r.status == .ok)
        #expect(abs(try #require(r.rmssd) - 50) < 1e-9)
        #expect(abs(try #require(r.meanHR) - 60000 / 825) < 1)
    }

    @Test func excludesPairsTouchingArtifacts() throws {
        var rrs = (0..<90).map { $0 % 2 == 0 ? 800.0 : 850.0 }
        var valid = Array(repeating: true, count: 90)
        rrs[45] = 1650; valid[45] = false   // a missed beat must not create a huge difference
        let beats = makeBeats(rrs, valid: valid)
        let r = HRVCalculator.compute(beats, window: .s60, endingAt: beats.last!.time)
        #expect(r.status == .ok)
        #expect(abs(try #require(r.rmssd) - 50) < 1e-9)
    }

    @Test func doesNotPairAcrossGaps() throws {
        var beats = makeBeats((0..<90).map { _ in 800.0 })
        beats[40].rr = 1200
        beats[40].afterGap = true
        let r = HRVCalculator.compute(beats, window: .s60, endingAt: beats.last!.time)
        #expect(try #require(r.rmssd) > 0) // 1200→800 contributes, gap transition doesn't
        #expect(r.validPairs < 89)
    }

    @Test func insufficientWhileCollecting() {
        let beats = makeBeats(Array(repeating: 800, count: 20)) // 16 s
        let r = HRVCalculator.compute(beats, window: .s60, endingAt: beats.last!.time)
        #expect(r.rmssd == nil)
        if case .collecting = r.status {} else { Issue.record("expected collecting, got \(r.status)") }
    }

    @Test func tooManyArtifacts() {
        let valid = (0..<90).map { $0 % 3 != 0 } // 33% invalid
        let beats = makeBeats(Array(repeating: 800, count: 90), valid: valid)
        let r = HRVCalculator.compute(beats, window: .s60, endingAt: beats.last!.time)
        #expect(r.status == .tooManyArtifacts)
        #expect(r.rmssd == nil)
    }

    @Test func seriesBreaksAcrossGap() {
        let a = makeBeats(Array(repeating: 800, count: 100), end: Date(timeIntervalSince1970: 1_000))
        var b = makeBeats((0..<100).map { $0 % 2 == 0 ? 800.0 : 820.0 }, end: Date(timeIntervalSince1970: 1_500))
        b[0].afterGap = true
        let pts = HRVCalculator.series(a + b, window: .s30, from: a.first!.time, to: b.last!.time, step: 5)
        let segments = Set(pts.filter { $0.rmssd != nil }.map(\.segment))
        #expect(segments.count == 2)
    }
}

struct PipelineTests {
    @Test func beatProcessorTimestampsAndGaps() {
        var p = BeatProcessor()
        let t0 = Date(timeIntervalSince1970: 0)
        var all: [Beat] = []
        for i in 0..<10 {
            let m = HeartRateMeasurement(bpm: 60, contactDetected: true, energyExpended: nil, rrIntervalsMs: [1000])
            all += p.process(m, receivedAt: t0.addingTimeInterval(Double(i) + 0.05 * Double(i % 2)))
        }
        #expect(all.count == 10)
        #expect(all.first!.afterGap)
        #expect(all.dropFirst().allSatisfy { !$0.afterGap })
        #expect(zip(all, all.dropFirst()).allSatisfy { $0.time < $1.time })

        p.markGap()
        let m = HeartRateMeasurement(bpm: 60, contactDetected: true, energyExpended: nil, rrIntervalsMs: [1000])
        let after = p.process(m, receivedAt: t0.addingTimeInterval(100))
        #expect(after.first?.afterGap == true)
        #expect(after.first?.valid == false) // filter re-seeds after a gap
        #expect(after.first?.time == t0.addingTimeInterval(100))
    }

    @Test func flagsStrapWithoutRR() {
        let session = LiveSession(store: DayStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func packet(bpm: Int = 70, contact: Bool? = true, rr: [Double] = []) -> HeartRateMeasurement {
            HeartRateMeasurement(bpm: bpm, contactDetected: contact, energyExpended: nil, rrIntervalsMs: rr)
        }
        func send(_ m: HeartRateMeasurement, from start: Double, seconds: Int) {
            for i in 0..<seconds { session.handle(m, at: t0.addingTimeInterval(start + Double(i))) }
        }

        send(packet(), from: 0, seconds: 15)            // t = 0…14
        #expect(!session.noRR)
        session.handle(packet(), at: t0.addingTimeInterval(15))
        #expect(session.noRR)
        #expect(session.current.rmssd == nil)
        session.handle(packet(rr: [857]), at: t0.addingTimeInterval(16))
        #expect(!session.noRR)

        // A contact problem, or 0 bpm, in between restarts the count.
        send(packet(), from: 20, seconds: 10)
        session.handle(packet(contact: false), at: t0.addingTimeInterval(30))
        send(packet(), from: 31, seconds: 10)
        #expect(!session.noRR)
        session.handle(packet(bpm: 0, contact: nil), at: t0.addingTimeInterval(41))
        send(packet(), from: 42, seconds: 10)
        #expect(!session.noRR)

        // Neither ever triggers it on its own.
        send(packet(contact: false), from: 60, seconds: 30)
        send(packet(bpm: 0, contact: nil), from: 90, seconds: 30)
        #expect(!session.noRR)

        // Disconnecting clears it.
        send(packet(), from: 120, seconds: 20)
        #expect(session.noRR)
        session.handleDisconnect()
        #expect(!session.noRR)
        send(packet(), from: 140, seconds: 10)
        #expect(!session.noRR)
    }

    @Test func dayStoreRoundTripAndTags() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DayStore(root: root)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        store.append(Beat(time: t, rr: 812.5, valid: true, afterGap: true), bpm: 74)
        store.append(Beat(time: t.addingTimeInterval(0.8), rr: 800, valid: false, afterGap: false), bpm: 74)
        store.append(Beat(time: t.addingTimeInterval(10), rr: 790, valid: true, afterGap: true), bpm: 75)
        let day = DayKey.key(for: t)
        #expect(store.days == [day])

        let beats = store.loadBeats(day: day)
        #expect(beats.count == 3)
        #expect(beats[0].rr == 812.5 && beats[0].valid && beats[0].afterGap)
        #expect(!beats[1].valid && !beats[1].afterGap)
        #expect(beats[2].afterGap)
        #expect(beats[2].time == t.addingTimeInterval(10))

        let tag = store.addTag(nil, at: t, kind: .drop, change: -0.4)
        store.updateTag(tag.id, label: "Budget call")
        store.addTag("Meeting", at: t.addingTimeInterval(60))

        let reloaded = DayStore(root: root)
        #expect(reloaded.days == [day])
        #expect(reloaded.tags(on: day).map(\.label) == ["Budget call", "Meeting"])
        #expect(reloaded.tags(on: day).first?.change == -0.4)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func beatsSplitAcrossMidnight() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DayStore(root: root)
        let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        store.append(Beat(time: midnight.addingTimeInterval(-0.5), rr: 800, valid: true, afterGap: true), bpm: 75)
        store.append(Beat(time: midnight.addingTimeInterval(0.3), rr: 800, valid: true, afterGap: false), bpm: 75)
        store.flush()
        #expect(store.days.count == 2)
        #expect(store.loadBeats(day: DayKey.key(for: midnight)).count == 1)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func migratesLegacySessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacy = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let ms: Int64 = 1_700_000_000_000
        let csv = "epoch_ms,rr_ms,valid,bpm,event\n\(ms),800.0,1,75,\n\(ms + 800),810.0,1,75,\n"
        try csv.write(to: legacy.appendingPathComponent("x.csv"), atomically: true, encoding: .utf8)

        let store = DayStore(root: root)
        let beats = store.loadBeats(day: DayKey.key(for: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(beats.map(\.rr) == [800, 810])
        #expect(beats[0].afterGap && !beats[1].afterGap)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        try? FileManager.default.removeItem(at: root)
    }
}

struct ChangeDetectorTests {
    let t0 = Date(timeIntervalSince1970: 0)

    /// Feeds `values` at 5 s steps starting at `start`; returns the first event.
    func feed(_ d: inout ChangeDetector, _ values: [Double?], from start: TimeInterval) -> ChangeDetector.Event? {
        var first: ChangeDetector.Event?
        for (i, v) in values.enumerated() {
            if let e = d.add(v, at: t0.addingTimeInterval(start + Double(i) * 5)), first == nil { first = e }
        }
        return first
    }

    @Test func detectsSustainedDrop() throws {
        var d = ChangeDetector()
        #expect(feed(&d, Array(repeating: 50, count: 600), from: 0) == nil)       // 50 min baseline
        let e = try #require(feed(&d, Array(repeating: 28, count: 30), from: 3000))
        #expect(e.kind == .drop)
        #expect(abs(e.change - (-0.44)) < 0.01)
    }

    @Test func detectsRise() throws {
        var d = ChangeDetector()
        _ = feed(&d, Array(repeating: 40, count: 600), from: 0)
        #expect(try #require(feed(&d, Array(repeating: 70, count: 30), from: 3000)).kind == .rise)
    }

    @Test func ignoresModestOrBriefChanges() {
        var d = ChangeDetector()
        _ = feed(&d, Array(repeating: 50, count: 600), from: 0)
        #expect(feed(&d, Array(repeating: 40, count: 60), from: 3000) == nil)    // −20%
        #expect(feed(&d, Array(repeating: 25, count: 12) + Array(repeating: 50, count: 30), from: 3300) == nil) // 1 min dip
    }

    @Test func needsBaselineAndRespectsSnooze() {
        var d = ChangeDetector()
        _ = feed(&d, Array(repeating: 50, count: 100), from: 0)                 // only ~8 min
        #expect(feed(&d, Array(repeating: 20, count: 30), from: 500) == nil)

        var s = ChangeDetector()
        _ = feed(&s, Array(repeating: 50, count: 600), from: 0)
        s.snooze(until: t0.addingTimeInterval(4000))
        #expect(feed(&s, Array(repeating: 20, count: 30), from: 3000) == nil)
    }
}
