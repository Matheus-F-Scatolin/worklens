import AppKit
import ApplicationServices
import Foundation

/// The Accessibility grant, in the same shape as `ScreenCaptureService.permissionState()` /
/// `requestPermission()` / `openScreenRecordingSettings()` (#52).
///
/// Two things about this permission that the Screen Recording one does not have:
///
/// - **It is bound to the code signature.** An ad-hoc rebuild is a different binary as far as TCC
///   is concerned, so the grant is lost; the "Worklens Dev" certificate is what makes it stick.
/// - **From a terminal, TCC attributes the request to the terminal.** `swift run Worklens
///   capture-once` needs Accessibility granted to Terminal or iTerm, not to Worklens; the bundled
///   app needs its own grant.
///
/// Nothing in the app reads an accessibility tree yet — the CLI is the only caller until #53.
public enum AccessibilityPermission {
    /// Whether this process may read other applications' accessibility trees. Cheap, no prompt.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks once, showing the system prompt that offers to open Settings. Returns the state now,
    /// which is almost always `false`: the user grants it in Settings, after this returns.
    @discardableResult
    public static func request() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings → Privacy & Security → Accessibility.
    public static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        // NSWorkspace is AppKit: hop to the main thread rather than whatever thread called us.
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }
}
