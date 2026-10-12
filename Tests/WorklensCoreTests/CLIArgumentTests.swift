import Foundation
import Testing

@testable import WorklensCore

/// The CLI's shared argument types and failure codes (#158). Everything here is offline and
/// clock-injected: `now` is pinned to a Wednesday so "yesterday" and "last-week" have one answer.
@Suite("CLI arguments and failures")
struct CLIArgumentTests {
    /// Wednesday 2026-09-16, 12:00 UTC — inside 2026-W38, whose Monday is 2026-09-14.
    private let now = Date(timeIntervalSince1970: 1_789_560_000)
    private let utc = TimeZone(identifier: "UTC")!

    private func day(_ text: String) -> String? {
        LocalDay(text, now: now, timeZone: utc)?.string
    }

    // MARK: LocalDay

    @Test("an explicit day is taken as written")
    func explicitDay() {
        #expect(day("2026-09-07") == "2026-09-07")
        #expect(day(" 2026-09-07 ") == "2026-09-07")
    }

    @Test("today and yesterday are words, not dates")
    func relativeWords() {
        #expect(day("today") == "2026-09-16")
        #expect(day("TODAY") == "2026-09-16")
        #expect(day("yesterday") == "2026-09-15")
        #expect(LocalDay.today(now: now, timeZone: utc).string == "2026-09-16")
    }

    @Test("a non-positive integer is an offset in days")
    func offsets() {
        #expect(day("0") == "2026-09-16")
        #expect(day("-1") == "2026-09-15")
        #expect(day("-30") == "2026-08-17")
    }

    @Test("a real day written loosely is padded rather than refused")
    func normalizes() {
        #expect(day("2026-9-7") == "2026-09-07")
    }

    @Test("anything else is rejected rather than guessed at")
    func rejects() {
        // The formatter resolves this to 2 March; each of the six hand checks this type replaces
        // accepted it and then reported on a day nothing had happened in.
        #expect(day("2026-02-30") == nil)
        #expect(day("07/09/2026") == nil)
        #expect(day("tomorrow") == nil)
        #expect(day("") == nil)
        // Forward offsets are refused: a day that has not happened has nothing to report on, and
        // `3` is far likelier to be a typo than a request for Saturday.
        #expect(day("3") == nil)
    }

    // MARK: CLIFailure

    @Test("each failure carries its documented exit code")
    func exitCodes() {
        #expect(CLIFailure.runtime("x").exitCode == 1)
        #expect(CLIFailure.permission("x").exitCode == 3)
        #expect(CLIFailure.config("x").exitCode == 4)
    }

    @Test("3 is the number that already existed, not a new one")
    func reusesTheExistingConstants() {
        #expect(CLIFailure.permission("x").exitCode == DataDirLocation.refusedExitCode)
    }

    @Test("the message is printed as given, with no decoration")
    func message() {
        #expect(CLIFailure.config("GEMINI_API_KEY is not set.").message == "GEMINI_API_KEY is not set.")
        #expect("\(CLIFailure.runtime("boom"))" == "boom")
    }

    @Test("the documented table lists every code the CLI can exit with")
    func tableCoversEveryCode() {
        for code in ["0", "1", "3", "4", "64"] {
            #expect(CLIFailure.table.contains("  \(code)"), "exit code \(code) is not in the table")
        }
        #expect(!CLIFailure.table.contains("  2 "), "nothing exits 2 since `run --headless` went")
    }
}
