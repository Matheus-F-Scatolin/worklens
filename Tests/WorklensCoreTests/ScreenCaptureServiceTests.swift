import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing
@testable import WorklensCore

/// Two displays side by side in global CG coordinates (top-left origin): the built-in laptop
/// screen at the origin and an external one to its right.
private enum Displays {
    static let builtIn = DisplayCandidate(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))
    static let external = DisplayCandidate(displayID: 2, bounds: CGRect(x: 1512, y: -300, width: 2560, height: 1440))
    static let both = [builtIn, external]
    static let mainID: CGDirectDisplayID = 1
}

@Suite("Display selection")
struct DisplaySelectorTests {
    @Test("Picks the display under the mouse")
    func mouseOnBuiltIn() {
        let picked = DisplaySelector.select(
            displays: Displays.both, mouse: CGPoint(x: 700, y: 400), mainDisplayID: Displays.mainID
        )
        #expect(picked == Displays.builtIn)
    }

    @Test("Moving the mouse to the second display changes the pick")
    func mouseOnExternal() {
        let picked = DisplaySelector.select(
            displays: Displays.both, mouse: CGPoint(x: 2800, y: 200), mainDisplayID: Displays.mainID
        )
        #expect(picked == Displays.external)
    }

    @Test("A point in the gap above the built-in display falls back to main")
    func mouseOutsideEveryDisplay() {
        let picked = DisplaySelector.select(
            displays: Displays.both, mouse: CGPoint(x: 300, y: -500), mainDisplayID: Displays.mainID
        )
        #expect(picked == Displays.builtIn)
    }

    @Test("No mouse location falls back to main")
    func noMouse() {
        let picked = DisplaySelector.select(
            displays: Displays.both, mouse: nil, mainDisplayID: Displays.mainID
        )
        #expect(picked == Displays.builtIn)
    }

    @Test("--display main ignores the mouse")
    func mainPreferenceIgnoresMouse() {
        let picked = DisplaySelector.select(
            displays: Displays.both, mouse: CGPoint(x: 2800, y: 200),
            mainDisplayID: Displays.mainID, preference: .main
        )
        #expect(picked == Displays.builtIn)
    }

    @Test("An unknown main display id falls back to the first display")
    func mainMissing() {
        let picked = DisplaySelector.select(
            displays: [Displays.external], mouse: nil, mainDisplayID: Displays.mainID
        )
        #expect(picked == Displays.external)
    }

    @Test("No displays at all selects nothing")
    func empty() {
        #expect(DisplaySelector.select(displays: [], mouse: .zero, mainDisplayID: 1) == nil)
    }
}

@Suite("Capture error classification")
struct CaptureErrorClassificationTests {
    /// -3801: the code ScreenCaptureKit reports when TCC refuses, including after the user
    /// declines the roughly-monthly re-authorization dialog.
    private static let userDeclined = NSError(domain: SCStreamErrorDomain, code: -3801)

    @Test("SCStreamError.userDeclined is a permission problem even while preflight still says yes")
    func userDeclinedWins() {
        let mapped = CaptureError.classify(Self.userDeclined, permissionState: .granted)
        #expect(mapped == .permissionDenied)
    }

    @Test("Any failure while preflight says denied is a permission problem")
    func preflightDenied() {
        let other = NSError(domain: NSOSStatusErrorDomain, code: -108)
        #expect(CaptureError.classify(other, permissionState: .denied) == .permissionDenied)
    }

    @Test("An unrelated failure with permission granted stays a capture failure")
    func genuineFailure() {
        let other = NSError(domain: "SomeOtherDomain", code: 42)
        guard case .captureFailed = CaptureError.classify(other, permissionState: .granted) else {
            Issue.record("expected .captureFailed")
            return
        }
    }

    @Test("A CaptureError passes through unchanged")
    func passthrough() {
        #expect(CaptureError.classify(CaptureError.noDisplay, permissionState: .granted) == .noDisplay)
    }
}
