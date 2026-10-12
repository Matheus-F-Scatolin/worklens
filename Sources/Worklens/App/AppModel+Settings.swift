import SwiftUI
import WorklensCore

/// How a Settings row reads and writes its key (#286). Every change saves at once — there are no
/// Save buttons — through the same `applySetting` the old panes used, and ends in a "Saved" toast.
extension AppModel {
    /// Why `key` cannot be changed from Settings, or nil when it can.
    func settingLock(_ key: String) -> String? {
        SettingsCopy.lockNote(configProvenance.source(of: key))
    }

    func isSettingLocked(_ key: String) -> Bool { settingLock(key) != nil }

    /// The sentence under a row: its lock, else what the loader said about a refused value.
    func settingNote(_ keys: String...) -> SettingsRowNote? {
        for key in keys {
            if let lock = settingLock(key) { return SettingsRowNote(text: lock) }
        }
        for key in keys {
            if let failure = settingsFailures[key] { return SettingsRowNote(text: failure, tone: .attention) }
        }
        return nil
    }

    /// The value `config-dump` would print for `key` — masked, when it is a secret.
    func settingValue(_ key: String) -> String {
        Config.key(named: key)?.read?(config) ?? ""
    }

    /// Writes `key`, reloads around it, and says "Saved · `label`". A refused value is kept under
    /// the row that sent it — the same sentence `worklens config set` prints — and nothing is
    /// toasted.
    @discardableResult
    func saveSetting(_ key: String, _ value: String, as label: String?) -> Bool {
        do {
            try applySetting(key, value)
            settingsFailures[key] = nil
            settingsToast(SettingsCopy.saved(label))
            return true
        } catch {
            settingsFailures[key] = ConfigError.note(error)
            return false
        }
    }

    /// Two keys that are one choice — the picture-quality presets — written together.
    @discardableResult
    func saveSettings(_ pairs: [(key: String, value: String)], as label: String?) -> Bool {
        do {
            for pair in pairs { try settings.set(pair.key, pair.value) }
            Log.ui.info("settings: \(pairs.map(\.key).joined(separator: ", ")) changed")
            reloadConfig()
            for pair in pairs { settingsFailures[pair.key] = nil }
            settingsToast(SettingsCopy.saved(label))
            return true
        } catch {
            if let first = pairs.first { settingsFailures[first.key] = ConfigError.note(error) }
            return false
        }
    }
}

extension AppModel {
    /// General's status line, from the same `MenuState` the menu draws (#286).
    var settingsStatus: SettingsStatus {
        SettingsStatus.make(
            state: state,
            firstActivity: settingsFirstCapture.flatMap {
                DayBoundaries.dayString($0) == DayBoundaries.dayString(Date()) ? $0 : nil
            },
            captureLine: menu.statusLine
        )
    }

    /// The section whose name carries the needs-you dot, and whose dot the gear carries too, or
    /// nil when nothing wants you.
    var settingsNeedsYou: SettingsSection? {
        SettingsStatus.needs(state: state).first?.section
    }

    /// Re-reads what the status line and the Access card depend on: the grants, which browsers
    /// went without an address today, and when today's first screenshot was taken. Reads only — nothing here can
    /// raise a macOS dialog (#79).
    func refreshSettingsHealth() {
        recheckPermissions()
        guard let db else { return }
        refreshBrowserURLs(db: db)
        settingsFirstCapture = (try? CaptureStore(db).firstCaptureAt(day: DayBoundaries.dayString(Date()))) ?? nil
    }

    /// Runs the remedy on the status line.
    func performSettingsRemedy(_ remedy: SettingsStatus.Remedy) {
        switch remedy {
        case let .review(target): openSettings(target)
        case let .perform(action): perform(action)
        }
    }
}
