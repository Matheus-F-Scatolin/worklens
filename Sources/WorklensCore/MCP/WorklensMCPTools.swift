import Foundation

/// The read-only tools `worklens mcp` exposes (#89, #241, #314, #321).
///
/// Every one of them is a thin call onto a service that already exists — `SearchService`,
/// `TimelineWriter.markdown`, `StatsService`, `ContextEventStore`
/// — so the MCP surface can never drift from what `worklens search` and the Today page show.
/// Nothing here writes: no migration runs, no file is touched, no lock is taken,
/// which is what makes it safe to run beside the app.
///
/// Descriptions say `YYYY-MM-DD` out loud and say whose data this is, because a client shows them
/// to a model that has never seen this repository.
public enum WorklensMCPTools {
    /// The default and maximum for `search`'s and `days`'s bounds. A result set the model has to
    /// wade through is worse than one more call.
    public static let searchDefaultDays = 30
    public static let searchDefaultLimit = 20
    public static let contextBodyLimit = 400
    public static let daysDefaultLimit = 90
    /// `now`'s window, in minutes: long enough to hold the thing you are in the middle of.
    public static let nowDefaultMinutes = 45
    /// How long a `span` may be, inclusive. A month of days is one read per day; past that the
    /// answer is a weekly `stats` call, not a longer loop.
    public static let spanMaxDays = 31
    /// And with `by: "project"` (#323): a quarter, since that answer reads spans, not `daily`.
    public static let spanProjectMaxDays = 92
    /// How far back `vocabulary` looks for what was actually used.
    public static let vocabularyDefaultDays = 30
    /// And the furthest it will look. Its own number rather than `spanMaxDays`: a span is one
    /// `StatsService.daily` read per day, while this is a vocabulary — a project that was last
    /// touched two months ago is still the name to use instead of guessing one.
    public static let vocabularyMaxDays = 90

    private static let ownership =
        "Everything this returns is your own recorded screen history on this Mac, stored locally by Worklens."

    public static func registry(
        config: Config,
        db: Database,
        taxonomy: TaxonomyStore,
        timeZone: TimeZone = .current
    ) -> MCPToolRegistry {
        MCPToolRegistry(
            [
                searchTool(db: db, taxonomy: taxonomy, timeZone: timeZone),
                timelineTool(config: config, db: db, taxonomy: taxonomy, timeZone: timeZone),
                statsTool(db: db, taxonomy: taxonomy, timeZone: timeZone, config: config),
                contextEventsTool(db: db, taxonomy: taxonomy, timeZone: timeZone),
                daysTool(db: db, taxonomy: taxonomy),
                nowTool(db: db, taxonomy: taxonomy, timeZone: timeZone),
                spanTool(db: db, taxonomy: taxonomy, timeZone: timeZone, config: config),
                vocabularyTool(db: db, taxonomy: taxonomy, timeZone: timeZone),
                shippedTool(config: config, db: db, taxonomy: taxonomy, timeZone: timeZone),
                agentSessionsTool(config: config, db: db, timeZone: timeZone),
            ],
            prompts: WorklensMCPPrompts.all(),
            instructions: instructions
        )
    }

    /// The sentence `initialize` appends to the data-directory one (#241).
    static let instructions =
        "Ask about the timeline and the stats."

    // MARK: - search

    static func searchTool(db: Database, taxonomy: TaxonomyStore, timeZone: TimeZone) -> MCPTool {
        MCPTool(
            name: "search",
            title: "Search your screen history",
            description: """
                Full-text search over what was actually on screen: frame descriptions, window \
                outlines, window titles and URL hosts. Use it to find when something happened; \
                each hit names the day, so follow up with `timeline`. Double-quote a run of words \
                to search it as a phrase. \(ownership)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "query": .object(["type": "string", "description": "What to look for."]),
                    "days": .object([
                        "type": "integer",
                        "description": .string("How many days back to look, counting today. 0 searches everything. Default \(searchDefaultDays)."),
                    ]),
                    "limit": .object([
                        "type": "integer",
                        "description": .string("How many hits to return. Default \(searchDefaultLimit), max 100."),
                    ]),
                    "project": .object([
                        "type": "string",
                        "description": "Optional: only what was named as this project. Call `vocabulary` for the names.",
                    ]),
                    "app": .object([
                        "type": "string",
                        "description": "Optional: only what was in this app, by name or by key. Call `vocabulary` for the keys.",
                    ]),
                ]),
                "required": .array(["query"]),
            ]),
            annotations: .read
        ) { arguments in
            let query = try arguments.requiredString("query", "the text to look for")
            let days = try arguments.int("days", default: searchDefaultDays, range: 0...3650)
            let limit = try arguments.int("limit", default: searchDefaultLimit, range: 1...100)
            let filters = SearchFilters(
                project: arguments.optionalString("project"), app: arguments.optionalString("app")
            )
            let results = try SearchService(db, timeZone: timeZone, projects: taxonomy.projects).search(
                query: query, days: dayRange(back: days, timeZone: timeZone), limit: limit,
                filters: filters
            )
            let narrowed = filterNote(filters)
            // A filter that hid everything reads exactly like a query nothing matched, so the
            // count of what it kept out is part of the answer rather than a footnote.
            let dropped = results.excluded > 0
                ? " \(results.excluded) other matching screenshot(s) were outside that filter."
                : ""
            guard !results.hits.isEmpty else {
                return "No screenshots match \(query.debugDescription)\(narrowed)"
                    + (days == 0 ? "." : " in the last \(days) day(s).") + dropped
            }
            let scope = days == 0 ? "all recorded days" : "the last \(days) day(s)"
            return "\(results.hits.count) hit(s) for \(query.debugDescription)\(narrowed) in \(scope).\(dropped)\n\n"
                + results.hits.map { line(for: $0, timeZone: timeZone) }.joined(separator: "\n\n")
        }
    }

    /// What to say about a filter in the sentence above the hits.
    private static func filterNote(_ filters: SearchFilters) -> String {
        var parts: [String] = []
        if let project = filters.project { parts.append("project \(project.debugDescription)") }
        if let app = filters.app { parts.append("app \(app.debugDescription)") }
        return parts.isEmpty ? "" : " in \(parts.joined(separator: " and "))"
    }

    private static func line(for hit: SearchHit, timeZone: TimeZone) -> String {
        let place = [hit.appName ?? hit.appKey, hit.windowTitle ?? hit.urlHost]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        let head = ([clock(timeZone).string(from: hit.capturedAt)] + place).joined(separator: " · ")
            + (hit.frames > 1 ? "  (\(hit.frames) frames)" : "")
        return "\(head)\n  day: \(hit.day)\n  \(hit.kind.rawValue): \(oneLine(hit.snippet))"
    }

    // MARK: - timeline

    static func timelineTool(
        config: Config, db: Database, taxonomy: TaxonomyStore, timeZone: TimeZone
    ) -> MCPTool {
        // `markdown(day:)` is `nonisolated`, so this reads the live rendering of `activity_blocks`
        // without awaiting a rebuild and without writing `timeline/<day>.md`.
        let writer = TimelineWriter(config: config, db: db, taxonomy: taxonomy, timeZone: timeZone)
        return MCPTool(
            name: "timeline",
            title: "One day's timeline",
            description: """
                The narrated timeline for one local day, as markdown: time blocks with the app, \
                the task, the window or topic and the project, plus meetings. This is the best \
                first call for "what did I work on on <day>?". Day format is YYYY-MM-DD, local \
                time. \(ownership)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "day": .object(["type": "string", "description": "Local day, YYYY-MM-DD."]),
                ]),
                "required": .array(["day"]),
            ]),
            annotations: .read
        ) { arguments in
            let day = try arguments.day("day", timeZone: timeZone)
            // The renderer answers an empty day with "Nothing recorded for this day.", which
            // leaves the model nowhere to go, so a day with nothing to render points it at `days`
            // instead. A day with no blocks still renders when it has shipped outputs (#314) or
            // context events, e.g. PRs merged while the app was off.
            let empty = try ActivityBlockStore(db).fetch(day: day).isEmpty
                && OutputStore(db).outputs(day: day, timeZone: timeZone).isEmpty
                && ContextEventStore(db).events(day: day, timeZone: timeZone).isEmpty
            guard !empty else {
                return "No timeline for \(day): no activity was recorded. Call `days` for the days that have data."
            }
            return try writer.markdown(day: day)
        }
    }

    // MARK: - stats

    static func statsTool(
        db: Database, taxonomy: TaxonomyStore, timeZone: TimeZone, config: Config
    ) -> MCPTool {
        MCPTool(
            name: "stats",
            title: "The numbers for a day or a week",
            description: """
                The computed numbers for one local day or one ISO week, as JSON: tracked minutes, \
                time by app, by category and by project, longest focus run, context switches, \
                meeting minutes and what the day's LLM calls cost. A single day carries \
                `projectSpans`: your screen and meeting time cut into stretches that never overlap, \
                each with its project key (byProject names it) or `unattributed` and why \
                (no_evidence, undescribed, redacted, meeting_without_company, conflict), the rule that decided it (assignment, \
                rule_url_prefix, rule_repo, rule_domain, meeting_company, agent_repo, resource_key, project_key, project_hint, detour, gap_fill) and \
                `overridden`, the weaker projects the evidence also named. A meeting counts once, as \
                the meeting, never also as the screen time under it. `byProject` is their sum: \
                minutes are screen minutes, meetingMinutes the meeting minutes counted toward the \
                row, meetingRules split them by the rule that named the company (yours, domain, \
                title, calendar_event, or owner), every share, a day's or a week's, is of the \
                screen and meeting minutes all the rows cover, and the `unattributed` row's parts \
                split its screen minutes by reason and its meetingRules its meeting minutes \
                (several_companies, no_company_domain, meeting_without_company, conflict). A day no \
                stretch names a project on has an empty byProject. `byDocument` \
                is time per document you had open: a Google file, a GitHub PR or issue, or a local \
                path with your home folder as `~`. Pass either `day` \
                (YYYY-MM-DD) or `week` (e.g. 2026-W37), not both. Each day also carries \
                `accounting`: every minute of the day in one bucket (meeting, away, screen, \
                batterySparse, asleep, locked, idle, paused, permissionMissing, notRunning, \
                unexplained), once over the whole day and once over the window from your first \
                to your last recorded moment; a single day adds its contiguous `spans`. \(ownership)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "day": .object(["type": "string", "description": "Local day, YYYY-MM-DD."]),
                    "week": .object(["type": "string", "description": "ISO week, e.g. 2026-W37."]),
                ]),
            ]),
            annotations: .read
        ) { arguments in
            let service = StatsService(
                db,
                timeZone: timeZone,
                category: taxonomy.categoryResolver,
                projects: { taxonomy.projects },
                ignoredDomains: { taxonomy.current.ignoredDomains ?? [] },
                baseIntervals: DayAccounting.BaseIntervals(config: config)
            )
            if let week = arguments.optionalString("week") {
                guard arguments.optionalString("day") == nil else {
                    throw MCPToolError("pass either day or week, not both")
                }
                guard let isoWeek = ISOWeek.parse(week, timeZone: timeZone) else {
                    throw MCPToolError("week must look like 2026-W37 (got \"\(week)\")")
                }
                return try StatsAggregator.prettyJSON(service.weekly(isoWeek))
            }
            let day = try arguments.day("day", timeZone: timeZone)
            return try StatsAggregator.prettyJSON(service.daily(day: day))
        }
    }

    // MARK: - context_events

    static func contextEventsTool(db: Database, taxonomy: TaxonomyStore? = nil, timeZone: TimeZone) -> MCPTool {
        MCPTool(
            name: "context_events",
            title: "Meetings",
            description: """
                Meetings synced from outside the screen (Granola notes and calendar events) \
                between two local days inclusive, both YYYY-MM-DD. Bodies are cut at \(contextBodyLimit) characters; a \
                full Granola transcript is on disk and is deliberately not returned. Each Granola meeting then lists \
                the next steps and decisions its full summary names, and says which ones name you; set \
                outcomes_only to get just those meetings, without the body. Each meeting says the company it \
                counts toward and the rule that named it (yours, domain, title or calendar_event), or why none \
                did (several_companies, no_company_domain); pass company to keep one company's meetings. \(ownership)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "from": .object(["type": "string", "description": "First local day, YYYY-MM-DD."]),
                    "to": .object(["type": "string", "description": "Last local day, inclusive, YYYY-MM-DD."]),
                    "sources": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": .string("Optional filter: any of \(ContextSource.allCases.map(\.rawValue).joined(separator: ", "))."),
                    ]),
                    "outcomes_only": .object([
                        "type": "boolean",
                        "description": "Optional: only the meetings that list next steps or decisions, without the body line.",
                    ]),
                    "company": .object([
                        "type": "string",
                        "description": "Optional: only the meetings counted toward this company, by key, name, alias or domain; none for the meetings no company was named for.",
                    ]),
                ]),
                "required": .array(["from", "to"]),
            ]),
            annotations: .read
        ) { arguments in
            let from = try arguments.day("from", timeZone: timeZone)
            let to = try arguments.day("to", timeZone: timeZone)
            guard let start = DayBoundaries.range(day: from, timeZone: timeZone)?.start,
                  let end = DayBoundaries.range(day: to, timeZone: timeZone)?.end,
                  start < end
            else { throw MCPToolError("from must not be after to") }

            var sources: [ContextSource]?
            if let names = arguments.optionalStrings("sources"), !names.isEmpty {
                let parsed = names.compactMap { ContextSource(rawValue: $0.lowercased()) }
                guard parsed.count == names.count else {
                    throw MCPToolError(
                        "sources must be any of \(ContextSource.allCases.map(\.rawValue).joined(separator: ", "))"
                    )
                }
                sources = parsed
            }

            let outcomesOnly = arguments["outcomes_only"]?.boolValue
                ?? (arguments["outcomes_only"]?.stringValue?.lowercased() == "true")

            // #318: every source is read so a Granola note can take its calendar event's company,
            // then the sources filter applies.
            let all = try ContextEventStore(db).fetch(from: start, to: end)
            let catalog = taxonomy?.current ?? Taxonomy.seed
            let companies = MeetingAttribution.resolve(all, taxonomy: catalog)
            var events = sources.map { wanted in all.filter { wanted.contains($0.source) } } ?? all
            if let company = arguments.optionalString("company")?.trimmingCharacters(in: .whitespaces),
               !company.isEmpty {
                events = events.filter {
                    companyMatches(companies[$0.id], company, projects: catalog.projectList)
                }
                guard !events.isEmpty else {
                    if company.lowercased() == "none" {
                        return "No meetings without a company between \(from) and \(to)."
                    }
                    return "No meetings counted toward \(company) between \(from) and \(to)."
                }
            }
            if outcomesOnly {
                events = events.filter { !($0.outcomes?.isEmpty ?? true) }
                guard !events.isEmpty else {
                    return "No meetings with next steps or decisions between \(from) and \(to)."
                }
            }
            guard !events.isEmpty else {
                return "No context events between \(from) and \(to)."
            }
            return "\(events.count) event(s) between \(from) and \(to).\n\n"
                + events.map {
                    block(for: $0, company: companies[$0.id], timeZone: timeZone, withBody: !outcomesOnly)
                }
                .joined(separator: "\n\n")
        }
    }

    /// Does `filter` name the company a meeting counts toward? `none` asks for the meetings no
    /// rule settled; anything else is a key, a spelling of the entry, or a `company:` domain.
    static func companyMatches(_ company: MeetingCompany?, _ filter: String, projects: [ProjectEntry]) -> Bool {
        guard let company else { return false }
        if filter.lowercased() == "none" { return company.key == nil }
        guard let key = company.key else { return false }
        if key == filter || key == MeetingAttribution.companyKeyPrefix + filter.lowercased() { return true }
        if let name = company.name, ProjectEntry.fold(name) == ProjectEntry.fold(filter) { return true }
        guard let entry = ProjectEntry.lookup(key: key, in: projects) else { return false }
        // A domain the entry claims, so a meeting settled by the `yours` rule still answers to it.
        let domain = MeetingAttribution.normalized(filter)
        if (entry.domains ?? []).contains(where: { MeetingAttribution.normalized($0) == domain }) { return true }
        return entry.matches(filter)
    }

    /// `  company: Acme · rule: domain`, or `  company: none · rule: several_companies`.
    static func companyLine(_ company: MeetingCompany) -> String {
        "  company: \(company.key == nil ? "none" : company.name ?? company.key ?? "none") · rule: \(company.rule.rawValue)"
    }

    private static func block(
        for event: ContextEvent, company: MeetingCompany? = nil, timeZone: TimeZone, withBody: Bool = true
    ) -> String {
        let formatter = clock(timeZone)
        let span = event.endAt.map { "\(formatter.string(from: event.startAt))-\(time(timeZone).string(from: $0))" }
            ?? formatter.string(from: event.startAt)
        var out = [
            [span, event.source.rawValue, event.isMeeting ? "meeting" : "note",
             event.title ?? "(untitled)"].joined(separator: " · ")
        ]
        if let participants = participants(event.participantsJson), !participants.isEmpty {
            out.append("  participants: \(participants.joined(separator: ", "))")
        }
        if let company {
            out.append(companyLine(company))
        }
        if withBody, let body = ContextBody.oneLine(event.bodyMd, limit: contextBodyLimit) {
            out.append("  \(body)")
        }
        if let outcomes = event.outcomes {
            out += outcomeLines(outcomes)
        }
        return out.joined(separator: "\n")
    }

    /// The longest single outcome line `context_events` prints.
    static let outcomeLineLimit = MeetingOutcomes.textLimit

    /// `next steps (3, 1 names you):` and its items, then the decisions (#316).
    static func outcomeLines(_ outcomes: MeetingOutcomes) -> [String] {
        func item(_ item: MeetingOutcomes.Item) -> String {
            let line = item.detail.map { "\(item.text): \($0)" } ?? item.text
            return "  - " + (ContextBody.oneLine(line, limit: outcomeLineLimit) ?? item.text)
        }
        var out: [String] = []
        if !outcomes.nextSteps.isEmpty {
            let named = outcomes.nextSteps.filter(\.namesYou).count
            let verb = named == 1 ? "names you" : "name you"
            let count = named > 0 ? "\(outcomes.nextSteps.count), \(named) \(verb)" : "\(outcomes.nextSteps.count)"
            out.append("  next steps (\(count)):")
            out += outcomes.nextSteps.map(item)
        }
        if !outcomes.decisions.isEmpty {
            out.append("  decisions (\(outcomes.decisions.count)):")
            out += outcomes.decisions.map(item)
        }
        return out
    }

    private static func participants(_ json: String?) -> [String]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    // MARK: - days

    static func daysTool(db: Database, taxonomy: TaxonomyStore) -> MCPTool {
        MCPTool(
            name: "days",
            title: "Which days have data",
            description: """
                Which local days have recorded data at all, newest first, with the number of \
                frames, how many of them were described, and a plain sentence about the day: what \
                the day's own apps and minutes say, empty when there is nothing to say. Days \
                that still have an older daily report keep that report's first line as their \
                headline. Call this when you do not know which days to ask about: every other \
                tool takes a YYYY-MM-DD day from here. \(ownership)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "limit": .object([
                        "type": "integer",
                        "description": .string("How many days to return, newest first. Default \(daysDefaultLimit), max 1000."),
                    ]),
                ]),
            ]),
            annotations: .read
        ) { arguments in
            let limit = try arguments.int("limit", default: daysDefaultLimit, range: 1...1000)
            // The headline names apps the way every other tool here names them (#249).
            let days = try MCPDayIndex(db)
                .days(limit: limit, labels: TimelineLabels.from(taxonomy.current))
            guard !days.isEmpty else { return "No days have data yet: nothing has been captured." }
            var lines = [
                "| day | frames | described | headline |", "|---|---:|---:|---|",
            ]
            for day in days {
                // A sentence with a pipe in it would split the row into two cells.
                let headline = day.headline.replacingOccurrences(of: "|", with: "/")
                lines.append("| \(day.day) | \(day.frames) | \(day.described) | \(headline) |")
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - now

    /// What `now` answers with. App keys, project names, minutes and a timestamp — never a window
    /// title, a URL or a file name (#241).
    struct NowWindow: Codable, Sendable {
        var minutes: Int
        var from: Date
        var to: Date
    }

    struct NowBlock: Codable, Sendable {
        var appKey: String
        var taskKey: String
        var minutes: Int
        var start: Date
        var end: Date
    }

    struct NowAnswer: Codable, Sendable {
        var window: NowWindow
        /// The app the last described screenshot in the window was in.
        var appKey: String?
        var appName: String?
        /// The project the describer named on that screenshot, if it named one.
        var project: String?
        var blocks: [NowBlock]
        var lastScreenshotAt: Date?
        /// How long ago that screenshot was. A large number is the honest signal that nothing is
        /// being captured right now — pausing is the running app's state, and this is a separate
        /// read-only process that cannot see it.
        var minutesSinceLastScreenshot: Int?
        var note: String?
    }

    /// `clock` is the seam the tests move: everything else here reads "the last N minutes", which
    /// is unanswerable against a fixture day without one.
    static func nowTool(
        db: Database,
        taxonomy: TaxonomyStore,
        timeZone: TimeZone,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) -> MCPTool {
        MCPTool(
            name: "now",
            title: "What is in front of you",
            description: """
                What has been on screen in the last few minutes, as JSON: the app and project in \
                front, the time blocks inside the window with their minutes, and when the most \
                recent screenshot was taken. Use it for "what am I doing right now?". A last \
                screenshot much older than the window means nothing is being captured at the \
                moment. `minutes` is how far back to look, 5 to 180, default \(nowDefaultMinutes). \
                \(ownership)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "minutes": .object([
                        "type": "integer",
                        "description": .string("How many minutes back to look. Default \(nowDefaultMinutes), 5 to 180."),
                    ]),
                ]),
            ]),
            annotations: .read
        ) { arguments in
            try nowAnswer(
                arguments, db: db, taxonomy: taxonomy, timeZone: timeZone, now: clock()
            )
        }
    }

    /// The body of `now`, out of the `MCPTool(…)` call: inside it, the whole read was one
    /// expression to the type checker, and a release build gave up on it in CI.
    private static func nowAnswer(
        _ arguments: JSONValue, db: Database, taxonomy: TaxonomyStore, timeZone: TimeZone,
        now: Date
    ) throws -> String {
        let minutes = try arguments.int("minutes", default: nowDefaultMinutes, range: 5...180)
        let end = now
        let start = end.addingTimeInterval(-Double(minutes) * 60)

        // The screenshots inside the window, newest first: the latest one says what is in
        // front. Bounded by the window itself, so the answer does not depend on how often
        // capture happens to be looking.
        let recent = try DescriptionStore(db).fetchBetween(start, end)
        let front = recent.first
        let project = recent
            .lazy
            .compactMap { projectName(detailsJSON: $0.description.detailsJson, taxonomy: taxonomy) }
            .first

        // Blocks can straddle midnight, so both days the window touches are read.
        let startDay = DayBoundaries.dayString(start, timeZone: timeZone)
        let endDay = DayBoundaries.dayString(end, timeZone: timeZone)
        let days = Set([startDay, endDay])
        let store = ActivityBlockStore(db)
        let blocks = try days.sorted()
            .flatMap { try store.fetch(day: $0) }
            .filter { $0.endAt > start && $0.startAt < end }
            .sorted { $0.startAt < $1.startAt }
            .map { (block: ActivityBlock) -> NowBlock in
                let inside: TimeInterval = min(block.endAt, end)
                    .timeIntervalSince(max(block.startAt, start))
                let minutes = Int((inside / 60).rounded())
                return NowBlock(
                    appKey: block.appKey, taskKey: block.taskKey, minutes: minutes,
                    start: block.startAt, end: block.endAt
                )
            }

        // Just after midnight the newest screenshot still lives under yesterday's day
        // string, so the window's start day is read when the end day has nothing.
        let captures = CaptureStore(db)
        var lastFrame = try captures.fetchLastFrame(day: endDay, timeZone: timeZone)
        if lastFrame == nil, startDay != endDay {
            lastFrame = try captures.fetchLastFrame(day: startDay, timeZone: timeZone)
        }
        let gap = lastFrame.map { Int((end.timeIntervalSince($0.at) / 60).rounded()) }
        let note: String?
        if let gap, gap > minutes {
            note = "The most recent screenshot is older than this window: nothing is being captured right now."
        } else if lastFrame == nil {
            note = "No screenshot has been taken today."
        } else if recent.isEmpty {
            note = "Nothing in this window has been summarized yet."
        } else {
            note = nil
        }

        return try StatsAggregator.prettyJSON(NowAnswer(
            window: NowWindow(minutes: minutes, from: start, to: end),
            appKey: front?.description.appKey,
            appName: front?.appName,
            project: project,
            blocks: blocks,
            lastScreenshotAt: lastFrame?.at,
            minutesSinceLastScreenshot: gap,
            note: note
        ))
    }

    // MARK: - span

    static func spanTool(
        db: Database, taxonomy: TaxonomyStore, timeZone: TimeZone, config: Config
    ) -> MCPTool {
        MCPTool(
            name: "span",
            title: "The numbers over a range of days",
            description: """
                The computed numbers over an inclusive range of local days, as JSON: one line per \
                day with its tracked, active and meeting minutes, plus the range's totals and its \
                top apps, categories, projects and documents. One call instead of one `stats` call per day. \
                Each day carries its `accounting` buckets without spans, and `accounting` at the \
                top sums them over the range, for the whole days and for their windows. \
                `from` and `to` are YYYY-MM-DD and may be at most \(spanMaxDays) days apart. \
                With `by: "project"` (up to \(spanProjectMaxDays) days) it returns instead every \
                project with its screen, meeting and agent minutes, per day and by the rule that \
                decided them, an `unattributed` row with its reasons and the window's \
                `notRecorded` minutes; `project` narrows `projects` to one row and leaves \
                `unattributed`, `notRecorded` and `totals` whole-range. `reasons` and `byRule` keep \
                the allocator's own snake_case names. \
                \(ownership)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "from": .object(["type": "string", "description": "First local day, YYYY-MM-DD."]),
                    "to": .object(["type": "string", "description": "Last local day, inclusive, YYYY-MM-DD."]),
                    "by": .object([
                        "type": "string", "enum": .array(["day", "project"]),
                        "description": "day (the default) or project.",
                    ]),
                    "project": .object([
                        "type": "string",
                        "description": "With by project: one project's name or alias, as `vocabulary` lists them.",
                    ]),
                ]),
                "required": .array(["from", "to"]),
            ]),
            annotations: .read
        ) { arguments in
            let from = try arguments.day("from", timeZone: timeZone)
            let to = try arguments.day("to", timeZone: timeZone)
            guard from <= to else { throw MCPToolError("from must not be after to") }
            if let value = arguments["by"], !value.isNull, value.stringValue == nil {
                throw MCPToolError("by must be \"day\" or \"project\"")
            }
            let by = arguments.optionalString("by")?.lowercased() ?? "day"
            guard by == "day" || by == "project" else {
                throw MCPToolError("by must be \"day\" or \"project\" (got \"\(by)\")")
            }
            let days = StatsService.days(from: from, to: to, timeZone: timeZone)
            guard days.count <= (by == "project" ? spanProjectMaxDays : spanMaxDays) else {
                throw MCPToolError(
                    "\(from) to \(to) is \(days.count) days, and span covers at most \(spanMaxDays) "
                        + "by day and \(spanProjectMaxDays) by project: ask for a shorter range, "
                        + "or call `stats` with a week."
                )
            }
            var project: String?
            if let name = arguments.optionalString("project") {
                guard by == "project" else { throw MCPToolError("project works only with by: \"project\"") }
                guard let entry = taxonomy.resolveProject(hint: name) else {
                    throw MCPToolError(
                        "no project is called \"\(name)\": call `vocabulary` for the names Worklens knows"
                    )
                }
                project = entry.key
            }
            let service = StatsService(
                db,
                timeZone: timeZone,
                category: taxonomy.categoryResolver,
                projects: { taxonomy.projects },
                ignoredDomains: { taxonomy.current.ignoredDomains ?? [] },
                baseIntervals: DayAccounting.BaseIntervals(config: config)
            )
            if by == "project" {
                return try StatsAggregator.prettyJSON(service.timesheet(from: from, to: to, project: project))
            }
            return try StatsAggregator.prettyJSON(service.span(from: from, to: to))
        }
    }

    /// The project one frame was about: the catalog entry its d5 `project_key` names (#315),
    /// else its hint folded onto the catalog, else the hint as written. Nil when it named neither.
    private static func projectName(detailsJSON: String?, taxonomy: TaxonomyStore) -> String? {
        let details = TimelineFrame.details(json: detailsJSON)
        if let key = details.projectKey, let entry = taxonomy.current.project(forKey: key) {
            return entry.name
        }
        guard let hint = details.projectHint else { return nil }
        return taxonomy.resolveProject(hint: hint)?.name ?? hint
    }

    // MARK: - vocabulary

    struct VocabularyTerm: Codable, Sendable {
        var key: String
        var name: String
        /// A catalog project's `kind` (#315): `house`, `company` or `side`. Absent for an
        /// unmarked project, a hint the catalog does not know, and every category and app.
        var kind: String?
        /// The most recent local day it was seen on. Nil for something the taxonomy declares that
        /// has not turned up in the window.
        var lastSeen: String?
        var daysSeen: Int
        /// The rules you wrote on a catalog project (#324). Absent when it has none.
        var rules: VocabularyRules?

        /// snake_case on the wire, the way every tool name and argument here is, and the way
        /// #241's acceptance spells these two.
        enum CodingKeys: String, CodingKey {
            case key
            case name
            case kind
            case lastSeen = "last_seen"
            case daysSeen = "days_seen"
            case rules
        }
    }

    /// A project's domain, repo and URL-prefix rules (#324), each list absent when empty.
    struct VocabularyRules: Codable, Sendable, Equatable {
        var domains: [String]?
        var repos: [String]?
        var urlPrefixes: [String]?

        enum CodingKeys: String, CodingKey {
            case domains, repos
            case urlPrefixes = "url_prefixes"
        }

        init?(_ entry: ProjectEntry) {
            func list(_ kind: ProjectRuleKind) -> [String]? {
                let values = kind.values(on: entry)
                return values.isEmpty ? nil : values
            }
            // The house's domains are your own (#318), never a rule.
            domains = entry.kind == .house ? nil : list(.domain)
            repos = list(.repo)
            urlPrefixes = list(.urlPrefix)
            if domains == nil, repos == nil, urlPrefixes == nil { return nil }
        }
    }

    struct VocabularyAnswer: Codable, Sendable {
        var from: String
        var to: String
        var projects: [VocabularyTerm]
        var categories: [VocabularyTerm]
        var apps: [VocabularyTerm]
    }

    static func vocabularyTool(db: Database, taxonomy: TaxonomyStore, timeZone: TimeZone) -> MCPTool {
        MCPTool(
            name: "vocabulary",
            title: "The names Worklens knows",
            description: """
                The projects, categories and app keys this install actually knows, each with the \
                most recent day it was seen on and how many days it was seen. Call it before \
                filtering a `search` or reading a `span`, so you use a name that exists instead of \
                guessing one. `days` is how far back to look, default \(vocabularyDefaultDays). \
                A catalog project lists the domain, repo and URL-prefix `rules` the user wrote. \
                Nothing here writes: when the user wants a project's time corrected, suggest the \
                command for a terminal or Claude Code, with `--dry-run` so they see the minutes \
                first: `worklens projects rule add --domain <domain> --project <key> --dry-run`, \
                or `worklens projects assign --from <local time> --to <local time> --project <key> --dry-run`. \
                \(ownership)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "days": .object([
                        "type": "integer",
                        "description": .string("How many days back to look, counting today. Default \(vocabularyDefaultDays), max \(vocabularyMaxDays)."),
                    ]),
                ]),
            ]),
            annotations: .read
        ) { arguments in
            let days = try arguments.int(
                "days", default: vocabularyDefaultDays, range: 1...vocabularyMaxDays
            )
            guard let range = dayRange(back: days, timeZone: timeZone) else {
                throw MCPToolError("days must be between 1 and \(vocabularyMaxDays)")
            }
            let window = StatsService.days(
                from: range.lowerBound, to: range.upperBound, timeZone: timeZone
            )

            // Apps and categories come from the blocks, which is what the timeline and the stats
            // are built from; projects come from what the describer named on each frame.
            var appDays: [String: Set<String>] = [:]
            for block in try ActivityBlockStore(db)
                .fetchRange(from: range.lowerBound, to: range.upperBound) where block.source == .screen {
                appDays[block.appKey, default: []].insert(block.day)
            }
            var categoryDays: [String: Set<String>] = [:]
            let category = taxonomy.categoryResolver
            for (appKey, seen) in appDays {
                guard let name = category(appKey) else { continue }
                categoryDays[name, default: []].formUnion(seen)
            }

            var projectDays: [String: Set<String>] = [:]
            var projectNames: [String: String] = [:]
            let descriptions = DescriptionStore(db)
            for day in window {
                // #315: a d5 frame's key outranks its hint; a key the catalog lost falls back.
                var keyed: Set<String> = []
                for (captureID, key) in try descriptions.projectKeys(day: day, timeZone: timeZone) {
                    guard let entry = taxonomy.current.project(forKey: key) else { continue }
                    keyed.insert(captureID)
                    projectNames[entry.key] = entry.name
                    projectDays[entry.key, default: []].insert(day)
                }
                for (captureID, hint) in try descriptions.projectHints(day: day, timeZone: timeZone)
                where !keyed.contains(captureID) {
                    let entry = taxonomy.resolveProject(hint: hint)
                    let key = entry?.key ?? ProjectEntry.fold(hint)
                    projectNames[key] = entry?.name ?? hint
                    projectDays[key, default: []].insert(day)
                }
            }
            // The taxonomy's own project list, so a name that exists but was not used this month
            // is still offered rather than guessed at.
            for project in taxonomy.projects where projectNames[project.key] == nil {
                projectNames[project.key] = project.name
                projectDays[project.key] = []
            }

            var projectKinds: [String: String] = [:]
            var projectRules: [String: VocabularyRules] = [:]
            for project in taxonomy.projects {
                projectKinds[project.key] = project.kind?.rawValue
                projectRules[project.key] = VocabularyRules(project)
            }

            func terms(
                _ seen: [String: Set<String>], names: [String: String] = [:], kinds: [String: String] = [:],
                rules: [String: VocabularyRules] = [:]
            ) -> [VocabularyTerm] {
                seen.map { key, days in
                    VocabularyTerm(
                        key: key,
                        name: names[key] ?? key,
                        kind: kinds[key],
                        lastSeen: days.max(),
                        daysSeen: days.count,
                        rules: rules[key]
                    )
                }
                .sorted { ($0.daysSeen, $1.key) > ($1.daysSeen, $0.key) }
            }

            return try StatsAggregator.prettyJSON(VocabularyAnswer(
                from: range.lowerBound,
                to: range.upperBound,
                projects: terms(projectDays, names: projectNames, kinds: projectKinds, rules: projectRules),
                categories: terms(categoryDays),
                apps: terms(appDays)
            ))
        }
    }

    // MARK: - Helpers

    /// `back` days counting today, as the inclusive day range `SearchService` takes. Nil means "everything", which is what `days: 0` asks for.
    private static func dayRange(back: Int, timeZone: TimeZone) -> ClosedRange<String>? {
        guard back > 0 else { return nil }
        let today = Date()
        let first = today.addingTimeInterval(-Double(back - 1) * 86_400)
        let from = DayBoundaries.dayString(first, timeZone: timeZone)
        return from...DayBoundaries.dayString(today, timeZone: timeZone)
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func clock(_ timeZone: TimeZone) -> DateFormatter {
        formatter("yyyy-MM-dd HH:mm", timeZone)
    }

    private static func time(_ timeZone: TimeZone) -> DateFormatter {
        formatter("HH:mm", timeZone)
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
