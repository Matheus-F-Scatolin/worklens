import ArgumentParser
import Foundation
import WorklensCore

/// `worklens timeline --date D --rebuild` — the one way to repair a past day's `activity_blocks`.
///
/// The app rebuilds only today and yesterday at launch (`TimelineWriter.rebuildRecentDays`), so a
/// day older than that keeps whatever blocks it had until this runs. The Week page draws those
/// blocks; the MCP `timeline` tool is how the result is read.
struct TimelineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "timeline",
        abstract: "Rebuild a day's activity blocks."
    )

    @Option(help: ArgumentHelp(LocalDay.argumentHelp))
    var date: LocalDay = .today()

    @Flag(help: "Rebuild activity_blocks for the day. Required.")
    var rebuild = false

    func validate() throws {
        guard rebuild else {
            throw ValidationError("Pass --rebuild: the command only rebuilds a day's timeline.")
        }
    }

    func run() async throws {
        let config = try CLIConfig.load()
        let db = try Database(dataDir: config.dataDir)
        let taxonomy = try TaxonomyStore(dataDir: config.dataDir)
        let writer = TimelineWriter(config: config, db: db, taxonomy: taxonomy)
        let day = date.string
        _ = try await writer.rebuild(day: day)
        print("Rebuilt \(day).")
    }
}
