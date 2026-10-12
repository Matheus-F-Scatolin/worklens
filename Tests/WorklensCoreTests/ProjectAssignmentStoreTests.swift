import Foundation
import GRDB
import Testing
@testable import WorklensCore

/// #324: the `project_assignments` table and its store.
@Suite("ProjectAssignmentStore")
struct ProjectAssignmentStoreTests {
    private func at(_ minute: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + minute * 60) }

    @Test("the migration adds the table, its columns and the range index")
    func schema() throws {
        let db = try Database.inMemory()
        #expect(Migrations.tableNames.last == "project_assignments")
        let (columns, indexes) = try db.writer.read { db in
            (
                try db.columns(in: "project_assignments").map(\.name),
                try db.indexes(on: "project_assignments").map(\.name)
            )
        }
        #expect(columns == ["id", "from_at", "to_at", "project_key", "created_at"])
        #expect(indexes.contains("idx_project_assignments_range"))
    }

    @Test("insert, read back, overlap, count, reassign and delete")
    func roundTrip() throws {
        let store = ProjectAssignmentStore(try Database.inMemory())
        let first = try store.insert(from: at(0), to: at(60), projectKey: "acme", createdAt: at(100))
        let second = try store.insert(from: at(30), to: at(90), projectKey: "beta", createdAt: at(100))
        #expect(first.id != second.id)
        #expect(try store.assignment(id: first.id) == first)
        #expect(try store.all() == [first, second])

        // Half-open: a row ending where the window starts does not overlap it.
        #expect(try store.overlapping(from: at(60), to: at(120)).map(\.id) == [second.id])
        #expect(try store.overlapping(from: at(-30), to: at(0)).isEmpty)
        #expect(try store.overlapping(from: at(10), to: at(40)).map(\.id) == [first.id, second.id])

        #expect(try store.count(projectKey: "acme") == 1)
        #expect(try store.reassign(projectKey: "acme", to: "beta") == 1)
        #expect(try store.count(projectKey: "beta") == 2)

        #expect(try store.delete(id: first.id))
        #expect(try !store.delete(id: first.id))
        #expect(try store.assignment(id: first.id) == nil)
    }

    @Test("the same created_at breaks the tie by id, so the later row is the newer one")
    func newer() {
        let older = ProjectAssignment(id: 1, from: at(0), to: at(10), projectKey: "a", createdAt: at(5))
        let sameTime = ProjectAssignment(id: 2, from: at(0), to: at(10), projectKey: "b", createdAt: at(5))
        let later = ProjectAssignment(id: 0, from: at(0), to: at(10), projectKey: "c", createdAt: at(6))
        #expect(sameTime.isNewer(than: older))
        #expect(!older.isNewer(than: sameTime))
        #expect(later.isNewer(than: sameTime))
    }

    @Test("erasing a range keeps the assignments: they are your own corrections, not captured data")
    func eraseKeepsAssignments() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-assignments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var config = Config.defaults()
        config.dataDir = dir
        let db = try Database(dataDir: dir)
        let store = ProjectAssignmentStore(db)
        let row = try store.insert(from: at(0), to: at(60), projectKey: "acme", createdAt: at(100))

        let eraser = DataEraser(config: config, db: db, timeZone: TimeZone(identifier: "UTC")!, now: { at(200) })
        try await eraser.erase(from: at(-10), to: at(70))
        #expect(try store.all() == [row])
    }
}
