import CoreGraphics
import Foundation
import Testing
@testable import WorklensCore

// Security findings #1 (a screenshot is one approved window, revalidated after the capture) and
// #4 (the host blocklist fails closed when a browser will not say where it is).

@Suite("FocusedWindowSelector")
struct FocusedWindowSelectorTests {
    private let rect = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test("The first normal, visible, window-sized entry of the app is the focused window")
    func picksFrontWindowOfPid() {
        let windows = [
            WindowCandidate(windowID: 1, ownerPID: 9, bounds: rect),           // another app, in front
            WindowCandidate(windowID: 2, ownerPID: 5, layer: 25, bounds: rect), // a menu-bar extra
            WindowCandidate(windowID: 3, ownerPID: 5, alpha: 0, bounds: rect),  // invisible
            WindowCandidate(windowID: 4, ownerPID: 5, bounds: CGRect(x: 0, y: 0, width: 1, height: 1)),
            WindowCandidate(windowID: 5, ownerPID: 5, bounds: rect),
            WindowCandidate(windowID: 6, ownerPID: 5, bounds: rect),
        ]
        #expect(FocusedWindowSelector.select(windows, pid: 5)?.windowID == 5)
    }

    @Test("An app with no window on screen has none, so nothing is photographed")
    func noWindow() {
        let windows = [WindowCandidate(windowID: 1, ownerPID: 9, bounds: rect)]
        #expect(FocusedWindowSelector.select(windows, pid: 5) == nil)
        #expect(FocusedWindowSelector.select([], pid: 5) == nil)
    }

    @Test("The window list's dictionaries parse in order, and an incomplete entry is dropped")
    func parsesWindowList() {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200).dictionaryRepresentation
        let raw: [[String: Any]] = [
            [
                kCGWindowNumber as String: 42, kCGWindowOwnerPID as String: 5,
                kCGWindowLayer as String: 0, kCGWindowAlpha as String: 1.0,
                kCGWindowBounds as String: bounds,
            ],
            [kCGWindowNumber as String: 43, kCGWindowOwnerPID as String: 5],
        ]
        let parsed = FocusedWindowSelector.candidates(fromWindowList: raw)
        #expect(parsed == [WindowCandidate(
            windowID: 42, ownerPID: 5, bounds: CGRect(x: 10, y: 20, width: 300, height: 200)
        )])
    }

    @Test("A window on the second monitor is recorded against that monitor")
    func displayOfWindow() {
        let displays = [
            DisplayCandidate(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900)),
            DisplayCandidate(displayID: 2, bounds: CGRect(x: 1440, y: 0, width: 2560, height: 1440)),
        ]
        // Straddles both, mostly on the second.
        let window = CGRect(x: 1300, y: 100, width: 1000, height: 600)
        #expect(FocusedWindowSelector.displayID(for: window, displays: displays) == 2)
        #expect(FocusedWindowSelector.displayID(
            for: CGRect(x: 100, y: 100, width: 400, height: 300), displays: displays
        ) == 1)
        #expect(FocusedWindowSelector.displayID(
            for: CGRect(x: -5000, y: 0, width: 10, height: 10), displays: displays
        ) == nil)
    }
}

@Suite("CaptureRevalidation")
struct CaptureRevalidationTests {
    private let policy = PrivacyPolicy(
        bundleIDs: ["com.1password.1password"], titlePatterns: ["(?i)private browsing"],
        urlHosts: ["bank.example"]
    )
    private let terminal = ForegroundContext(
        bundleID: "com.apple.Terminal", appName: "Terminal", pid: 1, windowTitle: "zsh"
    )

    private func valid(
        _ after: ForegroundContext, captured: CGWindowID? = 7, current: CGWindowID? = 7,
        before: ForegroundContext? = nil
    ) -> Bool {
        CaptureRevalidation.screenshotStillValid(
            before: before ?? terminal, after: after,
            capturedWindowID: captured, currentWindowID: current, policy: policy
        )
    }

    @Test("The change count: kept only when nothing moved and the watcher could watch")
    func nothingMoved() {
        let mark = FocusChangeMark(generation: 4, pid: 1, reach: .full)
        #expect(CaptureRevalidation.nothingMoved(before: mark, after: mark, pid: 1))

        // There and back again: the ends match, the count does not.
        var moved = mark
        moved.generation = 6
        #expect(!CaptureRevalidation.nothingMoved(before: mark, after: moved, pid: 1))

        // Fails closed on a missing mark, a blind watcher, or a mark about another app.
        #expect(!CaptureRevalidation.nothingMoved(before: nil, after: mark, pid: 1))
        #expect(!CaptureRevalidation.nothingMoved(before: mark, after: nil, pid: 1))
        var blind = mark
        blind.reach = .blind
        #expect(!CaptureRevalidation.nothingMoved(before: blind, after: mark, pid: 1))
        #expect(!CaptureRevalidation.nothingMoved(before: mark, after: blind, pid: 1))
        #expect(!CaptureRevalidation.nothingMoved(before: mark, after: mark, pid: 2))
        var otherApp = mark
        otherApp.pid = 2
        #expect(!CaptureRevalidation.nothingMoved(before: otherApp, after: mark, pid: 1))

        // Without Accessibility only app switches are heard; an unchanged count still passes.
        var switchesOnly = mark
        switchesOnly.reach = .activationsOnly
        #expect(CaptureRevalidation.nothingMoved(before: switchesOnly, after: switchesOnly, pid: 1))
    }

    @Test("The live monitor marks nothing until it is started")
    func monitorFailsClosedBeforeStart() {
        #expect(FocusChangeMonitor().mark() == nil)
    }

    @Test("Same window, same app, still allowed: the screenshot is kept")
    func unchanged() {
        #expect(valid(terminal))
    }

    @Test("Another window of the same app came to the front: dropped")
    func windowChanged() {
        #expect(!valid(terminal, current: 8))
        #expect(!valid(terminal, current: nil))
        #expect(!valid(terminal, captured: nil))
    }

    @Test("A switch to a blocked app during the capture: dropped")
    func switchedToBlockedApp() {
        let vault = ForegroundContext(
            bundleID: "com.1password.1password", appName: "1Password", pid: 2, windowTitle: "Vault"
        )
        #expect(!valid(vault))
    }

    @Test("The same window now carries a blocked title: dropped")
    func titleBecameBlocked() {
        var after = terminal
        after.windowTitle = "Bank — Private Browsing"
        #expect(!valid(after))
        #expect(!CaptureRevalidation.contextStillValid(before: terminal, after: after, policy: policy))
    }

    @Test("A browser tab moved to another site, read privately: dropped")
    func privateSiteChanged() {
        let before = ForegroundContext(
            bundleID: "com.google.Chrome", appName: "Chrome", pid: 3, windowTitle: "Docs",
            policySite: .host("docs.example")
        )
        var after = before
        after.policySite = .host("other.example")
        #expect(valid(before, before: before))
        #expect(!valid(after, before: before))
        after.policySite = .host("app.bank.example")
        #expect(!valid(after, before: before))
    }
}

@Suite("PrivacyPolicy fails closed on an unknown host")
struct PrivacyPolicyHostUnknownTests {
    private let chrome = ForegroundContext(
        bundleID: "com.google.Chrome", appName: "Chrome", pid: 3, windowTitle: "Untitled"
    )

    private func decide(_ site: ForegroundContext.PolicySite?, hosts: [String] = ["bank.example"]) -> PrivacyDecision {
        var context = chrome
        context.policySite = site
        return PrivacyPolicy(bundleIDs: [], titlePatterns: [], urlHosts: hosts).decision(for: context)
    }

    @Test("Host exclusions set and the address unreadable: blocked, with its own reason")
    func unreadableIsBlocked() {
        #expect(decide(.unreadable).skipReason == .blockedHostUnknown)
        #expect(SkipReason.blockedHostUnknown.isBlocked)
    }

    @Test("No host exclusions: an unreadable address changes nothing")
    func noListNoBlock() {
        #expect(decide(.unreadable, hosts: []) == .allow)
    }

    @Test("A privately read host is matched even though nothing was stored")
    func privateHostMatches() {
        #expect(decide(.host("app.bank.example")).skipReason == .blockedHost)
        #expect(decide(.host("docs.example")) == .allow)
    }

    @Test("A page with no host, and an app that is no browser, are allowed")
    func readButHostless() {
        #expect(decide(.noHost) == .allow)
        #expect(decide(nil) == .allow)
    }

    @Test("The app-switch overload, which never sees a page, does not fail closed")
    func stringOverloadUnchanged() {
        let policy = PrivacyPolicy(bundleIDs: [], titlePatterns: [], urlHosts: ["bank.example"])
        #expect(policy.decision(bundleID: "com.google.Chrome", windowTitle: nil, browserURL: nil) == .allow)
    }

    @Test("\"Capture now\" says why, without naming the page")
    func captureNowLine() {
        let line = MenuModel.captureNowSkippedLine(.hostUnknown)
        #expect(line?.contains("address") == true)
        #expect(MenuModel.captureNowSkippedLine(.focusChanged) != nil)
        #expect(MenuModel.captureNowSkippedLine(.noWindow) != nil)
    }
}
