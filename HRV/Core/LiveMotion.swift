import Foundation
import Observation

/// Live accelerometer pipeline: frames → per-second signals → the last 30 min for the Live chart.
@Observable
final class LiveMotion {
    /// The last complete second.
    private(set) var current: MotionSecond?
    private(set) var buckets: [MotionBucket] = []
    private(set) var postureChanges: [Date] = []

    @ObservationIgnored private var frames: [MotionFrame] = []
    @ObservationIgnored private var seconds: [MotionSecond] = []
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var upright: SIMD3<Double>?

    static let chartSpan = LiveSession.chartSpan
    static let tick = LiveSession.tick
    /// Long enough that the upright reference isn't just the last half hour's posture.
    private static let bufferSpan: TimeInterval = 2 * 3600

    init(store: DayStore) {
        restoreRecent(store)
    }

    func handle(_ f: MotionFrame) {
        frames.removeAll { f.received.timeIntervalSince($0.received) > 7 }
        frames.append(f)
        // The newest second is still filling. Seconds already kept are final.
        let complete = MotionAnalysis.seconds(frames).dropLast()
        let lastKept = seconds.last?.time ?? .distantPast
        seconds += complete.filter { $0.time > lastKept }
        current = complete.last.map(withTilt)

        if lastTick.map({ f.received.timeIntervalSince($0) >= Self.tick }) ?? true {
            lastTick = f.received
            let cutoff = f.received.addingTimeInterval(-Self.bufferSpan)
            if let i = seconds.firstIndex(where: { $0.time >= cutoff }), i > 0 { seconds.removeFirst(i) }
            rebuild(now: f.received)
        }
    }

    func handleDisconnect() {
        frames = []
        current = nil
    }

    private func rebuild(now: Date) {
        let day = MotionAnalysis.analyze(seconds: seconds)
        let from = now.addingTimeInterval(-Self.chartSpan)
        let recent = MotionDay(seconds: day.seconds.filter { $0.time >= from }, upright: day.upright,
                               postureChanges: day.postureChanges.filter { $0 >= from })
        buckets = recent.buckets(step: Self.tick)
        postureChanges = recent.postureChanges
        upright = day.upright
    }

    private func withTilt(_ s: MotionSecond) -> MotionSecond {
        guard let upright else { return s }
        var one = [s]
        MotionAnalysis.applyTilt(&one, upright: upright)
        return one[0]
    }

    /// After a relaunch, pick up the last 2 h from today's motion file, off the main thread.
    private func restoreRecent(_ store: DayStore) {
        let now = Date()
        let url = store.motionURL(day: DayKey.key(for: now))
        Task { @MainActor in
            let restored = await Task.detached(priority: .utility) { () -> [MotionSecond] in
                guard let data = try? Data(contentsOf: url), let frames = MotionFile.decode(data) else { return [] }
                let cutoff = now.addingTimeInterval(-Self.bufferSpan)
                return MotionAnalysis.seconds(frames.filter { $0.received > cutoff })
            }.value
            guard !restored.isEmpty else { return }
            let firstLive = seconds.first?.time ?? .distantFuture
            seconds = restored.filter { $0.time < firstLive } + seconds
            rebuild(now: lastTick ?? restored.last!.time)
        }
    }
}
