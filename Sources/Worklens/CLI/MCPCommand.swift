import ArgumentParser
import Darwin
import Foundation
import WorklensCore

/// `worklens mcp` — an MCP server over stdin/stdout, so Claude Desktop (or Cowork, or Codex) can
/// read the same history the menu bar shows (#89).
///
/// Read-only and lock-free on purpose: it is launched *by the client* while the app is running, so
/// it takes no instance lock and every tool in `WorklensMCPTools.registry` is a query. Opening
/// the database still runs `Migrations.migrator`, exactly as `search` does — the client launches the binary inside `Worklens.app`, so
/// its schema is the app's own.
///
/// **stdout is the protocol.** The first thing `run()` does is duplicate fd 1 and point fd 1 at
/// stderr: after that a stray `print`, an ArgumentParser diagnostic or a library's `fprintf`
/// cannot corrupt the stream, and the only way to reach the client is the duplicate. `Log` was
/// never a risk — it writes to os_log and `FileLog` — and the log file is how you debug a server
/// whose stdout you cannot read.
struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve your Worklens history to an MCP client (Claude Desktop) over stdio.",
        subcommands: [MCPInstallCommand.self]
    )

    func run() throws {
        let client = MCPCommand.claimStdout()

        let config = try CLIConfig.load()
        let db = try Database(dataDir: config.dataDir)
        let taxonomy = try TaxonomyStore(dataDir: config.dataDir)
        let registry = WorklensMCPTools.registry(config: config, db: db, taxonomy: taxonomy)

        // The one line that says the server came up, and where it is reading from — a wrong
        // `DATA_DIR` is the failure this catches, and it is invisible from the client's side.
        Log.ui.info("mcp: \(registry.tools.count) tool(s) over stdio, reading \(config.dataDir.path)")

        defer { FileLog.shared.flush() }
        // One line per request on stderr, the file the client keeps about this server: the only
        // record of whether a call it says failed ever arrived.
        try MCPServer(registry: registry, dataDir: config.dataDir)
            .serve(MCPStdioTransport(output: client)) { line in
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
        Log.ui.info("mcp: client closed stdin, exiting")
    }

    /// Takes the real stdout for the protocol and hands fd 1 to stderr.
    ///
    /// Returns the descriptor responses must be written to. If `dup` fails there is nothing to
    /// take, so fd 1 is left alone and used as-is rather than losing the transport entirely.
    private static func claimStdout() -> Int32 {
        fflush(stdout)
        let duplicate = dup(STDOUT_FILENO)
        guard duplicate >= 0 else { return STDOUT_FILENO }
        dup2(STDERR_FILENO, STDOUT_FILENO)
        return duplicate
    }
}
