import Foundation
import GRDB

/// Reads and writes `activity_blocks`.
public struct ActivityBlockStore: Sendable {
    private let db: Database
    public init(_ db: Database) { self.db = db }

    public func fetch(day: String) throws -> [ActivityBlock] {
        try db.writer.read { db in
            try ActivityBlock
                .filter(Column("day") == day)
                .order(Column("start_at").asc)
                .fetchAll(db)
        }
    }

    /// Insert or replace by primary key, refreshing `updated_at`.
    public func upsert(_ block: ActivityBlock) throws {
        var block = block
        block.updatedAt = Date()
        try db.writer.write { try block.save($0) }
    }

    /// Clears the screen-derived blocks for a day so the timeline can be rebuilt from scratch
    /// without touching blocks that came from calendar or Granola.
    public func deleteScreenBlocks(day: String) throws {
        try db.writer.write { db in
            _ = try ActivityBlock
                .filter(Column("day") == day && Column("source") == ActivitySource.screen.rawValue)
                .deleteAll(db)
        }
    }

    /// Clears the screen-derived blocks that overlap `[from, to]`, whichever day they belong to.
    /// #16's eraser uses this rather than `deleteScreenBlocks(day:)`: a partial erase must not
    /// take down the blocks either side of the stretch it removed.
    @discardableResult
    public func deleteScreenBlocks(overlapping from: Date, to: Date) throws -> [String] {
        try db.writer.write { db in
            let condemned = try ActivityBlock
                .filter(Column("source") == ActivitySource.screen.rawValue)
                .filter(Column("start_at") <= to && Column("end_at") >= from)
                .fetchAll(db)
            for block in condemned { _ = try block.delete(db) }
            return condemned.map(\.day)
        }
    }

    /// Clears the blocks a context source owns for a day, so #19 can rewrite them from
    /// `context_events` without touching the screen-derived ones.
    public func deleteBlocks(day: String, sources: [ActivitySource]) throws {
        guard !sources.isEmpty else { return }
        let raw = sources.map(\.rawValue)
        try db.writer.write { db in
            _ = try ActivityBlock
                .filter(Column("day") == day && raw.contains(Column("source")))
                .deleteAll(db)
        }
    }

    /// Inclusive on both ends; `from` and `to` are `YYYY-MM-DD`.
    public func fetchRange(from: String, to: String) throws -> [ActivityBlock] {
        try db.writer.read { db in
            try ActivityBlock
                .filter(Column("day") >= from && Column("day") <= to)
                .order(Column("day").asc, Column("start_at").asc)
                .fetchAll(db)
        }
    }
}
