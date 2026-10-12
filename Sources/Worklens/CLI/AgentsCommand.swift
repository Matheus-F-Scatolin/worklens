import ArgumentParser
import Foundation
import WorklensCore

/// `worklens agents …` — your Claude Code and Codex sessions (#321): which repo your prompts and
/// the agents' turns went to, and the PRs they linked. Metadata only, read from the agents' own
/// logs. The app reads them on the context-sync cadence; `sync` reads now and `forget` deletes.
struct AgentsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agents",
        abstract: "List your Claude Code and Codex sessions per repo, read their logs now, or delete what was read.",
        subcommands: [ListCommand.self, SyncCommand.self, ForgetCommand.self],
        defaultSubcommand: ListCommand.self
    )

    static let defaultDays = 7

    struct ListCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "Print your prompts, your minutes and the agents' minutes per repo."
        )

        @Option(help: "First day. Defaults to 7 days back, today included.")
        var from: LocalDay?

        @Option(help: "Last day, inclusive. Defaults to today.")
        var to: LocalDay?

        @Option(help: "Only this repo (owner/name or name).")
        var repo: String?

        @OptionGroup var output: JSONOutputOptions

        func run() throws {
            let config = try CLIConfig.load()
            let db = try Database(dataDir: config.dataDir)
            let toDay = to?.string ?? DayBoundaries.dayString(Date())
            let fromDay = from?.string ?? DayBoundaries.dayString(
                Date().addingTimeInterval(-Double(AgentsCommand.defaultDays - 1) * 86_400)
            )
            guard fromDay <= toDay,
                  let start = DayBoundaries.range(day: fromDay)?.start,
                  let end = DayBoundaries.range(day: toDay)?.end
            else { throw ValidationError("--from must not be after --to") }

            let status = AgentSyncStatus.load(db).sentence(enabled: config.agentSessions)
            let report = try AgentLedger(db: db).report(
                from: fromDay, to: toDay, start: start, end: end, repo: repo, status: status
            )
            try CLIOutput.printOrJSON(json: output.json, text: text(report), payload: report)
        }

        private func text(_ report: AgentLedger.Report) -> String {
            guard !report.repos.isEmpty else {
                return "No agent sessions between \(report.from) and \(report.to).\n\(report.status)"
            }
            var lines = ["\(report.from) to \(report.to)", report.status]
            for row in report.repos {
                let prs = row.prs.keys.sorted().map { "\(row.prs[$0] ?? 0) \($0)" }
                lines += [
                    "",
                    "\(row.repo ?? "no repo"): \(Format.count(row.prompts)) \(row.prompts == 1 ? "prompt" : "prompts"), "
                        + "\(row.yourMinutes) min yours, \(row.agentMinutes) min agent"
                        + (prs.isEmpty ? "" : "; PRs: \(prs.joined(separator: ", "))"),
                ]
                for session in report.sessions where session.repo == row.repo {
                    lines.append(
                        "  \(session.start ?? "?") \(session.tool) \(session.id.prefix(8)) "
                            + "\(session.branch.map { "on \($0) " } ?? "")· \(session.prompts) prompts, "
                            + "\(session.yourMinutes) min yours, \(session.agentMinutes) min agent · \(session.outcome)"
                    )
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    struct SyncCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sync",
            abstract: "Read the Claude Code and Codex logs now, instead of waiting for the next context sync."
        )

        @Option(help: "How many days back an unread log may be. Defaults to a day before the last full read, or 30 days the first time.")
        var days: Int?

        func run() async throws {
            if let days, days < 1 { throw ValidationError("--days must be at least 1") }
            let config = try CLIConfig.load()
            guard config.agentSessions else {
                throw CLIFailure.config("AGENT_SESSIONS is false: set it to true to read your agent sessions.")
            }
            let db = try Database(dataDir: config.dataDir)
            let sync = AgentSessionSync(config: config, db: db, log: { _, _ in })
            var files = 0, bytes: Int64 = 0, prompts = 0
            // A first read can be over a gigabyte: keep going a round at a time until it is done.
            while true {
                switch await sync.sync(days: days) {
                case let .success(result):
                    files += result.files
                    bytes += result.bytes
                    prompts += result.prompts
                    for store in result.unrecognized {
                        print("\(AgentSessionSync.storeName(store)): format not recognized; nothing was read from it.")
                    }
                    guard result.pending, result.bytes > 0 else {
                        let counts = try AgentSessionStore(db).counts()
                        print("Read \(files) files (\(bytes / 1_048_576) MB): \(prompts) new prompts. "
                              + "Stored: \(counts.sessions) sessions, \(counts.prompts) prompts, \(counts.prs) PR links.")
                        return
                    }
                case let .failure(error):
                    throw CLIFailure.runtime("\(error)")
                }
            }
        }
    }

    struct ForgetCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "forget",
            abstract: "Delete what was read. The next sync reads it again unless AGENT_SESSIONS=false."
        )

        func run() throws {
            let config = try CLIConfig.load()
            let db = try Database(dataDir: config.dataDir)
            let removed = AgentSessionSync.forget(db: db)
            print("Deleted \(removed) agent \(removed == 1 ? "session" : "sessions").")
            if config.agentSessions {
                print("AGENT_SESSIONS is still true, so the next sync reads them again.")
            }
        }
    }
}
