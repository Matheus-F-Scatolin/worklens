import AppKit

/// Whether Worklens is a Dock app right now. A menu-bar app while nothing of it is on screen, and
/// a regular one — Dock tile, ⌘-Tab entry, the menu bar across the top — for as long as one of
/// its windows is open or minimized. Closing the last window puts it back in the menu bar alone.
///
/// **Mechanism.** The bundle stays `LSUIElement`, so every launch starts as `.accessory` and a
/// login item never flashes a Dock tile. `NSApp.setActivationPolicy` moves between the two at
/// runtime; the question it answers is `wantsDock`, re-asked whenever a window becomes key,
/// changes occlusion (ordered in or out), is minimized or restored, or closes.
///
/// **Order matters on the way in.** A policy that turns `.regular` while the app is already
/// active can leave the menu bar showing the previous app's menus until the next activation, so
/// `AppModel` calls `windowWillOpen()` *before* it activates and opens a window; the notifications
/// are the backstop for windows that appear any other way.
///
/// `pinned` is Settings → General → "Keep Worklens in the Dock" (#147): the Dock tile stays when
/// no window is open, for someone whose menu-bar icon is hidden behind the notch.
@MainActor
final class DockPresence {
    static let shared = DockPresence()

    var pinned = false {
        didSet { apply() }
    }

    private var observers: [NSObjectProtocol] = []
    /// While a window is on its way in, nothing downgrades: an occlusion change on some other
    /// window in that gap would otherwise flip the policy back and forth once.
    private var openingUntil = Date.distantPast

    private init() {}

    /// Called once from `applicationDidFinishLaunching`.
    func start() {
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                // Next turn, not this one: `willClose` arrives while the closing window is still
                // visible, and would otherwise count it.
                DispatchQueue.main.async { MainActor.assumeIsolated { DockPresence.shared.apply() } }
            }
        }
        apply()
    }

    /// Become a Dock app before a window is asked to open, so the activation that follows brings
    /// the menu bar with it. Settles a moment later in case no window came of it.
    func windowWillOpen() {
        openingUntil = Date().addingTimeInterval(Self.openingGrace)
        setPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openingGrace + 0.05) {
            MainActor.assumeIsolated { DockPresence.shared.apply() }
        }
    }

    private func apply() {
        let opening = Date() < openingUntil
        setPolicy(pinned || opening || Self.hasOpenWindow() ? .regular : .accessory)
    }

    private static let openingGrace: TimeInterval = 1

    private func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    /// A window a person opened: titled, not a panel (alerts, open/save sheets), and on screen or
    /// sitting in the Dock minimized. The status item, its menu and tooltips are none of these.
    private static func hasOpenWindow() -> Bool {
        NSApp.windows.contains { window in
            window.styleMask.contains(.titled)
                && !(window is NSPanel)
                && (window.isVisible || window.isMiniaturized)
        }
    }
}
