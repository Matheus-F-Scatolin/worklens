import Foundation

/// The sentences the Settings page says that are not about one row (#286): the toast every change
/// ends in, and why a row is locked. Here rather than in the SwiftUI, so the wording is tested and
/// so no config key name can leak into it — `docs/copy.md` keeps those out of every sentence a
/// person reads, and the only place Settings shows one is Advanced's provenance table.
public enum SettingsCopy {
    /// The toast after a change: `Saved · Launch at login`, or plain `Saved`.
    public static func saved(_ what: String? = nil) -> String {
        guard let what, !what.isEmpty else { return L10n.string("Saved") }
        return L10n.format("Saved · %@", what)
    }

    /// Why a row cannot be changed from here, or nil when it can. Today's rule (#108): a key the
    /// process environment or the file `WORKLENS_ENV_FILE` names supplies wins over the settings
    /// file, so an edit would change a file nobody reads. Every other layer is written past.
    ///
    /// The wording is the old `ConfigSourceNote`'s — which layer, in words — plus the remedy, and
    /// it names neither the variable nor the file.
    public static func lockNote(_ layer: ConfigLayer) -> String? {
        switch layer {
        case .process:
            return L10n.string("Set in the environment Worklens was launched with, which wins. Remove it there to change this here.")
        case .explicitFile:
            return L10n.string("Set in the settings file this run was pointed at, which wins. Remove it there, then press Reload in Advanced.")
        case .appSettings, .appSupport, .cwd, .fallback:
            return nil
        }
    }
}

/// Capture's Access card (#286): the one line under Browsers, from each browser's Automation
/// answer. Here so the grouping and the grammar are tested rather than assembled in a view.
public enum AccessCopy {
    /// `Optional. Google Chrome shares page addresses; Safari hasn't been asked.` — each answer
    /// once, allowed first, and never a browser that is closed, since macOS will not say.
    public static func browsersLine(_ browsers: [AutomationPermission.BrowserStatus]) -> String {
        guard !browsers.isEmpty else {
            return L10n.string("Optional. No browser Worklens can read an address from is installed.")
        }
        func names(_ status: AutomationPermission.Status) -> [String] {
            browsers.filter { $0.status == status }.map(\.name)
        }
        var clauses: [String] = []
        let allowed = names(.allowed)
        if !allowed.isEmpty {
            clauses.append(allowed.count == 1
                ? L10n.format("%@ shares page addresses", list(allowed))
                : L10n.format("%@ share page addresses", list(allowed)))
        }
        let notAsked = names(.notAsked)
        if !notAsked.isEmpty {
            clauses.append(notAsked.count == 1
                ? L10n.format("%@ hasn't been asked", list(notAsked))
                : L10n.format("%@ haven't been asked", list(notAsked)))
        }
        let denied = names(.denied)
        if !denied.isEmpty {
            clauses.append(denied.count == 1
                ? L10n.format("%@ said no", list(denied))
                : L10n.format("%@ said no", list(denied)))
        }
        guard !clauses.isEmpty else {
            return L10n.string("Optional. Open a browser to see whether it shares page addresses.")
        }
        return L10n.format("Optional. %@.", clauses.joined(separator: "; "))
    }

    /// The pill beside Browsers: every one that answered said yes, or which one wants a yes.
    public static func browsersPill(_ browsers: [AutomationPermission.BrowserStatus]) -> (text: String, allowed: Bool)? {
        if let first = browsers.first(where: { $0.status == .notAsked }) {
            return (L10n.format("%@ needs a yes", first.name), false)
        }
        if browsers.contains(where: { $0.status == .denied }) {
            return (L10n.string("Off"), false)
        }
        if browsers.contains(where: { $0.status == .allowed }) {
            return (L10n.string("Allowed"), true)
        }
        return nil
    }

    static func list(_ names: [String]) -> String { ListFormatter.localizedString(byJoining: names) }
}
