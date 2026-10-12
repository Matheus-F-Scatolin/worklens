import Foundation
import Testing
@testable import WorklensCore

// MARK: - Fixtures

private enum MemoFixtures {
    static let repo = "halyard/memos"
    static let mergedAt = GHFixtures.date("2026-09-07T13:00:00Z")

    static func merged(_ number: Int, repo: String = MemoFixtures.repo) -> Output {
        Output(
            kind: .prMerged, at: mergedAt, repo: repo, number: number,
            url: "https://github.com/\(repo)/pull/\(number)", title: "Update memos \(number)",
            resourceKey: GitHubOutputs.pullKey(repo, number), externalId: "pr:\(repo)#\(number)",
            provenance: "gh search prs --author=@me", syncedAt: GHFixtures.syncedAt
        )
    }

    static func files(_ pairs: [(String, String)]) -> Data {
        let items = pairs.map { #"{"path":"\#($0.0)","additions":3,"deletions":1,"changeType":"\#($0.1)"}"# }
        return Data(#"{"files":[\#(items.joined(separator: ","))]}"#.utf8)
    }
}

/// A `gh` that answers `pr view --json files` from a table and everything else like
/// `FakeGHRunner`.
private final class MemoGH: GHRunning, @unchecked Sendable {
    let inner = FakeGHRunner()
    private let lock = NSLock()
    private var answers: [String: Data] = [:]
    private var failures: [String: GHOutput] = [:]
    private var _reads: [String] = []

    /// `gh` refuses this PR's file list with `output`, or answers again when nil.
    func fail(_ repo: String, _ number: Int, with output: GHOutput?) {
        lock.withLock { failures["\(repo)#\(number)"] = output }
    }

    func answer(_ repo: String, _ number: Int, _ files: [(String, String)]) {
        lock.withLock { answers["\(repo)#\(number)"] = MemoFixtures.files(files) }
    }

    /// Every `repo#number` whose files were read, in order.
    var reads: [String] { lock.withLock { _reads } }

    func run(_ arguments: [String]) async throws -> GHOutput {
        guard arguments.starts(with: ["pr", "view"]), let repoIndex = arguments.firstIndex(of: "--repo") else {
            return try await inner.run(arguments)
        }
        let key = "\(arguments[repoIndex + 1])#\(arguments[2])"
        return lock.withLock {
            _reads.append(key)
            return failures[key] ?? GHOutput(status: 0, stdout: answers[key] ?? MemoFixtures.files([]))
        }
    }
}

private final class MemoLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(String, String)] = []
    func append(_ level: String, _ line: String) { lock.withLock { lines.append((level, line)) } }
    func at(_ level: String) -> [String] { lock.withLock { lines.filter { $0.0 == level }.map(\.1) } }
}

private struct MemoHarness {
    let db: Database
    let dataDir: URL
    let taxonomy: TaxonomyStore
    let gh = MemoGH()
    let lines = MemoLines()

    init(projects: [ProjectEntry] = []) throws {
        db = try Database.inMemory()
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoOutputsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        taxonomy = try TaxonomyStore(dataDir: dataDir)
        var next = taxonomy.current
        next.projects = projects
        try taxonomy.save(next)
    }

    func memo(repos: [String] = [MemoFixtures.repo]) -> MemoOutputs {
        let dir = dataDir
        let lines = lines
        return MemoOutputs(
            repos: repos, db: db, taxonomy: { try TaxonomyStore(dataDir: dir) },
            log: { level, line in lines.append(level == .info ? "info" : "debug", line) }
        )
    }

    /// The catalog as it is on disk now.
    var projects: [ProjectEntry] { ((try? TaxonomyStore(dataDir: dataDir))?.projects) ?? [] }

    func rows(_ source: String = Output.memo) throws -> [Output] {
        try OutputStore(db).outputs(from: .distantPast, to: .distantFuture).filter { $0.source == source }
    }

    @discardableResult
    func apply(_ changed: [Output], repos: [String] = [MemoFixtures.repo]) async throws -> MemoApplyResult {
        try await memo(repos: repos).apply(changed: changed, runner: gh, syncedAt: GHFixtures.syncedAt)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dataDir) }
}

// MARK: - The path rule

@Suite("MemoPathRule")
struct MemoPathRuleTests {
    @Test("ADDED publishes, MODIFIED, RENAMED and CHANGED update")
    func kinds() {
        #expect(MemoPathRule.events(files: [("corpus/companies/acme/memo.md", "ADDED")])
            == [MemoEvent(slug: "acme", kind: .memoPublished, path: "corpus/companies/acme/memo.md")])
        for change in ["MODIFIED", "RENAMED", "CHANGED"] {
            #expect(MemoPathRule.events(files: [("corpus/companies/acme/memo.md", change)]).map(\.kind)
                == [.memoUpdated])
        }
    }

    @Test(
        "html, _history, _updates, deeper paths, other roots, underscore files and DELETED give nothing",
        arguments: [
            ("corpus/companies/acme/memo.html", "MODIFIED"),
            ("corpus/companies/acme/_history/2026-09-01.md", "ADDED"),
            ("corpus/companies/acme/_updates/log.md", "ADDED"),
            ("corpus/companies/acme/notes/call.md", "ADDED"),
            ("corpus/companies/acme/_draft.md", "ADDED"),
            ("corpus/companies/acme/memo.md", "DELETED"),
            ("corpus/companies/memo.md", "ADDED"),
            ("corpus/people/acme/memo.md", "ADDED"),
            ("docs/companies/acme/memo.md", "MODIFIED"),
        ]
    )
    func nothing(path: String, change: String) {
        #expect(MemoPathRule.events(files: [(path, change)]).isEmpty)
    }

    @Test("two companies give two events, add plus modify gives one publish")
    func perCompany() {
        let events = MemoPathRule.events(files: [
            ("corpus/companies/acme/memo.md", "MODIFIED"),
            ("corpus/companies/beta-labs/memo.md", "MODIFIED"),
            ("corpus/companies/acme/acme-v2.md", "ADDED"),
            ("corpus/companies/acme/_history/old.md", "ADDED"),
        ])
        #expect(events.map(\.slug) == ["acme", "beta-labs"])
        #expect(events.map(\.kind) == [.memoPublished, .memoUpdated])
        #expect(events[0].path == "corpus/companies/acme/acme-v2.md")
    }

    @Test("gh's files answer decodes")
    func decode() throws {
        let files = try MemoPathRule.decodeFiles(MemoFixtures.files([("corpus/companies/acme/memo.md", "MODIFIED")]))
        #expect(files == [MemoPathRule.File(path: "corpus/companies/acme/memo.md", changeType: "MODIFIED")])
        #expect(MemoPathRule.filesArguments(repo: "o/r", number: 7) == ["pr", "view", "7", "--repo", "o/r", "--json", "files"])
    }
}

// MARK: - The matcher

@Suite("MemoCompanyMatcher")
struct MemoCompanyMatcherTests {
    @Test("acme-corp finds Acme Corp by name, by alias and by a domain alias")
    func finds() {
        let byName = ProjectEntry(key: "acme corp", name: "Acme Corp", kind: .company)
        #expect(MemoCompanyMatcher.match(slug: "acme-corp", in: [byName]) == .one(byName))

        let byAlias = ProjectEntry(key: "acme", name: "ACME Corporation", aliases: ["acme-corp"])
        #expect(MemoCompanyMatcher.match(slug: "acme-corp", in: [byAlias]) == .one(byAlias))

        let byDomain = ProjectEntry(key: "company:acmecorp.com", name: "Acmecorp", aliases: ["acmecorp.com"], kind: .company)
        #expect(MemoCompanyMatcher.match(slug: "acme-corp", in: [byDomain]) == .one(byDomain))

        let other = ProjectEntry(key: "beta", name: "Beta")
        #expect(MemoCompanyMatcher.match(slug: "acme-corp", in: [other]) == MemoCompanyMatcher.Match.none)
    }

    @Test("two entries answering the same try is ambiguous; the house entry never answers")
    func ambiguous() {
        let one = ProjectEntry(key: "acme", name: "Acme", aliases: ["acmecorp.com"])
        let two = ProjectEntry(key: "acme io", name: "Acme IO", aliases: ["acme-corp.io"])
        #expect(MemoCompanyMatcher.match(slug: "acme-corp", in: [one, two]) == .ambiguous)

        let house = ProjectEntry(key: "halyard", name: "Halyard", kind: .house)
        #expect(MemoCompanyMatcher.match(slug: "halyard", in: [house]) == MemoCompanyMatcher.Match.none)
    }

    @Test("a created entry is named from the slug")
    func displayName() {
        #expect(MemoCompanyMatcher.displayName(slug: "acme-corp") == "Acme Corp")
        #expect(MemoCompanyMatcher.displayName(slug: "beta_labs") == "Beta Labs")
    }
}

// MARK: - The pass

@Suite("MemoOutputs")
struct MemoOutputsTests {
    @Test("a PR touching only html in 10 folders gives 0 rows")
    func htmlOnly() async throws {
        let h = try MemoHarness()
        defer { h.cleanUp() }
        h.gh.answer(MemoFixtures.repo, 1, (1...10).map { ("corpus/companies/co\($0)/memo.html", "MODIFIED") })
        let result = try await h.apply([MemoFixtures.merged(1)])
        #expect(result.prsRead == 1)
        #expect(try h.rows().isEmpty)
        #expect(h.projects.isEmpty)
    }

    @Test("rows link to the matched company, one per folder, at the merge time")
    func rows() async throws {
        let acme = ProjectEntry(key: "acme corp", name: "Acme Corp", kind: .company)
        let h = try MemoHarness(projects: [acme])
        defer { h.cleanUp() }
        h.gh.answer(MemoFixtures.repo, 1, [("corpus/companies/acme-corp/memo.md", "MODIFIED")])
        try await h.apply([MemoFixtures.merged(1)])
        let rows = try h.rows()
        #expect(rows.count == 1)
        #expect(rows[0].kind == .memoUpdated)
        #expect(rows[0].projectKey == "acme corp")
        #expect(rows[0].title == "Acme Corp")
        #expect(rows[0].at == MemoFixtures.mergedAt)
        #expect(rows[0].reference == "\(MemoFixtures.repo)#1")
        #expect(rows[0].provenance == "memo-path-rule v1")
    }

    @Test("an ambiguous folder links nothing and creates nothing")
    func ambiguousCreatesNothing() async throws {
        let one = ProjectEntry(key: "acme", name: "Acme", aliases: ["acmecorp.com"])
        let two = ProjectEntry(key: "acme io", name: "Acme IO", aliases: ["acme-corp.io"])
        let h = try MemoHarness(projects: [one, two])
        defer { h.cleanUp() }
        h.gh.answer(MemoFixtures.repo, 1, [("corpus/companies/acme-corp/memo.md", "MODIFIED")])
        let result = try await h.apply([MemoFixtures.merged(1)])
        #expect(result.ambiguous == 1)
        #expect(result.created == 0)
        #expect(try h.rows().map(\.projectKey) == [nil])
        #expect(h.projects.count == 2)
    }

    @Test("an unknown folder creates one company entry; a second sync creates none")
    func createsOnce() async throws {
        let h = try MemoHarness()
        defer { h.cleanUp() }
        h.gh.answer(MemoFixtures.repo, 1, [("corpus/companies/acme-corp/memo.md", "ADDED")])
        h.gh.answer(MemoFixtures.repo, 2, [("corpus/companies/acme-corp/memo.md", "MODIFIED")])

        let first = try await h.apply([MemoFixtures.merged(1)])
        #expect(first.created == 1)
        let second = try await h.apply([MemoFixtures.merged(2)])
        #expect(second.created == 0)

        let projects = h.projects
        #expect(projects == [ProjectEntry(key: "acme corp", name: "Acme Corp", aliases: ["acme-corp"], kind: .company)])
        let onDisk = try Taxonomy.decode(Data(contentsOf: h.taxonomy.fileURL))
        #expect(onDisk.validationProblems().isEmpty)
        #expect(try h.rows().map(\.projectKey) == ["acme corp", "acme corp"])
        #expect(try h.rows().map(\.kind) == [.memoPublished, .memoUpdated])
    }

    @Test("after a merge the next pass relinks the rows; a rerun and the backfill add no duplicates")
    func relinkAndNoDuplicates() async throws {
        let h = try MemoHarness()
        defer { h.cleanUp() }
        h.gh.answer(MemoFixtures.repo, 1, [("corpus/companies/acme-corp/memo.md", "MODIFIED")])
        try await h.apply([MemoFixtures.merged(1)])
        try await h.apply([MemoFixtures.merged(1)])
        #expect(try h.rows().count == 1)

        // You merge the created entry into the one you already had.
        let catalog = try TaxonomyStore(dataDir: h.dataDir)
        var next = catalog.current
        next.projects = (next.projects ?? []) + [ProjectEntry(key: "acme", name: "Acme", kind: .company)]
        try catalog.save(next)
        try ProjectCatalog(db: h.db, taxonomy: catalog).merge(key: "acme corp", into: "acme")

        let result = try await h.apply([])
        #expect(result.prsRead == 0)
        #expect(result.relinked == 1)
        #expect(try h.rows().map(\.projectKey) == ["acme"])
        #expect(try h.rows().map(\.title) == ["Acme"])

        // The ledger already holds the PR; a newly listed repo backfills it once, and only once.
        try OutputStore(h.db).upsert(MemoFixtures.merged(1))
        let before = h.gh.reads.count
        let backfill = try await h.apply([], repos: [MemoFixtures.repo, "halyard/decks"])
        #expect(backfill.prsRead == 1)
        #expect(try await h.apply([], repos: [MemoFixtures.repo, "halyard/decks"]).prsRead == 0)
        #expect(h.gh.reads.count == before + 1)
        #expect(try h.rows().count == 1)
        #expect(try h.rows().map(\.projectKey) == ["acme"])
    }

    @Test("a reviewed PR, an unlisted repo and an empty MEMO_REPOS read nothing and write nothing")
    func outOfScope() async throws {
        let h = try MemoHarness()
        defer { h.cleanUp() }
        for n in 1...3 { h.gh.answer(MemoFixtures.repo, n, [("corpus/companies/acme/memo.md", "ADDED")]) }
        h.gh.answer("halyard/other", 4, [("corpus/companies/acme/memo.md", "ADDED")])

        var reviewed = MemoFixtures.merged(1)
        reviewed.kind = .reviewSubmitted
        reviewed.externalId = "review:99"
        try await h.apply([reviewed])
        try await h.apply([MemoFixtures.merged(4, repo: "halyard/other")])
        try await h.apply([MemoFixtures.merged(2)], repos: [])

        #expect(h.gh.reads.isEmpty)
        #expect(try h.rows().isEmpty)
        #expect(h.projects.isEmpty)
    }

    @Test("a PR gh will not read is skipped; gh rate-limited ends the pass and the next one backfills")
    func failures() async throws {
        let h = try MemoHarness()
        defer { h.cleanUp() }
        for n in 1...3 { h.gh.answer(MemoFixtures.repo, n, [("corpus/companies/co\(n)/memo.md", "MODIFIED")]) }
        h.gh.fail(MemoFixtures.repo, 1, with: GHOutput(status: 1, stderr: "GraphQL: Could not resolve to a PullRequest"))
        h.gh.fail(MemoFixtures.repo, 3, with: GHOutput(status: 1, stderr: "HTTP 403: API rate limit exceeded"))

        let first = try await h.apply([1, 2, 3].map { MemoFixtures.merged($0) })
        #expect(first.skipped == 1)
        #expect(first.prsRead == 1)
        #expect(try h.rows().count == 1)

        // The ledger wrote the round's rows; the next pass backfills what was not read.
        try OutputStore(h.db).upsert([1, 2, 3].map { MemoFixtures.merged($0) })
        h.gh.fail(MemoFixtures.repo, 3, with: nil)
        let next = try await h.apply([])
        #expect(next.prsRead == 2)
        #expect(try h.rows().count == 2)
        #expect(try await h.apply([]).prsRead == 0)
    }

    @Test("an empty MEMO_REPOS deletes the memo rows it had")
    func offDeletes() async throws {
        let h = try MemoHarness()
        defer { h.cleanUp() }
        h.gh.answer(MemoFixtures.repo, 1, [("corpus/companies/acme/memo.md", "ADDED")])
        try await h.apply([MemoFixtures.merged(1)])
        #expect(try h.rows().count == 1)
        try await h.apply([], repos: [])
        #expect(try h.rows().isEmpty)
    }

    @Test("shipped(project:) returns the company's memo rows and the PR count is unchanged")
    func shippedReadSide() async throws {
        let acme = ProjectEntry(key: "acme corp", name: "Acme Corp", kind: .company)
        let h = try MemoHarness(projects: [acme])
        defer { h.cleanUp() }
        h.gh.answer(MemoFixtures.repo, 1, [
            ("corpus/companies/acme-corp/memo.md", "MODIFIED"),
            ("corpus/companies/beta/memo.md", "ADDED"),
        ])
        let pr = MemoFixtures.merged(1)
        try await h.apply([pr])
        try OutputStore(h.db).upsert(pr)

        let utc = TimeZone(identifier: "UTC")!
        let range = DayBoundaries.range(day: "2026-09-07", timeZone: utc)!
        func text(_ project: String?) throws -> String {
            try WorklensMCPTools.shippedText(
                from: "2026-09-07", to: "2026-09-07", start: range.start, end: range.end,
                project: project, config: Config.defaults(), db: h.db, projects: h.projects, timeZone: utc
            )
        }
        let all = try text(nil)
        #expect(all.contains("1 PR merged"))
        #expect(all.contains("1 memo updated"))
        #expect(all.contains("1 memo published"))

        let acmeOnly = try text("Acme Corp")
        #expect(acmeOnly.contains("13:00 You updated the memo for Acme Corp in \(MemoFixtures.repo)#1"))
        #expect(acmeOnly.contains("https://github.com/\(MemoFixtures.repo)/pull/1"))
        #expect(!acmeOnly.contains("PR merged"))
        #expect(!acmeOnly.contains("Beta"))

        let section = ShippedSection.timelineLines(try h.rows() + [pr], projects: h.projects, timeZone: utc)
        #expect(section.contains("- 13:00 You published the memo for Beta in \(MemoFixtures.repo)#1"))
    }

    @Test("a describe prompt over a created entry has no slug; info logs name no company or path")
    func privacy() async throws {
        let h = try MemoHarness()
        defer { h.cleanUp() }
        h.gh.answer(MemoFixtures.repo, 1, [("corpus/companies/acme-corp/memo.md", "ADDED")])
        try await h.apply([MemoFixtures.merged(1)])

        let store = try TaxonomyStore(dataDir: h.dataDir)
        let prompt = DescribePrompt.userPrompt(
            resolved: nil, taxonomy: store, input: DescribePrompt.Input(at: MemoFixtures.mergedAt)
        )
        let schema = "\(DescribePrompt.schema(resolved: nil, taxonomy: store.current))"
        #expect(prompt.contains("Acme Corp"))
        #expect(!prompt.contains("acme-corp"))
        #expect(!schema.contains("acme-corp"))

        let info = h.lines.at("info").joined(separator: "\n")
        #expect(!info.isEmpty)
        for secret in ["acme", "Acme", "corpus", "memo.md", "memos"] {
            #expect(!info.contains(secret))
        }
        #expect(h.lines.at("debug").contains { $0.contains("corpus/companies/acme-corp/memo.md") })
    }

    @Test("OutputSync reads a merged PR's files once, in the round its row lands")
    func throughTheLedger() async throws {
        let h = try MemoHarness()
        defer { h.cleanUp() }
        // GHFixtures' merged PR is acme/widgets#12.
        h.gh.answer("acme/widgets", 12, [("corpus/companies/acme/memo.md", "MODIFIED")])
        let sync = OutputSync(
            db: h.db, runner: h.gh, memo: h.memo(repos: ["Acme/Widgets"]),
            now: { GHFixtures.syncedAt }, log: { _, _ in }
        )
        let first = try await sync.sync().get()
        #expect(first.memo?.prsRead == 1)
        #expect(first.memo?.updated == 1)
        _ = try await sync.sync().get()
        #expect(h.gh.reads == ["acme/widgets#12"])
        #expect(try h.rows().count == 1)
        #expect(try h.rows(Output.github).filter { $0.kind == .prMerged }.count == 1)

        #expect(OutputSync.forget(db: h.db) > 1)
        #expect(try h.rows().isEmpty)
    }

    @Test("a backfill where gh fails (a 502, not 'no such PR') skips nothing; the next pass reads them")
    func failingBackfillIsReadAgain() async throws {
        let h = try MemoHarness()
        defer { h.cleanUp() }
        try OutputStore(h.db).upsert([1, 2].map { MemoFixtures.merged($0) })
        for n in 1...2 {
            h.gh.answer(MemoFixtures.repo, n, [("corpus/companies/co\(n)/memo.md", "MODIFIED")])
            h.gh.fail(MemoFixtures.repo, n, with: GHOutput(status: 1, stderr: "HTTP 502: Bad Gateway"))
        }

        let failed = try await h.apply([])
        #expect(failed.prsRead == 0)
        #expect(failed.skipped == 0)
        #expect(try AppStateStore(h.db).get(MemoOutputs.backfillKey) == nil)

        for n in 1...2 { h.gh.fail(MemoFixtures.repo, n, with: nil) }
        let next = try await h.apply([])
        #expect(next.prsRead == 2)
        #expect(try h.rows().count == 2)
        #expect(h.gh.reads.count == 3)
    }

    @Test("a catalog that will not open reads nothing and re-arms the backfill")
    func brokenCatalog() async throws {
        struct Broken: Error {}
        let h = try MemoHarness()
        defer { h.cleanUp() }
        h.gh.answer(MemoFixtures.repo, 1, [("corpus/companies/acme/memo.md", "ADDED")])
        let broken = MemoOutputs(repos: [MemoFixtures.repo], db: h.db, taxonomy: { throw Broken() }, log: { _, _ in })
        let result = try await broken.apply(changed: [MemoFixtures.merged(1)], runner: h.gh, syncedAt: GHFixtures.syncedAt)
        #expect(result.prsRead == 0)
        #expect(h.gh.reads.isEmpty)
        #expect(try h.rows().isEmpty)

        try OutputStore(h.db).upsert(MemoFixtures.merged(1))
        #expect(try await h.apply([]).created == 1)
        #expect(try h.rows().map(\.projectKey) == ["acme"])
    }

    @Test("a created company a stale catalog save dropped comes back; the house entry is never one")
    func droppedCompanyComesBack() async throws {
        let h = try MemoHarness(projects: [ProjectEntry(key: "halyard", name: "Halyard", kind: .house)])
        defer { h.cleanUp() }
        h.gh.answer(MemoFixtures.repo, 1, [("corpus/companies/acme-corp/memo.md", "MODIFIED")])
        try await h.apply([MemoFixtures.merged(1)])

        // Another process saves the catalog it read before the entry was added.
        let stale = try TaxonomyStore(dataDir: h.dataDir)
        var next = stale.current
        next.projects = [ProjectEntry(key: "halyard", name: "Halyard", kind: .house)]
        try stale.save(next)

        let result = try await h.apply([])
        #expect(result.created == 1)
        #expect(h.projects.map(\.key) == ["halyard", "acme corp"])
        #expect(try h.rows().map(\.projectKey) == ["acme corp"])
        #expect(try h.rows().map(\.projectRule) == ["memo_created"])

        #expect(throws: ProjectCatalogError.self) {
            try ProjectCatalog.addCompany(name: "Halyard", aliases: ["halyard"], in: stale)
        }
    }

    @Test("MEMO_REPOS reads a GitHub URL as owner/name and warns about a bare name")
    func repoNames() throws {
        #expect(MemoOutputs.repoName(" https://github.com/halyard/memos.git/ ") == "halyard/memos")
        #expect(MemoOutputs.repoName("github.com/halyard/memos") == "halyard/memos")
        #expect(MemoOutputs.repoName("halyard/memos") == "halyard/memos")

        let cwd = URL(fileURLWithPath: "/tmp/worklens-test-cwd", isDirectory: true)
        let url = try Config.load(
            sources: [ConfigSource(layer: .cwd, url: nil, values: ["MEMO_REPOS": "https://github.com/halyard/memos"])],
            cwd: cwd
        )
        #expect(url.config.memoRepos == ["halyard/memos"])
        #expect(url.warnings.isEmpty)
        let bare = try Config.load(
            sources: [ConfigSource(layer: .cwd, url: nil, values: ["MEMO_REPOS": "memos"])], cwd: cwd
        )
        #expect(bare.warnings == [.repoWithoutOwner(key: "MEMO_REPOS")])
    }
}
