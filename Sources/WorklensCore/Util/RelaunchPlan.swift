import Foundation

/// How Worklens starts itself again, as a string rather than as an action, so the one part of it
/// that is easy to get wrong can be unit-tested without quitting anything.
///
/// **The order matters more than the mechanism.** The obvious call —
/// `NSWorkspace.openApplication(createsNewApplicationInstance: true)` followed by
/// `NSApp.terminate` — leaves nothing running: `SingleInstance.anotherAppIsRunning()` makes a
/// second copy activate the first and exit immediately, so the new instance is gone before the
/// old one has finished quitting. The bug only shows on a real double launch, which is why it is
/// written down here rather than discovered. So, like `scripts/update.sh`: a detached shell waits
/// for this process to leave the process table, *then* `open`s the bundle, and only then does the
/// app terminate. By the time `open` runs there is no first instance to defer to.
///
/// **Waiting on a pid, not on a pattern.** `update.sh` waits with `pgrep -a -f "$APP_BIN"`, and
/// `-a` is load-bearing there because BSD `pgrep` excludes its own ancestors and the app is one.
/// The same line inside this helper never finishes: the helper's own command line *contains* the
/// binary path, `-a` puts the helper (pgrep's parent) back in the match list, and the loop
/// matches itself forever. The app knows its own pid, `kill -0` answers exactly the question
/// being asked, and neither can match the wrong process.
public enum RelaunchPlan {
    /// `processID` is the app's own pid; `bundlePath` the `.app` to reopen.
    public static func script(processID: Int32, bundlePath: String) -> String {
        // `kill -0` sends no signal: it asks whether the process still exists. Once it does not,
        // stderr is silenced because the failing read *is* the exit condition.
        "while kill -0 \(processID) 2>/dev/null; do sleep 0.1; done; open \(quote(bundlePath))"
    }

    /// A path inside single quotes, with any single quote in it closed, escaped and reopened —
    /// the usual `'\''`. An application folder may be called anything at all.
    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
