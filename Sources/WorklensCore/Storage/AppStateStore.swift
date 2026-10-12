import Foundation
import GRDB

/// Small key/value scratchpad for things that do not deserve a table: the last fingerprint,
/// the last report date, sync cursors.
public struct AppStateStore: Sendable {
    private let db: Database
    public init(_ db: Database) { self.db = db }

    public func get(_ key: String) throws -> String? {
        try db.writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = ?", arguments: [key])
        }
    }

    public func set(_ key: String, _ value: String) throws {
        try db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_state (key, value, updated_at) VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                    """,
                arguments: [key, value, Date()]
            )
        }
    }

    /// Every key starting with `prefix`. #137 uses it to drop the one-day budget raises that
    /// belong to days that have passed.
    public func keys(withPrefix prefix: String) throws -> [String] {
        try db.writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT key FROM app_state WHERE key LIKE ? ESCAPE '\\'",
                arguments: [AppStateStore.likePattern(prefix)]
            )
        }
    }

    /// `LIKE` treats `%` and `_` as wildcards, so a prefix that contains one has to escape it.
    static func likePattern(_ prefix: String) -> String {
        var escaped = ""
        for character in prefix {
            if character == "%" || character == "_" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped + "%"
    }

    public func delete(_ key: String) throws {
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM app_state WHERE key = ?", arguments: [key])
        }
    }

    public func getDate(_ key: String) throws -> Date? {
        guard let raw = try get(key) else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    public func setDate(_ key: String, _ date: Date) throws {
        try set(key, ISO8601DateFormatter().string(from: date))
    }

    public func getCodable<T: Decodable>(_ key: String) throws -> T? {
        guard let raw = try get(key), let data = raw.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func setCodable<T: Encodable>(_ key: String, _ value: T) throws {
        let data = try JSONEncoder().encode(value)
        try set(key, String(decoding: data, as: UTF8.self))
    }
}
