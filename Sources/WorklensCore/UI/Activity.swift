import Foundation

/// Something Worklens is doing right now because the user asked it to (#150).
///
/// Until this existed the only in-progress signal in the app was a relabelled menu item. A sync,
/// a configuration reload and an erase ran in complete silence — so the honest reading of a
/// button was "that did nothing", and the honest response was to press it again.
///
/// Each of those registers an `Activity` for as long as it runs. The menu draws one row per
/// activity, the status-item glyph goes `.busy` while any of them stands, and the auto-updater
/// refuses to restart the app underneath one.
///
/// **No ticking clock.** #231 took the per-activity rows out of the menu: `MenuBarExtra(.menu)`
/// draws a real `NSMenu`, and what the menu still says is the status-item glyph going `.busy`.
/// The notice that lands when the thing finishes is what actually tells you.
public struct Activity: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case sync
        case reload
        case erase
    }

    /// Unique per thing-being-done.
    public let id: String
    public let kind: Kind
    /// What is happening, with no trailing ellipsis: `Syncing integrations`.
    public let label: String
    public let startedAt: Date
    /// Whether the menu draws a Cancel button beside the row. The handle itself lives in
    /// `AppModel`, keyed by `id`: `MenuState` is `Equatable` and `Sendable`, and a closure is
    /// neither.
    public let cancellable: Bool

    public init(
        id: String,
        kind: Kind,
        label: String,
        startedAt: Date = Date(),
        cancellable: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.startedAt = startedAt
        self.cancellable = cancellable
    }
}

/// The `app_state` key the updater leaves behind, and the one sentence it turns into (#150).
///
/// "Update and restart…" makes the menu-bar icon vanish for a minute or two while
/// `scripts/update.sh` pulls, rebuilds, re-signs and relaunches. Nothing confirmed the app ever
/// came back, so the only way to find out was to keep watching the menu bar. The commit that was
/// *running* goes into `app_state` before the quit; the next launch compares it with the commit
/// stamped into `Info.plist` and says so when the two differ.
public enum UpdatePending {
    public static let key = "update_pending"

    /// `Worklens is back — now on 0ae882e`, or nil when there is nothing honest to say: no key,
    /// an unstamped build that cannot be compared, or an update that relaunched the same commit
    /// because it failed. The caller clears the key either way, so a failed update stays quiet
    /// exactly once rather than every launch afterwards.
    public static func notice(pending: String?, running: String?) -> String? {
        guard let pending, !pending.isEmpty else { return nil }
        guard let running, !running.isEmpty else { return nil }
        guard pending != running else { return nil }
        return "Worklens is back: now on \(UpdatePending.short(running))"
    }

    static func short(_ commit: String) -> String { String(commit.prefix(7)) }
}
