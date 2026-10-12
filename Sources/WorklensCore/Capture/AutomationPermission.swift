import AppKit
import CoreServices
import Foundation

/// Whether this app may drive a browser over Apple events, in the same shape as
/// `AccessibilityPermission` (#53): a status anything may *read*, and one call that asks.
///
/// `status(forBundleID:)` passes `askUserIfNeeded: false`, which is the whole point: it reports
/// the answer TCC already has without provoking the dialog, so a Settings pane, a menu tick and
/// a CLI can all consult it freely. `request(forBundleID:)` (#79) is the single exception, and
/// like `AccessibilityPermission.request()` it is reached only from an explicit click.
///
/// Moved out of `Settings/PermissionsSettingsView.swift` for #64: the menu needs the same answer
/// the pane shows, and two probes would be two chances to disagree about what "allowed" means.
public enum AutomationPermission {
    /// The four answers `AEDeterminePermissionToAutomateTarget` actually gives.
    public enum Status: String, Sendable, Equatable, CaseIterable {
        /// The user said yes; the URL probe will be answered.
        case allowed
        /// The user said no. The probe fails on every attempt and backs off ten minutes at a time.
        case denied
        /// The browser is not running, so there is nobody to ask. Not an answer about the grant:
        /// TCC returns `procNotFound` whether or not permission was ever given.
        case notRunning
        /// No answer on file — the dialog has not been shown, or was dismissed without one.
        case notAsked

        /// True only for `allowed`. `notRunning` is deliberately not "not allowed": it says
        /// nothing about the grant, and treating it as a denial would put a warning on screen
        /// for a browser the user simply closed.
        public var isAllowed: Bool { self == .allowed }

        /// Whether asking could still produce a dialog. Only `notAsked` can: macOS never prompts
        /// twice, so `denied` is settled until the user changes it in System Settings, `allowed`
        /// has nothing left to ask, and `notRunning` has nobody to ask (#79).
        public var canRequest: Bool { self == .notAsked }
    }

    /// One scriptable browser and where its Automation grant stands.
    public struct BrowserStatus: Sendable, Equatable {
        public let bundleID: String
        /// The installed app's own name — "Google Chrome", not `com.google.Chrome`.
        public let name: String
        public let status: Status

        public init(bundleID: String, name: String, status: Status) {
            self.bundleID = bundleID
            self.name = name
            self.status = status
        }
    }

    /// The current answer for one bundle id. Cheap, and it cannot prompt.
    public static func status(forBundleID bundleID: String) -> Status {
        determine(bundleID, askUserIfNeeded: false)
    }

    /// Raises the macOS Automation consent dialog for one browser, and answers with what TCC
    /// recorded — the same read `status(forBundleID:)` does, one moment later.
    ///
    /// This is the only call in Worklens that can prompt, and it exists because nothing else
    /// can (#79). System Settings → Privacy & Security → Automation lists only applications that
    /// have already asked and been answered, so a browser at `.notAsked` has no row there to
    /// switch on; and the URL probe's own first Apple event raises the dialog but times out
    /// after 1.5 s waiting for an answer, so it never records one. Asking on purpose is the only
    /// path that ends in a decision.
    ///
    /// Three things follow from how `AEDeterminePermissionToAutomateTarget` behaves:
    ///
    /// - **It blocks until the user answers**, so the wait happens on a background queue and the
    ///   caller gets it back with `await`. A synchronous call from a SwiftUI action would freeze
    ///   the pane behind the dialog.
    /// - **The target has to be running**, or it returns `procNotFound` and shows nothing. The
    ///   pane offers no button for a browser that is closed.
    /// - **macOS asks once.** After a denial this returns `.denied` without a dialog forever,
    ///   which is why `.denied` gets "Open System Settings" instead of another attempt.
    ///
    /// Mirrors `AccessibilityPermission.request()`: reached only from an explicit click, never
    /// from a capture tick, from launch, or from opening Settings.
    public static func request(forBundleID bundleID: String) async -> Status {
        await request(forBundleID: bundleID, ask: askTCC)
    }

    /// The seam. `ask` is the one thing here a test cannot run — it needs a real user and a real
    /// dialog — so everything around it (which rows may ask, what the badge becomes) is testable
    /// and only this closure is not.
    static func request(
        forBundleID bundleID: String,
        ask: @escaping @Sendable (String) -> Status
    ) async -> Status {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ask(bundleID))
            }
        }
    }

    /// The blocking TCC call, off on its own so `request` is nothing but the hop off the main
    /// thread. `askUserIfNeeded: true` raises the dialog *without* sending a real Apple event:
    /// no script runs, and nothing about the browser is read.
    private static let askTCC: @Sendable (String) -> Status = { bundleID in
        determine(bundleID, askUserIfNeeded: true)
    }

    private static func determine(_ bundleID: String, askUserIfNeeded: Bool) -> Status {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let descriptor = target.aeDesc else { return .notRunning }
        return status(
            forCode: AEDeterminePermissionToAutomateTarget(
                descriptor, typeWildCard, typeWildCard, askUserIfNeeded
            )
        )
    }

    /// The four `OSStatus` values that matter, in one place so asking and reading cannot drift.
    /// `-1744` (`errAEEventWouldRequireUserConsent`) is the one the default arm catches: consent
    /// that has never been asked for, which is exactly the row that gets a button.
    static func status(forCode code: OSStatus) -> Status {
        switch code {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .notRunning
        default: return .notAsked
        }
    }

    /// One row's status replaced in place, leaving the rest of the pane alone. A grant that
    /// lands has to move a badge without reopening Settings, and a browser that is not the one
    /// asked about must not be re-read behind the user's back.
    public static func applying(
        _ status: Status, toBundleID bundleID: String, in rows: [BrowserStatus]
    ) -> [BrowserStatus] {
        rows.map { row in
            guard row.bundleID == bundleID else { return row }
            return BrowserStatus(bundleID: row.bundleID, name: row.name, status: status)
        }
    }

    /// The installed app's display name, or nil when nothing with that bundle id is installed.
    public static func displayName(forBundleID bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    /// Every installed browser that has a URL AppleScript at all, with its status. Firefox has
    /// none, so it never appears: there is no permission that would make it answer.
    public static func browsers() -> [BrowserStatus] {
        BrowserRegistry.browsers.compactMap { browser in
            guard BrowserRegistry.urlScript(for: browser) != nil,
                  let name = displayName(forBundleID: browser.bundleID)
            else { return nil }
            return BrowserStatus(
                bundleID: browser.bundleID, name: name, status: status(forBundleID: browser.bundleID)
            )
        }
    }

    /// Opens System Settings → Privacy & Security → Automation.
    public static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        else { return }
        // NSWorkspace is AppKit: hop to the main thread rather than whatever thread called us.
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    /// What a surface says when the probe is getting nowhere, worded for whoever is at the
    /// keyboard. Names no browser: the caller knows which one, and this is the sentence after it.
    public static let settingsHint = """
        Open System Settings → Privacy & Security → Automation and switch the browser on under \
        Worklens. Without it the timeline says "Chrome" where it could say "GitHub".
        """
}
