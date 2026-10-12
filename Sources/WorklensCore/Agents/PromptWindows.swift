import Foundation

/// A stretch of your own time that went to one agent session's repo, inside one local day.
public struct RepoInterval: Sendable, Equatable {
    public var day: String
    public var repo: String?
    public var sessionId: String
    public var start: Date
    public var end: Date

    public init(day: String, repo: String?, sessionId: String, start: Date, end: Date) {
        self.day = day
        self.repo = repo
        self.sessionId = sessionId
        self.start = start
        self.end = end
    }

    public var seconds: TimeInterval { end.timeIntervalSince(start) }
}

/// Which of your minutes went to which session (#321). Pure.
///
/// Each prompt claims the 3 minutes before it and the 10 after, and a later prompt takes over at
/// its own instant. What a prompt claims counts only while the app it was typed in was in front
/// (the Claude app, the Codex app, a terminal for the CLI) and the day's blocks say you were
/// active. A prompt from a host with no app of its own (`sdk-cli`, a workflow's agent) claims
/// nothing and cuts nothing. Agent minutes are never in here: they are not your time.
public enum PromptWindows {
    public static let before: TimeInterval = 3 * 60
    public static let after: TimeInterval = 10 * 60

    public struct Prompt: Sendable, Equatable {
        public var at: Date
        public var sessionId: String
        public var repo: String?
        public var host: String?

        public init(at: Date, sessionId: String, repo: String?, host: String?) {
            self.at = at
            self.sessionId = sessionId
            self.repo = repo
            self.host = host
        }
    }

    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "com.cmuxterm.app",
    ]

    /// The apps a prompt from this host is typed in. Empty for a host nobody types in.
    public static func bundleIds(forHost host: String?) -> Set<String> {
        switch host {
        case "claude-desktop": ["com.anthropic.claudefordesktop"]
        case AgentStoreParsers.codexDesktopHost: ["com.openai.codex"]
        case "cli": terminals
        default: []
        }
    }

    /// - Parameters:
    ///   - foreground: the `foreground_sessions` rows around the prompts; an open row counts as
    ///     running to the end of whatever window asks.
    ///   - active: the stretches the day's blocks say you were active (not idle, locked, away).
    public static func attribute(
        prompts: [Prompt], foreground: [ForegroundSession], active: [DateInterval],
        timeZone: TimeZone = .current
    ) -> [RepoInterval] {
        let local = prompts
            .filter { !bundleIds(forHost: $0.host).isEmpty }
            .sorted { $0.at == $1.at ? $0.sessionId < $1.sessionId : $0.at < $1.at }
        let activeUnion = union(active)
        var out: [RepoInterval] = []
        var previousEnd = Date.distantPast
        for (index, prompt) in local.enumerated() {
            let next = index + 1 < local.count ? local[index + 1].at : Date.distantFuture
            let start = max(prompt.at.addingTimeInterval(-before), previousEnd)
            let end = min(prompt.at.addingTimeInterval(after), next)
            previousEnd = max(previousEnd, end)
            guard end > start else { continue }

            let bundles = bundleIds(forHost: prompt.host)
            let front = union(foreground.compactMap { row -> DateInterval? in
                guard let bundle = row.appBundleId, bundles.contains(bundle) else { return nil }
                let rowEnd = min(row.endAt ?? end, end)
                let rowStart = max(row.startAt, start)
                return rowEnd > rowStart ? DateInterval(start: rowStart, end: rowEnd) : nil
            })
            for piece in intersect(front, activeUnion) {
                for (day, range) in splitAtMidnight(piece, timeZone: timeZone) {
                    out.append(RepoInterval(
                        day: day, repo: prompt.repo, sessionId: prompt.sessionId,
                        start: range.start, end: range.end
                    ))
                }
            }
        }
        return out
    }

    // MARK: Interval arithmetic

    /// Sorted, non-overlapping cover of the intervals.
    public static func union(_ intervals: [DateInterval]) -> [DateInterval] {
        var out: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) where interval.duration > 0 {
            if let last = out.last, interval.start <= last.end {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                out.append(interval)
            }
        }
        return out
    }

    /// The overlap of two sorted, non-overlapping lists.
    static func intersect(_ a: [DateInterval], _ b: [DateInterval]) -> [DateInterval] {
        var out: [DateInterval] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            let start = max(a[i].start, b[j].start)
            let end = min(a[i].end, b[j].end)
            if end > start { out.append(DateInterval(start: start, end: end)) }
            if a[i].end < b[j].end { i += 1 } else { j += 1 }
        }
        return out
    }

    /// Seconds the union of `intervals` covers inside `[from, to)`.
    public static func coveredSeconds(_ intervals: [DateInterval], from: Date, to: Date) -> TimeInterval {
        guard to > from else { return 0 }
        return intersect(union(intervals), [DateInterval(start: from, end: to)])
            .reduce(0) { $0 + $1.duration }
    }

    static func splitAtMidnight(_ interval: DateInterval, timeZone: TimeZone) -> [(String, DateInterval)] {
        var out: [(String, DateInterval)] = []
        var start = interval.start
        while start < interval.end {
            let day = DayBoundaries.dayString(start, timeZone: timeZone)
            let dayEnd = DayBoundaries.range(day: day, timeZone: timeZone)?.end ?? interval.end
            let end = min(dayEnd, interval.end)
            guard end > start else { break }
            out.append((day, DateInterval(start: start, end: end)))
            start = end
        }
        return out
    }
}
