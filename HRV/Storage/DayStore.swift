import Foundation
import Observation

/// A moment on the timeline: a manual tag, or a detected HRV change (labelled once answered).
struct Tag: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case manual, drop, rise }

    var id = UUID()
    var time: Date
    var kind: Kind
    var label: String?
    /// Relative HRV change for detected events, e.g. -0.4.
    var change: Double?

    var title: String {
        if let label { return label }
        let pct = Int(((change ?? 0) * 100).rounded())
        return kind == .drop ? "HRV drop \(pct)% · unanswered" : "HRV rise +\(pct)% · unanswered"
    }
}

struct DaySummary: Codable, Equatable {
    var recordedSeconds: Double
    var meanHR: Double?
    var medianRMSSD: Double?    // 5 min windows
}

enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(for date: Date) -> String {
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    static func date(_ key: String) -> Date? {
        formatter.timeZone = .current
        return formatter.date(from: key)
    }
}

/// Always-on storage: one append-only CSV per local day in Documents/days
/// (`epoch_ms,rr_ms,valid,bpm,event`, with `gap` rows at discontinuities), plus tags.json.
@Observable
final class DayStore {
    static let quickLabels = ["Meeting", "Conversation", "Focus", "Break", "Meditation", "Exercise", "Meal", "Caffeine"]

    private(set) var days: [String] = []          // newest first
    private(set) var tags: [Tag] = []
    private(set) var summaries: [String: DaySummary] = [:]

    @ObservationIgnored private let root: URL
    @ObservationIgnored private let dir: URL
    @ObservationIgnored private var handle: FileHandle?
    @ObservationIgnored private var currentDay: String?
    @ObservationIgnored private var buffer = ""
    @ObservationIgnored private var lastFlush = Date()
    private static let header = "epoch_ms,rr_ms,valid,bpm,event\n"

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = self.root.appendingPathComponent("days", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        migrateSessions()
        scanDays()
        tags = Self.load([Tag].self, from: tagsURL) ?? []
        summaries = Self.load([String: DaySummary].self, from: summariesURL) ?? [:]
    }

    var tagsURL: URL { dir.appendingPathComponent("tags.json") }
    var summariesURL: URL { dir.appendingPathComponent("summaries.json") }
    func csvURL(day: String) -> URL { dir.appendingPathComponent("\(day).csv") }

    // MARK: - Recording

    func append(_ beat: Beat, bpm: Int) {
        let day = DayKey.key(for: beat.time)
        if day != currentDay { open(day) }
        let ms = Int64(beat.time.timeIntervalSince1970 * 1000)
        if beat.afterGap { buffer += "\(ms),,,,gap\n" }
        buffer += "\(ms),\(String(format: "%.1f", beat.rr)),\(beat.valid ? 1 : 0),\(bpm),\n"
        if Date().timeIntervalSince(lastFlush) > 10 { flush() }
    }

    func flush() {
        lastFlush = Date()
        guard !buffer.isEmpty, let handle else { return }
        handle.write(Data(buffer.utf8))
        buffer = ""
    }

    private func open(_ day: String) {
        flush()
        try? handle?.close()
        let url = csvURL(day: day)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(Self.header.utf8),
                                           attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        currentDay = day
        if !days.contains(day) { scanDays() }
    }

    // MARK: - Reading

    func loadBeats(day: String) -> [Beat] {
        if day == currentDay { flush() }
        guard let text = try? String(contentsOf: csvURL(day: day), encoding: .utf8) else { return [] }
        return Self.parseCSV(text)
    }

    static func parseCSV(_ text: String) -> [Beat] {
        var beats: [Beat] = []
        var gap = true
        for line in text.split(separator: "\n").dropFirst() {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 5, let ms = Double(f[0]) else { continue }
            if f[4] == "gap" { gap = true; continue }
            guard let rr = Double(f[1]) else { continue }
            beats.append(Beat(time: Date(timeIntervalSince1970: ms / 1000), rr: rr, valid: f[2] == "1", afterGap: gap))
            gap = false
        }
        return beats
    }

    static func summarize(_ beats: [Beat]) -> DaySummary {
        let valid = beats.filter(\.valid)
        var s = DaySummary(recordedSeconds: beats.reduce(0) { $0 + $1.rr } / 1000)
        if !valid.isEmpty { s.meanHR = 60000 / (valid.reduce(0) { $0 + $1.rr } / Double(valid.count)) }
        if let first = beats.first, let last = beats.last {
            let values = HRVCalculator.series(beats, window: .m5, from: first.time, to: last.time, step: 60)
                .compactMap(\.rmssd)
            if !values.isEmpty { s.medianRMSSD = ArtifactFilter.median(values) }
        }
        return s
    }

    /// Computes summaries for days that lack one (and always for today), off the main thread.
    func refreshSummaries() async {
        let today = DayKey.key(for: Date())
        for day in days where summaries[day] == nil || day == today {
            if day == today { flush() }
            let url = csvURL(day: day)
            let summary = await Task.detached(priority: .utility) { () -> DaySummary in
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                return Self.summarize(Self.parseCSV(text))
            }.value
            summaries[day] = summary
        }
        // Today's summary keeps changing; only persist finished days.
        Self.save(summaries.filter { $0.key != today }, to: summariesURL)
    }

    func deleteDay(_ day: String) {
        if day == currentDay {
            buffer = ""
            try? handle?.close()
            handle = nil
            currentDay = nil
        }
        try? FileManager.default.removeItem(at: csvURL(day: day))
        tags.removeAll { DayKey.key(for: $0.time) == day }
        summaries[day] = nil
        days.removeAll { $0 == day }
        Self.save(tags, to: tagsURL)
        Self.save(summaries, to: summariesURL)
    }

    private func scanDays() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        days = names.filter { $0.hasSuffix(".csv") }.map { String($0.dropLast(4)) }.sorted(by: >)
    }

    // MARK: - Tags

    func tags(on day: String) -> [Tag] {
        tags.filter { DayKey.key(for: $0.time) == day }.sorted { $0.time < $1.time }
    }

    @discardableResult
    func addTag(_ label: String?, at time: Date, kind: Tag.Kind = .manual, change: Double? = nil) -> Tag {
        let tag = Tag(time: time, kind: kind, label: label, change: change)
        tags.append(tag)
        Self.save(tags, to: tagsURL)
        return tag
    }

    func updateTag(_ id: UUID, label: String?) {
        guard let i = tags.firstIndex(where: { $0.id == id }) else { return }
        tags[i].label = label
        Self.save(tags, to: tagsURL)
    }

    func deleteTag(_ id: UUID) {
        tags.removeAll { $0.id == id }
        Self.save(tags, to: tagsURL)
    }

    // MARK: - Persistence helpers

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Folds recordings from the earlier start/stop version (Documents/sessions) into day files.
    private func migrateSessions() {
        let legacy = root.appendingPathComponent("sessions", isDirectory: true)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: legacy.path) else { return }
        var rowsByDay: [String: [(Int64, String)]] = [:]
        for name in names where name.hasSuffix(".csv") {
            guard let text = try? String(contentsOf: legacy.appendingPathComponent(name), encoding: .utf8) else { continue }
            var first = true
            for line in text.split(separator: "\n").dropFirst() {
                guard let ms = Int64(line.prefix { $0 != "," }) else { continue }
                let day = DayKey.key(for: Date(timeIntervalSince1970: Double(ms) / 1000))
                if first { rowsByDay[day, default: []].append((ms, "\(ms),,,,gap")); first = false }
                rowsByDay[day, default: []].append((ms, String(line)))
            }
        }
        for (day, rows) in rowsByDay {
            let body = rows.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n") + "\n"
            let url = csvURL(day: day)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(body.utf8))
                try? h.close()
            } else {
                try? Data((Self.header + body).utf8).write(to: url)
            }
        }
        try? fm.removeItem(at: legacy)
        UserDefaults.standard.removeObject(forKey: "activeSessionID")
    }
}
