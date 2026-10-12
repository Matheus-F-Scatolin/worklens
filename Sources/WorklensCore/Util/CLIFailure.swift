import Foundation

/// A CLI run that went wrong, as opposed to a command line that was typed wrong.
///
/// ArgumentParser treats every `ValidationError` the same way: it prints the subcommand's whole
/// usage block and exits 64. That is right for a misspelled flag and wrong for a missing
/// `GEMINI_API_KEY`, an HTTP 500 or an unreadable `.env` — the operator reads a wall of usage and
/// starts hunting for the argument they got wrong, and every script sees the same 64 a typo
/// produces. Throwing one of these instead prints a single `error:` line and exits with a number
/// a script can branch on.
///
/// 3 predates this type and keeps its meaning exactly: it is `DataDirLocation.refusedExitCode`,
/// which is also what `capture-once` exits when macOS has not granted Screen Recording, and this
/// type reuses the constant rather than restating it. 2 was the busy code of `run --headless`,
/// which went on 2026-10-05; it is left unused rather than given a new meaning a script that
/// branched on it would misread.
///
/// The catch is in `CLIEntryPoint.run`, not here: ArgumentParser honours a custom exit code only
/// for a thrown `ExitCode`, and turns every other error into exit 1 (`MessageInfo.init`).
public enum CLIFailure: Error, Equatable, CustomStringConvertible {
    /// The work itself failed: a model call, a database read, a file that could not be written.
    case runtime(String)
    /// macOS has not granted something, or is refusing where the data directory lives.
    case permission(String)
    /// The configuration is unusable: an unparseable `.env`, a key that is required and missing.
    case config(String)

    public var exitCode: Int32 {
        switch self {
        case .runtime: return 1
        case .permission: return DataDirLocation.refusedExitCode
        case .config: return 4
        }
    }

    public var message: String {
        switch self {
        case let .runtime(message): return message
        case let .permission(message): return message
        case let .config(message): return message
        }
    }

    public var description: String { message }

    /// The table `worklens --help` prints. Kept here so the documentation and the behaviour
    /// cannot drift apart. Every line is short enough to survive the help screen's own wrapping,
    /// which would otherwise fold a row in half and lose the column.
    public static let table = """
        Exit codes:
          0   success
          1   the run failed: a model call, the database, an unwritable file
          3   a macOS permission is missing, or DATA_DIR is unsafe to write to
          4   the configuration is unusable
          64  the command line was wrong
        """
}
