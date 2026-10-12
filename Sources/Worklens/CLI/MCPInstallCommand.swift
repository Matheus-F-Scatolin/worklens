import AppKit
import ArgumentParser
import Darwin
import Foundation
import WorklensCore

/// `worklens mcp install` — writes the `mcpServers.worklens` entry into Claude Desktop's
/// configuration, the same one Settings → Integrations' button writes (#140).
///
/// Both surfaces sit on `MCPClientConfig`, so the JSON, the backup and the merge rules cannot
/// drift apart. The two things this command does that the card also does: it asks before
/// touching another application's file, and it runs the round trip afterwards and says which
/// `DATA_DIR` the launched server would read — a wrong path and a wrong data directory fail
/// identically from the client's side, which is to say silently.
struct MCPInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Add Worklens to an MCP client's configuration (asks first)."
    )

    @Flag(name: .customLong("print"), help: "Print the JSON entry and change nothing.")
    var printOnly = false

    /// #248: the same writer, for either client on this Mac. The default is what it has always
    /// been, so a typed `worklens mcp install` and `--print` are unchanged.
    @Option(
        name: .customLong("client"),
        help: "Which client's configuration to write: claudeDesktop, claudeCode or codex."
    )
    var client: MCPClientConfig.Client = .claudeDesktop

    func run() throws {
        let config = try CLIConfig.load()
        let envFile = ProcessInfo.processInfo.environment["WORKLENS_ENV_FILE"].map {
            URL(fileURLWithPath: $0)
        }
        guard let executable = Bundle.main.executableURL else {
            throw ValidationError("could not find this binary's own path")
        }
        let plan = MCPClientConfig.plan(executable: executable, envFile: envFile)
        let url = client.configURL()
        // Codex's file is TOML, so the entry shown is the table that goes into it.
        let entry = client == .codex ? plan.toml : plan.json

        if printOnly {
            say(entry)
            say("")
            say(client == .codex
                ? "Add that to \(url.path), keeping any mcp_servers you already have."
                : "Merge that into \(url.path), keeping any mcpServers you already have.")
            return
        }

        let health = MCPClientConfig.health(entry: MCPClientConfig.read(at: url), expecting: plan)
        say(describe(health, url: url))
        if case .pointsHere = health {
            say("Nothing to change.")
            smoke(envFile: envFile, appDataDir: config.dataDir)
            return
        }
        if case .unparseable(let why) = health {
            throw ValidationError(
                "\(url.path) \(why): Worklens will not overwrite a file it cannot merge into. "
                    + "Fix the file, or use `worklens mcp install --print` and paste the entry in."
            )
        }

        // Claude Desktop writes its own file back out while it is open, which would undo this
        // within minutes. Closed, it reads the entry at its next launch.
        if client == .claudeDesktop,
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: MCPClientConfig.claudeDesktopBundleID
            ).isEmpty
        {
            throw CLIFailure.runtime(
                "Claude Desktop is open, and while it is open it writes its settings back over "
                    + "this entry. Quit it (⌘Q), run this again, then open it."
            )
        }

        say("")
        say(entry)
        say("")
        guard confirm("Write that into \(url.path)? The file is copied aside first. [y/N] ") else {
            say("Nothing was written.")
            return
        }

        let installation = try MCPClientConfig.install(plan, at: url)
        if let backup = installation.backup {
            say("Backed the old file up to \(backup.path)")
        }
        say(installation.createdFile ? "Created \(url.path)" : "Updated \(url.path)")
        smoke(envFile: envFile, appDataDir: config.dataDir)
        switch client {
        case .claudeDesktop:
            say("Quit Claude Desktop and open it again: it reads that file only at launch.")
        case .claudeCode, .codex:
            say("Start a new \(client.title) session: it reads that file when it starts.")
        }
    }

    /// The round trip, resolved the way the client will resolve it.
    private func smoke(envFile: URL?, appDataDir: URL) {
        do {
            let clientConfig = try MCPSmokeTest.clientConfig(envFile: envFile)
            let result = try MCPSmokeTest.run(config: clientConfig, appDataDir: appDataDir)
            say(result.summary)
            if let note = result.mismatchNote { say(note) }
        } catch {
            say("The server did not come up: \(error)")
        }
    }

    private func describe(_ health: MCPClientConfig.Health, url: URL) -> String {
        switch health {
        case .notInstalled:
            return "\(url.lastPathComponent) has no worklens server yet."
        case .pointsHere:
            return "\(url.lastPathComponent) already points at this binary."
        case .pointsElsewhere(let command):
            return "\(url.lastPathComponent) points at \(command): another build of Worklens."
        case .outOfDate(let command):
            return "\(url.lastPathComponent) points at \(command) with different arguments or "
                + "a different pinned environment."
        case .stalePath(let command):
            return "\(url.lastPathComponent) points at \(command), which is not on disk any more."
        case .unparseable(let why):
            return "\(url.lastPathComponent): \(why)"
        }
    }

    /// Editing another application's configuration is not something to do because a command was
    /// typed with a typo, so this asks. Without a terminal there is nobody to ask: `--print`
    /// is the answer for a script.
    private func confirm(_ question: String) -> Bool {
        guard isatty(STDIN_FILENO) == 1 else {
            say("Not a terminal, so there is nobody to confirm with. Run this from a terminal, "
                + "or use `worklens mcp install --print` and paste the entry in yourself.")
            return false
        }
        FileHandle.standardError.write(Data(question.utf8))
        guard let answer = readLine(strippingNewline: true)?.lowercased() else { return false }
        return answer == "y" || answer == "yes"
    }

    /// stdout, deliberately: `mcp` itself hands fd 1 to stderr because stdout is the protocol,
    /// but this subcommand is a person at a terminal and never serves anything.
    private func say(_ line: String) {
        print(line)
    }
}

/// `--client claudeCode`. The conformance is here rather than in `WorklensCore`, which must not
/// depend on ArgumentParser.
extension MCPClientConfig.Client: ExpressibleByArgument {
    public init?(argument: String) {
        guard let client = MCPClientConfig.Client(rawValue: argument) else { return nil }
        self = client
    }

    public static var allValueStrings: [String] {
        MCPClientConfig.Client.allCases.map(\.rawValue)
    }
}
