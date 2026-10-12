import AppKit
import Foundation
import WorklensCore

/// What the menu asks of `AppModel` and nothing else asks for (#231).
///
/// The menu itself is `MenuContent`; every action it fires is a method `AppModel` already had.
/// These two are the glue the native menu adds: one thing to call when the menu opens, and the
/// one line the menu draws that is not already a `MenuModel` row.
@MainActor
extension AppModel {
    /// Called from `MenuContent.body`, which SwiftUI evaluates when the menu is *opened*.
    ///
    /// Today's numbers are two table reads, so they are asked for here rather than in the 30 s
    /// refresh loop (PLAN §1.6) — `refreshTodaySnapshot()` no-ops while the cached snapshot is
    /// younger than `TodaySnapshot.cacheSeconds`, and the read itself runs off the main actor.
    /// A menu opened before the first read has finished simply has no tally row.
    func menuWillOpen() {
        refreshTodaySnapshot()
    }

    /// The menu's tally row — `2h 05m active · 45m in meetings · $0.42 of $2.00` — or nil before
    /// anything is tracked today, where the row is left out rather than drawn empty.
    ///
    /// Nil while a configuration or storage fault has degraded the menu: the row under the
    /// status line is then the sentence that says what went wrong, carrying the remedies, and
    /// today's numbers are not the question at that moment.
    var menuTallyLine: String? {
        guard !menu.isDegraded else { return nil }
        guard let line = today?.tallyLine, !line.isEmpty else { return nil }
        return line
    }

    // MARK: - The shortcut that opens Worklens (#252)

    /// The second global hotkey. A menu-bar app that feels native answers a key press, and until
    /// this the only way into the reader was click-the-icon-then-⌘O.
    func registerOpenHotkey() {
        let spec = storedOpenHotkey() ?? HotkeySpec.defaultOpen
        guard !clashesWithOwnHotkey(spec, slot: .open) else {
            openHotkeyClashesWithPause = true
            return
        }
        openHotkeyClashesWithPause = false
        let ok = GlobalHotkey.shared.register(spec, slot: .open) { [weak self] in
            self?.frontHomeWindow()
        }
        openHotkey = ok ? spec : nil
        if !ok {
            note(error: "The shortcut \(spec.display) for opening Worklens is taken by another "
                + "app: pick a different one in Settings → Privacy.")
        }
    }

    func storedOpenHotkey() -> HotkeySpec? {
        guard let db else { return nil }
        return (try? AppStateStore(db).getCodable(HotkeySpec.openKey)) ?? nil
    }

    /// Stores the shortcut that opens Worklens and registers it. Passing nil restores `⌥⇧W`.
    ///
    /// A combination the pause shortcut already holds is not stored at all: it could never be
    /// registered, and persisting it would lose the working binding on the next launch too.
    func setOpenHotkey(_ spec: HotkeySpec?) {
        guard !clashesWithOwnHotkey(spec ?? HotkeySpec.defaultOpen, slot: .open) else {
            openHotkeyClashesWithPause = true
            objectWillChange.send()
            return
        }
        store(spec, under: HotkeySpec.openKey)
        registerOpenHotkey()
        objectWillChange.send()
    }

    /// True when `spec` is what Worklens's *other* shortcut is already registered with.
    ///
    /// `RegisterEventHotKey` answers a combination this same process owns with
    /// `eventHotKeyExistsErr` — the same code another app's claim produces — and by then
    /// `register(_:slot:)` has already dropped the binding it was replacing. So the question is
    /// asked here first: the row blames the right owner and the working shortcut survives.
    func clashesWithOwnHotkey(_ spec: HotkeySpec, slot: GlobalHotkey.Slot) -> Bool {
        spec == GlobalHotkey.shared.registered(slot == .pause ? .open : .pause)
    }

    func store(_ spec: HotkeySpec?, under key: String) {
        guard let db else { return }
        if let spec {
            try? AppStateStore(db).setCodable(key, spec)
        } else {
            try? AppStateStore(db).delete(key)
        }
    }

    /// What the open shortcut does: bring Worklens forward and put the home window in front of
    /// whatever you were in. The same thing clicking the Dock tile does.
    func frontHomeWindow() {
        openWindow(id: AppModel.readerWindowID)
    }
}
