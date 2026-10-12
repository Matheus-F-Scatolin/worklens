import Foundation
import Testing
@testable import WorklensCore

@Suite("MCPClientConfig")
struct MCPClientConfigTests {
    private func parse(_ json: String) -> MCPClientConfig.Entry {
        MCPClientConfig.parse(Data(json.utf8))
    }

    @Test("the documented entry parses")
    func documented() {
        let entry = parse("""
            {"mcpServers": {"worklens": {
              "command": "/Applications/Worklens.app/Contents/MacOS/Worklens", "args": ["mcp"]
            }}}
            """)
        #expect(entry == .configured(
            command: "/Applications/Worklens.app/Contents/MacOS/Worklens", args: ["mcp"], env: [:]
        ))
    }

    /// The name is the user's; what identifies the entry is the binary it launches.
    @Test("an entry under another name is found by its command")
    func otherName() {
        let entry = parse("""
            {"mcpServers": {"my-day": {"command": "/x/Worklens.app/Contents/MacOS/Worklens",
              "args": ["mcp"]}}}
            """)
        #expect(entry == .configured(
            command: "/x/Worklens.app/Contents/MacOS/Worklens", args: ["mcp"], env: [:]
        ))
    }

    @Test("other servers are left alone")
    func unrelatedServers() {
        #expect(parse("""
            {"mcpServers": {"filesystem": {"command": "/usr/bin/npx", "args": ["-y", "server"]}}}
            """) == .notConfigured)
        #expect(parse("{}") == .notConfigured)
    }

    /// "could not read" is a different answer from "missing", and the difference matters:
    /// this file is edited by hand.
    @Test("a broken file is unreadable, not missing")
    func broken() {
        #expect(parse("{ not json") == .unreadable("not valid JSON"))
        #expect(parse("""
            {"mcpServers": {"worklens": {"args": ["mcp"]}}}
            """) == .unreadable("the worklens entry has no \"command\""))
    }

    @Test("a missing file is not an error")
    func missingFile() {
        #expect(MCPClientConfig.read(
            at: URL(fileURLWithPath: "/nonexistent/claude_desktop_config.json")
        ) == .noFile)
    }

    /// The half that decides which database the launched server reads (#140).
    @Test("a pinned environment is read back")
    func pinnedEnvironment() {
        #expect(parse("""
            {"mcpServers": {"worklens": {"command": "/x/Worklens", "args": ["mcp"],
              "env": {"WORKLENS_ENV_FILE": "/repo/.env"}}}}
            """) == .configured(
                command: "/x/Worklens", args: ["mcp"], env: ["WORKLENS_ENV_FILE": "/repo/.env"]
            ))
    }

    @Test("a command inside a bundle names its bundle")
    func bundleForCommand() {
        #expect(MCPClientConfig.bundle(
            forCommand: "/Applications/Worklens.app/Contents/MacOS/Worklens"
        )?.lastPathComponent == "Worklens.app")
        #expect(MCPClientConfig.bundle(forCommand: "/usr/local/bin/worklens") == nil)
    }
}
