import Foundation
import GRDB

public enum DatabaseError: Error, CustomStringConvertible {
    case integrityCheckFailed(String)
    /// The database was unusable and has been set aside; the app is running on a fresh one.
    /// Carried as an error case rather than thrown, so `recoveredFrom` can report it.
    case replacedCorrupt(movedTo: String, detail: String)

    public var description: String {
        switch self {
        case let .integrityCheckFailed(detail):
            return "SQLite integrity check failed: \(detail)"
        case let .replacedCorrupt(movedTo, detail):
            return "the database could not be opened (\(detail)); it was moved to \(movedTo) "
                + "and a new one was created"
        }
    }
}

/// The one way into `DATA_DIR/worklens.sqlite`. Everything else in Worklens goes through a
/// repository that holds one of these.
///
/// The writer is a `DatabasePool` (WAL) for on-disk databases so the UI can read while workers
/// write, and a `DatabaseQueue` for the in-memory database tests use — hence `writer: any
/// DatabaseWriter` rather than a concrete `DatabasePool`.
public final class Database: Sendable {
    public let writer: any DatabaseWriter

    /// Set when the file on disk was unusable and this instance is a fresh replacement. The app
    /// reads it to tell the user, because silently starting over on an empty database is the one
    /// failure a personal history tool must never be quiet about.
    public let recoveredFrom: DatabaseError?

    /// Opens (creating if needed) `dataDir/worklens.sqlite`, runs migrations, checks integrity.
    ///
    /// A file that fails to open, to migrate or to `PRAGMA quick_check` is **not** a reason to
    /// refuse to start: the alternative is an app that will not run until someone finds the
    /// sqlite CLI. It is moved aside to `worklens.sqlite.corrupt-<timestamp>` (with its `-wal`
    /// and `-shm`) and a new one takes its place, with `recoveredFrom` set so the user hears
    /// about it. Nothing is deleted — a corrupt database is still the only copy of a history,
    /// and `sqlite3 .recover` on it later is a real option.
    public init(dataDir: URL) throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let url = dataDir.appendingPathComponent("worklens.sqlite")
        do {
            let pool = try DatabasePool(path: url.path, configuration: Database.configuration())
            try Migrations.migrator.migrate(pool)
            try Database.quickCheck(pool)
            self.writer = pool
            self.recoveredFrom = nil
        } catch {
            let detail = (error as? DatabaseError)?.description ?? "\(error)"
            let movedTo = try Database.setAside(url)
            Log.storage.error("database unusable (\(detail)); moved to \(movedTo.lastPathComponent)")
            let pool = try DatabasePool(path: url.path, configuration: Database.configuration())
            try Migrations.migrator.migrate(pool)
            self.writer = pool
            self.recoveredFrom = .replacedCorrupt(movedTo: movedTo.path, detail: detail)
        }
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        self.recoveredFrom = nil
        try Migrations.migrator.migrate(writer)
    }

    private init(readOnly writer: any DatabaseWriter) {
        self.writer = writer
        self.recoveredFrom = nil
    }

    /// Opens `dataDir/worklens.sqlite` **read-only**, with no migration and no `quick_check` —
    /// and so with no path that moves the file aside. `init(dataDir:)` treats every failure to
    /// open as corruption, `SQLITE_BUSY` past the five-second timeout included, which a caller
    /// that only wants to read must not be able to do to a database the app itself has open
    /// (#140). A data directory with no file in it yet gets a fresh in-memory database rather
    /// than a new file on disk.
    public static func readOnly(dataDir: URL) throws -> Database {
        let url = dataDir.appendingPathComponent("worklens.sqlite")
        guard FileManager.default.fileExists(atPath: url.path) else { return try inMemory() }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(5)
        configuration.foreignKeysEnabled = true
        return Database(readOnly: try DatabaseQueue(path: url.path, configuration: configuration))
    }

    /// Renames `worklens.sqlite` and its sidecars out of the way, returning where the main file
    /// went. The timestamp is in the name, so a second failure never overwrites the first.
    private static func setAside(_ url: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = "corrupt-\(formatter.string(from: Date()))"
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).\(suffix)")

        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            try manager.moveItem(at: url, to: target)
        }
        for sidecar in ["-wal", "-shm"] {
            let from = URL(fileURLWithPath: url.path + sidecar)
            guard manager.fileExists(atPath: from.path) else { continue }
            try? manager.moveItem(at: from, to: URL(fileURLWithPath: target.path + sidecar))
        }
        return target
    }

    /// A fresh, migrated, in-memory database. Each call is independent.
    public static func inMemory() throws -> Database {
        let queue = try DatabaseQueue(configuration: configuration())
        return try Database(writer: queue)
    }

    static func configuration() -> Configuration {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return config
    }

    private static func quickCheck(_ writer: any DatabaseWriter) throws {
        let result = try writer.read { db in
            try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
        }
        guard result == "ok" else { throw DatabaseError.integrityCheckFailed(result) }
    }

    /// `PRAGMA integrity_check`, for the storage tests. Returns "ok" on a healthy database.
    public func integrityCheck() throws -> String {
        try writer.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "unknown"
        }
    }

    /// Flushes the write-ahead log into the main file and truncates it. Run at shutdown, so a
    /// `-wal` the size of a day's writes does not outlive the process that made it.
    public func checkpoint() throws {
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// Rewrites the file to reclaim the space deleted rows left behind. Minutes-long on a large
    /// database and it takes the write lock, which is why #18 only runs it when the app has been
    /// idle for ten minutes and at most once a week.
    public func vacuum() throws {
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }

    /// The size of the database and its write-ahead log, for the log.
    public func fileBytes(dataDir: URL) -> Int64 {
        let base = dataDir.appendingPathComponent("worklens.sqlite").path
        return [base, base + "-wal", base + "-shm"].reduce(Int64(0)) { total, path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// Row counts for every table in the v1 schema, in schema order.
    public func tableCounts() throws -> [(table: String, rows: Int)] {
        try writer.read { db in
            try Migrations.tableNames.map { name in
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(name)") ?? 0
                return (table: name, rows: count)
            }
        }
    }
}
