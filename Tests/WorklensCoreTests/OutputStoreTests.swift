import Foundation
import GRDB
import Testing
@testable import WorklensCore

@Suite("OutputStore")
struct OutputStoreTests {
    private func output(
        _ externalId: String = "pr:acme/widgets#12", kind: OutputKind = .prMerged,
        at: Date = GHFixtures.date("2026-09-07T13:00:00Z"), title: String = "Add the ledger",
        provenance: String = "gh search prs", syncedAt: Date = GHFixtures.syncedAt
    ) -> Output {
        Output(
            kind: kind, at: at, repo: "acme/widgets", number: 12,
            url: "https://github.com/acme/widgets/pull/12", title: title,
            resourceKey: "github.com/acme/widgets/pull/12", externalId: externalId,
            provenance: provenance, syncedAt: syncedAt
        )
    }

    @Test("the migration creates outputs and its indexes")
    func migration() throws {
        let db = try Database.inMemory()
        let (columns, indexes) = try db.writer.read { db in
            (
                try db.columns(in: "outputs").map(\.name),
                try db.indexes(on: "outputs").map(\.name)
            )
        }
        #expect(columns == [
            "id", "source", "kind", "at", "repo", "number", "url", "title", "path", "resource_key",
            "external_id", "project_key", "project_rule", "provenance", "synced_at",
        ])
        #expect(Set(indexes).isSuperset(of: [
            "idx_outputs_source_ext", "idx_outputs_at", "idx_outputs_repo_number", "idx_outputs_resource_key",
        ]))
        #expect(Migrations.tableNames.contains("outputs"))
    }

    @Test("a kind this build does not know still decodes, and keeps its spelling")
    func unknownKind() throws {
        let db = try Database.inMemory()
        let store = OutputStore(db)
        try store.upsert(output("deck:1", kind: OutputKind(rawValue: "deck_published")))
        let row = try #require(try store.outputs(day: "2026-09-07", timeZone: TimeZone(identifier: "UTC")!).first)
        #expect(row.kind.rawValue == "deck_published")
        #expect(!OutputKind.known.contains(row.kind))
        #expect(row.kind.verb == "deck published")
    }

    @Test("upserting the same row again changes nothing, not even synced_at")
    func idempotent() throws {
        let db = try Database.inMemory()
        let store = OutputStore(db)
        #expect(try store.upsert(output()))
        let first = try store.outputs(from: .distantPast, to: .distantFuture)

        // The next round's query has a different window and a later sync time.
        #expect(try !store.upsert(output(provenance: "gh search prs later", syncedAt: GHFixtures.syncedAt + 900)))
        #expect(try store.outputs(from: .distantPast, to: .distantFuture) == first)

        // A real change is written, onto the same id.
        #expect(try store.upsert(output(title: "Add the shipped ledger", syncedAt: GHFixtures.syncedAt + 1800)))
        let changed = try store.outputs(from: .distantPast, to: .distantFuture)
        #expect(changed.count == 1)
        #expect(changed[0].id == first[0].id)
        #expect(changed[0].title == "Add the shipped ledger")
    }

    @Test("a day's rows are the ones whose time falls in it; deleteAll takes one source")
    func dayAndDelete() throws {
        let db = try Database.inMemory()
        let store = OutputStore(db)
        let utc = TimeZone(identifier: "UTC")!
        try store.upsert(output("a", at: GHFixtures.date("2026-09-07T23:59:00Z")))
        try store.upsert(output("b", at: GHFixtures.date("2026-09-08T00:01:00Z")))
        #expect(try store.outputs(day: "2026-09-07", timeZone: utc).map(\.externalId) == ["a"])
        #expect(try store.delete(source: Output.github, externalId: "a") == 1)
        #expect(try store.deleteAll(source: Output.github) == 1)
        #expect(try store.count(source: Output.github) == 0)
    }
}
