import Foundation
import Observation

/// Live pipeline: measurements → filtered beats → rolling HRV, change detection, and storage.
@Observable
final class LiveSession {
    private(set) var bpm: Int?
    private(set) var current = HRVResult(status: .collecting(have: 0, need: 60), validPairs: 0, artifactFraction: 0)
    private(set) var series: [HRVPoint] = []

    var window: HRVWindow = .s60 {
        didSet { rebuildSeries() }
    }

    /// Called with a detected change; return value as for `ChangePrompter.handle`.
    @ObservationIgnored var onChange: ((ChangeDetector.Event) async -> Bool)?

    @ObservationIgnored private let store: DayStore
    @ObservationIgnored private var processor = BeatProcessor()
    @ObservationIgnored private var detector = ChangeDetector()
    @ObservationIgnored private var beats: [Beat] = []
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var segment = 0

    static let chartSpan: TimeInterval = 30 * 60
    static let tick: TimeInterval = 5
    private static let bufferSpan: TimeInterval = 65 * 60   // detector baseline needs the past hour

    init(store: DayStore) {
        self.store = store
        restoreRecent()
    }

    func handle(_ m: HeartRateMeasurement, at now: Date) {
        bpm = m.bpm
        let newBeats = processor.process(m, receivedAt: now)
        guard !newBeats.isEmpty else { return }
        beats.append(contentsOf: newBeats)
        for b in newBeats { store.append(b, bpm: m.bpm) }

        current = HRVCalculator.compute(beats, window: window, endingAt: now)

        // Driven by packets rather than a Timer so it keeps working while backgrounded.
        if lastTick.map({ now.timeIntervalSince($0) >= Self.tick }) ?? true {
            lastTick = now
            appendPoint(current, at: now)
            detect(at: now)
            trim(now)
        }
    }

    func handleDisconnect() {
        processor.markGap()
        store.flush()
        bpm = nil
        current = HRVResult(status: .collecting(have: 0, need: window.seconds), validPairs: 0, artifactFraction: 0)
        segment += 1
    }

    /// The user is clearly aware of what's going on; don't prompt right after a manual tag.
    func didTagManually(at t: Date) {
        detector.snooze(until: t.addingTimeInterval(15 * 60))
    }

    private func detect(at now: Date) {
        let r60 = window == .s60 ? current : HRVCalculator.compute(beats, window: .s60, endingAt: now)
        guard let event = detector.add(r60.rmssd, at: now), let onChange else { return }
        detector.snooze(until: now.addingTimeInterval(10 * 60))
        Task { @MainActor in
            if await onChange(event) {
                detector.snooze(until: now.addingTimeInterval(ChangePrompter.cooldown))
            }
        }
    }

    private func appendPoint(_ r: HRVResult, at t: Date) {
        if r.rmssd == nil, series.last?.rmssd != nil { segment += 1 }
        series.append(HRVPoint(time: t, rmssd: r.rmssd, meanHR: r.meanHR, segment: segment))
    }

    /// After a relaunch, pick up the last hour from today's file so the chart and baseline aren't empty.
    private func restoreRecent() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.bufferSpan)
        let recent = store.loadBeats(day: DayKey.key(for: now)).filter { $0.time > cutoff }
        guard let first = recent.first, let last = recent.last else { return }
        beats = recent
        for p in HRVCalculator.series(beats, window: .s60, from: first.time, to: last.time, step: Self.tick) {
            _ = detector.add(p.rmssd, at: p.time)
        }
        rebuildSeries()
    }

    private func rebuildSeries() {
        guard let last = beats.last else {
            series = []
            return
        }
        let end = lastTick ?? last.time
        let from = max(beats[0].time, end.addingTimeInterval(-Self.chartSpan))
        series = HRVCalculator.series(beats, window: window, from: from, to: end, step: Self.tick)
        segment = series.last?.segment ?? 0
        if bpm != nil { current = HRVCalculator.compute(beats, window: window, endingAt: last.time) }
    }

    private func trim(_ now: Date) {
        let cutoff = now.addingTimeInterval(-Self.bufferSpan)
        if let first = beats.first, first.time < cutoff {
            beats.removeFirst(HRVCalculator.firstIndex(in: beats, after: cutoff))
        }
        let chartCutoff = now.addingTimeInterval(-Self.chartSpan)
        series.removeAll { $0.time < chartCutoff }
    }
}
