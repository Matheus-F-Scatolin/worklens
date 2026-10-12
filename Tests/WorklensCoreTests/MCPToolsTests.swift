import Foundation
import Testing
@testable import WorklensCore

/// #89's seven tools, over an in-memory database and a temp `DATA_DIR`.
///
/// Days come from `DayBoundaries` in the machine's own timezone, exactly as the stores derive
/// them, so nothing here hard-codes a string — `days()` groups `captures` with SQLite's
/// `localtime`, which is the same clock.
private let nine = DayBoundaries.range(day: "2026-09-09", timeZone: .current)!
    .start.addingTimeInterval(9 * 3600)
private var fixtureDay: String { DayBoundaries.dayString(nine) }

private struct Harness {
    let dataDir: URL
    let db: Database
    let taxonomy: TaxonomyStore
    let registry: MCPToolRegistry

    init() throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        var config = Config.defaults()
        config.dataDir = dataDir

        db = try Database.inMemory()
        taxonomy = try TaxonomyStore(dataDir: dataDir)
        registry = WorklensMCPTools.registry(
            config: config, db: db, taxonomy: taxonomy, timeZone: .current
        )
    }

    /// `now` reads a window ending at the wall clock, so the tests hand it their own (#241).
    func now(at moment: Date, _ arguments: JSONValue = .object([:])) throws -> JSONValue {
        try JSONDecoder().decode(
            JSONValue.self, from: Data(nowText(at: moment, arguments).utf8)
        )
    }

    /// The same answer as raw text — what the privacy assertion reads.
    func nowText(at moment: Date, _ arguments: JSONValue = .object([:])) throws -> String {
        try WorklensMCPTools.nowTool(
            db: db, taxonomy: taxonomy, timeZone: .current, clock: { moment }
        ).handler(arguments)
    }

    /// One described frame, indexed for search, plus the `activity_blocks` row over it.
    func frame(
        minute: Double, summary: String, title: String = "#general", projectHint: String? = nil
    ) throws {
        try frame(
            at: nine.addingTimeInterval(minute * 60), summary: summary, title: title,
            projectHint: projectHint
        )
    }

    /// The same frame at an arbitrary moment — what the tools that read *recent* data need.
    func frame(
        at: Date, summary: String, title: String = "#general", projectHint: String? = nil
    ) throws {
        let capture = Capture(
            capturedAt: at,
            appBundleId: "com.tinyspeck.slackmacgap",
            appName: "Slack",
            windowTitle: title,
            describeStatus: .described
        )
        try CaptureStore(db).insert(capture)
        try DescriptionStore(db).insert(Description(
            captureId: capture.id, provider: "gemini", model: "gemini-3.5-flash-lite",
            appKey: "slack", taskKey: "reading_messages", summaryMd: summary,
            detailsJson: projectHint.map { #"{"project_hint":"\#($0)"}"# }, createdAt: at
        ))
    }

    /// A block over an arbitrary interval, on the day its start falls in.
    func block(from: Date, to: Date) throws {
        try ActivityBlockStore(db).upsert(ActivityBlock(
            day: DayBoundaries.dayString(from),
            startAt: from, endAt: to,
            appKey: "slack", taskKey: "reading_messages", title: "#general",
            captureCount: 4, source: .screen, createdAt: from, updatedAt: from
        ))
    }

    func block(fromMinute: Double, toMinute: Double) throws {
        try ActivityBlockStore(db).upsert(ActivityBlock(
            day: fixtureDay,
            startAt: nine.addingTimeInterval(fromMinute * 60),
            endAt: nine.addingTimeInterval(toMinute * 60),
            appKey: "slack", taskKey: "reading_messages", title: "#general",
            captureCount: 4, source: .screen, createdAt: nine, updatedAt: nine
        ))
    }

    /// Runs a tool the way `tools/call` would, and requires it to have succeeded.
    func call(_ name: String, _ arguments: JSONValue = .object([:])) throws -> String {
        let result = try registry.call(name: name, arguments: arguments)
        #expect(!result.isError, "\(name) failed: \(result.text)")
        return result.text
    }

    /// Runs a tool and requires it to have failed, returning the message.
    func failure(_ name: String, _ arguments: JSONValue) throws -> String {
        let result = try registry.call(name: name, arguments: arguments)
        #expect(result.isError, "\(name) unexpectedly succeeded: \(result.text)")
        return result.text
    }
}

@Suite("MCP tools")
struct MCPToolsTests {
    @Test("the registry declares the read-only tools, each with a schema and a day format")
    func declaration() throws {
        let harness = try Harness()
        #expect(harness.registry.tools.map(\.name).sorted()
            == ["agent_sessions", "context_events", "days", "now", "search", "shipped", "span", "stats",
                "timeline", "vocabulary"])
        for tool in harness.registry.tools {
            #expect(tool.inputSchema["type"]?.stringValue == "object")
            // Whose data this is, in every description a client shows a model.
            #expect(tool.description.contains("your own"))
            // #241: what a client shows a person, and the badge it shows it behind.
            #expect(tool.title?.isEmpty == false)
            #expect(tool.annotations == .read)
        }
        // The five prompts ride on the same registry, with the sentence about what to ask.
        #expect(harness.registry.prompts.count == 5)
        #expect(harness.registry.instructions == "Ask about the timeline and the stats.")
        // The three tools that take a day say the format out loud.
        for name in ["timeline", "stats", "context_events"] {
            let tool = try #require(harness.registry.tool(named: name))
            #expect(tool.description.contains("YYYY-MM-DD"))
        }
        // `stats` is where a client learns the rule names `byRule` and `projectSpans` carry.
        let stats = try #require(harness.registry.tool(named: "stats"))
        for rule in ProjectSpan.Rule.allCases {
            #expect(stats.description.contains(rule.rawValue), "stats does not name \(rule.rawValue)")
        }
    }

    @Test("search finds a frame by its description and names the day to follow up on")
    func search() throws {
        let harness = try Harness()
        try harness.frame(minute: 5, summary: "Reading the lyrics thread in #general.")
        try harness.frame(minute: 40, summary: "Reviewing a pull request.")

        let text = try harness.call("search", .object(["query": "lyrics", "days": 0]))
        #expect(text.contains("1 hit(s)"))
        #expect(text.contains("day: \(fixtureDay)"))
        #expect(text.contains("lyrics thread"))
        #expect(!text.contains("pull request"))

        let empty = try harness.call("search", .object(["query": "kayak", "days": 0]))
        #expect(empty.contains("No screenshots match"))
    }

    @Test("search takes its bounds as strings too, and refuses one out of range")
    func searchBounds() throws {
        let harness = try Harness()
        try harness.frame(minute: 5, summary: "Reading the lyrics thread.")
        #expect(try harness.call("search", .object(["query": "lyrics", "limit": "1", "days": "0"]))
            .contains("1 hit(s)"))
        #expect(try harness.failure("search", .object(["query": "lyrics", "limit": 0]))
            .contains("limit must be between"))
        #expect(try harness.failure("search", .object(["query": " "])).contains("query is required"))
    }

    @Test("search narrows to a project or an app, and says what the filter kept out")
    func searchFilters() throws {
        let harness = try Harness()
        try harness.frame(minute: 5, summary: "Reading the lyrics thread.", projectHint: "Acme")
        try harness.frame(minute: 40, summary: "Reading the payments thread.", projectHint: "Beta")

        let narrowed = try harness.call(
            "search", .object(["query": "thread", "days": 0, "project": "acme"])
        )
        #expect(narrowed.contains("1 hit(s)"))
        #expect(narrowed.contains("project \"acme\""))
        #expect(narrowed.contains("lyrics"))
        #expect(!narrowed.contains("payments"))
        #expect(narrowed.contains("1 other matching screenshot(s) were outside that filter"))

        // An app filter matches the taxonomy key as well as the name macOS reported.
        #expect(try harness.call("search", .object(["query": "thread", "days": 0, "app": "slack"]))
            .contains("2 hit(s)"))
        let nothing = try harness.call(
            "search", .object(["query": "thread", "days": 0, "project": "gamma"])
        )
        #expect(nothing.contains("No screenshots match"))
        #expect(nothing.contains("2 other matching screenshot(s)"))
    }

    @Test("now names the app in front, the minutes in the window and the last screenshot")
    func now() throws {
        let harness = try Harness()
        try harness.frame(minute: 0, summary: "Reading #general.", projectHint: "Acme")
        try harness.frame(minute: 10, summary: "Still reading #general.", projectHint: "Acme")
        try harness.block(fromMinute: 0, toMinute: 18)

        let answer = try harness.now(at: nine.addingTimeInterval(20 * 60))
        #expect(answer["appKey"]?.stringValue == "slack")
        #expect(answer["appName"]?.stringValue == "Slack")
        #expect(answer["project"]?.stringValue == "Acme")
        #expect(answer["window"]?["minutes"]?.intValue == WorklensMCPTools.nowDefaultMinutes)
        #expect(answer["blocks"]?.arrayValue?.count == 1)
        #expect(answer["blocks"]?[0]?["minutes"]?.intValue == 18)
        #expect(answer["lastScreenshotAt"]?.stringValue != nil)
        #expect(answer["minutesSinceLastScreenshot"]?.intValue == 10)
        // Never a window title, a URL or a summary: #241's privacy line. Read at the same
        // moment as above, so the assertion sees an answer that actually has the blocks in it.
        let raw = try harness.nowText(at: nine.addingTimeInterval(20 * 60))
        #expect(raw.contains("slack"))
        #expect(!raw.contains("#general"))

        // A window that ends long after the last screenshot says the capture gap out loud.
        let later = try harness.now(at: nine.addingTimeInterval(600 * 60), .object(["minutes": 30]))
        #expect(later["note"]?.stringValue?.contains("nothing is being captured") == true)
        #expect(later["blocks"]?.arrayValue?.isEmpty == true)

        // Just after midnight the newest screenshot is still filed under yesterday, and the
        // window reaches back into it: the gap is real, not "no screenshot today".
        let midnight = DayBoundaries.range(day: fixtureDay, timeZone: .current)!.end
        try harness.frame(at: midnight.addingTimeInterval(-5 * 60), summary: "Reading late.")
        let past = try harness.now(at: midnight.addingTimeInterval(20 * 60))
        #expect(past["minutesSinceLastScreenshot"]?.intValue == 25)
        #expect(past["note"]?.stringValue == nil)
    }

    @Test("span adds up the same numbers as one stats call per day, and refuses a long range")
    func span() throws {
        let harness = try Harness()
        try harness.block(fromMinute: 0, toMinute: 18)
        try harness.frame(minute: 5, summary: "Reading #general.")
        let nextDay = nine.addingTimeInterval(24 * 3600)
        try harness.frame(at: nextDay, summary: "Reading #general again.")
        try harness.block(from: nextDay, to: nextDay.addingTimeInterval(30 * 60))

        let last = DayBoundaries.dayString(nine.addingTimeInterval(6 * 24 * 3600))
        let text = try harness.call("span", .object(["from": .string(fixtureDay), "to": .string(last)]))
        let answer = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(answer["days"]?.arrayValue?.count == 7)

        let service = StatsService(
            harness.db, timeZone: .current,
            category: harness.taxonomy.categoryResolver,
            projects: { harness.taxonomy.projects }
        )
        let summed = try StatsService.days(from: fixtureDay, to: last)
            .reduce(0) { try $0 + service.daily(day: $1).trackedMinutes }
        #expect(answer["trackedMinutes"]?.intValue == summed)
        #expect(summed > 0)
        #expect(answer["daysWithActivity"]?.intValue == 2)
        #expect(answer["byApp"]?[0]?["key"]?.stringValue == "slack")

        #expect(try harness.failure("span", .object(["from": "2026-01-01", "to": "2026-12-31"]))
            .contains("at most \(WorklensMCPTools.spanMaxDays)"))
        #expect(try harness.failure("span", .object(["from": .string(last), "to": .string(fixtureDay)]))
            .contains("must not be after"))
    }

    @Test("vocabulary lists the projects and app keys that were actually used, with a last seen")
    func vocabulary() throws {
        let harness = try Harness()
        // Recent on purpose: this is the one tool whose window is measured from today.
        let earlier = Date().addingTimeInterval(-90 * 60)
        try harness.frame(at: earlier, summary: "Reading #general.", projectHint: "Acme")
        try harness.block(from: earlier, to: earlier.addingTimeInterval(30 * 60))

        let text = try harness.call("vocabulary", .object([:]))
        let answer = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let today = DayBoundaries.dayString(earlier)
        let projects = try #require(answer["projects"]?.arrayValue)
        let acme = try #require(projects.first { $0["name"]?.stringValue == "Acme" })
        // snake_case on the wire, like every tool and argument name here (#241).
        #expect(acme["last_seen"]?.stringValue == today)
        #expect(acme["days_seen"]?.intValue == 1)
        let apps = try #require(answer["apps"]?.arrayValue)
        #expect(apps.contains { $0["key"]?.stringValue == "slack" })
        // A vocabulary looks further back than a span does, and says how far when it refuses.
        #expect(try harness.call("vocabulary", .object(["days": 90])).contains("projects"))
        #expect(
            try harness.failure("vocabulary", .object(["days": 400]))
                .contains("must be between 1 and \(WorklensMCPTools.vocabularyMaxDays)"))
    }

    @Test("timeline renders the day's blocks, and says so when a day has none")
    func timeline() throws {
        let harness = try Harness()
        try harness.frame(minute: 5, summary: "Reading #general.")
        try harness.block(fromMinute: 0, toMinute: 18)

        let text = try harness.call("timeline", .object(["day": .string(fixtureDay)]))
        #expect(text.contains("#general"))

        #expect(try harness.call("timeline", .object(["day": "2019-01-01"]))
            .contains("No timeline for 2019-01-01"))
        #expect(try harness.failure("timeline", .object(["day": "yesterday"]))
            .contains("must look like 2026-09-07"))
    }

    @Test("stats answers for a day or a week, and never for both")
    func stats() throws {
        let harness = try Harness()
        try harness.frame(minute: 5, summary: "Reading #general.")
        try harness.block(fromMinute: 0, toMinute: 18)

        let daily = try harness.call("stats", .object(["day": .string(fixtureDay)]))
        #expect(daily.contains("\"day\" : \"\(fixtureDay)\""))

        let week = try #require(ISOWeek.containing(dayString: fixtureDay))
        let weekly = try harness.call("stats", .object(["week": .string(week.identifier)]))
        #expect(weekly.contains(week.start))

        #expect(try harness.failure("stats", .object(["day": .string(fixtureDay), "week": "2026-W37"]))
            .contains("not both"))
        #expect(try harness.failure("stats", .object(["week": "week 37"])).contains("2026-W37"))
    }

    @Test("context_events cuts a long body and filters by source")
    func contextEvents() throws {
        let harness = try Harness()
        let store = ContextEventStore(harness.db)
        try store.upsert(ContextEvent(
            source: .granola, externalId: "n1",
            startAt: nine, endAt: nine.addingTimeInterval(3600),
            title: "Weekly sync",
            participantsJson: #"["ana","bruno"]"#,
            bodyMd: String(repeating: "transcript ", count: 400),
            isMeeting: true, syncedAt: nine
        ))
        try store.upsert(ContextEvent(
            source: .calendar, externalId: "c1", startAt: nine.addingTimeInterval(120),
            title: "Ship review", bodyMd: "shipped it", syncedAt: nine
        ))

        let all = try harness.call("context_events",
                                   .object(["from": .string(fixtureDay), "to": .string(fixtureDay)]))
        #expect(all.contains("2 event(s)"))
        #expect(all.contains("Weekly sync"))
        #expect(all.contains("participants: ana, bruno"))
        // The Granola body is cut, not returned whole.
        #expect(all.count < 4400)
        #expect(all.contains("…"))

        let granolaOnly = try harness.call("context_events", .object([
            "from": .string(fixtureDay), "to": .string(fixtureDay), "sources": .array(["granola"]),
        ]))
        #expect(granolaOnly.contains("1 event(s)"))
        #expect(!granolaOnly.contains("shipped it"))

        #expect(try harness.failure("context_events", .object([
            "from": .string(fixtureDay), "to": .string(fixtureDay), "sources": .array(["notion"]),
        ])).contains("sources must be"))
        #expect(try harness.call("context_events", .object(["from": "2019-01-01", "to": "2019-01-02"]))
            .contains("No context events"))
    }

    @Test("days lists the days that have frames")
    func days() throws {
        let harness = try Harness()
        #expect(try harness.call("days").contains("No days have data yet"))

        try harness.frame(minute: 5, summary: "Reading #general.")
        try harness.frame(minute: 6, summary: "Still reading.")
        let days = try harness.call("days")
        #expect(days.contains("| day | frames | described | headline |"))
        #expect(days.contains("| \(fixtureDay) | 2 | 2 |"))
    }

    @Test("nothing a tool is handed reaches a log above debug")
    func argumentsAreNotLogged() throws {
        // The guard is structural — no tool closure calls `Log` at all — so this is the check that
        // keeps it that way: a search term is window content (#89 §3).
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/WorklensCore/MCP/WorklensMCPTools.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("Log."))
    }
}

// MARK: - d5 project keys (#315)

@Suite("WorklensMCPTools project kinds (#315)")
struct MCPProjectKindTests {
    @Test("vocabulary names a keyed frame by its entry and shows each project's kind")
    func vocabularyShowsKind() throws {
        let harness = try Harness()
        var taxonomy = harness.taxonomy.current
        taxonomy.projects = [
            ProjectEntry(key: "firm", name: "Firm", kind: .house),
            ProjectEntry(key: "acme", name: "Acme Corp", kind: .company),
            ProjectEntry(key: "misc", name: "Misc"),
        ]
        try harness.taxonomy.save(taxonomy)

        let earlier = Date().addingTimeInterval(-90 * 60)
        // A d5 frame that named only a key, and a d4 frame that named only a hint.
        let keyed = Capture(capturedAt: earlier, appName: "Slack", windowTitle: "#general", describeStatus: .described)
        try CaptureStore(harness.db).insert(keyed)
        try DescriptionStore(harness.db).insert(Description(
            captureId: keyed.id, provider: "gemini", model: "gemini-3.5-flash-lite",
            appKey: "slack", taskKey: "reading_messages", summaryMd: "Reads the board thread.",
            detailsJson: #"{"project_key":"acme"}"#, createdAt: earlier
        ))
        try harness.frame(at: earlier.addingTimeInterval(60), summary: "Reads mail.", projectHint: "Misc")

        let text = try harness.call("vocabulary", .object([:]))
        let answer = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let projects = try #require(answer["projects"]?.arrayValue)
        let acme = try #require(projects.first { $0["name"]?.stringValue == "Acme Corp" })
        #expect(acme["kind"]?.stringValue == "company")
        let misc = try #require(projects.first { $0["name"]?.stringValue == "Misc" })
        #expect(misc["kind"]?.stringValue == nil)
    }
}

// MARK: - Time per document (#319)

@Suite("WorklensMCPTools time per document (#319)")
struct MCPDocumentTimeTests {
    /// A Chrome frame on a PR page, and a VS Code frame whose window reported a local file.
    private func seed(_ harness: Harness) throws {
        try harness.block(fromMinute: 0, toMinute: 20)
        let page = Capture(
            capturedAt: nine.addingTimeInterval(5 * 60), appName: "Chrome", windowTitle: "Fix it",
            browserUrl: "https://github.com/Owner/Repo/pull/12", describeStatus: .described
        )
        let editor = Capture(
            capturedAt: nine.addingTimeInterval(15 * 60), appName: "Code", windowTitle: "a.md",
            describeStatus: .described
        )
        try CaptureStore(harness.db).insert(page)
        try CaptureStore(harness.db).insert(editor)
        try AXSnapshotStore(harness.db).insert(AXSnapshotRecord(
            captureId: editor.id, coverage: .full, textHash: "h", documentUrl: "file:///tmp/notes/a.md"
        ))
    }

    @Test("stats names the documents you had open, and span merges them by key")
    func statsAndSpan() throws {
        let harness = try Harness()
        try seed(harness)
        let text = try harness.call("stats", .object(["day": .string(fixtureDay)]))
        let answer = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let rows = try #require(answer["byDocument"]?.arrayValue)
        #expect(rows.compactMap { $0["key"]?.stringValue }.sorted()
            == ["file:/tmp/notes/a.md", "github.com/owner/repo/pull/12"])
        #expect(rows.allSatisfy { $0["minutes"]?.intValue == 10 })

        let span = try harness.call("span", .object(["from": .string(fixtureDay), "to": .string(fixtureDay)]))
        let spanAnswer = try JSONDecoder().decode(JSONValue.self, from: Data(span.utf8))
        #expect(spanAnswer["byDocument"]?.arrayValue?.count == 2)
    }

    @Test("span adds one PR's minutes across two days into one row")
    func spanMergesAcrossDays() throws {
        let harness = try Harness()
        try seed(harness)
        let nextNine = try #require(Calendar.current.date(byAdding: .day, value: 1, to: nine))
        try harness.block(from: nextNine, to: nextNine.addingTimeInterval(10 * 60))
        try CaptureStore(harness.db).insert(Capture(
            capturedAt: nextNine.addingTimeInterval(5 * 60), appName: "Chrome", windowTitle: "Fix it",
            browserUrl: "https://github.com/owner/repo/pull/12/files", describeStatus: .described
        ))

        let span = try harness.call("span", .object([
            "from": .string(fixtureDay), "to": .string(DayBoundaries.dayString(nextNine)),
        ]))
        let answer = try JSONDecoder().decode(JSONValue.self, from: Data(span.utf8))
        let rows = try #require(answer["byDocument"]?.arrayValue)
        let pr = rows.filter { $0["key"]?.stringValue == "github.com/owner/repo/pull/12" }
        #expect(pr.count == 1)
        #expect(pr.first?["minutes"]?.intValue == 20)
    }

    @Test("shipped gives a PR the minutes its page was on your screen")
    func shippedScreenTime() throws {
        let harness = try Harness()
        try seed(harness)
        try OutputStore(harness.db).upsert([
            Output(
                kind: .prMerged, at: nine.addingTimeInterval(3600), repo: "owner/repo", number: 12,
                url: "https://github.com/owner/repo/pull/12", title: "Fix it", externalId: "pr12",
                provenance: "test", syncedAt: nine
            ),
            Output(
                kind: .prMerged, at: nine.addingTimeInterval(3600), repo: "owner/repo", number: 13,
                title: "Other", externalId: "pr13", provenance: "test", syncedAt: nine
            ),
        ])
        let text = try harness.call("shipped", .object(["from": .string(fixtureDay), "to": .string(fixtureDay)]))
        let lines = text.split(separator: "\n")
        #expect(lines.first { $0.contains("#12") }?.hasSuffix(" · on your screen 10m") == true)
        #expect(lines.first { $0.contains("#13") }?.contains("on your screen") == false)
    }
}

@Suite("span by project (#323)")
struct MCPSpanByProjectTests {
    @Test("without by the answer is the by-day one, byte for byte")
    func defaultIsByDay() throws {
        let harness = try Harness()
        try harness.block(fromMinute: 0, toMinute: 18)
        try harness.frame(minute: 5, summary: "Reading #general.")
        let range: JSONValue = .object(["from": .string(fixtureDay), "to": .string(fixtureDay)])
        let plain = try harness.call("span", range)
        let byDay = try harness.call("span", .object([
            "from": .string(fixtureDay), "to": .string(fixtureDay), "by": "day",
        ]))
        #expect(plain == byDay)
        #expect(!plain.contains("\"by\""))
    }

    @Test("by project lists every project, project narrows to one, and an unknown name points at vocabulary")
    func byProject() throws {
        let harness = try Harness()
        var taxonomy = harness.taxonomy.current
        taxonomy.projects = [
            ProjectEntry(key: "firm", name: "Firm", kind: .house),
            ProjectEntry(key: "acme", name: "Acme Corp", kind: .company),
        ]
        try harness.taxonomy.save(taxonomy)
        try harness.block(fromMinute: 0, toMinute: 6)
        for minute in 0..<3 { try harness.frame(minute: Double(minute), summary: "Reading.", projectHint: "Acme Corp") }
        for minute in 3..<6 { try harness.frame(minute: Double(minute), summary: "Reading.", projectHint: "Firm") }

        let text = try harness.call("span", .object([
            "from": .string(fixtureDay), "to": .string(fixtureDay), "by": "project",
        ]))
        let answer = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(answer["by"]?.stringValue == "project")
        let projects = try #require(answer["projects"]?.arrayValue)
        #expect(Set(projects.compactMap { $0["key"]?.stringValue }) == ["acme", "firm"])
        #expect(projects.first { $0["key"]?.stringValue == "firm" }?["kind"]?.stringValue == "house")
        #expect(answer["unattributed"]?["breakdown"]?["screenNoProject"]?.intValue != nil)
        #expect(answer["notRecorded"]?["idle"]?.intValue != nil)
        #expect(!text.contains("#general"))

        let one = try harness.call("span", .object([
            "from": .string(fixtureDay), "to": .string(fixtureDay), "by": "project", "project": "acme corp",
        ]))
        let narrowed = try JSONDecoder().decode(JSONValue.self, from: Data(one.utf8))
        #expect(narrowed["projects"]?.arrayValue?.compactMap { $0["key"]?.stringValue } == ["acme"])
        #expect(narrowed["projects"]?[0]?["screenMinutes"]?.intValue == 3)

        let unknown = try harness.failure("span", .object([
            "from": .string(fixtureDay), "to": .string(fixtureDay), "by": "project", "project": "Nowhere",
        ]))
        #expect(unknown.contains("`vocabulary`"))
        #expect(try harness.failure("span", .object([
            "from": .string(fixtureDay), "to": .string(fixtureDay), "project": "Acme Corp",
        ])).contains("by"))
        #expect(try harness.failure("span", .object([
            "from": .string(fixtureDay), "to": .string(fixtureDay), "by": "week",
        ])).contains("by must be"))
        #expect(try harness.failure("span", .object([
            "from": .string(fixtureDay), "to": .string(fixtureDay), "by": .number(1),
        ])).contains("by must be"))
        let capitalised = try harness.call("span", .object([
            "from": .string(fixtureDay), "to": .string(fixtureDay), "by": "Project",
        ]))
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(capitalised.utf8))["by"]?.stringValue == "project")
    }

    @Test("by project takes 92 days and refuses 93; by day refuses 32")
    func caps() throws {
        let harness = try Harness()
        let from = "2026-06-01"
        func last(_ count: Int) -> String {
            DayBoundaries.dayString(
                DayBoundaries.range(day: from, timeZone: .current)!.start
                    .addingTimeInterval(Double(count - 1) * 86_400 + 3_600)
            )
        }
        #expect(StatsService.days(from: from, to: last(92)).count == 92)
        let quarter = try harness.call("span", .object(["from": .string(from), "to": .string(last(92)), "by": "project"]))
        #expect(quarter.contains("\"projects\""))
        let tooLong = try harness.failure(
            "span", .object(["from": .string(from), "to": .string(last(93)), "by": "project"])
        )
        #expect(tooLong.contains("at most \(WorklensMCPTools.spanMaxDays)"))
        #expect(tooLong.contains("\(WorklensMCPTools.spanProjectMaxDays) by project"))
        #expect(try harness.failure("span", .object(["from": .string(from), "to": .string(last(32))]))
            .contains("at most \(WorklensMCPTools.spanMaxDays)"))
        #expect(try harness.failure("span", .object(["from": .string(from), "to": .string(last(32)), "by": "day"]))
            .contains("at most \(WorklensMCPTools.spanMaxDays)"))
    }
}
