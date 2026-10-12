import Foundation
import Testing
@testable import WorklensCore

/// #140: writing another application's configuration file, and proving afterwards that the
/// server the client will launch reads the directory the user thinks it does.
@Suite("MCP install")
struct MCPInstallTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-mcp-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func plan(_ command: String = "/Applications/Worklens.app/Contents/MacOS/Worklens")
        -> MCPClientConfig.Plan
    {
        MCPClientConfig.Plan(command: command)
    }

    private func object(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    // MARK: The entry

    @Test("the plan is the documented entry, and pins nothing when there is nothing to pin")
    func planShape() throws {
        let json = plan().json
        #expect(json.contains("\"mcpServers\""))
        #expect(json.contains("\"worklens\""))
        #expect(json.contains("\"mcp\""))
        // Pretty-printed JSON escapes nothing in a path that a reader would have to undo.
        #expect(json.contains("/Applications/Worklens.app/Contents/MacOS/Worklens"))
        #expect(!json.contains("\"env\""))
    }

    /// The bullet this feature exists for: the client launches with a minimal environment, so
    /// the entry has to carry `WORKLENS_ENV_FILE` or the server reads the App Support layer
    /// alone.
    @Test("an env file the app was launched with is pinned into the entry")
    func planPinsEnvironment() {
        let pinned = MCPClientConfig.plan(
            executable: URL(fileURLWithPath: "/x/Worklens"),
            envFile: URL(fileURLWithPath: "/repo/.env")
        )
        #expect(pinned.env == ["WORKLENS_ENV_FILE": "/repo/.env"])
        #expect(pinned.json.contains("WORKLENS_ENV_FILE"))
    }

    // MARK: Writing

    @Test("a first install creates the file and needs no backup")
    func createsFile() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("claude_desktop_config.json")

        let installation = try MCPClientConfig.install(plan(), at: url)
        #expect(installation.createdFile)
        #expect(installation.backup == nil)

        let servers = try #require(try object(at: url)["mcpServers"] as? [String: Any])
        let entry = try #require(servers["worklens"] as? [String: Any])
        #expect(entry["command"] as? String == "/Applications/Worklens.app/Contents/MacOS/Worklens")
        #expect(entry["args"] as? [String] == ["mcp"])
    }

    @Test("only the worklens entry is merged; everything else survives")
    func mergesOnlyItsOwnEntry() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("claude_desktop_config.json")
        let before = """
            {"globalShortcut": "Cmd+Space",
             "mcpServers": {"filesystem": {"command": "/usr/bin/npx", "args": ["-y", "fs"]},
                            "worklens": {"command": "/old/Worklens", "args": ["serve"]}}}
            """
        try Data(before.utf8).write(to: url)

        let installation = try MCPClientConfig.install(plan(), at: url)
        #expect(!installation.createdFile)

        let written = try object(at: url)
        #expect(written["globalShortcut"] as? String == "Cmd+Space")
        let servers = try #require(written["mcpServers"] as? [String: Any])
        let other = try #require(servers["filesystem"] as? [String: Any])
        #expect(other["command"] as? String == "/usr/bin/npx")
        let entry = try #require(servers["worklens"] as? [String: Any])
        #expect(entry["command"] as? String == "/Applications/Worklens.app/Contents/MacOS/Worklens")
        #expect(entry["args"] as? [String] == ["mcp"])

        // The old file is still readable, byte for byte.
        let backup = try #require(installation.backup)
        #expect(try String(contentsOf: backup, encoding: .utf8) == before)
    }

    @Test("a file that is not JSON is refused, not replaced")
    func refusesUnmergeableFile() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("claude_desktop_config.json")
        try Data("{ hand edited, and broken".utf8).write(to: url)

        #expect(throws: MCPClientConfig.InstallError.self) {
            try MCPClientConfig.install(plan(), at: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ hand edited, and broken")
    }

    /// An empty file is a normal state — a client that has been opened but never configured —
    /// and there is nothing in it to lose.
    @Test("an empty file is written rather than refused")
    func emptyFile() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("claude_desktop_config.json")
        try Data("\n".utf8).write(to: url)

        let installation = try MCPClientConfig.install(plan(), at: url)
        #expect(installation.backup != nil)
        #expect(try object(at: url)["mcpServers"] != nil)
    }

    /// The backup name is second-granular, so the second install wants the path the first one
    /// used. What must survive there is the user's own file, not the entry Worklens itself
    /// wrote a moment earlier.
    @Test("two installs in the same second keep the first backup")
    func repeatedInstall() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("claude_desktop_config.json")
        let before = #"{"mcpServers":{},"theirs":"hand-edited"}"#
        try before.write(to: url, atomically: true, encoding: .utf8)
        let now = Date()
        try MCPClientConfig.install(plan(), at: url, now: now)
        let second = try MCPClientConfig.install(plan(), at: url, now: now)
        let backup = try #require(second.backup)
        #expect(backup == MCPClientConfig.backupURL(for: url, now: now))
        #expect(try String(contentsOf: backup, encoding: .utf8) == before)
    }

    /// `parse` finds an entry the user renamed by its command, so `install` has to repoint that
    /// entry. Adding a second one under `worklens` would leave the renamed one launching a
    /// binary that is gone, while the health check — which finds the fresh one — said all well.
    @Test("an entry the user renamed is repointed, not duplicated")
    func repointsRenamedEntry() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("claude_desktop_config.json")
        let before = """
            {"mcpServers":{"my-day":{"command":"/old/Worklens.app/Contents/MacOS/Worklens",\
            "args":["mcp"]},"other":{"command":"/usr/bin/true"}}}
            """
        try before.write(to: url, atomically: true, encoding: .utf8)

        try MCPClientConfig.install(plan(), at: url)

        let servers = try #require(try object(at: url)["mcpServers"] as? [String: Any])
        #expect(servers["worklens"] == nil)
        #expect(servers["other"] != nil)
        let mine = try #require(servers["my-day"] as? [String: Any])
        #expect(mine["command"] as? String == plan().command)
        #expect(
            MCPClientConfig.health(
                entry: MCPClientConfig.read(at: url), expecting: plan(), isExecutable: { _ in true }
            ) == .pointsHere
        )
    }

    // MARK: Health

    @Test("what is written, read back")
    func healthRoundTrip() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("claude_desktop_config.json")
        let plan = plan()
        try MCPClientConfig.install(plan, at: url)
        let health = MCPClientConfig.health(
            entry: MCPClientConfig.read(at: url), expecting: plan, isExecutable: { _ in true }
        )
        #expect(health == .pointsHere)
    }

    @Test("every state the card draws")
    func healthStates() {
        let plan = plan()
        let onDisk: (String) -> Bool = { _ in true }

        #expect(MCPClientConfig.health(entry: .noFile, expecting: plan, isExecutable: onDisk)
            == .notInstalled)
        #expect(MCPClientConfig.health(entry: .notConfigured, expecting: plan, isExecutable: onDisk)
            == .notInstalled)
        #expect(MCPClientConfig.health(
            entry: .unreadable("not valid JSON"), expecting: plan, isExecutable: onDisk
        ) == .unparseable("not valid JSON"))
        #expect(MCPClientConfig.health(
            entry: .configured(command: "/other/Worklens", args: ["mcp"], env: [:]),
            expecting: plan, isExecutable: onDisk
        ) == .pointsElsewhere(command: "/other/Worklens"))
        #expect(MCPClientConfig.health(
            entry: .configured(command: plan.command, args: ["serve"], env: [:]),
            expecting: plan, isExecutable: onDisk
        ) == .outOfDate(command: plan.command))
        // The normal outcome after a worktree is deleted: the entry is fine, the binary is gone.
        #expect(MCPClientConfig.health(
            entry: .configured(command: plan.command, args: ["mcp"], env: [:]),
            expecting: plan, isExecutable: { _ in false }
        ) == .stalePath(command: plan.command))
    }

    /// A pinned environment is part of the entry, so an entry that has lost it is out of date
    /// even though its command is right.
    @Test("a missing environment pin is out of date")
    func healthEnvironmentPin() {
        let pinned = MCPClientConfig.plan(
            executable: URL(fileURLWithPath: "/x/Worklens"),
            envFile: URL(fileURLWithPath: "/repo/.env")
        )
        #expect(MCPClientConfig.health(
            entry: .configured(command: "/x/Worklens", args: ["mcp"], env: [:]),
            expecting: pinned, isExecutable: { _ in true }
        ) == .outOfDate(command: "/x/Worklens"))
    }
}

/// The half of #140 that answers "and will it read my data?".
@Suite("MCP smoke test")
struct MCPSmokeTestTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-mcp-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("the round trip reports the tools and the directory it read them from")
    func roundTrip() throws {
        let dir = try temporaryDirectory()
        var config = Config.defaults(cwd: dir, isBundledApp: false)
        config.dataDir = dir.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: config.dataDir, withIntermediateDirectories: true)

        let result = try MCPSmokeTest.run(config: config, appDataDir: config.dataDir)
        #expect(result.toolCount == 10)
        #expect(result.dataDir == config.dataDir)
        #expect(result.matchesApp)
        // #241: the "+" menu's side of the round trip is part of what the install reports.
        #expect(result.promptCount == 5)
        #expect(result.summary
            == "\(result.toolCount) tools and \(result.promptCount) prompts ready, reading "
                + config.dataDir.path)
        #expect(result.mismatchNote == nil)
    }

    /// It runs inside the app, against the directory the app has open, so it opens the database
    /// read-only: `Database(dataDir:)` reads a busy file as a corrupt one and moves it aside.
    @Test("the round trip opens no writer on the database")
    func readsWithoutWriting() throws {
        let dir = try temporaryDirectory()
        var config = Config.defaults(cwd: dir, isBundledApp: false)
        config.dataDir = dir.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: config.dataDir, withIntermediateDirectories: true)

        _ = try MCPSmokeTest.run(config: config)

        let sqlite = config.dataDir.appendingPathComponent("worklens.sqlite")
        #expect(!FileManager.default.fileExists(atPath: sqlite.path))
    }

    /// Reported, never created: a smoke test that makes an empty data tree answers its own
    /// question wrongly, and leaves one behind.
    @Test("a data directory that is not there is a failure, not a new directory")
    func missingDataDir() throws {
        let dir = try temporaryDirectory()
        var config = Config.defaults(cwd: dir, isBundledApp: false)
        config.dataDir = dir.appendingPathComponent("gone")

        #expect(throws: MCPSmokeTest.Failure.noDataDir(config.dataDir)) {
            try MCPSmokeTest.run(config: config)
        }
        #expect(!FileManager.default.fileExists(atPath: config.dataDir.path))
    }

    @Test("a directory the app does not share is named in the note")
    func mismatch() throws {
        let dir = try temporaryDirectory()
        var config = Config.defaults(cwd: dir, isBundledApp: false)
        config.dataDir = dir.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: config.dataDir, withIntermediateDirectories: true)

        let elsewhere = dir.appendingPathComponent("somewhere-else")
        let result = try MCPSmokeTest.run(config: config, appDataDir: elsewhere)
        #expect(!result.matchesApp)
        #expect(result.mismatchNote?.contains(elsewhere.path) == true)
    }

    /// The client's process has no inherited environment and cwd `/`, so `<cwd>/.env` is not a
    /// layer it will ever see — the pinned file is.
    @Test("configuration resolves the way the client will resolve it")
    func clientResolution() throws {
        let dir = try temporaryDirectory()
        let pinnedData = dir.appendingPathComponent("pinned-data")
        try FileManager.default.createDirectory(at: pinnedData, withIntermediateDirectories: true)
        let envFile = dir.appendingPathComponent("repo.env")
        try Data("DATA_DIR=\(pinnedData.path)\n".utf8).write(to: envFile)

        let config = try MCPSmokeTest.clientConfig(
            envFile: envFile,
            appSupportEnv: dir.appendingPathComponent("no-such.env"),
            settingsFile: dir.appendingPathComponent("no-such.json")
        )
        #expect(config.dataDir.path == pinnedData.path)
    }

    /// Without a pin the App Support layer is the only one left, which is exactly the failure
    /// the card has to be able to describe.
    @Test("with nothing pinned, the App Support layer is the only one left")
    func clientResolutionWithoutPin() throws {
        let dir = try temporaryDirectory()
        let appSupportData = dir.appendingPathComponent("app-support-data")
        try FileManager.default.createDirectory(at: appSupportData, withIntermediateDirectories: true)
        let appSupportEnv = dir.appendingPathComponent("app-support.env")
        try Data("DATA_DIR=\(appSupportData.path)\n".utf8).write(to: appSupportEnv)

        let config = try MCPSmokeTest.clientConfig(
            envFile: nil,
            appSupportEnv: appSupportEnv,
            settingsFile: dir.appendingPathComponent("no-such.json")
        )
        #expect(config.dataDir.path == appSupportData.path)
    }

    /// The other half of "is it reading my data?": the client can ask the server itself, without
    /// opening a log file.
    @Test("initialize names the directory the server is answering from")
    func initializeCarriesDataDir() throws {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        let told = try #require(
            MCPServer(registry: MCPToolRegistry([]), dataDir: URL(fileURLWithPath: "/tmp/wl-data"))
                .handle(line: request)
        )
        #expect(told.contains("instructions"))
        #expect(told.contains("/tmp/wl-data"))

        let silent = try #require(MCPServer(registry: MCPToolRegistry([])).handle(line: request))
        #expect(!silent.contains("instructions"))
    }
}

/// #248: two clients, one writer — and the watch that notices when a link that used to work
/// stopped working.
@Suite("MCP clients")
struct MCPClientTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-mcp-clients-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func plan(_ command: String = "/Applications/Worklens.app/Contents/MacOS/Worklens")
        -> MCPClientConfig.Plan
    {
        MCPClientConfig.Plan(command: command)
    }

    // MARK: Which file

    /// Not TCC-protected: an ordinary file in App Support.
    @Test("Claude Desktop's file is its own config in App Support")
    func claudeDesktopURLUnchanged() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(
            MCPClientConfig.Client.claudeDesktop.configURL(home: home).path
                == "/Users/someone/Library/Application Support/Claude/claude_desktop_config.json"
        )
    }

    @Test("Claude Code's file is ~/.claude.json")
    func claudeCodeURL() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(
            MCPClientConfig.Client.claudeCode.configURL(home: home).path
                == "/Users/someone/.claude.json"
        )
        #expect(MCPClientConfig.Client.claudeCode.bundleID == nil)
        #expect(
            MCPClientConfig.Client.claudeDesktop.bundleID == MCPClientConfig.claudeDesktopBundleID)
    }

    /// The raw values are what `worklens mcp install --client` accepts, so they are the spelling
    /// a script types.
    @Test("every client has a stable name and a title of its own")
    func clientNames() {
        #expect(MCPClientConfig.Client.allCases.map(\.rawValue) == ["claudeDesktop", "claudeCode", "codex"])
        #expect(MCPClientConfig.Client.claudeDesktop.title == "Claude Desktop")
        #expect(MCPClientConfig.Client.claudeCode.title == "Claude Code")
        #expect(MCPClientConfig.Client.codex.title == "Codex")
        #expect(MCPClientConfig.Client(rawValue: "claudeCode") == .claudeCode)
        #expect(MCPClientConfig.Client(rawValue: "codex") == .codex)
    }

    // MARK: The same write

    /// The promise the second client had to keep: connecting Claude Desktop writes what it wrote
    /// before, byte for byte — which is `Plan.json` and a newline, the same bytes **Copy JSON**
    /// puts on the pasteboard and `worklens mcp install --print` prints.
    @Test("a first connect writes the entry it has always written, byte for byte")
    func writesTheSameJSON() throws {
        let dir = try temporaryDirectory()
        for client in MCPClientConfig.Client.allCases {
            let url = dir.appendingPathComponent(
                "\(client.rawValue)-\(client.configURL().lastPathComponent)")
            try MCPClientConfig.install(plan(), at: url)
            let written = try String(contentsOf: url, encoding: .utf8)
            #expect(written == (client == .codex ? plan().toml : plan().json) + "\n")
        }
    }

    /// `~/.claude.json` is Claude Code's whole state file, not only its servers: everything in it
    /// has to come back out unchanged.
    @Test("a Claude Code file keeps everything that is not the worklens entry")
    func mergesIntoClaudeCodeFile() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent(".claude.json")
        let existing = """
            {
              "numStartups": 12,
              "projects": {"/Users/someone/code": {"allowedTools": []}},
              "mcpServers": {"other": {"command": "/usr/bin/other"}}
            }
            """
        try Data(existing.utf8).write(to: url)

        let installation = try MCPClientConfig.install(plan(), at: url)
        #expect(!installation.createdFile)
        #expect(installation.backup != nil)

        let data = try Data(contentsOf: url)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["numStartups"] as? Int == 12)
        #expect(object["projects"] as? [String: Any] != nil)
        let servers = try #require(object["mcpServers"] as? [String: Any])
        #expect(servers["other"] != nil)
        let entry = try #require(servers["worklens"] as? [String: Any])
        #expect(entry["command"] as? String == "/Applications/Worklens.app/Contents/MacOS/Worklens")
    }

    /// The one failure this feature must not have, now that it writes a file a person's whole
    /// Claude Code state lives in.
    @Test("a ~/.claude.json that does not parse is refused and left untouched")
    func refusesUnparseableClaudeCodeFile() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent(".claude.json")
        let nonsense = "{ this was hand-edited and never closed\n"
        try Data(nonsense.utf8).write(to: url)

        #expect(throws: MCPClientConfig.InstallError.self) {
            try MCPClientConfig.install(plan(), at: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == nonsense)

        let health = MCPClientConfig.health(entry: MCPClientConfig.read(at: url), expecting: plan())
        if case .unparseable = health {} else {
            Issue.record("a file that does not parse is unparseable, not \(health)")
        }
    }

    // MARK: Noticing that the link broke

    @Test("a client pointing here is a connected link")
    func linkConnected() {
        let readings = [
            MCPClientConfig.Reading(client: .claudeDesktop, health: .pointsHere),
            MCPClientConfig.Reading(client: .claudeCode, health: .notInstalled),
        ]
        #expect(MCPClientConfig.linkState(readings, everConnected: []) == .connected)
        #expect(MCPClientConfig.linkState(readings, everConnected: [.claudeDesktop]) == .connected)
    }

    /// The whole point of the `app_state` row: somebody who never connected a client is never
    /// told their link broke, however stale the entry another checkout left behind.
    @Test("an install that never connected raises nothing, ever")
    func neverConnectedRaisesNothing() {
        let broken = [
            MCPClientConfig.Reading(
                client: .claudeDesktop, health: .stalePath(command: "/old/Worklens")),
            MCPClientConfig.Reading(
                client: .claudeCode, health: .pointsElsewhere(command: "/other/Worklens")),
        ]
        #expect(MCPClientConfig.linkState(broken, everConnected: []) == .nothingConnected)
        #expect(MCPClientConfig.linkState([], everConnected: []) == .nothingConnected)
    }

    @Test("a link that worked and now points at a build that is gone is broken")
    func linkBroken() {
        let stale = [
            MCPClientConfig.Reading(
                client: .claudeDesktop, health: .stalePath(command: "/old/Worklens"))
        ]
        #expect(
            MCPClientConfig.linkState(stale, everConnected: [.claudeDesktop])
                == .broken(.claudeDesktop))
    }

    /// The two clients break one at a time. A flag plus "does anything point here" would call
    /// this connected and say nothing, which is the silence this feature exists to remove.
    @Test("one client still pointing here does not hide the other one breaking")
    func oneBrokenAmongConnected() {
        let mixed = [
            MCPClientConfig.Reading(client: .claudeDesktop, health: .pointsHere),
            MCPClientConfig.Reading(
                client: .claudeCode, health: .stalePath(command: "/old/Worklens")),
        ]
        #expect(
            MCPClientConfig.linkState(mixed, everConnected: [.claudeDesktop, .claudeCode])
                == .broken(.claudeCode))
        // The never-connected guarantee is unchanged: a client that never connected stays quiet
        // however stale its entry is.
        #expect(
            MCPClientConfig.linkState(mixed, everConnected: [.claudeDesktop]) == .connected)
    }

    /// `outOfDate` and `pointsElsewhere` still launch a server that works, and `unparseable` is
    /// somebody else's file. None of them earns a problem the user has to dismiss.
    @Test("out of date, another build and unreadable are not a broken link")
    func linkStatesThatRaiseNothing() {
        let outOfDate = [
            MCPClientConfig.Reading(
                client: .claudeDesktop, health: .outOfDate(command: "/x/Worklens"))
        ]
        #expect(MCPClientConfig.linkState(outOfDate, everConnected: [.claudeDesktop]) == .nothingConnected)

        let unparseable = [
            MCPClientConfig.Reading(client: .claudeCode, health: .unparseable("not valid JSON"))
        ]
        #expect(MCPClientConfig.linkState(unparseable, everConnected: [.claudeCode]) == .nothingConnected)

        // The case that kept coming back: Claude Desktop names this checkout's build/ copy, which
        // still runs, while the menu bar is the installed one and Claude Code points here.
        let elsewhere = [
            MCPClientConfig.Reading(
                client: .claudeDesktop,
                health: .pointsElsewhere(command: "/repo/build/Worklens.app/Contents/MacOS/Worklens")),
            MCPClientConfig.Reading(client: .claudeCode, health: .pointsHere),
        ]
        #expect(
            MCPClientConfig.linkState(elsewhere, everConnected: [.claudeDesktop, .claudeCode])
                == .connected)
    }

    /// The sentence reaches the menu, the Activity list and the log, so it says what broke and
    /// what to do — and names no file, no path and no key.
    @Test("the reconnect notice states the fact, then the remedy, and names no path")
    func noticeWording() {
        let message = SetupIssue.mcpDisconnected.message
        #expect(message.contains("Settings"))
        #expect(!message.contains("/"))
        #expect(!message.contains(".json"))
        #expect(message.hasSuffix("."))
        // Nothing Worklens does has stopped: capture, describing and reports all carry on.
        #expect(!SetupIssue.mcpDisconnected.blocksWork)
        #expect(SetupIssue.bySeverity.last == .mcpDisconnected)
        #expect(SetupIssue.bySeverity.first == .screenRecordingDenied)
        #expect(SetupIssue(rawValue: "mcpDisconnected") == .mcpDisconnected)
    }
}
