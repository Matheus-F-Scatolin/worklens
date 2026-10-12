import Foundation

/// How long a shipped GitHub row's page was on your screen (#319): a direct join between an
/// output's `repo` and `number` and the frames whose `ArtifactKey` names the same PR or issue.
/// Pure; the `shipped` MCP tool reads it.
///
/// Only the `windowDays` local days up to and including the output's day count. When several rows
/// share a PR or issue (opened, then closed), only the latest carries the minutes, so no minute is
/// counted twice.
public enum OutputViewTime {
    public static let windowDays = 30

    /// The first local day a range starting at `from` needs read: `windowDays - 1` days earlier.
    public static func firstDay(from: String, timeZone: TimeZone) -> String? {
        guard let start = DayBoundaries.range(day: from, timeZone: timeZone)?.start else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let earlier = calendar.date(byAdding: .day, value: -(windowDays - 1), to: start) else { return nil }
        return DayBoundaries.dayString(earlier, timeZone: timeZone)
    }

    /// ` · on your screen 25m` after a shipped row, or nothing when it rounds to no minutes.
    public static func suffix(seconds: Double) -> String {
        guard StatsAggregator.minutes(seconds) > 0 else { return "" }
        return " · on your screen \(TimelineRenderer.duration(seconds))"
    }

    /// `output.id` → seconds on screen. `perDay` is local day → `StatsService.documentSeconds`.
    /// A row that is not a GitHub PR or issue, or that a later row with the same key outranks,
    /// is absent (zero).
    public static func seconds(
        outputs: [Output], perDay: [String: [ArtifactKey: Double]], timeZone: TimeZone
    ) -> [String: Double] {
        struct Ref: Hashable { let repo: String; let number: Int }
        var latest: [Ref: Output] = [:]
        for output in outputs where output.source == Output.github {
            guard let repo = output.repo?.lowercased(), !repo.isEmpty, let number = output.number else { continue }
            let ref = Ref(repo: repo, number: number)
            if let current = latest[ref], (current.at, current.id) >= (output.at, output.id) { continue }
            latest[ref] = output
        }
        var result: [String: Double] = [:]
        for (ref, output) in latest {
            let last = DayBoundaries.dayString(output.at, timeZone: timeZone)
            guard let first = firstDay(from: last, timeZone: timeZone) else { continue }
            var total = 0.0
            for (day, keys) in perDay where first <= day && day <= last {
                for (key, value) in keys {
                    guard let found = key.githubReference, found.repo == ref.repo, found.number == ref.number
                    else { continue }
                    total += value
                }
            }
            if total > 0 { result[output.id] = total }
        }
        return result
    }
}
