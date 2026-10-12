import AppKit
import Foundation
import WorklensCore

/// Stops a second Worklens from running against the same data.
///
/// Two Worklenses is not a cosmetic problem: both would capture on their own timers, both would
/// drain the describe queue, and the budget each of them enforces would only know about half the
/// spend. So both entry points refuse to start twice, by the means available to each:
///
/// - **The app** asks the window server first. Another process with the same bundle identifier
///   means the user double-clicked an app that is already running (or `open`ed it while it sat in
///   the menu bar) — so the running one is activated, asked for its home window, and this one
///   exits, which is what a menu-bar app should do rather than complaining.
/// - **Both** then take `InstanceLock` on `DATA_DIR/.lock`, which is what catches the case the
///   window server cannot see: `swift run Worklens run` has no bundle identifier at all.
enum SingleInstance {
    /// The same string `Config` matches on to tell a bundled app from `swift run`.
    static let bundleIdentifier = Config.bundleIdentifier

    /// True when another copy of the app is already running; it is brought to the front first.
    @MainActor
    static func anotherAppIsRunning() -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: SingleInstance.bundleIdentifier)
            .filter { $0.processIdentifier != mine }
        guard let first = others.first else { return false }
        // "Activate" on its own only brings back whichever window was key last — or, with none
        // open, just makes the menu clickable, which is no help to the person who launched a
        // second copy because they could not find the menu (#147). So the running copy is also
        // asked, over `SettingsReveal`, to put its home window in front: the same place the Dock
        // tile and ⌥⇧W land (#279). It used to ask for Settings, before the reader was home.
        first.activate(options: [])
        SettingsReveal.postHome()
        Log.ui.warn("another Worklens is already running (pid \(first.processIdentifier)); exiting")
        return true
    }
}
