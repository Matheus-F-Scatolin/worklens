import ArgumentParser
import Foundation
import WorklensCore

/// `worklens shipped …` — the GitHub shipped ledger (#314): what you merged, closed, opened and
/// reviewed, read through `gh`. The app syncs it on the context-sync cadence; `sync` runs one
/// round now and `forget` deletes it.
struct ShippedCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shipped",
        abstract: "List what you shipped on GitHub, sync it now, or delete it.",
        subcommands: [ListCommand.self, SyncCommand.self, ForgetCommand.self],
        defaultSubcommand: ListCommand.self
    )

    static let defaultDays = 30

    struct ListCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "Print the ledger, per kind and per project."
        )

        @Option(help: "First day. Defaults to 30 days back, today included.")
        var from: LocalDay?

        @Option(help: "Last day, inclusive. Defaults to today.")
        var to: LocalDay?

        @Option(help: "Only this project, or this repo (owner/name or name).")
        var project: String?

        @OptionGroup var output: JSONOutputOptions

        /// `{from, to, status, counts: {kind: n}, outputs: [...]}`. No total: counts are per kind.
        private struct Payload: Encodable {
            let from: String
            let to: String
            let status: String
            let counts: [String: Int]
            let outputs: [Output]
        }

        func run() throws {
            let config = try CLIConfig.load()
            let db = try Database(dataDir: config.dataDir)
            let toDay = to?.string ?? DayBoundaries.dayString(Date())
            let fromDay = from?.string ?? DayBoundaries.dayString(
                Date().addingTimeInterval(-Double(ShippedCommand.defaultDays - 1) * 86_400)
            )
            guard fromDay <= toDay,
                  let start = DayBoundaries.range(day: fromDay)?.start,
                  let end = DayBoundaries.range(day: toDay)?.end
            else { throw ValidationError("--from must not be after --to") }

            let projects = (try? TaxonomyStore(dataDir: config.dataDir))?.projects ?? []
            var rows = try OutputStore(db).outputs(from: start, to: end)
            if let project, !project.isEmpty {
                rows = rows.filter { ShippedSection.matches($0, filter: project, projects: projects) }
            }
            let status = OutputSyncStatus.load(db).sentence(enabled: config.githubShipped)

            try CLIOutput.printOrJSON(
                json: output.json,
                text: text(rows, from: fromDay, to: toDay, status: status, projects: projects),
                payload: Payload(
                    from: fromDay, to: toDay, status: status,
                    counts: Dictionary(
                        uniqueKeysWithValues: ShippedSection.counts(rows).map { ($0.kind.rawValue, $0.count) }
                    ),
                    outputs: rows
                )
            )
        }

        private func text(
            _ rows: [Output], from: String, to: String, status: String, projects: [ProjectEntry]
        ) -> String {
            guard !rows.isEmpty else { return "Nothing shipped between \(from) and \(to).\n\(status)" }
            var lines = ["\(from) to \(to): \(ShippedSection.countsLine(rows))", status]
            for group in ShippedSection.groups(rows, projects: projects) {
                lines += ["", "\(group.name): \(ShippedSection.countsLine(group.outputs))"]
                lines += group.outputs.map {
                    "  " + ShippedSection.line($0, timeZone: .current, format: "yyyy-MM-dd HH:mm", withURL: true)
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    struct SyncCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sync",
            abstract: "Ask gh for what you shipped now, instead of waiting for the next context sync."
        )

        @Option(help: "How many days back to look. Defaults to a day before the last sync, or 30 days the first time.")
        var days: Int?

        func run() async throws {
            if let days, days < 1 { throw ValidationError("--days must be at least 1") }
            let config = try CLIConfig.load()
            guard config.githubShipped else {
                throw CLIFailure.config("GITHUB_SHIPPED is false: set it to true to sync what you shipped.")
            }
            let db = try Database(dataDir: config.dataDir)
            let memo = MemoOutputs.forConfig(config, db: db)
            switch await OutputSync(db: db, memo: memo).sync(days: days) {
            case let .success(result):
                print("Found \(result.found), wrote \(result.changed), removed \(result.removed) "
                      + "since \(DayBoundaries.dayString(result.since)).")
                // #317: counts only, never a company or a path.
                if let m = result.memo, !memo.repos.isEmpty {
                    print("Memos: read \(m.prsRead) PRs, \(m.published) published, \(m.updated) updated, "
                          + "\(m.created) companies added, \(m.ambiguous) ambiguous, \(m.skipped) skipped, \(m.relinked) relinked.")
                }
            case let .failure(error):
                throw CLIFailure.runtime((error as? GHError)?.description ?? "\(error)")
            }
        }
    }

    struct ForgetCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "forget",
            abstract: "Delete the ledger. The next sync fills it again unless GITHUB_SHIPPED=false."
        )

        func run() throws {
            let config = try CLIConfig.load()
            let db = try Database(dataDir: config.dataDir)
            let removed = OutputSync.forget(db: db)
            print("Deleted \(removed) shipped \(removed == 1 ? "item" : "items").")
            if config.githubShipped {
                print("GITHUB_SHIPPED is still true, so the next sync fills it again.")
            }
        }
    }
}
