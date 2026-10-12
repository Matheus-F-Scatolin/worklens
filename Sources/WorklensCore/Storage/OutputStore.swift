import Foundation
import GRDB

/// Reads and writes `outputs`, the shipped ledger (#314).
///
/// Neither `DataEraser` nor `Retention` touches this table, the same way they leave
/// `context_events` alone: a merged PR is not something Worklens watched you do. `deleteAll` is
/// what `worklens shipped forget` and `GITHUB_SHIPPED=false` call.
public struct OutputStore: Sendable {
    private let db: Database
    public init(_ db: Database) { self.db = db }

    /// Inserts the row, or updates the one with the same `(source, external_id)` when something
    /// it says changed. Returns whether a row was written.
    ///
    /// A re-sync that finds the same PR again writes nothing: `provenance` carries the query's date
    /// window, which moves every round, so it and `synced_at` only follow a real change. The
    /// project columns are never overwritten here; they belong to whatever attributed the row.
    @discardableResult
    public func upsert(_ output: Output) throws -> Bool {
        try upsert([output]) > 0
    }

    /// Every row in one write transaction. Returns how many were written.
    @discardableResult
    public func upsert(_ outputs: [Output]) throws -> Int {
        guard !outputs.isEmpty else { return 0 }
        return try db.writer.write { db in
            var written = 0
            for output in outputs {
                if try Self.upsert(output, in: db) { written += 1 }
            }
            return written
        }
    }

    private static func upsert(_ output: Output, in db: GRDB.Database) throws -> Bool {
        try db.execute(
            sql: """
                INSERT INTO outputs
                  (id, source, kind, at, repo, number, url, title, path, resource_key,
                   external_id, project_key, project_rule, provenance, synced_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source, external_id) DO UPDATE SET
                  kind = excluded.kind,
                  at = excluded.at,
                  repo = excluded.repo,
                  number = excluded.number,
                  url = excluded.url,
                  title = excluded.title,
                  path = excluded.path,
                  resource_key = excluded.resource_key,
                  provenance = excluded.provenance,
                  synced_at = excluded.synced_at
                WHERE outputs.kind IS NOT excluded.kind
                   OR outputs.at IS NOT excluded.at
                   OR outputs.repo IS NOT excluded.repo
                   OR outputs.number IS NOT excluded.number
                   OR outputs.url IS NOT excluded.url
                   OR outputs.title IS NOT excluded.title
                   OR outputs.path IS NOT excluded.path
                   OR outputs.resource_key IS NOT excluded.resource_key
                """,
            arguments: [
                output.id, output.source, output.kind, output.at, output.repo, output.number,
                output.url, output.title, output.path, output.resourceKey, output.externalId,
                output.projectKey, output.projectRule, output.provenance, output.syncedAt,
            ]
        )
        return db.changesCount > 0
    }

    /// Removes one row. What a reopened PR or issue does to the terminal row it had.
    @discardableResult
    public func delete(source: String, externalId: String) throws -> Int {
        try db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM outputs WHERE source = ? AND external_id = ?",
                arguments: [source, externalId]
            )
            return db.changesCount
        }
    }

    /// Every row of one source. Returns how many went.
    @discardableResult
    public func deleteAll(source: String) throws -> Int {
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM outputs WHERE source = ?", arguments: [source])
            return db.changesCount
        }
    }

    /// Rows whose `at` falls in `[from, to)`, oldest first.
    public func outputs(from: Date, to: Date) throws -> [Output] {
        try db.writer.read { db in
            try Output
                .filter(Column("at") >= from && Column("at") < to)
                .order(Column("at").asc, Column("external_id").asc)
                .fetchAll(db)
        }
    }

    /// One local day's rows, oldest first.
    public func outputs(day: String, timeZone: TimeZone = .current) throws -> [Output] {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return [] }
        return try outputs(from: range.start, to: range.end)
    }

    public func count(source: String) throws -> Int {
        try db.writer.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM outputs WHERE source = ?", arguments: [source]
            ) ?? 0
        }
    }
}
