import Foundation
import ServiceManagement
import WorklensCore

/// The Settings → General "Launch at login" toggle, over `SMAppService`.
///
/// `SMAppService.mainApp` registers the *bundle*, which is why this is unavailable under
/// `swift run`: there is no bundle to register, `Bundle.main.bundleIdentifier` is nil, and the
/// toggle says so rather than failing on click.
///
/// `.requiresApproval` is not an error either. macOS puts a newly registered login item in
/// System Settings → General → Login Items in a disabled state when the app is not notarised —
/// which an ad-hoc or self-signed Worklens never is — so the honest UI is to register, then say
/// "approve it in Login Items" with a button that opens exactly that pane.
@MainActor
enum LaunchAtLogin {
    enum State: Equatable {
        case unavailable(String)
        case enabled
        case requiresApproval
        case disabled
        case notFound

        var isOn: Bool { self == .enabled || self == .requiresApproval }

        /// What Settings shows next to the toggle.
        var explanation: String? {
            switch self {
            case let .unavailable(why): return why
            case .enabled: return nil
            case .requiresApproval:
                return "Registered, but macOS wants you to approve it: open Login Items and "
                    + "switch Worklens on. (Unsigned apps always land here.)"
            case .disabled, .notFound: return nil
            }
        }
    }

    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func state() -> State {
        guard isAvailable else {
            return .unavailable("Only the bundled app can register itself: this is `swift run`.")
        }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .notFound
        @unknown default: return .disabled
        }
    }

    /// Registers or unregisters, returning the resulting state. Errors come back as
    /// `.unavailable(message)` so the caller has one thing to render.
    @discardableResult
    static func set(_ on: Bool) -> State {
        guard isAvailable else { return state() }
        do {
            if on {
                try SMAppService.mainApp.register()
                Log.ui.info("registered Worklens as a login item")
            } else {
                try SMAppService.mainApp.unregister()
                Log.ui.info("removed Worklens from the login items")
            }
            return state()
        } catch {
            Log.ui.warn("launch at login \(on ? "registration" : "removal") failed: \(error.localizedDescription)")
            return .unavailable(error.localizedDescription)
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
