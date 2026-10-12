import Foundation
import GRDB

/// Reads and writes `foreground_sessions`.
///
/// The invariant every method preserves: **at most one open row**. `openInterval` closes whatever
/// was open before it inserts, so a missed close (a crash, a notification that never arrived)
/// cannot leave two rows claiming the same minute.
public struct ForegroundSessionStore: Sendable {
    private let db: Database
    public init(_ db: Database) { self.db = db }

    // MARK: Writing

    /// The open row, if there is one. Latest start wins, so an older leak is never mistaken for
    /// the live interval.
    public func openSession() throws -> ForegroundSession? {
        try db.writer.read { db in
            try ForegroundSession
                .filter(Column("end_at") == nil)
                .order(Column("start_at").desc)
                .fetchOne(db)
        }
    }

    public func insert(_ session: ForegroundSession) throws {
        try db.writer.write { try session.insert($0) }
    }

    /// Closes the open row (if any) at `at`, then opens `session`. Returns the row as stored.
    @discardableResult
    public func openInterval(_ session: ForegroundSession) throws -> ForegroundSession {
        try db.writer.write { db in
            let open = try ForegroundSession.filter(Column("end_at") == nil).fetchAll(db)
            for var row in open {
                row.endAt = max(row.startAt, session.startAt)
                try row.update(db)
            }
            try session.insert(db)
            return session
        }
    }

    /// Closes one row. `at` is clamped to the row's start, so a clock that went backwards cannot
    /// write a negative interval.
    @discardableResult
    public func close(id: String, at: Date) throws -> ForegroundSession? {
        try db.writer.write { db in
            guard var row = try ForegroundSession.filter(Column("id") == id).fetchOne(db) else { return nil }
            row.endAt = max(row.startAt, at)
            try row.update(db)
            return row
        }
    }

    /// Closes every row left open, at `at` clamped per row. Returns how many were closed.
    @discardableResult
    public func closeOpen(at: Date) throws -> Int {
        try db.writer.write { db in
            let open = try ForegroundSession.filter(Column("end_at") == nil).fetchAll(db)
            for var row in open {
                row.endAt = max(row.startAt, at)
                try row.update(db)
            }
            return open.count
        }
    }

    // MARK: Reading

    /// Every row whose interval overlaps `[from, to)`. An open row counts as reaching `to`.
    public func fetch(overlapping from: Date, to: Date) throws -> [ForegroundSession] {
        try db.writer.read { db in
            try ForegroundSession
                .filter(Column("start_at") < to)
                .filter(Column("end_at") == nil || Column("end_at") > from)
                .order(Column("start_at").asc)
                .fetchAll(db)
        }
    }

    /// Every row overlapping the local day. Rows that started yesterday and ran into it are
    /// included; `StatsAggregator` clips them against the day's blocks.
    public func fetch(day: String, timeZone: TimeZone = .current) throws -> [ForegroundSession] {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return [] }
        return try fetch(overlapping: range.start, to: range.end)
    }

    // MARK: Erasing

    /// What `deleteRange` did, so the eraser can report it without reading the table back.
    public struct EraseCounts: Sendable, Equatable {
        public var deleted = 0
        public var trimmed = 0
        public var total: Int { deleted + trimmed }
    }

    /// Removes the part of every session that falls inside `[from, to]`.
    ///
    /// A row entirely inside the stretch goes. A row that only overlaps an edge is trimmed to the
    /// part outside it. A row that spans the whole stretch is **split** rather than truncated:
    /// truncating would silently donate the minutes after `to` to nothing, and the point of the
    /// table is that the day still adds up after an erase.
    @discardableResult
    public func deleteRange(from: Date, to: Date) throws -> EraseCounts {
        try db.writer.write { db in
            var counts = EraseCounts()
            let candidates = try ForegroundSession
                .filter(Column("start_at") <= to)
                .filter(Column("end_at") == nil || Column("end_at") >= from)
                .order(Column("start_at").asc)
                .fetchAll(db)

            for row in candidates {
                // An open row has no end yet; for overlap arithmetic it reaches forever, which
                // makes it either a straddle or a start-edge trim, never a whole deletion.
                let end = row.endAt
                let startsBefore = row.startAt < from
                let endsAfter = end.map { $0 > to } ?? true

                switch (startsBefore, endsAfter) {
                case (false, false):
                    try row.delete(db)
                    counts.deleted += 1
                case (true, false):
                    var trimmed = row
                    trimmed.endAt = from
                    try trimmed.update(db)
                    counts.trimmed += 1
                case (false, true):
                    var trimmed = row
                    trimmed.startAt = to
                    if let end, end < to { trimmed.endAt = to }
                    try trimmed.update(db)
                    counts.trimmed += 1
                case (true, true):
                    var head = row
                    head.endAt = from
                    try head.update(db)
                    var tail = row
                    tail.id = Identifiers.new()
                    tail.startAt = to
                    tail.endAt = end
                    try tail.insert(db)
                    counts.trimmed += 1
                }
            }
            return counts
        }
    }
}
