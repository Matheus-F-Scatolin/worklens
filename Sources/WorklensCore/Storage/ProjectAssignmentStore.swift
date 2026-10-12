import Foundation
import GRDB

/// A stretch of time you said was one project (#324): `worklens projects assign`.
public struct ProjectAssignment: Sendable, Equatable, Codable {
    public var id: Int64
    public var from: Date
    public var to: Date
    public var projectKey: String
    public var createdAt: Date

    public init(id: Int64, from: Date, to: Date, projectKey: String, createdAt: Date) {
        self.id = id
        self.from = from
        self.to = to
        self.projectKey = projectKey
        self.createdAt = createdAt
    }

    /// Does `self` win an overlap with `other`? The newest does; the higher id breaks a tie.
    public func isNewer(than other: ProjectAssignment) -> Bool {
        (createdAt, id) > (other.createdAt, other.id)
    }

    enum CodingKeys: String, CodingKey {
        case id, from, to
        case projectKey = "project"
        case createdAt = "created_at"
    }
}

/// `project_assignments`: insert, delete by id, read what overlaps a range. Nothing here logs.
public struct ProjectAssignmentStore: Sendable {
    private let db: Database

    public init(_ db: Database) { self.db = db }

    @discardableResult
    public func insert(from: Date, to: Date, projectKey: String, createdAt: Date = Date()) throws -> ProjectAssignment {
        try db.writer.write { db in
            try db.execute(
                sql: "INSERT INTO project_assignments (from_at, to_at, project_key, created_at) VALUES (?, ?, ?, ?)",
                arguments: [from, to, projectKey, createdAt]
            )
            return ProjectAssignment(
                id: db.lastInsertedRowID, from: from, to: to, projectKey: projectKey, createdAt: createdAt
            )
        }
    }

    /// Returns whether a row went.
    @discardableResult
    public func delete(id: Int64) throws -> Bool {
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM project_assignments WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    public func assignment(id: Int64) throws -> ProjectAssignment? {
        try fetch("SELECT * FROM project_assignments WHERE id = ?", [id]).first
    }

    /// Every row, oldest stretch first.
    public func all() throws -> [ProjectAssignment] {
        try fetch("SELECT * FROM project_assignments ORDER BY from_at, id", [])
    }

    /// Rows that overlap `[from, to)`, oldest stretch first.
    public func overlapping(from: Date, to: Date) throws -> [ProjectAssignment] {
        try fetch(
            "SELECT * FROM project_assignments WHERE from_at < ? AND to_at > ? ORDER BY from_at, id",
            [to, from]
        )
    }

    public func count(projectKey: String) throws -> Int {
        try db.writer.read { db in
            guard try db.tableExists("project_assignments") else { return 0 }
            return try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM project_assignments WHERE project_key = ?", arguments: [projectKey]
            ) ?? 0
        }
    }

    /// Points every row on `key` at `target`: what `projects merge` does. Returns how many moved.
    @discardableResult
    public func reassign(projectKey key: String, to target: String) throws -> Int {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE project_assignments SET project_key = ? WHERE project_key = ?", arguments: [target, key]
            )
            return db.changesCount
        }
    }

    /// A read-only database an older app has not migrated has no table yet: no rows, not an error.
    private func fetch(_ sql: String, _ arguments: StatementArguments) throws -> [ProjectAssignment] {
        try db.writer.read { db in
            guard try db.tableExists("project_assignments") else { return [] }
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                ProjectAssignment(
                    id: row["id"], from: row["from_at"], to: row["to_at"],
                    projectKey: row["project_key"], createdAt: row["created_at"]
                )
            }
        }
    }
}
