import Foundation

/// Display names for the keys a block carries. Kept as plain dictionaries rather than a live
/// `TaxonomyStore` so the renderer is a pure function and its golden test needs no files.
public struct TimelineLabels: Sendable, Equatable {
    /// `gmail` → `Browser / Gmail`.
    public var apps: [String: String]
    /// `triaging` → `Triaging`.
    public var tasks: [String: String]

    public init(apps: [String: String] = [:], tasks: [String: String] = [:]) {
        self.apps = apps
        self.tasks = tasks
    }

    public static func from(_ taxonomy: Taxonomy) -> TimelineLabels {
        var apps: [String: String] = [:]
        var tasks: [String: String] = [:]
        for app in taxonomy.apps {
            apps[app.key] = app.name
            for task in app.tasks where tasks[task.key] == nil {
                tasks[task.key] = humanize(task.key)
            }
            for web in app.webApps ?? [] {
                apps[web.key] = "\(app.name) / \(web.name)"
                for task in web.tasks where tasks[task.key] == nil {
                    tasks[task.key] = humanize(task.key)
                }
            }
        }
        for task in taxonomy.universalTasks where tasks[task.key] == nil {
            tasks[task.key] = humanize(task.key)
        }
        return TimelineLabels(apps: apps, tasks: tasks)
    }

    public func app(_ key: String) -> String { apps[key] ?? TimelineLabels.humanize(key) }
    public func task(_ key: String) -> String { tasks[key] ?? TimelineLabels.humanize(key) }

    /// `reading_messages` → `Reading messages`.
    static func humanize(_ key: String) -> String {
        let words = key.split(separator: "_").map(String.init)
        guard let first = words.first else { return key }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst())
            .joined(separator: " ")
    }
}

/// Renders one day as the markdown file the user reads and the projects pass learns from.
///
/// The file is the product of the describe pipeline: it has to make sense on its own, in any
/// editor, with no app running. Second person, no scores, no judgment.
public enum TimelineRenderer {
    /// At most this many bullets per block — the first, the last, and the most recent in between.
    public static let maxBulletsPerBlock = 6

    public static func render(
        day: String,
        blocks: [ActivityBlock],
        frames: [TimelineFrame] = [],
        contextEvents: [ContextEvent] = [],
        /// #314: what you shipped that day, for `## Shipped`.
        outputs: [Output] = [],
        labels: TimelineLabels = TimelineLabels(),
        projects: [ProjectEntry] = [],
        /// #146: the stretches of the day Worklens was not watching, for the footer.
        coverageGaps: [CoverageGap] = [],
        /// #322: the day's project spans. When given, a heading names the project covering most
        /// of its block, the same answer the stats threads read; nil keeps each frame's hint.
        projectSpans: [ProjectSpan]? = nil,
        timeZone: TimeZone = .current
    ) -> String {
        let ordered = blocks.sorted { $0.startAt < $1.startAt }
        // #90: the day's hints folded onto the canonical list once, here, so every heading in the
        // file names a project the same way the stats table does.
        let named = HeadingProjects(
            named: projectSpans == nil ? projectNames(frames: frames, projects: projects) : [:],
            spans: projectSpans
        )
        var lines: [String] = ["# Worklens timeline: \(heading(day: day, timeZone: timeZone))", ""]
        lines.append(statsLine(blocks: ordered, frames: frames))

        // #146: the one sentence that tells a quiet day from an unwatched one. Built here because
        // the day with nothing in it is exactly the day that needs it.
        let coverage = coverageSentence(day: day, gaps: coverageGaps, timeZone: timeZone)

        if ordered.isEmpty, contextEvents.isEmpty, outputs.isEmpty {
            lines += ["", "Nothing recorded for this day."]
            if let footer = footer(blocks: [], frames: frames, coverage: coverage) {
                lines += ["", "---", footer]
            }
            return lines.joined(separator: "\n") + "\n"
        }

        // #19: a screen block that fits entirely inside a meeting is not a separate stretch of
        // the day — it is what you had open during the call. Render it under the meeting.
        let nested = nest(ordered)

        // #94: a run of sub-minute blocks is a burst of switching, not stretches of the day.
        // Collapsed into one line under the block that follows it.
        var pending: [ActivityBlock] = []
        for block in ordered where nested.hosted[block.id] == nil {
            // #63: a block with no duration is a duplicated tick, not a stretch of the day. Kept
            // here as well as in `BlockBuilder` so an old database reads clean without a rebuild.
            guard block.endAt.timeIntervalSince(block.startAt) >= BlockBuilder.minimumBlockDuration
            else { continue }
            if isShort(block) {
                pending.append(block)
                continue
            }
            lines.append("")
            lines.append(header(
                for: block, frames: frames, named: named, labels: labels, timeZone: timeZone
            ))
            if let line = subject(of: block, frames: frames, labels: labels) {
                lines.append(line)
            }
            if let collapsed = collapsedRun(
                pending, frames: frames, labels: labels, timeZone: timeZone
            ) {
                lines.append(collapsed)
                pending = []
            }
            lines += bullets(for: block, frames: frames, timeZone: timeZone)

            guard let inside = nested.children[block.id], !inside.isEmpty else { continue }
            lines.append("- During the call:")
            var pendingInside: [ActivityBlock] = []
            for child in inside {
                if isShort(child) {
                    pendingInside.append(child)
                    continue
                }
                // Ahead of the heading rather than under it, unlike the top-level case: a
                // nested block's own bullets are indented under its `- ` item, and a line
                // squeezed between the two would collect them.
                if let collapsed = collapsedRun(
                    pendingInside, frames: frames, labels: labels, timeZone: timeZone
                ) {
                    lines.append("  " + collapsed)
                    pendingInside = []
                }
                lines.append("  - " + nestedHeader(
                    for: child, frames: frames, named: named, labels: labels, timeZone: timeZone
                ))
                if let line = subject(of: child, frames: frames, labels: labels) {
                    lines.append("    " + line)
                }
                lines += bullets(for: child, frames: frames, timeZone: timeZone)
                    .map { "    " + $0 }
            }
            if let collapsed = collapsedRun(
                pendingInside, frames: frames, labels: labels, timeZone: timeZone
            ) {
                lines.append("  " + collapsed)
            }
        }
        // A day that ended mid-switch has nothing left to sit under.
        if let collapsed = collapsedRun(
            pending, frames: frames, labels: labels, timeZone: timeZone
        ) {
            lines += ["", collapsed]
        }

        lines += ShippedSection.timelineLines(outputs, projects: projects, timeZone: timeZone)
        lines += contextSection(contextEvents, timeZone: timeZone)

        if let footer = footer(blocks: ordered, frames: frames, coverage: coverage) {
            lines += ["", "---", footer]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Collapsing sub-minute runs (#94)

    /// A block shorter than this is a moment of switching, not a stretch of the day.
    public static let shortBlockDuration: TimeInterval = 60

    /// True for a screen block too short to deserve a heading of its own. Meeting and away blocks
    /// are never folded away: a calendar entry means the same thing however brief it was.
    public static func isShort(_ block: ActivityBlock) -> Bool {
        block.source == .screen && block.duration < shortBlockDuration
    }

    /// One line for a run of consecutive sub-minute blocks:
    /// `- 08:50–08:51 Switching: Web browser (New Tab) → Claude Desktop`.
    ///
    /// Nearly half of a day's blocks are one frame long (#94); a heading and a bullet each made
    /// the file unreadable. Only the presentation changes — `activity_blocks` still holds every
    /// one of them, so `DailyStats` sees exactly what it saw before. Consecutive steps in the
    /// same app on the same subject collapse into one arrow, because "Chrome → Chrome → Chrome"
    /// says nothing the clock does not.
    static func collapsedRun(
        _ run: [ActivityBlock], frames: [TimelineFrame], labels: TimelineLabels, timeZone: TimeZone
    ) -> String? {
        guard let first = run.first, let last = run.last else { return nil }
        var steps: [String] = []
        for block in run {
            let next = step(for: block, frames: frames, labels: labels)
            if steps.last != next { steps.append(next) }
        }
        let span = "\(clock(first.startAt, timeZone))-\(clock(last.endAt, timeZone))"
        return "- \(span) Switching: \(steps.joined(separator: " → "))"
    }

    /// `Web browser (GitHub PR #55)` — the app label plus whatever the block's own subject line
    /// would have said, so the run keeps what it was you were switching between.
    private static func step(
        for block: ActivityBlock, frames: [TimelineFrame], labels: TimelineLabels
    ) -> String {
        if block.appKey == BlockBuilder.idleKey { return "Idle" }
        let app = labels.app(block.appKey)
        if block.taskKey == BlockBuilder.redactedTaskKey { return "\(app) (redacted)" }
        guard let detail = subjectText(of: block, frames: frames, labels: labels),
              detail.text.caseInsensitiveCompare(app) != .orderedSame
        else { return app }
        return "\(app) (\(detail.text))"
    }

    // MARK: - Nested headings

    private static func nestedHeader(
        for block: ActivityBlock,
        frames: [TimelineFrame],
        named: HeadingProjects,
        labels: TimelineLabels,
        timeZone: TimeZone
    ) -> String {
        heading(
            for: block, frames: frames, named: named, labels: labels, timeZone: timeZone,
            nested: true
        )
    }

    // MARK: - Header

    /// The numbers come from `totals`, so the header line is a union of the day, never a sum.
    private static func statsLine(
        blocks: [ActivityBlock], frames: [TimelineFrame]
    ) -> String {
        statsParts(totals(blocks: blocks, frames: frames))
            .joined(separator: " · ")
    }

    // MARK: - Nesting (#19)

    public struct Nesting: Sendable, Equatable {
        /// Meeting block id → the screen blocks it contains, in time order.
        public var children: [String: [ActivityBlock]] = [:]
        /// Screen block id → the meeting block hosting it.
        public var hosted: [String: String] = [:]

        public init() {}
    }

    /// A screen block that fits entirely inside a meeting is not a separate stretch of the day —
    /// it is what you had open during the call.
    public static func nest(_ ordered: [ActivityBlock]) -> Nesting {
        // #94: an away block is not a call, so whatever little screen time falls inside a lunch
        // keeps its own place in the day rather than being listed "during the call".
        let meetings = ordered.filter {
            $0.source != .screen && $0.appKey != StatsAggregator.awayAppKey
        }
        guard !meetings.isEmpty else { return Nesting() }

        var result = Nesting()
        for block in ordered where block.source == .screen {
            // Innermost first, so back-to-back calls each keep their own screen time.
            guard let host = meetings
                .filter({ $0.startAt <= block.startAt && block.endAt <= $0.endAt })
                .min(by: { $0.duration < $1.duration })
            else { continue }
            result.children[host.id, default: []].append(block)
            result.hosted[block.id] = host.id
        }
        return result
    }

    // MARK: - Headings

    static func span(_ block: ActivityBlock, timeZone: TimeZone) -> String {
        "\(clock(block.startAt, timeZone))"
            + "-\(clock(block.endAt, timeZone))"
    }

    /// The whole heading line the markdown carries, without its `## `: the clock span, the
    /// labels, and the length in brackets. Both the top-level and the nested headings call this,
    /// so there is one set of naming rules.
    static func heading(
        for block: ActivityBlock,
        frames: [TimelineFrame],
        named: HeadingProjects,
        labels: TimelineLabels,
        timeZone: TimeZone,
        nested: Bool
    ) -> String {
        let text = label(
            for: block, frames: frames, named: named, labels: labels, nested: nested
        )
        // Where the block came from, on the calendar and Granola bands only — the file has said
        // so since #19, and a screen block has nowhere else it could have come from.
        let provenance = !nested && block.source != .screen
            ? ", source: \(block.source.rawValue)" : ""
        return "\(span(block, timeZone: timeZone)) · \(text)"
            + " (\(duration(block.duration)))\(provenance)"
    }

    /// The middle of a heading: everything between the clock span and the length.
    static func label(
        for block: ActivityBlock,
        frames: [TimelineFrame],
        named: HeadingProjects,
        labels: TimelineLabels,
        nested: Bool
    ) -> String {
        // A nested block is always a screen block — `nest` only hosts those — so the calendar
        // form only ever applies at the top level.
        if !nested, block.source != .screen {
            let title = block.title?.nonEmpty.map { " · \"\($0)\"" } ?? ""
            // #94: a timed calendar event with other people and no screen time is time away
            // from the machine, not a call you sat through.
            let kind = block.appKey == StatsAggregator.awayAppKey ? "Away" : "Meeting"
            return "\(kind)\(title)"
        }
        if block.appKey == BlockBuilder.idleKey { return "Idle" }
        // #90: what the stretch was *for*, when the describer named it — the third field of the
        // heading, after the app and the task, so a day's projects read straight off the file.
        let project = projectSuffix(of: block, frames: frames, named: named)
        let app = labels.app(block.appKey)
        if nested, block.taskKey == BlockBuilder.redactedTaskKey { return "\(app) · Redacted" }
        if !nested, block.taskKey == BlockBuilder.meetingTaskKey {
            return "\(app) · Meeting\(project)"
        }
        return "\(app) · \(labels.task(block.taskKey))\(project)"
    }

    /// `2026-09-07 (Monday)`.
    static func heading(day: String, timeZone: TimeZone) -> String {
        guard let date = DayBoundaries.range(day: day, timeZone: timeZone)?.start
        else { return day }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE"
        return "\(day) (\(formatter.string(from: date)))"
    }

    // MARK: - The day's totals

    /// The numbers behind the file's totals line.
    ///
    /// Unions, not sums: a meeting block sits on top of the screen blocks it contains (#19), and
    /// the header may not claim more minutes than the day actually had. Same
    /// arithmetic as `StatsAggregator.daily`.
    public struct Totals: Sendable, Equatable {
        public var trackedSeconds: TimeInterval
        public var idleSeconds: TimeInterval
        public var meetingSeconds: TimeInterval
        public var described: Int
        public var inherited: Int

        public var activeSeconds: TimeInterval { trackedSeconds - idleSeconds }
    }

    public static func totals(blocks: [ActivityBlock], frames: [TimelineFrame]) -> Totals {
        Totals(
            trackedSeconds: StatsAggregator.unionSeconds(blocks),
            idleSeconds: StatsAggregator.unionSeconds(
                blocks.filter { $0.appKey == BlockBuilder.idleKey }
            ),
            meetingSeconds: StatsAggregator.unionSeconds(blocks.filter(StatsAggregator.isMeeting)),
            described: frames.filter { !$0.isInherited && $0.summary?.nonEmpty != nil }.count,
            inherited: frames.filter(\.isInherited).count
        )
    }

    /// The parts of the markdown's totals line, in order, joined with ` · `; nothing else may
    /// build that line.
    static func statsParts(_ totals: Totals) -> [String] {
        var parts = [
            "Tracked \(duration(totals.trackedSeconds))",
            "Active \(duration(totals.activeSeconds))",
            "Idle \(duration(totals.idleSeconds))",
        ]
        if totals.meetingSeconds > 0 {
            parts.append("Meetings \(duration(totals.meetingSeconds))")
        }
        if totals.described + totals.inherited > 0 {
            parts.append("\(totals.described) frames described, \(totals.inherited) inherited")
        }
        return parts
    }

    // MARK: - Blocks

    /// The naming rules are `heading(for:…)`'s; all this adds is the markdown.
    private static func header(
        for block: ActivityBlock,
        frames: [TimelineFrame],
        named: HeadingProjects,
        labels: TimelineLabels,
        timeZone: TimeZone
    ) -> String {
        "## " + heading(
            for: block, frames: frames, named: named, labels: labels, timeZone: timeZone,
            nested: false
        )
    }

    // MARK: - Projects (#90)

    /// Capture id → the project its frame was about, folded onto the canonical list.
    static func projectNames(
        frames: [TimelineFrame], projects: [ProjectEntry]
    ) -> [String: ProjectNames.Project] {
        guard frames.contains(where: { $0.projectHint?.nonEmpty != nil || $0.projectKey != nil })
        else { return [:] }
        return ProjectNames.resolve(
            Dictionary(
                frames.map { frame in
                    (frame.captureId, ProjectNames.Observation(
                        hint: frame.projectHint, appName: frame.appName, windowTitle: frame.title,
                        projectKey: frame.projectKey
                    ))
                },
                uniquingKeysWith: { first, _ in first }
            ),
            projects: projects
        )
    }

    /// What a heading names projects from: the day's spans (#322), or, without them, each frame's
    /// folded hint (#90).
    struct HeadingProjects {
        var named: [String: ProjectNames.Project]
        var spans: [ProjectSpan]?
    }

    /// ` · worklens`, or "" when the block's frames named no project.
    ///
    /// With spans, the project covering most of the block (`ProjectSpans.project`), which is
    /// what the stats threads read. Without, the block's most frequent project, by the same rule
    /// as its dominant document: a block is one stretch of one thing, and a stray frame the
    /// describer read differently should not rename it. Inherited frames only vote when nothing
    /// else can.
    static func projectSuffix(
        of block: ActivityBlock, frames: [TimelineFrame], named projects: HeadingProjects
    ) -> String {
        guard block.source == .screen else { return "" }
        if let spans = projects.spans {
            return ProjectSpans.project(from: block.startAt, to: block.endAt, in: spans)
                .map { " · \($0.name)" } ?? ""
        }
        let named = projects.named
        guard !named.isEmpty else { return "" }
        let own = frames.filter { $0.at >= block.startAt && $0.at < block.endAt }
        let fresh = own.filter { !$0.isInherited }.compactMap { named[$0.captureId]?.name }
        let all = own.compactMap { named[$0.captureId]?.name }
        guard let project = mostFrequent(fresh.isEmpty ? all : fresh) else { return "" }
        return " · \(project)"
    }

    // MARK: - Subject (#69)

    /// The one line under a block heading that names what was on screen.
    ///
    /// `Window: <title>` normally. But an app whose window title is its own name — Claude Desktop
    /// always reports "Claude"; Granola, Finder and Preview often do the same — spends that line
    /// saying nothing, so the describer's dominant `document` takes its place as `Topic: …`.
    /// Prose rather than a bullet.
    static func subject(
        of block: ActivityBlock, frames: [TimelineFrame], labels: TimelineLabels
    ) -> String? {
        subjectText(of: block, frames: frames, labels: labels)
            .map { "\($0.prefix): \($0.text)" }
    }

    /// The same choice `subject` renders, before it becomes a line: `Window` or `Topic`, and the
    /// text itself. #94's collapsed runs want the text without the label.
    static func subjectText(
        of block: ActivityBlock, frames: [TimelineFrame], labels: TimelineLabels
    ) -> (prefix: String, text: String)? {
        guard block.source == .screen else { return nil }
        let title = block.title?.nonEmpty
        let own = frames.filter { $0.at >= block.startAt && $0.at < block.endAt }
        let saysNothing = title.map { isAppName($0, block: block, frames: own, labels: labels) } ?? true
        if saysNothing, let document = dominantDocument(own) { return ("Topic", document) }
        return title.map { ("Window", $0) }
    }

    /// Case-insensitively: the block's own app label, or the name macOS reported for the app on
    /// any of the block's frames.
    private static func isAppName(
        _ title: String, block: ActivityBlock, frames: [TimelineFrame], labels: TimelineLabels
    ) -> Bool {
        if labels.app(block.appKey).caseInsensitiveCompare(title) == .orderedSame { return true }
        return frames.contains { $0.appName?.caseInsensitiveCompare(title) == .orderedSame }
    }

    /// The document the block spent most of its frames on — the most-frequent rule
    /// `BlockBuilder.dominantTitle` uses for titles, and the first one seen wins a tie. Inherited
    /// frames repeat the frame before them, so they only vote when nothing else can.
    private static func dominantDocument(_ frames: [TimelineFrame]) -> String? {
        mostFrequent(frames.filter { !$0.isInherited }.compactMap { $0.document?.nonEmpty })
            ?? mostFrequent(frames.compactMap { $0.document?.nonEmpty })
    }

    private static func mostFrequent(_ values: [String]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for value in values {
            if counts[value] == nil { order.append(value) }
            counts[value, default: 0] += 1
        }
        guard let best = order.max(by: { (counts[$0] ?? 0) < (counts[$1] ?? 0) }) else { return nil }
        return String(best.prefix(BlockBuilder.maxTitleLength))
    }

    /// One bullet per distinct summary the person's own frames produced, timestamped. Inherited
    /// frames repeat the frame before them, so quoting them would pad the day with echoes.
    static func bullets(
        for block: ActivityBlock, frames: [TimelineFrame], timeZone: TimeZone
    ) -> [String] {
        if block.appKey == BlockBuilder.idleKey { return [] }
        if block.taskKey == BlockBuilder.redactedTaskKey {
            return ["- \(BlockBuilder.redactedSummary)"]
        }
        // A meeting block speaks for itself. The frames inside its window belong to the screen
        // blocks nested under it, and quoting them here as well would say everything twice.
        if block.source != .screen {
            return block.summaryMd?.nonEmpty.map { ["- \($0)"] } ?? []
        }

        var seen: Set<String> = []
        var distinct: [(Date, String)] = []
        for frame in frames.filter({ $0.at >= block.startAt && $0.at < block.endAt })
            .sorted(by: { $0.at < $1.at })
        {
            guard !frame.isInherited, let summary = frame.summary?.nonEmpty else { continue }
            guard seen.insert(summary).inserted else { continue }
            distinct.append((frame.at, summary))
        }

        if distinct.isEmpty {
            guard let summary = block.summaryMd?.nonEmpty else { return [] }
            return ["- \(summary)"]
        }
        return trimmed(distinct).map { "- \(clock($0.0, timeZone)) \($0.1)" }
    }

    /// Keeps the first and the last summary and fills the middle from the most recent, so a long
    /// block still shows how it started and how it ended.
    private static func trimmed(_ items: [(Date, String)]) -> [(Date, String)] {
        guard items.count > maxBulletsPerBlock else { return items }
        let first = items[0]
        let tail = Array(items.dropFirst().suffix(maxBulletsPerBlock - 1))
        return [first] + tail
    }

    // MARK: - Context (#19)

    /// What happened off-screen: the meetings Granola and your calendar recorded.
    ///
    /// Only ever the short form. Transcripts live in files and stay there.
    static func contextSection(_ events: [ContextEvent], timeZone: TimeZone) -> [String] {
        let ordered = events.sorted { $0.startAt < $1.startAt }
        // Deduplicated the same way the meeting blocks are, so the Context list and the blocks
        // above it can never disagree about how many meetings the day had.
        let meetings = ContextBlocks.deduplicate(ordered.filter(\.isMeeting))
        guard !meetings.isEmpty else { return [] }

        var lines = ["", "## Context", "", "Meetings (\(meetings.count)):"]
        for meeting in meetings {
            let span = "\(clock(meeting.startAt, timeZone))-\(clock(meeting.effectiveEndAt, timeZone))"
            let excerpt = ContextBody.oneLine(meeting.bodyMd, limit: 200).map { ": \($0)" } ?? ""
            lines.append("- \(span) [\(meeting.source.rawValue)] \(meeting.title ?? "untitled")\(excerpt)")
            lines += outcomeLines(meeting.outcomes)
        }
        return lines
    }

    /// Most nested next-step and decision lines one meeting gets (#316). The full list is one
    /// `context_events` call away.
    static let maxOutcomeLines = 5

    static func outcomeLines(_ outcomes: MeetingOutcomes?) -> [String] {
        guard let outcomes else { return [] }
        let items = outcomes.nextSteps.map { ("Next step", $0.text) } + outcomes.decisions.map { ("Decision", $0.text) }
        return items.prefix(maxOutcomeLines).compactMap { label, text in
            ContextBody.oneLine(text, limit: 160).map { "  - \(label): \($0)" }
        }
    }

    // MARK: - Footer

    /// #146: the coverage sentence leads, because it is the one part of the footer that changes
    /// what the rest of the file means — an empty afternoon is not the same fact when Worklens
    /// was paused through it.
    static func coverageSentence(
        day: String, gaps: [CoverageGap], timeZone: TimeZone
    ) -> String? {
        guard !gaps.isEmpty, let range = DayBoundaries.range(day: day, timeZone: timeZone)
        else { return nil }
        return CoverageSpans.sentence(gaps, within: range, timeZone: timeZone)
    }

    static func footer(
        blocks: [ActivityBlock], frames: [TimelineFrame], coverage: String? = nil
    ) -> String? {
        let redacted = blocks
            .filter { $0.taskKey == BlockBuilder.redactedTaskKey }
            .reduce(0) { $0 + $1.duration }
        let sensitive = frames.filter(\.isSensitive).count
        guard redacted > 0 || sensitive > 0 || coverage != nil else { return nil }

        var parts: [String] = []
        if let coverage { parts.append(coverage) }
        if redacted > 0 { parts.append("\(duration(redacted)) redacted (blocked app or title)") }
        if sensitive > 0 {
            parts.append("\(sensitive) frame\(sensitive == 1 ? "" : "s") flagged sensitive")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Formatting

    /// The locale is injected and defaults to `Format.fixed` on purpose: what this renders lands
    /// in a file on disk and inside a model prompt, and `Tests/Fixtures/timeline-golden.md` is
    /// written in it. A `.autoupdatingCurrent` default here would make `make test` pass or fail
    /// depending on the developer's System Settings (#157).
    static func clock(
        _ date: Date, _ timeZone: TimeZone, locale: Locale = Format.fixed
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// `7h 42m`, or `44m` under an hour. Rounded to the minute: nobody reads seconds.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        // Zero-padded past the hour, the way the MCP `stats` tool prints it, so the timeline and the report
        // read as one system.
        return rest == 0 ? "\(hours)h" : String(format: "%dh %02dm", hours, rest)
    }
}

public extension ActivityBlock {
    var duration: TimeInterval { endAt.timeIntervalSince(startAt) }
}
