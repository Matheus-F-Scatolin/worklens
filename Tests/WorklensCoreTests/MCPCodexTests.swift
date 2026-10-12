import Foundation
import Testing

@testable import WorklensCore

/// Codex's `~/.codex/config.toml`: the one client file that is TOML.
///
/// The promise is the JSON writer's, made stronger by editing lines rather than re-serializing:
/// every line that is not Worklens's own table comes back exactly as it was, and a file written in
/// a form a line edit could break is refused rather than rewritten.
@Suite("MCP Codex")
struct MCPCodexTests {
    private func temporaryFile(_ text: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-mcp-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.toml")
        if let text { try Data(text.utf8).write(to: url) }
        return url
    }

    private let plan = MCPClientConfig.Plan(
        command: "/Applications/Worklens.app/Contents/MacOS/Worklens",
        env: ["WORKLENS_ENV_FILE": "/Users/me/worklens/.env"]
    )

    private let codexFile = """
        model = "gpt-5"
        # My servers
        [mcp_servers.docs]
        command = "npx"
        args = [
          "-y",
          "docs-mcp", # the good one
        ]

        [mcp_servers.docs.env]
        TOKEN = 'abc'

        [profiles.fast]
        model = "gpt-5-mini"

        """

    @Test("the entry is a table with the command, args and an inline env")
    func entryShape() {
        #expect(plan.toml == """
            [mcp_servers.worklens]
            command = "/Applications/Worklens.app/Contents/MacOS/Worklens"
            args = ["mcp"]
            env = { WORKLENS_ENV_FILE = "/Users/me/worklens/.env" }
            """)
    }

    @Test("a connect appends the table and leaves every other line as it was")
    func appendsAndPreserves() throws {
        let url = try temporaryFile(codexFile)
        let installation = try MCPClientConfig.install(plan, at: url)
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written == codexFile + "\n" + plan.toml + "\n")
        #expect(installation.backup != nil)
        #expect(installation.createdFile == false)
        #expect(MCPClientConfig.health(
            entry: MCPClientConfig.read(at: url), expecting: plan, isExecutable: { _ in true }
        ) == .pointsHere)
    }

    @Test("a file that is not there is created with only the table")
    func createsTheFile() throws {
        let url = try temporaryFile(nil)
            .deletingLastPathComponent().appendingPathComponent(".codex/config.toml")
        let installation = try MCPClientConfig.install(plan, at: url)
        #expect(installation.createdFile)
        #expect(try String(contentsOf: url, encoding: .utf8) == plan.toml + "\n")
    }

    @Test("a second connect replaces the table in place rather than adding another")
    func replacesInPlace() throws {
        let stale = """
            [mcp_servers.worklens]
            command = "/old/Worklens.app/Contents/MacOS/Worklens"
            args = ["mcp"]

            # Keep me
            [mcp_servers.docs]
            command = "npx"

            """
        let url = try temporaryFile(stale)
        #expect(MCPClientConfig.health(
            entry: MCPClientConfig.read(at: url), expecting: plan, isExecutable: { _ in true }
        ) == .pointsElsewhere(command: "/old/Worklens.app/Contents/MacOS/Worklens"))
        try MCPClientConfig.install(plan, at: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == plan.toml + "\n\n" + """
            # Keep me
            [mcp_servers.docs]
            command = "npx"

            """)
    }

    @Test("an entry the user renamed is repointed under its own name")
    func renamedEntry() throws {
        let url = try temporaryFile("""
            [mcp_servers."my day"]
            command = "/old/Worklens"
            args = ["mcp"]
            """)
        #expect(MCPClientConfig.installedKey(at: url) == "my day")
        try MCPClientConfig.install(plan, at: url)
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.hasPrefix("[mcp_servers.\"my day\"]\ncommand = \"/Applications/"))
        #expect(!written.contains("[mcp_servers.worklens]"))
    }

    @Test("an env subtable and dotted env keys are read back as the launch environment")
    func readsEnvForms() {
        let subtable = MCPTOML.parse("""
            [mcp_servers.worklens]
            command = "/x/Worklens"
            args = ['mcp']

            [mcp_servers.worklens.env]
            WORKLENS_ENV_FILE = "/a/.env"
            """)
        #expect(subtable == .configured(
            command: "/x/Worklens", args: ["mcp"], env: ["WORKLENS_ENV_FILE": "/a/.env"]))
        let dotted = MCPTOML.parse("""
            [mcp_servers.worklens]
            command = "/x/Worklens" # the app
            env.WORKLENS_ENV_FILE = "/a/.env"
            """)
        #expect(dotted == .configured(
            command: "/x/Worklens", args: [], env: ["WORKLENS_ENV_FILE": "/a/.env"]))
    }

    @Test("a path with quotes and backslashes survives the round trip")
    func escaping() throws {
        let odd = MCPClientConfig.Plan(command: #"/Users/a "b"\c/Worklens"#)
        let url = try temporaryFile("")
        try MCPClientConfig.install(odd, at: url)
        #expect(MCPClientConfig.read(at: url) == .configured(
            command: #"/Users/a "b"\c/Worklens"#, args: ["mcp"], env: [:]))
    }

    @Test("servers written inline or as dotted keys are refused, and the file is untouched")
    func refusesOtherForms() throws {
        for text in [
            #"mcp_servers = { docs = { command = "npx" } }"#,
            "mcp_servers.docs.command = \"npx\"\n",
            "[mcp_servers]\ndocs = { command = \"npx\" }\n",
        ] {
            let url = try temporaryFile(text)
            #expect(throws: MCPClientConfig.InstallError.self) {
                try MCPClientConfig.install(plan, at: url)
            }
            #expect(try String(contentsOf: url, encoding: .utf8) == text)
            let siblings = try FileManager.default.contentsOfDirectory(
                atPath: url.deletingLastPathComponent().path)
            #expect(siblings == ["config.toml"])
        }
    }

    @Test("a disconnect takes out the table and its subtables and nothing else")
    func removes() throws {
        let url = try temporaryFile(codexFile)
        try MCPClientConfig.install(plan, at: url)
        let removal = try #require(try MCPClientConfig.remove(key: "worklens", at: url))
        #expect(removal.backup != nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == codexFile)
        #expect(MCPClientConfig.installedKey(at: url) == nil)
        #expect(try MCPClientConfig.remove(key: "worklens", at: url) == nil)

        let docs = try #require(try MCPClientConfig.remove(key: "docs", at: url))
        #expect(docs.key == "docs")
        #expect(try String(contentsOf: url, encoding: .utf8) == """
            model = "gpt-5"
            # My servers
            [profiles.fast]
            model = "gpt-5-mini"

            """)
    }

    @Test("Codex lives in ~/.codex/config.toml")
    func location() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(MCPClientConfig.Client.codex.configURL(home: home).path
            == "/Users/someone/.codex/config.toml")
        #expect(MCPClientConfig.Client.codex.bundleID == nil)
        #expect(MCPClientConfig.Client.codex.presencePaths(home: home)
            .contains(URL(fileURLWithPath: "/Users/someone/.codex")))
    }
}
