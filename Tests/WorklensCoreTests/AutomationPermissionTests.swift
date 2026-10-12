import CoreServices
import Foundation
import Testing
@testable import WorklensCore

/// The decision half of #79. The TCC call itself needs a real user in front of a real dialog, so
/// it sits behind `request(forBundleID:ask:)`; everything that decides *whether* to make it, and
/// what the pane does with the answer, is here.
@Suite("Automation permission — asking, and what the pane does with the answer")
struct AutomationPermissionTests {
    private typealias Status = AutomationPermission.Status

    @Test("Only a browser with no answer on file gets a Request button")
    func onlyNotAskedCanBeAsked() {
        #expect(Status.notAsked.canRequest)
        // macOS never prompts twice: after a denial only System Settings can flip it, and a
        // button that raises no dialog is the dead end this issue exists to remove.
        #expect(!Status.denied.canRequest)
        #expect(!Status.allowed.canRequest)
        // Nobody to ask — `AEDeterminePermissionToAutomateTarget` answers procNotFound and shows
        // nothing at all when the target is not running.
        #expect(!Status.notRunning.canRequest)
    }

    @Test("The four OSStatus values asking and reading share")
    func statusCodes() {
        #expect(AutomationPermission.status(forCode: noErr) == .allowed)
        #expect(AutomationPermission.status(forCode: OSStatus(errAEEventNotPermitted)) == .denied)
        #expect(AutomationPermission.status(forCode: OSStatus(procNotFound)) == .notRunning)
        // -1744, errAEEventWouldRequireUserConsent: the row that gets the button.
        #expect(AutomationPermission.status(forCode: -1744) == .notAsked)
    }

    @Test("An answer moves that row's badge and leaves every other row alone")
    func applyingOneRow() {
        let rows = [
            AutomationPermission.BrowserStatus(
                bundleID: "com.apple.Safari", name: "Safari", status: .notAsked
            ),
            AutomationPermission.BrowserStatus(
                bundleID: "com.google.Chrome", name: "Google Chrome", status: .allowed
            ),
        ]
        let after = AutomationPermission.applying(
            .allowed, toBundleID: "com.apple.Safari", in: rows
        )
        #expect(after[0].status == .allowed)
        #expect(after[0].name == "Safari")
        #expect(after[1] == rows[1])
    }

    @Test("A denial lands on the badge too — the button goes, Open System Settings stays")
    func applyingDenial() {
        let rows = [
            AutomationPermission.BrowserStatus(
                bundleID: "com.apple.Safari", name: "Safari", status: .notAsked
            )
        ]
        let after = AutomationPermission.applying(.denied, toBundleID: "com.apple.Safari", in: rows)
        #expect(after[0].status == .denied)
        #expect(!after[0].status.canRequest)
    }

    @Test("An answer for a browser the pane is not showing changes nothing")
    func applyingUnknownBundle() {
        let rows = [
            AutomationPermission.BrowserStatus(
                bundleID: "com.apple.Safari", name: "Safari", status: .notAsked
            )
        ]
        #expect(AutomationPermission.applying(.allowed, toBundleID: "com.brave.Browser", in: rows) == rows)
    }

    @Test("Asking blocks off the main thread and hands back what TCC said")
    func requestWaitsOffTheMainThread() async {
        // The real call does not return until the user answers the dialog. This fake stands in
        // for that wait and records where it happened: on the main thread it would be the pane
        // freezing behind its own dialog.
        nonisolated(unsafe) var askedOnMainThread = true
        nonisolated(unsafe) var askedFor: String?
        let status = await AutomationPermission.request(
            forBundleID: "com.apple.Safari",
            ask: { bundleID in
                askedOnMainThread = Thread.isMainThread
                askedFor = bundleID
                return .allowed
            }
        )
        #expect(status == .allowed)
        #expect(askedFor == "com.apple.Safari")
        #expect(!askedOnMainThread)
    }
}
