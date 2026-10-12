import Foundation
import GRDB

/// The storage side of `ProjectSpans` (#322): reads a day's frames and the evidence the other
/// sources left, and hands them to the pure allocator. Computed on read, never stored: a late
/// description, a rebuilt block or a catalog merge changes past days, and a table would need
/// invalidating on each.
///
/// Nothing here logs. A span names its rule, never the URL, document, repo or title behind it.
public struct ProjectSpanService: Sendable {
    private let db: Database
    private let timeZone: TimeZone
    private let projects: @Sendable () -> [ProjectEntry]
    private let ignoredDomains: @Sendable () -> [String]
    private let now: @Sendable () -> Date
    private let baseIntervals: DayAccounting.BaseIntervals

    public init(
        _ db: Database,
        timeZone: TimeZone = .current,
        projects: @escaping @Sendable () -> [ProjectEntry] = { [] },
        ignoredDomains: @escaping @Sendable () -> [String] = { [] },
        now: @escaping @Sendable () -> Date = { Date() },
        baseIntervals: DayAccounting.BaseIntervals = .shipped
    ) {
        self.db = db
        self.timeZone = timeZone
        self.projects = projects
        self.ignoredDomains = ignoredDomains
        self.now = now
        self.baseIntervals = baseIntervals
    }

    /// The day's spans, read from scratch. Nil where the day has no accounting, the way
    /// `StatsService.daily` then reads `byProject` per frame.
    public func spans(day: String) throws -> [ProjectSpan]? {
        let blocks = try ActivityBlockStore(db).fetch(day: day)
        guard let accounting = try StatsService.accounting(
            db: db, day: day, timeZone: timeZone, now: now(), blocks: blocks,
            captures: try CaptureStore(db).fetch(day: day, timeZone: timeZone),
            sessions: try ForegroundSessionStore(db).fetch(day: day, timeZone: timeZone),
            baseIntervals: baseIntervals
        ) else { return nil }
        return try spans(
            day: day, accounting: accounting, blocks: blocks,
            events: try ContextEventStore(db).events(day: day, timeZone: timeZone)
        )
    }

    /// Each of `days` that has accounting, its spans as they are and as they would be under
    /// `catalog` and `assignments` (#324): what `ProjectCorrections.preview` diffs.
    public func comparisons(
        days: [String], catalog: [ProjectEntry], assignments: [ProjectAssignment]
    ) throws -> [ProjectCorrections.DayComparison] {
        try days.compactMap { day in
            let blocks = try ActivityBlockStore(db).fetch(day: day)
            guard let accounting = try StatsService.accounting(
                db: db, day: day, timeZone: timeZone, now: now(), blocks: blocks,
                captures: try CaptureStore(db).fetch(day: day, timeZone: timeZone),
                sessions: try ForegroundSessionStore(db).fetch(day: day, timeZone: timeZone),
                baseIntervals: baseIntervals
            ) else { return nil }
            let events = try ContextEventStore(db).events(day: day, timeZone: timeZone)
            let before = try spans(day: day, accounting: accounting, blocks: blocks, events: events)
            let after = ProjectSpans.build(try input(
                day: day, accounting: accounting, blocks: blocks, events: events,
                catalog: catalog, assignments: assignments
            ))
            return ProjectCorrections.DayComparison(day: day, before: before, after: after)
        }
    }

    /// Every local day from the oldest capture kept to today: the days a rule reaches.
    public func keptDays() throws -> [String] {
        let oldest = try db.writer.read { db in
            try Date.fetchOne(db, sql: "SELECT MIN(captured_at) FROM captures")
        }
        guard let oldest else { return [] }
        return StatsService.days(
            from: DayBoundaries.dayString(oldest, timeZone: timeZone),
            to: DayBoundaries.dayString(now(), timeZone: timeZone),
            timeZone: timeZone
        )
    }

    /// The local days `[from, to)` touches.
    public func days(from: Date, to: Date) -> [String] {
        guard to > from else { return [] }
        return StatsService.days(
            from: DayBoundaries.dayString(from, timeZone: timeZone),
            to: DayBoundaries.dayString(to.addingTimeInterval(-0.001), timeZone: timeZone),
            timeZone: timeZone
        )
    }

    /// The day's spans from the accounting, blocks and meetings a caller already read.
    func spans(
        day: String, accounting: DayAccounting, blocks: [ActivityBlock], events: [ContextEvent],
        policy: ProjectSpans.Policy = .default
    ) throws -> [ProjectSpan] {
        ProjectSpans.build(try input(day: day, accounting: accounting, blocks: blocks, events: events), policy: policy)
    }

    /// `catalog` and `assignments` stand in for the taxonomy's projects and the stored
    /// assignments when given: what `ProjectCorrections` previews a change with (#324).
    func input(
        day: String, accounting: DayAccounting, blocks: [ActivityBlock], events: [ContextEvent],
        catalog: [ProjectEntry]? = nil, assignments: [ProjectAssignment]? = nil
    ) throws -> ProjectSpans.Input {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else {
            return ProjectSpans.Input(accounting: [], frames: [], evidence: [])
        }
        let catalog = catalog ?? projects()
        let frames = try TimelineQueries(db).frames(day: day, timeZone: timeZone)
        let documentURLs = try AXSnapshotStore(db).documentURLs(day: day, timeZone: timeZone)
        let matcher = ProjectRuleMatcher(catalog: catalog)
        var evidence = Self.frameEvidence(frames, catalog: catalog)
        evidence += Self.resourceEvidence(
            frames,
            documentURLs: documentURLs,
            claims: try resourceClaims(catalog: catalog),
            catalog: catalog
        )
        evidence += Self.ruleEvidence(frames, documentURLs: documentURLs, matcher: matcher)
        evidence += Self.meetingEvidence(
            events, catalog: catalog, ignoredDomains: ignoredDomains(),
            range: (range.start, min(range.end, max(range.start, now()))), matcher: matcher
        )
        evidence += try agentEvidence(range: range, blocks: blocks, catalog: catalog, matcher: matcher)
        let claimed = try assignments ?? ProjectAssignmentStore(db).overlapping(from: range.start, to: range.end)
        return ProjectSpans.Input(
            accounting: accounting.spans ?? [],
            frames: frames.map { frame in
                ProjectSpans.Frame(
                    id: frame.captureId, at: frame.at, interval: frame.intervalSeconds,
                    isDescribed: frame.appKey != nil, isIdle: frame.isIdle, isRedacted: frame.isRedacted
                )
            },
            evidence: evidence,
            tick: TimeInterval(baseIntervals.capture),
            assignments: Self.assignments(claimed, catalog: catalog, range: range)
        )
    }

    /// Stored assignments as the allocator reads them, clipped to the day, newest highest. A key
    /// the catalog no longer has (a hand edit) is kept under its own spelling.
    static func assignments(
        _ rows: [ProjectAssignment], catalog: [ProjectEntry], range: (start: Date, end: Date)
    ) -> [ProjectSpans.Assignment] {
        let ordered = rows.sorted { $1.isNewer(than: $0) }
        return ordered.enumerated().compactMap { order, row in
            let start = max(row.from, range.start), end = min(row.to, range.end)
            guard end > start else { return nil }
            let entry = ProjectEntry.lookup(key: row.projectKey, in: catalog)
            return ProjectSpans.Assignment(
                start: start, end: end, project: entry?.key ?? row.projectKey, name: entry?.name, order: order
            )
        }
    }

    // MARK: Evidence

    /// `project_key` (#315) and folded `project_hint` (#70, #90), the way `ProjectNames` reads
    /// them. Redacted and idle frames name nothing.
    static func frameEvidence(_ frames: [TimelineFrame], catalog: [ProjectEntry]) -> [ProjectSpans.Evidence] {
        let usable = frames.filter { !$0.isRedacted && !$0.isIdle }
        guard usable.contains(where: { $0.projectHint?.nonEmpty != nil || $0.projectKey != nil }) else { return [] }
        let named = ProjectNames.resolve(
            Dictionary(
                usable.map { frame in
                    (frame.captureId, ProjectNames.Observation(
                        hint: frame.projectHint, appName: frame.appName, windowTitle: frame.title,
                        projectKey: frame.projectKey
                    ))
                },
                uniquingKeysWith: { first, _ in first }
            ),
            projects: catalog
        )
        return usable.compactMap { frame in
            guard let project = named[frame.captureId] else { return nil }
            let keyed = frame.projectKey.flatMap { ProjectEntry.lookup(key: $0, in: catalog) } != nil
            return ProjectSpans.Evidence(
                scope: .frame(frame.captureId), project: project.key, name: project.name,
                rule: keyed ? .projectKey : .projectHint
            )
        }
    }

    /// A document or PR on screen (#319) that the catalog claims: through a shipped row that
    /// carries both its resource key and a project, else, for GitHub, through its repo.
    static func resourceEvidence(
        _ frames: [TimelineFrame], documentURLs: [String: String], claims: [String: String],
        catalog: [ProjectEntry]
    ) -> [ProjectSpans.Evidence] {
        guard !catalog.isEmpty else { return [] }
        return frames.compactMap { frame in
            guard !frame.isRedacted, !frame.isIdle,
                  let key = ArtifactKey.resolve(url: frame.url, documentURL: documentURLs[frame.captureId])
            else { return nil }
            var entry = claims[key.canonical.lowercased()].flatMap { ProjectEntry.lookup(key: $0, in: catalog) }
            if entry == nil, let reference = key.githubReference {
                entry = project(forRepo: reference.repo, in: catalog)
            }
            guard let entry else { return nil }
            return ProjectSpans.Evidence(
                scope: .frame(frame.captureId), project: entry.key, name: entry.name, rule: .resourceKey
            )
        }
    }

    /// Lowercased resource key → the project key a shipped row put it under. A resource two rows
    /// put under different projects is claimed by neither.
    private func resourceClaims(catalog: [ProjectEntry]) throws -> [String: String] {
        guard !catalog.isEmpty else { return [:] }
        return try db.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT resource_key, project_key FROM outputs
                WHERE resource_key IS NOT NULL AND project_key IS NOT NULL
                ORDER BY resource_key, project_key
                """)
            var claims: [String: String] = [:]
            var disputed: Set<String> = []
            for row in rows {
                let key = (row["resource_key"] as String).lowercased()
                let project = row["project_key"] as String
                if let claimed = claims[key], claimed != project { disputed.insert(key) }
                claims[key] = claims[key] ?? project
            }
            return claims.filter { !disputed.contains($0.key) }
        }
    }

    /// Each meeting (#318), joined the way the timeline joins them, with its company or none,
    /// and, above it, the one project a domain rule names for its attendees (#324).
    static func meetingEvidence(
        _ events: [ContextEvent], catalog: [ProjectEntry], ignoredDomains: [String],
        range: (start: Date, end: Date), matcher: ProjectRuleMatcher? = nil
    ) -> [ProjectSpans.Evidence] {
        let meetings = ContextBlocks.deduplicate(events.filter(\.isMeeting))
        guard !meetings.isEmpty else { return [] }
        let answers = MeetingAttribution.resolve(events, catalog: catalog, ignoredDomains: ignoredDomains)
        // An ignored domain still answers to a domain rule written on it or under it, so a rule
        // added after `forget company:<domain>` moves that company's meetings.
        let ruled = catalog.filter { $0.kind != .house }.flatMap { $0.domains ?? [] }
            .compactMap(ProjectRuleMatcher.normalizedDomain)
        var excluded = Set(ignoredDomains.map(MeetingAttribution.normalized).filter { ignored in
            !ruled.contains { ProjectRuleMatcher.host($0, isUnder: ignored) }
        })
        for project in catalog where project.kind == .house {
            excluded.formUnion((project.domains ?? []).map(MeetingAttribution.normalized))
        }
        return meetings.flatMap { meeting -> [ProjectSpans.Evidence] in
            let start = max(meeting.startAt, range.start)
            let end = min(meeting.effectiveEndAt, range.end)
            guard end > start else { return [] }
            let company = answers[meeting.id]
            var rows = [ProjectSpans.Evidence(
                scope: .stretch(start: start, end: end), project: company?.key, name: company?.name,
                rule: .meetingCompany
            )]
            let named = matcher.map { $0.projects(forDomains: attendeeDomains(meeting, excluded: excluded)) } ?? []
            if named.count == 1 {
                rows.append(ProjectSpans.Evidence(
                    scope: .stretch(start: start, end: end), project: named[0].key, name: named[0].name,
                    rule: .ruleDomain
                ))
            }
            return rows
        }
    }

    /// The attendees' domains a domain rule may read: as written (so `eu.acme.com` can be its
    /// own rule), less your own, the house's, the ignored ones, personal mailboxes and rooms.
    static func attendeeDomains(_ event: ContextEvent, excluded: Set<String>) -> [String] {
        let own = MeetingAttribution.ownerEmail(event).flatMap(MeetingAttribution.domain(of:))
            .map(MeetingAttribution.registrableDomain)
        let registrableExcluded = Set(excluded.map(MeetingAttribution.registrableDomain))
        return Array(Set(event.participantEmails.compactMap(MeetingAttribution.domain(of:)).filter { domain in
            let registrable = MeetingAttribution.registrableDomain(domain)
            return !MeetingAttribution.isCalendarResource(domain) && registrable != own
                && !registrableExcluded.contains(registrable)
                && !MeetingAttribution.personalMailDomains.contains(registrable)
        })).sorted()
    }

    /// Your rules on what a frame shows (#324): the longest URL prefix, the GitHub repo, then
    /// the most specific domain, each over the frame's URL and its document's. Redacted and idle
    /// frames name nothing.
    static func ruleEvidence(
        _ frames: [TimelineFrame], documentURLs: [String: String], matcher: ProjectRuleMatcher
    ) -> [ProjectSpans.Evidence] {
        guard !matcher.isEmpty else { return [] }
        return frames.flatMap { frame -> [ProjectSpans.Evidence] in
            guard !frame.isRedacted, !frame.isIdle else { return [] }
            let urls = [frame.url, documentURLs[frame.captureId]]
            var rows: [ProjectSpans.Evidence] = []
            func add(_ entry: ProjectEntry?, _ rule: ProjectSpan.Rule) {
                guard let entry else { return }
                rows.append(ProjectSpans.Evidence(
                    scope: .frame(frame.captureId), project: entry.key, name: entry.name, rule: rule
                ))
            }
            add(matcher.project(forURLs: urls), .ruleUrlPrefix)
            let repo = ArtifactKey.resolve(url: frame.url, documentURL: documentURLs[frame.captureId])?
                .githubReference?.repo
            add(matcher.project(forRepo: repo), .ruleRepo)
            add(matcher.project(forHosts: urls.compactMap(ProjectRuleMatcher.host(of:))), .ruleDomain)
            return rows
        }
    }

    /// Your prompt windows (#321) in repos the catalog claims, and in repos a rule names (#324).
    private func agentEvidence(
        range: (start: Date, end: Date), blocks: [ActivityBlock], catalog: [ProjectEntry],
        matcher: ProjectRuleMatcher
    ) throws -> [ProjectSpans.Evidence] {
        guard !catalog.isEmpty else { return [] }
        let store = AgentSessionStore(db)
        let prompts = try store.prompts(from: range.start.addingTimeInterval(-PromptWindows.after), to: range.end)
        guard !prompts.isEmpty else { return [] }
        let sessions = Dictionary(uniqueKeysWithValues: try store.sessions().map { ($0.id, $0) })
        let windows = prompts.map { prompt in
            let counted = sessions[prompt.sessionId]?.parentId ?? prompt.sessionId
            return PromptWindows.Prompt(
                at: prompt.at, sessionId: counted, repo: sessions[counted]?.repo,
                host: sessions[prompt.sessionId]?.host
            )
        }
        let lookFrom = range.start.addingTimeInterval(-PromptWindows.after - PromptWindows.before)
        let foreground = try ForegroundSessionStore(db).fetch(overlapping: lookFrom, to: range.end)
        let active = blocks
            .filter { !StatsAggregator.isInactive($0) }
            .map { DateInterval(start: $0.startAt, end: max($0.startAt, $0.endAt)) }
        return PromptWindows.attribute(prompts: windows, foreground: foreground, active: active, timeZone: timeZone)
            .flatMap { piece -> [ProjectSpans.Evidence] in
                guard piece.end > range.start, piece.start < range.end, let repo = piece.repo else { return [] }
                let scope = ProjectSpans.Evidence.Scope.stretch(
                    start: max(piece.start, range.start), end: min(piece.end, range.end)
                )
                var rows: [ProjectSpans.Evidence] = []
                if let entry = Self.project(forRepo: repo, in: catalog) {
                    rows.append(ProjectSpans.Evidence(scope: scope, project: entry.key, name: entry.name, rule: .agentRepo))
                }
                if let entry = matcher.project(forRepo: repo) {
                    rows.append(ProjectSpans.Evidence(scope: scope, project: entry.key, name: entry.name, rule: .ruleRepo))
                }
                return rows
            }
    }

    /// The entry whose name or alias is the repo: `owner/name`, `name`, or `name` with `-`, `_`
    /// and `.` read as spaces, as `ShippedSection` groups a PR. The lowest key wins a tie.
    static func project(forRepo repo: String, in catalog: [ProjectEntry]) -> ProjectEntry? {
        let short = repo.split(separator: "/").last.map(String.init) ?? repo
        let spaced = String(short.map { "-_.".contains($0) ? " " : $0 })
        return catalog
            .filter { $0.matches(short) || $0.matches(repo) || $0.matches(spaced) }
            .min { $0.key < $1.key }
    }

    // MARK: Coverage

    /// What `worklens projects coverage` prints: counts over a range, under the span rules and
    /// under each frame alone with the meeting's company (what `byProject` did before #322).
    public struct Coverage: Sendable, Equatable {
        public var from: String
        public var to: String
        public var days: Int
        public var spans: SpanCoverage
        public var perFrame: SpanCoverage
    }

    /// One way of attributing, in minutes: what `coverage --json` prints for each.
    public struct CoverageMinutes: Encodable, Sendable, Equatable {
        public let screenMinutes: Int
        public let screenAttributedMinutes: Int
        /// Unattributed screen minutes by `ProjectSpan.Reason`.
        public let screenUnattributed: [String: Int]
        public let meetingMinutes: Int
        public let meetingAttributedMinutes: Int
        public let meetingUnattributed: [String: Int]
        /// Attributed minutes by the `ProjectSpan.Rule` that decided them.
        public let byRule: [String: Int]
        public let spans: Int
        public let absorbed: Int

        enum CodingKeys: String, CodingKey {
            case screenMinutes = "screen_minutes"
            case screenAttributedMinutes = "screen_attributed_minutes"
            case screenUnattributed = "screen_unattributed"
            case meetingMinutes = "meeting_minutes"
            case meetingAttributedMinutes = "meeting_attributed_minutes"
            case meetingUnattributed = "meeting_unattributed"
            case byRule = "by_rule"
            case spans, absorbed
        }

        public init(_ coverage: SpanCoverage) {
            func minutes(_ seconds: Double) -> Int { Int((seconds / 60).rounded()) }
            screenMinutes = minutes(coverage.screenSeconds)
            screenAttributedMinutes = minutes(coverage.screenAttributedSeconds)
            screenUnattributed = coverage.screenUnattributed.mapValues(minutes)
            meetingMinutes = minutes(coverage.meetingSeconds)
            meetingAttributedMinutes = minutes(coverage.meetingAttributedSeconds)
            meetingUnattributed = coverage.meetingUnattributed.mapValues(minutes)
            byRule = coverage.byRule.mapValues(minutes)
            spans = coverage.spans
            absorbed = coverage.absorbed
        }
    }

    /// `{from, to, days, spans, per_frame}`, the last two `CoverageMinutes`. Reasons and rules
    /// are fixed vocabularies: nothing here is ever a project key, a name or a title.
    public struct CoverageReport: Encodable, Sendable, Equatable {
        public let from: String
        public let to: String
        public let days: Int
        public let spans: CoverageMinutes
        public let perFrame: CoverageMinutes

        enum CodingKeys: String, CodingKey {
            case from, to, days, spans
            case perFrame = "per_frame"
        }

        public init(_ coverage: Coverage) {
            from = coverage.from
            to = coverage.to
            days = coverage.days
            spans = CoverageMinutes(coverage.spans)
            perFrame = CoverageMinutes(coverage.perFrame)
        }
    }

    /// The evidence `byProject` read before #322: each frame's key or hint, and the meeting's
    /// company (#318).
    static func perFrame(_ input: ProjectSpans.Input) -> ProjectSpans.Input {
        var input = input
        let before: Set<ProjectSpan.Rule> = [.meetingCompany, .projectKey, .projectHint]
        input.evidence = input.evidence.filter { before.contains($0.rule) }
        input.assignments = []
        return input
    }

    public func coverage(from: String, to: String) throws -> Coverage {
        let days = StatsService.days(from: from, to: to, timeZone: timeZone)
        var spans = SpanCoverage()
        var perFrame = SpanCoverage()
        for day in days {
            let blocks = try ActivityBlockStore(db).fetch(day: day)
            guard let accounting = try StatsService.accounting(
                db: db, day: day, timeZone: timeZone, now: now(), blocks: blocks,
                captures: try CaptureStore(db).fetch(day: day, timeZone: timeZone),
                sessions: try ForegroundSessionStore(db).fetch(day: day, timeZone: timeZone),
                baseIntervals: baseIntervals
            ) else { continue }
            let events = try ContextEventStore(db).events(day: day, timeZone: timeZone)
            let input = try input(day: day, accounting: accounting, blocks: blocks, events: events)
            spans = spans + ProjectSpans.coverage(ProjectSpans.build(input))
            perFrame = perFrame + ProjectSpans.coverage(ProjectSpans.build(Self.perFrame(input), policy: .perFrame))
        }
        return Coverage(from: from, to: to, days: days.count, spans: spans, perFrame: perFrame)
    }
}
