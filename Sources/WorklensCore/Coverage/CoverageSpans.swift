import Foundation

/// Why a stretch of a day is missing from the record (#146).
public enum CoverageGapReason: String, Sendable, Equatable, CaseIterable {
    /// You paused Worklens — the hotkey, or the menu.
    case paused
    /// The app was not running: quit, crashed, or mid-update.
    case notRunning = "not_running"
    /// Screen Recording was revoked, so every tick failed.
    case permissionMissing = "permission_missing"
    /// The daily budget was spent: the frames were kept, none of them was described — so the
    /// pictures exist and the record of what was in them does not.
    case budget

    /// The words the footer and the report use. Second person, no blame, no metric.
    public var phrase: String {
        switch self {
        case .paused: return "paused"
        case .notRunning: return "not running"
        case .permissionMissing: return "without Screen Recording permission"
        case .budget: return "over the daily budget"
        }
    }
}

/// A stretch of one day Worklens has no record of, and why.
public struct CoverageGap: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var reason: CoverageGapReason

    public init(start: Date, end: Date, reason: CoverageGapReason) {
        self.start = start
        self.end = end
        self.reason = reason
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Turns `coverage_events` — and the budget's own skip rows — into the spans of a day Worklens
/// was not watching, and into the one sentence the timeline, the reports and the menu say about
/// them.
///
/// Pure, so the wording is a unit test rather than a day spent pausing an app by hand.
public enum CoverageSpans {
    /// Spans shorter than this are noise: a pause you undid, a restart between two ticks. Also
    /// the distance under which two spans of the same kind are one span with a blink in it.
    public static let minimumGap: TimeInterval = 60

    /// How long after a `stopped` a frame or a foreground session has to land before it counts as
    /// proof that Worklens was running after all (#313). A straggler tick after a real quit, or
    /// the very frame `closeUnfinishedRun` dated its `stopped` to, falls inside it.
    public static let proofGrace: TimeInterval = minimumGap

    /// The uncovered spans of `[start, end)`.
    ///
    /// `events` must be ordered by time and should include the last event *before* `start` — that
    /// row is what says whether the day began with the app running. When there is no such row and
    /// no row inside the range, the answer is no gaps at all: a day from before this table
    /// existed is unknown, and unknown must not be rendered as "Worklens was not watching".
    ///
    /// `proofs` are times something only a running Worklens writes — a capture, the start of a
    /// foreground session — ascending, and should include the latest one at or before `start`.
    /// A proof more than `proofGrace` after a `notRunning` span began ends that span there: a
    /// stray `stopped` (a second copy quitting at launch, #313) must not erase a week. Proofs never
    /// open a span and never end `paused` or `permissionMissing`, which a running app reports.
    /// A `started` that follows a span a proof ended is a relaunch with no `stopped` of its own
    /// (the stray row already outranked it), so the stretch from the last proof to that `started`
    /// is not running.
    public static func gaps(
        events: [CoverageEvent], proofs: [Date] = [], start: Date, end: Date
    ) -> [CoverageGap] {
        guard end > start else { return [] }
        var open: CoverageGapReason?
        var openedAt = start
        var since = start
        var found: [CoverageGap] = []
        var sawAny = false
        // The latest proof since one ended a `notRunning` span — where the run it proved was last
        // seen, if a `started` later says it ended without a `stopped`.
        var provenAt: Date?

        // One replay in time order. A tie keeps input order, events first, so a proof at a
        // `stopped` row's own instant reads as after it.
        let unordered: [(at: Date, event: CoverageEvent?)] =
            events.map { ($0.at, $0) } + proofs.map { ($0, nil) }
        let steps = unordered.enumerated()
            .sorted { $0.element.at != $1.element.at ? $0.element.at < $1.element.at : $0.offset < $1.offset }
            .map(\.element)

        for step in steps where step.at < end {
            guard let event = step.event else {
                if provenAt != nil {
                    provenAt = step.at
                    continue
                }
                guard open == .notRunning, step.at.timeIntervalSince(since) > proofGrace else { continue }
                if step.at > start {
                    found.append(CoverageGap(start: openedAt, end: step.at, reason: .notRunning))
                }
                open = nil
                provenAt = step.at
                continue
            }
            sawAny = true
            if let proven = provenAt, event.coverageKind == .started, event.at > start {
                let from = max(proven, start)
                if event.at.timeIntervalSince(from) >= minimumGap {
                    found.append(CoverageGap(start: from, end: event.at, reason: .notRunning))
                }
            }
            provenAt = nil
            let next = event.opensGap
            if event.at <= start {
                if next != open { since = event.at }
                open = next
                continue
            }
            if next == open { continue }
            if let open { found.append(CoverageGap(start: openedAt, end: event.at, reason: open)) }
            open = next
            openedAt = event.at
            since = event.at
        }
        if sawAny, let open {
            found.append(CoverageGap(start: openedAt, end: end, reason: open))
        }
        return merge(found)
    }

    /// The budget's spans, read off the `captures` rows themselves.
    ///
    /// The budget gate needs no transition of its own: it already writes a row per held-back
    /// frame (`SkipReason.budget`). What it never did was say so anywhere a reader of the day
    /// would see. `rows` are the day's captures in time order, as `(time, skip reason)` pairs.
    public static func budgetGaps(
        rows: [(at: Date, skipReason: SkipReason?)], end: Date
    ) -> [CoverageGap] {
        var found: [CoverageGap] = []
        var openedAt: Date?
        for row in rows {
            if row.skipReason == .budget {
                if openedAt == nil { openedAt = row.at }
            } else if let start = openedAt {
                found.append(CoverageGap(start: start, end: row.at, reason: .budget))
                openedAt = nil
            }
        }
        if let start = openedAt, end > start {
            found.append(CoverageGap(start: start, end: end, reason: .budget))
        }
        return merge(found)
    }

    /// `spans` with every stretch covered by `blockers` cut out of them.
    ///
    /// The budget gate stops writing rows the moment the loop stops, so an open budget span would
    /// otherwise run to the end of the day and be told twice — "over the daily budget from 16:00,
    /// not running from 18:00" for the same evening. The transitions are the authority on whether
    /// Worklens was up at all, so they win the overlap.
    public static func clip(_ spans: [CoverageGap], outside blockers: [CoverageGap]) -> [CoverageGap] {
        guard !blockers.isEmpty else { return merge(spans) }
        var kept: [CoverageGap] = []
        for span in spans {
            var pieces = [span]
            for blocker in blockers {
                pieces = pieces.flatMap { piece -> [CoverageGap] in
                    guard blocker.start < piece.end, blocker.end > piece.start else { return [piece] }
                    var rest: [CoverageGap] = []
                    if blocker.start > piece.start {
                        rest.append(
                            CoverageGap(start: piece.start, end: blocker.start, reason: piece.reason)
                        )
                    }
                    if blocker.end < piece.end {
                        rest.append(
                            CoverageGap(start: blocker.end, end: piece.end, reason: piece.reason)
                        )
                    }
                    return rest
                }
            }
            kept += pieces
        }
        return merge(kept)
    }

    /// Orders spans, folds same-reason neighbours less than a minute apart into one, and drops
    /// what is left under a minute.
    public static func merge(_ gaps: [CoverageGap]) -> [CoverageGap] {
        let ordered = gaps.sorted { $0.start < $1.start }
        var merged: [CoverageGap] = []
        for gap in ordered {
            guard var last = merged.last,
                  last.reason == gap.reason,
                  gap.start.timeIntervalSince(last.end) < minimumGap
            else {
                merged.append(gap)
                continue
            }
            last.end = max(last.end, gap.end)
            merged[merged.count - 1] = last
        }
        return merged.filter { $0.duration >= minimumGap }
    }

    /// `Worklens was not running until 09:12, paused 14:00–15:20`, or nil when the day is whole.
    ///
    /// One sentence, in the user's words, chronological. Only the first span carries the subject,
    /// so the line reads the way the issue asked for it rather than as a table.
    public static func sentence(_ gaps: [CoverageGap], within day: (start: Date, end: Date), timeZone: TimeZone) -> String? {
        let phrases = gaps
            .sorted { $0.start < $1.start }
            .map { phrase($0, within: day, timeZone: timeZone) }
        guard !phrases.isEmpty else { return nil }
        return "Worklens was " + phrases.joined(separator: ", ")
    }

    /// One span in words: `paused 14:00–15:20`, `not running until 09:12`, `not running from
    /// 18:04`, `not running all day`. A span that runs to a day boundary has no useful clock time
    /// at that end, and `00:00` there reads as a time something happened.
    static func phrase(
        _ gap: CoverageGap, within day: (start: Date, end: Date), timeZone: TimeZone
    ) -> String {
        let opensDay = gap.start <= day.start
        let closesDay = gap.end >= day.end
        let from = TimelineRenderer.clock(gap.start, timeZone)
        let to = TimelineRenderer.clock(gap.end, timeZone)
        switch (opensDay, closesDay) {
        case (true, true): return "\(gap.reason.phrase) all day"
        case (true, false): return "\(gap.reason.phrase) until \(to)"
        case (false, true): return "\(gap.reason.phrase) from \(from)"
        case (false, false): return "\(gap.reason.phrase) \(from)-\(to)"
        }
    }

    /// How much of the day the spans cover, in seconds.
    public static func total(_ gaps: [CoverageGap]) -> TimeInterval {
        gaps.reduce(0) { $0 + $1.duration }
    }
}
