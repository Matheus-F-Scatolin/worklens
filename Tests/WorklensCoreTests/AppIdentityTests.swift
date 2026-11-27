import Foundation
import Testing
@testable import WorklensCore

/// The install rehearsal (docs/rehearsal.md) is the same binary under a second bundle identifier.
/// Everything that ties an install to this Mac follows from that identifier, and none of the
/// rehearsal's names may land on, or inside, the real app's.
@Suite("AppIdentity")
struct AppIdentityTests {
    private let home = URL(fileURLWithPath: "/Users/someone")

    // MARK: Which identity

    @Test("each bundle identifier names its identity, and nothing else names one")
    func fromBundleIdentifier() {
        #expect(AppIdentity(bundleIdentifier: "dev.worklens.app") == .main)
        #expect(AppIdentity(bundleIdentifier: "dev.worklens.rehearsal") == .rehearsal)
        #expect(AppIdentity(bundleIdentifier: "com.example.other") == nil)
        #expect(AppIdentity(bundleIdentifier: "dev.worklens") == nil)
        #expect(AppIdentity(bundleIdentifier: nil) == nil)
    }

    /// `swift run`, the tests and an unbundled binary have no identifier of ours: the real
    /// app's identity, exactly as before the rehearsal existed.
    @Test("an unknown or missing identifier is the real app")
    func unknownIsMain() {
        #expect(AppIdentity.resolve(mainBundleIdentifier: nil, executableBundleIdentifier: nil) == .main)
        #expect(AppIdentity.resolve(
            mainBundleIdentifier: "com.apple.dt.xctest.tool", executableBundleIdentifier: nil
        ) == .main)
        #expect(AppIdentity.resolve(
            mainBundleIdentifier: "com.example.other", executableBundleIdentifier: "com.example.too"
        ) == .main)
    }

    /// The command through its symlink: `Bundle.main` is the link's folder, with no identifier,
    /// and the identity comes from the bundle the executable resolves into.
    @Test("the symlinked command takes the identity of the bundle it resolves into")
    func symlinkedCommand() {
        #expect(AppIdentity.resolve(
            mainBundleIdentifier: nil, executableBundleIdentifier: "dev.worklens.rehearsal"
        ) == .rehearsal)
        #expect(AppIdentity.resolve(
            mainBundleIdentifier: nil, executableBundleIdentifier: "dev.worklens.app"
        ) == .main)
        // The app's own bundle wins over anything else.
        #expect(AppIdentity.resolve(
            mainBundleIdentifier: "dev.worklens.app", executableBundleIdentifier: "dev.worklens.rehearsal"
        ) == .main)
    }

    @Test("the tests run as the real app")
    func testsAreMain() {
        #expect(AppIdentity.current == .main)
        #expect(Config.bundleIdentifier == "dev.worklens.app")
    }

    // MARK: The names

    /// The strings scripts/app-identity.sh spells too; a change here is a change there.
    @Test("the real app's names are the ones it always had")
    func mainNames() {
        let main = AppIdentity.main
        #expect(main.bundleIdentifier == "dev.worklens.app")
        #expect(main.displayName == "Worklens")
        #expect(main.appBundleName == "Worklens.app")
        #expect(main.appSupportDir(home: home).path == "/Users/someone/Library/Application Support/Worklens")
        #expect(main.keychainService("google") == "dev.worklens.google")
        #expect(main.commandName == "worklens")
        #expect(main.mcpServerName == "worklens")
        #expect(main.updatesInPlace)
    }

    @Test("the rehearsal's names are its own")
    func rehearsalNames() {
        let rehearsal = AppIdentity.rehearsal
        #expect(rehearsal.bundleIdentifier == "dev.worklens.rehearsal")
        #expect(rehearsal.displayName == "Worklens Rehearsal")
        #expect(rehearsal.appBundleName == "Worklens Rehearsal.app")
        #expect(rehearsal.appSupportDir(home: home).path
            == "/Users/someone/Library/Application Support/Worklens Rehearsal")
        #expect(rehearsal.keychainService("google") == "dev.worklens.rehearsal.google")
        #expect(rehearsal.commandName == "worklens-rehearsal")
        #expect(rehearsal.mcpServerName == "worklens-rehearsal")
        #expect(!rehearsal.updatesInPlace)
    }

    @Test("no rehearsal name is, or sits inside, the real app's")
    func noOverlap() {
        let main = AppIdentity.main, rehearsal = AppIdentity.rehearsal
        let realDir = main.appSupportDir(home: home).path
        let rehearsalDir = rehearsal.appSupportDir(home: home).path
        #expect(rehearsalDir != realDir)
        #expect(!rehearsalDir.hasPrefix(realDir + "/"))
        #expect(!realDir.hasPrefix(rehearsalDir + "/"))
        #expect(rehearsal.bundleIdentifier != main.bundleIdentifier)
        #expect(rehearsal.appBundleName != main.appBundleName)
        #expect(rehearsal.keychainService("google") != main.keychainService("google"))
        #expect(rehearsal.commandName != main.commandName)
        #expect(rehearsal.mcpServerName != main.mcpServerName)
    }

    // MARK: Refusing the real folder

    @Test("the rehearsal refuses the real app's folder and anything inside it")
    func refusesRealDataDir() {
        let real = AppIdentity.main.appSupportDir(home: home)
        let rehearsal = AppIdentity.rehearsal
        #expect(rehearsal.refusesDataDir(real, home: home))
        #expect(rehearsal.refusesDataDir(real.appendingPathComponent("data"), home: home))
        #expect(rehearsal.refusesDataDir(
            URL(fileURLWithPath: "/Users/someone/Library/Application Support/Worklens/./data/../data"), home: home
        ))
        #expect(!rehearsal.refusesDataDir(
            rehearsal.appSupportDir(home: home).appendingPathComponent("data"), home: home
        ))
        #expect(!rehearsal.refusesDataDir(URL(fileURLWithPath: "/tmp/rehearsal-data"), home: home))
        // The real app is never refused its own folder.
        #expect(!AppIdentity.main.refusesDataDir(real.appendingPathComponent("data"), home: home))
    }

    // MARK: MCP entries

    @Test("neither identity claims the other's MCP entry")
    func mcpClaims() {
        let real = "/Applications/Worklens.app/Contents/MacOS/Worklens"
        let rehearsal = "/Applications/Worklens Rehearsal.app/Contents/MacOS/Worklens"
        #expect(AppIdentity.main.claimsMCPEntry(key: "my-day", command: real))
        #expect(!AppIdentity.main.claimsMCPEntry(key: "my-day", command: rehearsal))
        #expect(!AppIdentity.main.claimsMCPEntry(key: "worklens-rehearsal", command: real))
        #expect(AppIdentity.rehearsal.claimsMCPEntry(key: "renamed", command: rehearsal))
        #expect(!AppIdentity.rehearsal.claimsMCPEntry(key: "renamed", command: real))
        #expect(!AppIdentity.rehearsal.claimsMCPEntry(key: "worklens", command: rehearsal))
        #expect(!AppIdentity.rehearsal.claimsMCPEntry(key: "x", command: nil))
    }

    @Test("the rehearsal reads only its own entry from a file that has both")
    func parseBoth() {
        let json = Data("""
            {"mcpServers": {
              "worklens": {"command": "/Applications/Worklens.app/Contents/MacOS/Worklens", "args": ["mcp"]}
            }}
            """.utf8)
        #expect(MCPClientConfig.parse(json, identity: .rehearsal) == .notConfigured)
        #expect(MCPClientConfig.parse(json, identity: .main) != .notConfigured)
        #expect(MCPClientConfig.renamedEntryKey(in: [
            "worklens": ["command": "/Applications/Worklens.app/Contents/MacOS/Worklens"],
        ], identity: .rehearsal) == nil)
    }

    @Test("installing the rehearsal adds its own entry and leaves the real one alone")
    func installBeside() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("claude_desktop_config.json")
        let real = "/Applications/Worklens.app/Contents/MacOS/Worklens"
        try Data("""
            {"mcpServers": {"worklens": {"command": "\(real)", "args": ["mcp"]}}}
            """.utf8).write(to: url)

        try MCPClientConfig.install(
            MCPClientConfig.Plan(command: "/Applications/Worklens Rehearsal.app/Contents/MacOS/Worklens"),
            at: url, identity: .rehearsal
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let servers = try #require(object["mcpServers"] as? [String: Any])
        let realEntry = try #require(servers["worklens"] as? [String: Any])
        #expect(realEntry["command"] as? String == real)
        let rehearsalEntry = try #require(servers["worklens-rehearsal"] as? [String: Any])
        #expect((rehearsalEntry["command"] as? String)?.contains("Worklens Rehearsal.app") == true)
        #expect(MCPClientConfig.installedKey(at: url, identity: .rehearsal) == "worklens-rehearsal")
        #expect(MCPClientConfig.installedKey(at: url, identity: .main) == "worklens")
    }

    @Test("the Codex file gets the rehearsal's table beside the real one")
    func installTOMLBeside() throws {
        let text = """
            [mcp_servers.worklens]
            command = "/Applications/Worklens.app/Contents/MacOS/Worklens"
            args = ["mcp"]
            """
        let out = try MCPTOML.installing(
            MCPClientConfig.Plan(command: "/Applications/Worklens Rehearsal.app/Contents/MacOS/Worklens"),
            into: text, identity: .rehearsal
        )
        #expect(out.contains("[mcp_servers.worklens]\ncommand = \"/Applications/Worklens.app/Contents/MacOS/Worklens\""))
        #expect(MCPTOML.installedKey(in: out, identity: .rehearsal) == "worklens-rehearsal")
        #expect(MCPTOML.installedKey(in: out, identity: .main) == "worklens")
    }
}
