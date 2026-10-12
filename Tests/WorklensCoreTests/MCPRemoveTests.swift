import Foundation
import Testing

@testable import WorklensCore

/// #155: taking the Worklens entry back out of Claude Desktop's configuration.
///
/// The mirror of `MCPInstallTests`, and it has the same one thing to prove: a file somebody else
/// owns survives. An uninstall that removed a person's other MCP servers, or rewrote a file it
/// could not parse, would be a worse outcome than leaving the stale entry behind.
@Suite("MCP remove")
struct MCPRemoveTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-mcp-remove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ json: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("claude_desktop_config.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    private func servers(at url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        return try #require((object as? [String: Any])?["mcpServers"] as? [String: Any])
    }

    private let both = """
        {
          "mcpServers": {
            "worklens": {"command": "/Applications/Worklens.app/Contents/MacOS/Worklens", "args": ["mcp"]},
            "notes": {"command": "/opt/notes/server"}
          },
          "globalShortcut": "Alt+Space"
        }
        """

    // MARK: Finding the key

    @Test("the installed key is `worklens` when that is what the file calls it")
    func findsTheDocumentedKey() throws {
        let url = try write(both, in: try temporaryDirectory())
        #expect(MCPClientConfig.installedKey(at: url) == "worklens")
    }

    /// `install` writes back under whatever name the user gave the entry, so `remove` has to find
    /// it the same way or it would leave a renamed server behind launching a deleted binary.
    @Test("a renamed entry is found by the binary it launches")
    func findsARenamedKey() throws {
        let url = try write(
            """
            {"mcpServers": {"my-day": {"command": "/Applications/Worklens.app/Contents/MacOS/Worklens"}}}
            """,
            in: try temporaryDirectory()
        )
        #expect(MCPClientConfig.installedKey(at: url) == "my-day")
    }

    @Test("a file with no Worklens entry, no file at all, and a file of nonsense all answer nil")
    func findsNothing() throws {
        let directory = try temporaryDirectory()
        let other = try write(
            """
            {"mcpServers": {"notes": {"command": "/opt/notes/server"}}}
            """, in: directory)
        #expect(MCPClientConfig.installedKey(at: other) == nil)
        #expect(
            MCPClientConfig.installedKey(at: directory.appendingPathComponent("gone.json")) == nil)

        let broken = directory.appendingPathComponent("broken.json")
        try Data("{ not json".utf8).write(to: broken)
        #expect(MCPClientConfig.installedKey(at: broken) == nil)
    }

    // MARK: Removing

    @Test("only the Worklens entry goes; every other server and key survives")
    func removesOnlyOurs() throws {
        let url = try write(both, in: try temporaryDirectory())
        let removal = try #require(try MCPClientConfig.remove(key: "worklens", at: url))
        #expect(removal.key == "worklens")

        let servers = try servers(at: url)
        #expect(servers["worklens"] == nil)
        #expect(servers["notes"] != nil)
        let object = try #require(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        )
        #expect(object["globalShortcut"] as? String == "Alt+Space")
    }

    /// The last server out leaves `mcpServers: {}` rather than deleting the key. An empty object
    /// is valid, and removing a key nobody asked about is the failure this method must not have.
    @Test("removing the only server leaves an empty mcpServers behind, not a missing one")
    func leavesTheContainer() throws {
        let url = try write(
            """
            {"mcpServers": {"worklens": {"command": "/Applications/Worklens.app/Contents/MacOS/Worklens"}}}
            """,
            in: try temporaryDirectory()
        )
        try MCPClientConfig.remove(key: "worklens", at: url)
        #expect(try servers(at: url).isEmpty)
    }

    @Test("the old file is copied aside before the write")
    func backsUpFirst() throws {
        let url = try write(both, in: try temporaryDirectory())
        let removal = try #require(try MCPClientConfig.remove(key: "worklens", at: url))
        let backup = try #require(removal.backup)
        #expect(backup.lastPathComponent.hasSuffix(".bak"))
        let saved = try String(contentsOf: backup, encoding: .utf8)
        #expect(saved.contains("\"worklens\""))
    }

    /// Same reasoning as `install`: two removals in the same second want the same backup name,
    /// and the copy worth keeping is the first — the user's own file.
    @Test("a backup already at that name is the earlier one and is not replaced")
    func keepsTheFirstBackup() throws {
        let url = try write(both, in: try temporaryDirectory())
        let now = Date()
        try MCPClientConfig.remove(key: "worklens", at: url, now: now)
        try MCPClientConfig.remove(key: "notes", at: url, now: now)

        let backup = MCPClientConfig.backupURL(for: url, now: now)
        let saved = try String(contentsOf: backup, encoding: .utf8)
        #expect(saved.contains("\"worklens\""))
        #expect(try servers(at: url).isEmpty)
    }

    @Test("nothing to remove is nil, not an error, and touches no file")
    func nothingToDo() throws {
        let directory = try temporaryDirectory()
        #expect(
            try MCPClientConfig.remove(
                key: "worklens", at: directory.appendingPathComponent("gone.json")) == nil)

        let url = try write(
            """
            {"mcpServers": {"notes": {"command": "/opt/notes/server"}}}
            """, in: directory)
        let before = try Data(contentsOf: url)
        #expect(try MCPClientConfig.remove(key: "worklens", at: url) == nil)
        #expect(try Data(contentsOf: url) == before)

        let noServers = try write("{\"globalShortcut\": \"Alt+Space\"}", in: directory)
        #expect(try MCPClientConfig.remove(key: "worklens", at: noServers) == nil)
    }

    /// A file somebody hand-edited into invalid JSON is left exactly as it is: an uninstall that
    /// replaced it would take their other servers with it.
    @Test("a file that does not parse is an error, and is left untouched")
    func refusesUnparseableFiles() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("claude_desktop_config.json")
        try Data("{ \"mcpServers\": ".utf8).write(to: url)

        #expect(throws: MCPClientConfig.InstallError.self) {
            try MCPClientConfig.remove(key: "worklens", at: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ \"mcpServers\": ")
    }
}

/// #248: Disconnect, for the second client. The same `remove`, against the file Claude Code
/// keeps everything else in — so "every other key survives" matters more here than it did.
@Suite("MCP disconnect, Claude Code")
struct MCPRemoveClaudeCodeTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-mcp-disconnect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let claudeCodeFile = """
        {
          "numStartups": 12,
          "projects": {"/Users/someone/code": {"allowedTools": []}},
          "mcpServers": {
            "worklens": {"command": "/Applications/Worklens.app/Contents/MacOS/Worklens", "args": ["mcp"]},
            "other": {"command": "/usr/bin/other"}
          }
        }
        """

    @Test("disconnecting takes out only the worklens entry and copies the file aside first")
    func removesOnlyItsOwnEntry() throws {
        let url = try temporaryDirectory().appendingPathComponent(".claude.json")
        try Data(claudeCodeFile.utf8).write(to: url)

        let key = try #require(MCPClientConfig.installedKey(at: url))
        #expect(key == "worklens")
        let removal = try #require(try MCPClientConfig.remove(key: key, at: url))
        let backup = try #require(removal.backup)
        #expect(FileManager.default.fileExists(atPath: backup.path))

        let object = try #require(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        #expect(object["numStartups"] as? Int == 12)
        #expect(object["projects"] as? [String: Any] != nil)
        let servers = try #require(object["mcpServers"] as? [String: Any])
        #expect(servers["worklens"] == nil)
        #expect(servers["other"] != nil)
    }

    @Test("a Claude Code file with no Worklens entry has nothing to disconnect")
    func nothingToRemove() throws {
        let url = try temporaryDirectory().appendingPathComponent(".claude.json")
        try Data("{\"numStartups\": 3}".utf8).write(to: url)
        #expect(MCPClientConfig.installedKey(at: url) == nil)
        #expect(try MCPClientConfig.remove(key: "worklens", at: url) == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "{\"numStartups\": 3}")
    }
}
