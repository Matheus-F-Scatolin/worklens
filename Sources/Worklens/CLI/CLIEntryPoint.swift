import ArgumentParser
import Foundation
import WorklensCore

/// The CLI's async entry point.
///
/// This exists as a real function rather than as a line in `main.swift` on purpose. `main(_:)` and
/// `run()` each have a synchronous (`ParsableCommand`) and an asynchronous (`AsyncParsableCommand`)
/// overload; in top-level code the compiler picks the synchronous ones, so
/// `describe-pending` would print its help screen instead of running. Called from an ordinary function, the async
/// overloads win.
enum CLIEntryPoint {
    /// Subcommands that write into the data directory, and so must not run when it is somewhere
    /// SQLite cannot be trusted (#122).
    ///
    /// The read side is deliberately left alone. Refusing `search`, `projects` or
    /// `config-dump` would make a user who has already pointed `DATA_DIR` at iCloud Drive unable
    /// to look at what they have, which is the opposite of protecting it.
    static let writingCommands: Set<String> = [
        "capture-once", "describe-pending", "describe-one",
    ]

    /// One line on stderr when this is the loose `.build/release/Worklens` rather than the
    /// binary inside `Worklens.app` (#119).
    ///
    /// Worth saying because the two are different applications as far as macOS is concerned:
    /// they carry different signatures, so a Screen Recording or Accessibility grant made for
    /// one does nothing for the other, and a developer who has granted permission to their
    /// terminal can spend a while wondering why the menu-bar app still cannot see the screen.
    ///
    /// `BundleLayout.isBundled` is the test, and neither `Bundle.main.bundleIdentifier` nor a
    /// `.app` suffix on `bundlePath` would do: run through the `worklens` symlink `make install`
    /// creates, `Bundle.main` is `/usr/local/bin`, the identifier is nil, and a correctly
    /// installed CLI would print this note every time. Asking where the executable actually
    /// lives, symlinks resolved, is the question that distinguishes the two.
    ///
    /// stderr, never `Log`: this is a note to a person at a prompt, not a record, and `mcp`
    /// speaks a protocol on stdout that nothing may share.
    static func noteIfUnbundled() {
        guard !BundleLayout.isBundled else { return }
        let note = """
            note: this is the development binary, not Worklens.app; macOS treats them as \
            different apps, so screen-recording and automation permissions granted here do not \
            carry over. `make install` gives you a `worklens` command that runs the app's own \
            binary.

            """
        FileHandle.standardError.write(Data(note.utf8))
    }

    /// Parses and runs, rather than calling `WorklensCLI.main(_:)`, so that a `CLIFailure` can
    /// be caught here (#158).
    ///
    /// ArgumentParser decides a thrown error's exit code in `MessageInfo.init`: a `ValidationError`
    /// prints the subcommand's usage block and exits 64, an `ExitCode` carries its own number, and
    /// *everything else* becomes exit 1. So a failure type with its own code has to be caught
    /// before ArgumentParser sees it, which means owning the parse/run pair. Everything else —
    /// `--help`, `--version`, a real usage error, `ExitCode` — is handed straight back to
    /// `exit(withError:)` and behaves exactly as it did.
    ///
    /// The `AsyncParsableCommand` cast is the same one this file's own comment warns about: the
    /// synchronous `run()` would be picked otherwise, and `describe-pending` would print its help
    /// instead of describing anything.
    static func run(_ arguments: [String]) async {
        refuseNonLocalDataDir(arguments)
        do {
            var command = try WorklensCLI.parseAsRoot(arguments)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let failure as CLIFailure {
            FileHandle.standardError.write(Data(("error: " + failure.message + "\n").utf8))
            exit(failure.exitCode)
        } catch {
            WorklensCLI.exit(withError: error)
        }
    }

    /// Exits 3 when a writing subcommand was asked to write into a synced or remote `DATA_DIR`.
    /// Without this the menu-bar app's guard would be one line of UI and the CLI would corrupt
    /// the database anyway.
    private static func refuseNonLocalDataDir(_ arguments: [String]) {
        guard let command = arguments.first(where: { !$0.hasPrefix("-") }),
              writingCommands.contains(command),
              !arguments.contains("--help"), !arguments.contains("-h")
        else { return }

        let config = (try? Config.load()) ?? Config.defaults()
        guard !config.allowNonLocalDataDir,
              let location = DataDirLocation.check(config.dataDir)
        else { return }
        FileHandle.standardError.write(Data(("error: " + location.explanation + "\n").utf8))
        exit(DataDirLocation.refusedExitCode)
    }
}
