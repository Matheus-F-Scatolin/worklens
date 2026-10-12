import ArgumentParser
import Foundation
import WorklensCore

/// `worklens expect-restart` — "the app is about to be stopped on purpose" (#156).
///
/// `scripts/update.sh` quits the running app with `pkill`, which is a SIGTERM: AppKit runs no
/// `applicationShouldTerminate`, so the app never gets to write its clean-exit marker. Since #106
/// that update runs unattended every `AUTO_UPDATE_POLL_MINUTES`, which would make the single most
/// frequent restart on this machine look exactly like a crash. This is the one thing a CLI run
/// may write into the run markers, and the update script calls it immediately before the kill.
///
/// The claim expires after `RunMarkers.expectedRestartWindow`, so an update that failed half-way
/// through cannot excuse a real crash days later.
struct ExpectRestartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "expect-restart",
        abstract: "Record that Worklens is about to be stopped on purpose, so the next launch "
            + "does not report it as a crash."
    )

    func run() throws {
        let config = try CLIConfig.load()
        let db = try Database(dataDir: config.dataDir)
        try RunMarkers(AppStateStore(db)).expectRestart()
    }
}
