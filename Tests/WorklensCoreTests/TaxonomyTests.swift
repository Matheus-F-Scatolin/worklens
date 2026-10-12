import Foundation
import Testing
@testable import WorklensCore

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("worklens-taxonomy-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Taxonomy seed")
struct TaxonomySeedTests {
    @Test("the embedded seed parses and passes validation")
    func seedIsValid() throws {
        let taxonomy = Taxonomy.seed
        #expect(taxonomy.version == 1)
        #expect(taxonomy.apps.count > 20)
        #expect(taxonomy.validationProblems() == [])
    }

    @Test("first run writes taxonomy.json byte-identical to the seed")
    func seedWrittenVerbatim() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaxonomyStore(dataDir: dir)
        let onDisk = try Data(contentsOf: store.fileURL)
        #expect(onDisk == Data(TaxonomySeed.json.utf8))
    }

    @Test("validation catches duplicate keys, empty task lists and shared bundle ids")
    func validationCatchesProblems() {
        let task = TaskEntry(key: "t", description: "")
        var broken = Taxonomy(
            version: 1,
            apps: [
                AppEntry(key: "a", name: "A", category: "x", bundleIds: ["com.a"], tasks: [task, task]),
                AppEntry(key: "a", name: "A2", category: "x", bundleIds: ["com.a"], tasks: []),
            ],
            universalTasks: [TaskEntry(key: "other", description: "")]
        )
        let problems = broken.validationProblems()
        #expect(problems.contains { $0.contains("duplicate app key") })
        #expect(problems.contains { $0.contains("has no tasks") })
        #expect(problems.contains { $0.contains("duplicate task") })
        #expect(problems.contains { $0.contains("claimed by both") })

        broken.apps = [AppEntry(key: "a", name: "A", category: "x", bundleIds: ["com.a"], tasks: [task])]
        #expect(broken.validationProblems() == [])
    }
}

@Suite("TaxonomyStore.resolve")
struct TaxonomyResolveTests {
    private func store() throws -> (TaxonomyStore, URL) {
        let dir = tempDir()
        return (try TaxonomyStore(dataDir: dir), dir)
    }

    @Test("a bundle id resolves to its app")
    func bundleResolution() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolved = store.resolve(bundleID: "com.tinyspeck.slackmacgap", url: nil)
        #expect(resolved?.appKey == "slack")
        #expect(resolved?.isWebApp == false)
        #expect(resolved?.tasks.contains { $0.key == "huddle" } == true)
    }

    @Test("a web app in a browser beats the generic browser entry")
    func webAppPrecedence() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolved = store.resolve(bundleID: "com.google.Chrome", url: "https://mail.google.com/mail/u/0/#inbox")
        #expect(resolved?.appKey == "gmail")
        #expect(resolved?.isWebApp == true)
    }

    @Test("a browser URL with no known web app falls back to the browser")
    func browserFallback() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolved = store.resolve(bundleID: "com.apple.Safari", url: "https://example.com/blog/post")
        #expect(resolved?.appKey == "browser")
        #expect(resolved?.isWebApp == false)
    }

    @Test("subdomains match the pattern host")
    func subdomainMatch() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.resolve(bundleID: "com.google.Chrome", url: "https://www.linkedin.com/feed/")?.appKey == "linkedin")
        #expect(store.resolve(bundleID: "com.google.Chrome", url: "https://acme.affinity.co/lists/1")?.appKey == "affinity")
    }

    @Test("path prefixes separate the Google Docs family")
    func pathPrefixMatch() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.resolve(bundleID: "com.google.Chrome", url: "https://docs.google.com/spreadsheets/d/1x/edit")?.appKey == "gsheets")
        #expect(store.resolve(bundleID: "com.google.Chrome", url: "https://docs.google.com/document/d/1x/edit")?.appKey == "gdocs")
        #expect(store.resolve(bundleID: "com.google.Chrome", url: "https://docs.google.com/presentation/d/1x")?.appKey == "gslides")
    }

    @Test("a URL alongside a non-browser app does not turn it into a web app")
    func nonBrowserIgnoresURL() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.resolve(bundleID: "com.tinyspeck.slackmacgap", url: "https://github.com/x/y")?.appKey == "slack")
    }

    @Test("a URL alone still resolves when the bundle id is unknown")
    func urlOnly() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.resolve(bundleID: nil, url: "https://github.com/foo/bar")?.appKey == "github")
        #expect(store.resolve(bundleID: "com.example.unknown", url: "https://x.com/home")?.appKey == "x")
    }

    @Test("an unknown app with no URL is unresolved")
    func unknownIsNil() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.resolve(bundleID: "com.example.unknown", url: nil) == nil)
        #expect(store.resolve(bundleID: nil, url: nil) == nil)
    }
}

@Suite("TaxonomyStore vocabulary")
struct TaxonomyVocabularyTests {
    @Test("isKnownTask accepts app tasks, web-app tasks and universal tasks")
    func knownTasks() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaxonomyStore(dataDir: dir)
        #expect(store.isKnownTask(appKey: "slack", taskKey: "huddle"))
        #expect(store.isKnownTask(appKey: "gmail", taskKey: "triaging"))
        #expect(store.isKnownTask(appKey: "slack", taskKey: "other"))
        #expect(store.isKnownTask(appKey: "slack", taskKey: "switching"))
        #expect(!store.isKnownTask(appKey: "slack", taskKey: "coding"))
        #expect(!store.isKnownTask(appKey: "nope", taskKey: "coding"))
    }

    @Test("promptFragment stays under 600 characters for every app")
    func promptFragmentIsCompact() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaxonomyStore(dataDir: dir)
        let taxonomy = store.current

        for app in taxonomy.apps {
            let resolved = ResolvedApp(
                appKey: app.key, name: app.name, category: app.category,
                tasks: app.tasks, isWebApp: false
            )
            let fragment = store.promptFragment(for: resolved)
            #expect(fragment.count < 600, "\(app.key) fragment is \(fragment.count) chars")
            #expect(fragment.contains("other"))
        }
        for web in taxonomy.allWebApps {
            let resolved = ResolvedApp(
                appKey: web.key, name: web.name, category: web.category,
                tasks: web.tasks, isWebApp: true
            )
            #expect(store.promptFragment(for: resolved).count < 600)
        }
    }

    @Test("with no resolved app the fragment lists every app key")
    func unresolvedFragment() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaxonomyStore(dataDir: dir)
        let fragment = store.promptFragment(for: nil)
        #expect(fragment.contains("slack"))
        #expect(fragment.contains("gsheets"))
        #expect(fragment.contains("switching"))
    }
}

@Suite("TaxonomyStore categories")
struct TaxonomyCategoryTests {
    @Test("category(forAppKey:) answers for apps, web apps and nothing else")
    func categoryLookup() {
        let taxonomy = Taxonomy.seed
        #expect(taxonomy.category(forAppKey: "slack") == "communication")
        #expect(taxonomy.category(forAppKey: "gsheets") == "analysis")
        #expect(taxonomy.category(forAppKey: "browser") == "browser")
        #expect(taxonomy.category(forAppKey: "not_an_app") == nil)
    }

    @Test("the store's resolver feeds StatsAggregator.byCategory from the live taxonomy")
    func resolverDrivesStats() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaxonomyStore(dataDir: dir)

        let day = "2026-09-07"
        let zone = TimeZone(identifier: "UTC")!
        let start = DayBoundaries.range(day: day, timeZone: zone)!.start
        let blocks = [
            ActivityBlock(day: day, startAt: start.addingTimeInterval(9 * 3600), endAt: start.addingTimeInterval(10 * 3600),
                          appKey: "slack", taskKey: "reading_messages"),
            ActivityBlock(day: day, startAt: start.addingTimeInterval(10 * 3600), endAt: start.addingTimeInterval(10 * 3600 + 1800),
                          appKey: "gmail", taskKey: "triaging"),
            ActivityBlock(day: day, startAt: start.addingTimeInterval(11 * 3600), endAt: start.addingTimeInterval(11 * 3600 + 600),
                          appKey: "mystery_app", taskKey: "other"),
        ]
        let stats = StatsAggregator.daily(day: day, blocks: blocks, category: store.categoryResolver, timeZone: zone)
        #expect(stats.byCategory.map(\.key) == ["communication", "uncategorized"])
        #expect(stats.byCategory.first?.minutes == 90)
    }
}

@Suite("TaxonomyStore file watching")
struct TaxonomyReloadTests {
    @Test("an edited file changes resolve() once the 30 s window has passed")
    func reloadsAfterInterval() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = Clock()
        let store = try TaxonomyStore(dataDir: dir, now: { clock.value })
        #expect(store.resolve(bundleID: "com.example.custom", url: nil) == nil)

        var edited = store.current
        edited.apps.append(AppEntry(
            key: "custom", name: "Custom", category: "misc",
            bundleIds: ["com.example.custom"],
            tasks: [TaskEntry(key: "doing_things", description: "")]
        ))
        let data = try Taxonomy.encoder().encode(edited)
        try data.write(to: store.fileURL, options: .atomic)

        // Still inside the 30 s window: the store must not even stat the file.
        clock.value = clock.value.addingTimeInterval(5)
        #expect(store.resolve(bundleID: "com.example.custom", url: nil) == nil)

        clock.value = clock.value.addingTimeInterval(30)
        #expect(store.resolve(bundleID: "com.example.custom", url: nil)?.appKey == "custom")
        #expect(store.isKnownTask(appKey: "custom", taskKey: "doing_things"))
    }

    @Test("a malformed edit keeps the last good taxonomy")
    func malformedEditIsIgnored() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let store = try TaxonomyStore(dataDir: dir, now: { clock.value })

        try Data("{ not json".utf8).write(to: store.fileURL, options: .atomic)
        clock.value = clock.value.addingTimeInterval(60)

        #expect(store.resolve(bundleID: "com.tinyspeck.slackmacgap", url: nil)?.appKey == "slack")
    }

    @Test("init throws on a malformed file")
    func initRejectsMalformed() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("nope".utf8).write(to: dir.appendingPathComponent(TaxonomyStore.fileName))
        #expect(throws: TaxonomyError.self) { _ = try TaxonomyStore(dataDir: dir) }
    }

    @Test("save writes atomically, bumps the version and refuses an invalid taxonomy")
    func saveBumpsVersion() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaxonomyStore(dataDir: dir)

        var next = store.current
        next.apps.removeLast()
        try store.save(next)
        #expect(store.current.version == 2)

        let reloaded = try TaxonomyStore(dataDir: dir).current
        #expect(reloaded.version == 2)
        #expect(reloaded.apps.count == next.apps.count)

        var invalid = store.current
        invalid.apps[0].tasks = []
        #expect(throws: TaxonomyError.self) { try store.save(invalid) }
    }
}

/// A mutable clock the store reads through its `now` closure.
private final class Clock: @unchecked Sendable {
    var value = Date(timeIntervalSince1970: 1_757_000_000)
}

@Suite("Taxonomy project rules (#324)")
struct TaxonomyProjectRulesTests {
    @Test("a taxonomy written before rules existed decodes, with no rules on any project")
    func olderTaxonomyDecodes() throws {
        var older = Taxonomy.seed
        older.projects = [ProjectEntry(key: "acme", name: "Acme", domains: ["acme.com"])]
        let data = try Taxonomy.encoder().encode(older)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"rules\""))
        let decoded = try Taxonomy.decode(data)
        #expect(decoded.projects?.first?.rules == nil)
        #expect(decoded.projects?.first?.domains == ["acme.com"])
        #expect(decoded.validationProblems() == [])
    }

    @Test("rules round-trip as snake_case")
    func rulesRoundTrip() throws {
        var taxonomy = Taxonomy.seed
        taxonomy.projects = [ProjectEntry(
            key: "acme", name: "Acme",
            rules: ProjectRules(repos: ["acme/api"], urlPrefixes: ["notion.so/acme"])
        )]
        let data = try Taxonomy.encoder().encode(taxonomy)
        #expect(String(decoding: data, as: UTF8.self).contains("\"url_prefixes\""))
        #expect(try Taxonomy.decode(data).projects == taxonomy.projects)
    }

    @Test("two projects claiming one domain, repo or URL prefix are refused")
    func claimedTwiceIsRefused() {
        var taxonomy = Taxonomy.seed
        taxonomy.projects = [
            ProjectEntry(
                key: "acme", name: "Acme", domains: ["example.com"],
                rules: ProjectRules(repos: ["acme/api"], urlPrefixes: ["notion.so/acme"])
            ),
            ProjectEntry(
                key: "beta", name: "Beta", domains: ["www.example.com"],
                rules: ProjectRules(repos: ["github.com/Acme/API"], urlPrefixes: ["https://notion.so/acme/"])
            ),
        ]
        let problems = taxonomy.validationProblems()
        #expect(problems.contains("domain \"example.com\" is claimed by both \"acme\" and \"beta\""))
        #expect(problems.contains("repo \"acme/api\" is claimed by both \"acme\" and \"beta\""))
        #expect(problems.contains("url_prefix \"notion.so/acme\" is claimed by both \"acme\" and \"beta\""))

        taxonomy.projects?[1].domains = nil
        taxonomy.projects?[1].rules = ProjectRules(repos: ["no-owner"])
        #expect(taxonomy.validationProblems() == ["project \"beta\" has an unusable repo \"no-owner\""])

        taxonomy.projects?[1].rules = nil
        taxonomy.projects?[1].domains = ["localhost"]
        #expect(taxonomy.validationProblems() == ["project \"beta\" has an unusable domain \"localhost\""])
    }
}
