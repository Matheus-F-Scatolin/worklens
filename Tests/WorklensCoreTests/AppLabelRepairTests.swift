import Foundation
import GRDB
import Testing
@testable import WorklensCore

/// #312: Codex, cmux and Worklens reach existing installs, and past frames move to them.
@Suite("App label repair")
struct AppLabelRepairTests {
    private static let codex = "com.openai.codex"
    private static let cmux = "com.cmuxterm.app"
    private static let worklens = "dev.worklens.app"

    /// The seed as it shipped before revision 2: no Codex, no Worklens, no cmux under Terminal.
    private static var oldSeedJSON: String {
        let lines = TaxonomySeed.json.components(separatedBy: "\n")
            .filter { !$0.contains("\"key\": \"codex_desktop\"") && !$0.contains("\"key\": \"worklens\"") }
        var json = lines.joined(separator: "\n")
            .replacingOccurrences(of: ", \"com.cmuxterm.app\"", with: "")
        // Dropping the last app left a trailing comma on the one before it.
        json = json.replacingOccurrences(of: "}]},\n  ],", with: "}]}\n  ],")
        return json
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLabelRepairTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A data directory whose `taxonomy.json` is `json` (or the fresh seed when nil).
    private func store(json: String?) throws -> TaxonomyStore {
        let dir = try temporaryDirectory()
        if let json {
            try Data(json.utf8).write(to: dir.appendingPathComponent(TaxonomyStore.fileName))
        }
        return try TaxonomyStore(dataDir: dir)
    }

    private func onDisk(_ store: TaxonomyStore) throws -> Taxonomy {
        try Taxonomy.decode(Data(contentsOf: store.fileURL))
    }

    private func modified(_ store: TaxonomyStore) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.modificationDate] as? Date
    }

    private func byKey(_ apps: [AppEntry]) -> [String: AppEntry] {
        Dictionary(uniqueKeysWithValues: apps.map { ($0.key, $0) })
    }

    // MARK: Merge

    @Test("the old seed gains Codex and Worklens, cmux joins Terminal, nothing else moves")
    func oldSeedMerges() throws {
        let old = try Taxonomy.decode(Data(Self.oldSeedJSON.utf8))
        #expect(old.validationProblems().isEmpty)
        #expect(old.app(key: "codex_desktop") == nil)
        #expect(old.app(key: "worklens") == nil)

        let taxonomy = try store(json: Self.oldSeedJSON)
        let db = try Database.inMemory()
        let added = try AppLabelRepair(db: db, taxonomy: taxonomy).mergeIfDue()
        #expect(Set(added) == [Self.codex, Self.cmux, Self.worklens])

        let merged = try onDisk(taxonomy)
        #expect(merged.version == old.version + 1)
        #expect(byKey(merged.apps) == byKey(Taxonomy.seed.apps))
        #expect(merged.universalTasks == old.universalTasks)
        #expect(merged.projectList == old.projectList)
        #expect(merged.app(bundleID: Self.codex)?.key == "codex_desktop")
        #expect(merged.app(bundleID: Self.codex)?.category == "dev")
        #expect(merged.app(bundleID: Self.cmux)?.key == "terminal")
        #expect(merged.app(bundleID: Self.worklens)?.key == "worklens")
        // Existing apps keep their place; the new ones go last.
        #expect(Array(merged.apps.map(\.key).prefix(old.apps.count)) == old.apps.map(\.key))
    }

    @Test("a second merge writes nothing")
    func secondMergeWritesNothing() throws {
        let taxonomy = try store(json: Self.oldSeedJSON)
        let repair = AppLabelRepair(db: try Database.inMemory(), taxonomy: taxonomy)
        try repair.mergeIfDue()
        let before = try modified(taxonomy)
        let version = try onDisk(taxonomy).version

        #expect(try repair.mergeIfDue().isEmpty)
        #expect(try modified(taxonomy) == before)
        #expect(try onDisk(taxonomy).version == version)

        // The pure merge is idempotent too, revision or not.
        let again = TaxonomyMerge.apply(try onDisk(taxonomy), bundleIDs: TaxonomySeed.additions(after: 1))
        #expect(again.added.isEmpty)
    }

    /// The other path to a second merge: the app quit between `save` and recording the revision,
    /// so the guard lets the merge run again over a file that already lists every id.
    @Test("a merge whose revision was never recorded writes nothing and records it")
    func unrecordedRevisionWritesNothing() throws {
        let taxonomy = try store(json: Self.oldSeedJSON)
        let db = try Database.inMemory()
        let repair = AppLabelRepair(db: db, taxonomy: taxonomy)
        try repair.mergeIfDue()
        try AppStateStore(db).delete(AppLabelRepair.taxonomyRevisionKey)
        let before = try modified(taxonomy)
        let version = try onDisk(taxonomy).version

        #expect(try repair.mergeIfDue().isEmpty)
        #expect(try modified(taxonomy) == before)
        #expect(try onDisk(taxonomy).version == version)
        #expect(try AppStateStore(db).get(AppLabelRepair.taxonomyRevisionKey) == String(TaxonomySeed.appsRevision))
    }

    @Test("a file that maps Codex somewhere else is left alone")
    func codexMappedElsewhereIsLeftAlone() throws {
        var file = try Taxonomy.decode(Data(Self.oldSeedJSON.utf8))
        let chat = try #require(file.apps.firstIndex { $0.key == "chatgpt_desktop" })
        file.apps[chat].bundleIds.append(Self.codex)

        let (merged, added) = TaxonomyMerge.apply(file, bundleIDs: [Self.codex, Self.cmux, Self.worklens])
        #expect(added == [Self.cmux, Self.worklens])
        #expect(merged.app(key: "codex_desktop") == nil)
        #expect(merged.app(bundleID: Self.codex)?.key == "chatgpt_desktop")
    }

    @Test("an id is skipped when its seed key is a web app's in your file")
    func keyTakenByWebAppIsSkipped() throws {
        var file = try Taxonomy.decode(Data(Self.oldSeedJSON.utf8))
        let web = WebAppEntry(
            key: "worklens", name: "Worklens site", category: "reading",
            urlPatterns: ["worklens.example"], tasks: [TaskEntry(key: "reading", description: "")]
        )
        let host = try #require(file.apps.firstIndex { !($0.webApps ?? []).isEmpty })
        file.apps[host].webApps?.append(web)

        let (merged, added) = TaxonomyMerge.apply(file, bundleIDs: [Self.worklens])
        #expect(added.isEmpty)
        #expect(merged == file)
    }

    @Test("a Codex app you delete after the merge stays deleted")
    func deletedAppStaysDeleted() throws {
        let taxonomy = try store(json: Self.oldSeedJSON)
        let repair = AppLabelRepair(db: try Database.inMemory(), taxonomy: taxonomy)
        try repair.mergeIfDue()

        var edited = taxonomy.current
        edited.apps.removeAll { $0.key == "codex_desktop" }
        try taxonomy.save(edited)

        #expect(try repair.mergeIfDue().isEmpty)
        #expect(try onDisk(taxonomy).app(key: "codex_desktop") == nil)
    }

    @Test("a fresh data directory keeps the seed byte for byte and the merge writes nothing")
    func freshDataDirIsUntouched() throws {
        let taxonomy = try store(json: nil)
        let db = try Database.inMemory()
        #expect(try Data(contentsOf: taxonomy.fileURL) == Data(TaxonomySeed.json.utf8))

        #expect(try AppLabelRepair(db: db, taxonomy: taxonomy).mergeIfDue().isEmpty)
        #expect(try Data(contentsOf: taxonomy.fileURL) == Data(TaxonomySeed.json.utf8))
        #expect(try AppStateStore(db).get(AppLabelRepair.taxonomyRevisionKey) == String(TaxonomySeed.appsRevision))
    }

    // MARK: Relabel

    private static let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!

    /// Records the days `rebuild` was asked for, and can be told to fail.
    private actor Rebuilds {
        var days: [String] = []
        let failing: Bool
        init(failing: Bool = false) { self.failing = failing }
        func record(_ day: String) throws {
            days.append(day)
            if failing { throw CancellationError() }
        }
    }

    /// Frames across three local days in São Paulo. 2026-10-02 holds only frames that are
    /// already right, so it must never be rebuilt.
    private typealias Frame = (id: String, at: String, bundle: String, app: String, task: String, inherited: Bool)

    private func seededDB(extra: [Frame] = []) throws -> WorklensCore.Database {
        let db = try Database.inMemory()
        let frames: [Frame] = extra + [
            // 2026-10-01 local (the first is 23:30 local, already 10-02 in UTC).
            ("codex1", "2026-10-02T02:30:00Z", Self.codex, "chatgpt_desktop", "chatting_with_ai", false),
            ("codex2", "2026-10-02T02:31:00Z", Self.codex, "other", "other", true),
            ("wl1", "2026-10-01T15:00:00Z", Self.worklens, "other", "other", false),
            // 2026-10-02 local: nothing to change.
            ("chat1", "2026-10-02T15:00:00Z", "com.openai.chat", "chatgpt_desktop", "chatting_with_ai", false),
            ("cmux1", "2026-10-02T16:00:00Z", Self.cmux, "terminal", "running_commands", false),
            // 2026-10-03 local.
            ("cmux2", "2026-10-03T12:00:00Z", Self.cmux, "other", "other", false),
            ("wl2", "2026-10-03T13:00:00Z", Self.worklens, "system_settings", "configuring", true),
        ]
        let formatter = ISO8601DateFormatter()
        try db.writer.write { db in
            for frame in frames {
                let at = formatter.date(from: frame.at)!
                try db.execute(
                    sql: """
                        INSERT INTO captures (id, captured_at, app_bundle_id, describe_status,
                                              describe_attempts, created_at)
                        VALUES (?, ?, ?, 'described', 1, ?)
                        """,
                    arguments: [frame.id, at, frame.bundle, at]
                )
                try db.execute(
                    sql: """
                        INSERT INTO descriptions (id, capture_id, provider, model, app_key, task_key,
                                                  summary_md, is_inherited, created_at)
                        VALUES (?, ?, 'fake', 'm', ?, ?, 'You worked.', ?, ?)
                        """,
                    arguments: ["d-" + frame.id, frame.id, frame.app, frame.task, frame.inherited, at]
                )
            }
        }
        return db
    }

    private func labels(_ db: WorklensCore.Database) throws -> [String: String] {
        try db.writer.read { db in
            var out: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT capture_id, app_key, task_key FROM descriptions") {
                out[row["capture_id"]] = "\(row["app_key"] as String)/\(row["task_key"] as String)"
            }
            return out
        }
    }

    @Test("past Codex, Worklens and cmux frames take their keys; ChatGPT keeps its own")
    func relabelMovesPastFrames() async throws {
        let db = try seededDB()
        let taxonomy = try store(json: Self.oldSeedJSON)
        let repair = AppLabelRepair(db: db, taxonomy: taxonomy, timeZone: Self.saoPaulo)

        // Before the merge, the new ids resolve to nothing: the relabel waits.
        let early = Rebuilds()
        let earlyResult = try await repair.relabelIfDue { try await early.record($0) }
        #expect(earlyResult == nil)
        #expect(await early.days.isEmpty)

        try repair.mergeIfDue()
        let rebuilds = Rebuilds()
        let done = try await repair.relabelIfDue { try await rebuilds.record($0) }

        #expect(done == AppLabelRepair.Relabel(frames: 5, days: ["2026-10-01", "2026-10-03"]))
        #expect(await rebuilds.days == ["2026-10-01", "2026-10-03"])
        #expect(try labels(db) == [
            "codex1": "codex_desktop/other",
            "codex2": "codex_desktop/other",
            "wl1": "worklens/other",
            "chat1": "chatgpt_desktop/chatting_with_ai",
            "cmux1": "terminal/running_commands",
            "cmux2": "terminal/other",
            "wl2": "worklens/configuring",
        ])

        // Once per revision.
        let again = Rebuilds()
        let againResult = try await repair.relabelIfDue { try await again.record($0) }
        #expect(againResult == nil)
        #expect(await again.days.isEmpty)
    }

    @Test("a rebuild that throws leaves the revision unrecorded, and the retry rebuilds the same days")
    func failedRebuildIsRetried() async throws {
        let db = try seededDB()
        let taxonomy = try store(json: Self.oldSeedJSON)
        let repair = AppLabelRepair(db: db, taxonomy: taxonomy, timeZone: Self.saoPaulo)
        try repair.mergeIfDue()

        let failing = Rebuilds(failing: true)
        await #expect(throws: CancellationError.self) {
            try await repair.relabelIfDue { try await failing.record($0) }
        }
        #expect(try AppStateStore(db).get(AppLabelRepair.labelsRevisionKey) == nil)

        // The rows are already fixed, but the days were never rebuilt: the retry still does them.
        let retry = Rebuilds()
        let done = try await repair.relabelIfDue { try await retry.record($0) }
        #expect(done == AppLabelRepair.Relabel(frames: 0, days: ["2026-10-01", "2026-10-03"]))
        #expect(await retry.days == ["2026-10-01", "2026-10-03"])
        #expect(try AppStateStore(db).get(AppLabelRepair.labelsRevisionKey) == String(TaxonomySeed.appsRevision))
        #expect(try AppStateStore(db).get(AppLabelRepair.pendingDaysKey) == nil)
    }

    @Test("a file that maps Codex to ChatGPT moves every past Codex frame there, never to codex_desktop")
    func relabelFollowsYourCodexMapping() async throws {
        let db = try seededDB(extra: [
            ("codex3", "2026-10-03T14:00:00Z", Self.codex, "browser", "other", false),
            ("codex4", "2026-10-03T14:01:00Z", Self.codex, "system_settings", "configuring", false),
            ("codex5", "2026-10-03T14:02:00Z", Self.codex, "terminal", "running_commands", true),
        ])
        let json = Self.oldSeedJSON.replacingOccurrences(
            of: "\"bundle_ids\": [\"com.openai.chat\"]",
            with: "\"bundle_ids\": [\"com.openai.chat\", \"\(Self.codex)\"]"
        )
        let taxonomy = try store(json: json)
        #expect(taxonomy.current.app(bundleID: Self.codex)?.key == "chatgpt_desktop")
        let repair = AppLabelRepair(db: db, taxonomy: taxonomy, timeZone: Self.saoPaulo)
        try repair.mergeIfDue()
        #expect(taxonomy.current.app(key: "codex_desktop") == nil)

        let rebuilds = Rebuilds()
        _ = try await repair.relabelIfDue { try await rebuilds.record($0) }

        let after = try labels(db)
        for id in ["codex1", "codex2", "codex3", "codex4", "codex5"] {
            #expect(after[id]?.hasPrefix("chatgpt_desktop/") == true, "\(id) is \(after[id] ?? "missing")")
        }
        #expect(after["codex1"] == "chatgpt_desktop/chatting_with_ai")
        #expect(!after.values.contains { $0.hasPrefix("codex_desktop/") })
    }
}
