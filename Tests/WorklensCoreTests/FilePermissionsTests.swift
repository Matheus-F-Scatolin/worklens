import Foundation
import Testing
@testable import WorklensCore

/// Owner-only modes on the data folder, its files and the database sidecars.
@Suite("File permissions")
struct FilePermissionsTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-perms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]
        )
        return url
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("a created folder and its new parents are 0700; an existing one is tightened")
    func privateDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("screenshots/2026-10-12")
        try FilePermissions.createPrivateDirectory(at: nested)
        #expect(try mode(nested) == 0o700)
        #expect(try mode(nested.deletingLastPathComponent()) == 0o700)

        try FilePermissions.createPrivateDirectory(at: root)
        #expect(try mode(root) == 0o700)
    }

    @Test("writePrivate leaves a 0600 file with the bytes, replacing an older readable one")
    func writePrivate() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("frame.jpg")
        FileManager.default.createFile(atPath: file.path, contents: Data("old".utf8), attributes: [.posixPermissions: 0o644])

        try FilePermissions.writePrivate(Data("new".utf8), to: file)
        #expect(try mode(file) == 0o600)
        #expect(try Data(contentsOf: file) == Data("new".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(leftovers == ["frame.jpg"])
    }

    @Test("tightenTree strips group and other bits everywhere and skips symbolic links")
    func tightenTree() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let fm = FileManager.default
        let folder = root.appendingPathComponent("context/granola")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let note = folder.appendingPathComponent("note.md")
        fm.createFile(atPath: note.path, contents: Data(), attributes: [.posixPermissions: 0o644])
        let script = root.appendingPathComponent("tool")
        fm.createFile(atPath: script.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        let target = outside.appendingPathComponent("shared.txt")
        fm.createFile(atPath: target.path, contents: Data(), attributes: [.posixPermissions: 0o644])
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: target)

        // root, context, granola, note.md, tool
        #expect(FilePermissions.tightenTree(at: root) == 5)
        #expect(try mode(root) == 0o700)
        #expect(try mode(folder) == 0o700)
        #expect(try mode(note) == 0o600)
        #expect(try mode(script) == 0o700)
        #expect(try mode(target) == 0o644)
        #expect(FilePermissions.tightenTree(at: root) == 0)
    }

    @Test("the database and its -wal and -shm are 0600, new or left readable by an older build")
    func databaseFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fresh = root.appendingPathComponent("fresh")
        let db = try Database(dataDir: fresh)
        try db.checkpoint()
        #expect(try mode(fresh) == 0o700)
        for name in ["worklens.sqlite", "worklens.sqlite-wal", "worklens.sqlite-shm"] {
            let url = fresh.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { #expect(try mode(url) == 0o600) }
        }
        #expect(try mode(fresh.appendingPathComponent("worklens.sqlite")) == 0o600)

        let old = root.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        for name in ["worklens.sqlite", "worklens.sqlite-wal"] {
            FileManager.default.createFile(
                atPath: old.appendingPathComponent(name).path, contents: Data(),
                attributes: [.posixPermissions: 0o644]
            )
        }
        _ = try Database(dataDir: old)
        #expect(try mode(old) == 0o700)
        #expect(try mode(old.appendingPathComponent("worklens.sqlite")) == 0o600)
        #expect(try mode(old.appendingPathComponent("worklens.sqlite-wal")) == 0o600)
    }
}
