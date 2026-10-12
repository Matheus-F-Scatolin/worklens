import Foundation
import Testing
@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!
private let day = "2026-09-07"

private func row(
    _ id: String, _ kind: OutputKind, hour: Int, repo: String = "acme/widgets", number: Int = 12,
    projectKey: String? = nil
) -> Output {
    Output(
        kind: kind, at: GHFixtures.date("2026-09-07T\(String(format: "%02d", hour)):00:00Z"),
        repo: repo, number: number, url: "https://github.com/\(repo)/pull/\(number)",
        title: "Title \(id)", externalId: id, projectKey: projectKey,
        provenance: "gh search prs", syncedAt: GHFixtures.syncedAt
    )
}

private let rows = [
    row("a", .prMerged, hour: 10),
    row("b", .prMerged, hour: 11, number: 13),
    row("c", .issueOpened, hour: 12, number: 5),
    row("d", .reviewSubmitted, hour: 13, repo: "other/thing", number: 40),
]

private let projects = [ProjectEntry(key: "widgets", name: "Widgets", aliases: ["widget app"])]

@Suite("ShippedSection")
struct ShippedSectionTests {
    @Test("rows group under the project their repo names, else under the repo")
    func groups() {
        let groups = ShippedSection.groups(rows, projects: projects)
        #expect(groups.map(\.name) == ["Widgets", "other/thing"])
        #expect(groups[0].outputs.count == 3)
        // A project key wins over the repo.
        let keyed = row("e", .prMerged, hour: 9, repo: "other/thing", projectKey: "widgets")
        #expect(ShippedSection.groupName(for: keyed, projects: projects) == "Widgets")
    }

    @Test("a key merged into another project groups and filters under the target")
    func mergedKey() {
        // `ProjectCatalog.merge` keeps the source key as an alias of the target.
        let merged = [ProjectEntry(key: "widgets", name: "Widgets", aliases: ["old-widgets"])]
        let stale = row("m", .prMerged, hour: 9, repo: "other/thing", projectKey: "old-widgets")
        #expect(ShippedSection.groupName(for: stale, projects: merged) == "Widgets")
        #expect(ShippedSection.groups([stale, rows[0]], projects: merged).map(\.name) == ["Widgets"])
        #expect(ShippedSection.matches(stale, filter: "Widgets", projects: merged))
        #expect(ShippedSection.matches(stale, filter: "widgets", projects: merged))
        #expect(ShippedSection.matches(stale, filter: "old-widgets", projects: merged))
    }

    @Test("a repo's dashes, underscores and dots read as spaces against project names")
    func spacedRepoNames() {
        let named = [ProjectEntry(key: "my-app", name: "My App")]
        for repo in ["me/my-app", "me/my_app", "me/My.App"] {
            #expect(ShippedSection.groupName(for: row("s", .prMerged, hour: 9, repo: repo), projects: named) == "My App")
        }
        #expect(ShippedSection.groupName(for: row("t", .prMerged, hour: 9, repo: "me/other-app"), projects: named)
            == "me/other-app")
    }

    @Test("a repo rule outranks a project named like the repo, as it does for span (#324)")
    func repoRule() {
        let ruled = projects + [ProjectEntry(key: "beta", name: "Beta", rules: ProjectRules(repos: ["ACME/Widgets"]))]
        #expect(ShippedSection.groups(rows, projects: ruled).map(\.name) == ["Beta", "other/thing"])
        #expect(ShippedSection.groupName(for: rows[0], projects: ruled) == "Beta")
        #expect(ShippedSection.matches(rows[0], filter: "beta", projects: ruled))
        #expect(ShippedSection.matches(rows[0], filter: "Beta", projects: ruled))
        #expect(!ShippedSection.matches(rows[3], filter: "beta", projects: ruled))
        // A project key something attributed still wins over the rule.
        let keyed = row("e", .prMerged, hour: 9, projectKey: "widgets")
        #expect(ShippedSection.groupName(for: keyed, projects: ruled) == "Widgets")
    }

    @Test("counts are per kind and never summed")
    func counts() {
        #expect(ShippedSection.countsLine(rows) == "2 PRs merged · 1 issue opened · 1 review")
        let unknown = row("m", OutputKind(rawValue: "memo_published"), hour: 9)
        #expect(ShippedSection.countsLine([unknown]) == "1 memo published")
    }

    @Test("a filter matches the project, the repo or its short name")
    func filter() {
        #expect(rows.filter { ShippedSection.matches($0, filter: "widgets", projects: projects) }.count == 3)
        #expect(rows.filter { ShippedSection.matches($0, filter: "Other/Thing", projects: projects) }.count == 1)
        #expect(rows.filter { ShippedSection.matches($0, filter: "thing", projects: []) }.count == 1)
        #expect(rows.filter { ShippedSection.matches($0, filter: "nope", projects: projects) }.isEmpty)
    }

    // MARK: Timeline

    private let meeting = ContextEvent(
        source: .granola, externalId: "g1",
        startAt: GHFixtures.date("2026-09-07T14:00:00Z"), endAt: GHFixtures.date("2026-09-07T15:00:00Z"),
        title: "Weekly sync", isMeeting: true
    )
    private let block = ActivityBlock(
        day: day, startAt: GHFixtures.date("2026-09-07T09:00:00Z"),
        endAt: GHFixtures.date("2026-09-07T09:30:00Z"), appKey: "xcode", taskKey: "coding",
        title: "Worklens", captureCount: 30, source: .screen
    )

    @Test("## Shipped sits right before ## Context")
    func timelinePlacement() throws {
        let markdown = TimelineRenderer.render(
            day: day, blocks: [block], contextEvents: [meeting], outputs: rows,
            projects: projects, timeZone: utc
        )
        let shipped = try #require(markdown.range(of: "## Shipped"))
        let context = try #require(markdown.range(of: "## Context"))
        #expect(shipped.lowerBound < context.lowerBound)
        #expect(markdown.contains("Widgets: 2 PRs merged · 1 issue opened"))
        #expect(markdown.contains("- 10:00 merged acme/widgets#12: Title a"))
        #expect(markdown.contains("- 13:00 reviewed other/thing#40: Title d"))
        // Nothing between the shipped list and the context heading but a blank line.
        let between = markdown[shipped.upperBound..<context.lowerBound]
        #expect(between.hasSuffix("Title d\n\n"))
    }

    @Test("a day with only outputs renders them instead of 'Nothing recorded'")
    func outputsOnlyDay() {
        let markdown = TimelineRenderer.render(day: day, blocks: [], outputs: rows, timeZone: utc)
        #expect(markdown.contains("## Shipped"))
        #expect(!markdown.contains("Nothing recorded for this day."))
    }

    @Test("a day without outputs renders byte for byte as it did before")
    func noOutputsUnchanged() {
        let before = TimelineRenderer.render(
            day: day, blocks: [block], contextEvents: [meeting], timeZone: utc
        )
        let after = TimelineRenderer.render(
            day: day, blocks: [block], contextEvents: [meeting], outputs: [], timeZone: utc
        )
        #expect(before == after)
        #expect(!after.contains("Shipped"))
        #expect(TimelineRenderer.render(day: day, blocks: [], outputs: [], timeZone: utc)
            .contains("Nothing recorded for this day."))
    }

    @Test("the writer reads the day's outputs into the markdown")
    func writer() throws {
        let db = try Database.inMemory()
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-shipped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        var config = Config.defaults()
        config.dataDir = dataDir
        for output in rows { try OutputStore(db).upsert(output) }
        let writer = TimelineWriter(
            config: config, db: db, taxonomy: try TaxonomyStore(dataDir: dataDir), timeZone: utc
        )
        #expect(try writer.markdown(day: day).contains("## Shipped"))
    }

    // MARK: MCP

    private func registry() throws -> (MCPToolRegistry, Database) {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-shipped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        var config = Config.defaults()
        config.dataDir = dataDir
        let db = try Database.inMemory()
        for output in rows { try OutputStore(db).upsert(output) }
        let registry = WorklensMCPTools.registry(
            config: config, db: db, taxonomy: try TaxonomyStore(dataDir: dataDir), timeZone: utc
        )
        return (registry, db)
    }

    @Test("shipped is the ninth tool, and read-only")
    func declared() throws {
        let (registry, _) = try registry()
        #expect(registry.tools.count == 10)
        #expect(registry.tools[8].name == "shipped")
        let tool = try #require(registry.tool(named: "shipped"))
        #expect(tool.annotations == .read)
        #expect(tool.description.contains("YYYY-MM-DD"))
        #expect(tool.description.contains("your own"))
    }

    @Test("shipped prints per-kind counts, the status and one line per item, with no total")
    func answer() throws {
        let (registry, _) = try registry()
        let result = try registry.call(name: "shipped", arguments: .object(["from": .string(day), "to": .string(day)]))
        #expect(!result.isError)
        let text = result.text
        #expect(text.hasPrefix("Shipped between 2026-09-07 and 2026-09-07: 2 PRs merged · 1 issue opened · 1 review."))
        #expect(text.contains("GitHub never synced."))
        #expect(text.contains("2026-09-07 10:00 merged acme/widgets#12: Title a https://github.com/acme/widgets/pull/12"))
        // Four rows, and no number that adds them up.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "Shipped between 2026-09-07 and 2026-09-07: \(ShippedSection.countsLine(rows)).")
        for line in lines {
            #expect(!line.hasPrefix("4 ") && !line.contains(" 4 "), "\(line)")
        }
        #expect(!text.lowercased().contains("total"))
    }

    @Test("timeline shows a day that has shipped outputs but no activity")
    func timelineWithoutBlocks() throws {
        let (registry, _) = try registry()
        let text = try registry.call(name: "timeline", arguments: .object(["day": .string(day)])).text
        #expect(text.contains("## Shipped"))
        #expect(!text.contains("No timeline for"))
    }

    @Test("shipped filters by project or repo")
    func projectFilter() throws {
        let (registry, _) = try registry()
        let other = try registry.call(name: "shipped", arguments: .object([
            "from": .string(day), "to": .string(day), "project": "other/thing",
        ])).text
        #expect(other.contains("1 review"))
        #expect(!other.contains("acme/widgets"))
        let none = try registry.call(name: "shipped", arguments: .object([
            "from": .string(day), "to": .string(day), "project": "nope",
        ])).text
        #expect(none.hasPrefix("Nothing shipped for nope between"))
    }

    @Test("shipped refuses from after to, and more than 31 days")
    func bounds() throws {
        let (registry, _) = try registry()
        let backwards = try registry.call(name: "shipped", arguments: .object(["from": "2026-09-08", "to": "2026-09-07"]))
        #expect(backwards.isError)
        #expect(backwards.text.contains("from must not be after to"))
        let long = try registry.call(name: "shipped", arguments: .object(["from": "2026-08-01", "to": "2026-09-07"]))
        #expect(long.isError)
        #expect(long.text.contains("at most 31"))
        let month = try registry.call(name: "shipped", arguments: .object(["from": "2026-08-08", "to": "2026-09-07"]))
        #expect(!month.isError)
    }
}
