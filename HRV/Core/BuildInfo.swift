import Foundation

/// Which build is installed: version plus the git state written into BuildInfo.plist
/// at build time by `tools/embed-build-info.sh`.
struct BuildInfo {
    let version: String
    let commit: String
    let branch: String
    let dirty: Bool
    let buildTime: Date?

    init(info: [String: Any], version: String?) {
        self.version = version ?? "unknown"
        commit = info["GitCommit"] as? String ?? "unknown"
        branch = info["GitBranch"] as? String ?? "unknown"
        dirty = info["GitDirty"] as? Bool ?? false
        buildTime = (info["BuildTime"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
    }

    static let current: BuildInfo = {
        let info = Bundle.main.url(forResource: "BuildInfo", withExtension: "plist")
            .flatMap { NSDictionary(contentsOf: $0) as? [String: Any] } ?? [:]
        return BuildInfo(info: info, version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }()

    /// e.g. "0.1 · adb9a13* · tem-16 · Oct 17 14:05"; `*` marks uncommitted changes.
    func line(timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        var parts = [version, commit + (dirty ? "*" : ""), Self.shortBranch(branch)]
        if let t = buildTime {
            let style = Date.VerbatimFormatStyle(
                format: "\(month: .abbreviated) \(day: .defaultDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                locale: locale, timeZone: timeZone, calendar: Calendar(identifier: .gregorian))
            parts.append(t.formatted(style))
        }
        return parts.joined(separator: " · ")
    }

    /// "shuhxl/tem-16-detect-pairing" → "tem-16"; otherwise the part after the last "/".
    static func shortBranch(_ branch: String) -> String {
        let last = branch.split(separator: "/").last.map(String.init) ?? branch
        if let m = last.firstMatch(of: #/^(tem-\d+)(-|$)/#) { return String(m.1) }
        return last
    }
}
