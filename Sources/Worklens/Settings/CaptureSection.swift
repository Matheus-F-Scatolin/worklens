import AppKit
import SwiftUI
import WorklensCore

/// Settings → Capture (#286): what Worklens looks at, how often, picture quality, the language
/// summaries are written in, and the Access card — the one boxed group on any Settings page, because it is the one that can be broken.
///
/// From the old window: the Capture pane minus away-for (Advanced now), and the Permissions pane,
/// which is the card.
struct CaptureSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            look
            often
            quality
            summaries
            AccessCard(model: model)
        }
        .onAppear { model.refreshAccessibility() }
    }

    // MARK: What Worklens looks at

    private var look: some View {
        SettingsGroup(String(localized: "What Worklens looks at", comment: "Label")) {
            SettingsRow(
                String(localized: "Source", comment: "Setting"),
                detail: Self.sentence(for: model.config.captureSource),
                note: model.settingNote("CAPTURE_SOURCE") ?? accessibilityNote
            ) {
                SettingsSegmented(
                    label: String(localized: "Source", comment: "Setting"),
                    options: offeredSources.map { ($0, Self.name(of: $0)) },
                    selection: model.config.captureSource
                ) {
                    model.saveSetting("CAPTURE_SOURCE", $0.rawValue, as: String(localized: "Source", comment: "Setting"))
                }
                .disabled(model.isSettingLocked("CAPTURE_SOURCE"))
            }
        }
    }

    /// `Text only` takes no screenshot to fall back on, so without the grant that choice collects
    /// nothing; `Text and a picture` quietly becomes pictures only.
    private var accessibilityNote: SettingsRowNote? {
        guard model.config.captureSource != .screenshot, !model.accessibilityTrusted else { return nil }
        return SettingsRowNote(
            text: model.config.captureSource == .accessibility
                ? String(localized: "Reading text needs Accessibility, which is off, so nothing is being collected. Allow it under Access.", comment: "Label")
                : String(localized: "Reading text needs Accessibility, which is off, so Worklens takes pictures only. Allow it under Access.", comment: "Label"),
            tone: .attention
        )
    }

    /// The three shippable choices, plus `auto` only when some layer has already set it — the
    /// registry calls it a setting to test, not to ship.
    private var offeredSources: [CaptureSourceMode] {
        let shippable: [CaptureSourceMode] = [.both, .screenshot, .accessibility]
        return shippable.contains(model.config.captureSource) ? shippable : shippable + [model.config.captureSource]
    }

    static func name(of source: CaptureSourceMode) -> String {
        switch source {
        case .both: return String(localized: "Text and a picture", comment: "Setting")
        case .screenshot: return String(localized: "A picture only", comment: "Setting")
        case .accessibility: return String(localized: "Text only", comment: "Setting")
        case .auto: return String(localized: "Text, then the rest", comment: "Setting")
        }
    }

    static func sentence(for source: CaptureSourceMode) -> String {
        switch source {
        case .both: return String(localized: "The window's text and a screenshot, each time Worklens looks.", comment: "Setting detail")
        case .screenshot: return String(localized: "A screenshot each time Worklens looks, and no text.", comment: "Setting detail")
        case .accessibility: return String(localized: "The window's text only. No picture is ever taken.", comment: "Setting detail")
        case .auto: return String(localized: "The window's text, and a picture of what it missed. Set outside the app, for testing.", comment: "Setting detail")
        }
    }

    // MARK: How often

    private var often: some View {
        SettingsGroup(String(localized: "How often", comment: "Label")) {
            SettingsRow(
                String(localized: "Look at your screen every", comment: "Setting"),
                detail: String(localized: "A screenshot that barely changed is skipped.", comment: "Setting detail"),
                note: model.settingNote("CAPTURE_INTERVAL_SECONDS")
            ) {
                SettingsDuration(
                    model: model, key: "CAPTURE_INTERVAL_SECONDS",
                    label: String(localized: "Look at your screen every", comment: "Setting"),
                    choices: [15, 30, 60, 120, 300], current: model.config.captureIntervalSeconds
                )
            }
            SettingsRow(
                String(localized: "In a meeting, every", comment: "Setting"),
                detail: String(localized: "Slides and calls change slowly.", comment: "Setting detail"),
                note: model.settingNote("MEETING_CAPTURE_INTERVAL_SECONDS")
            ) {
                SettingsDuration(
                    model: model, key: "MEETING_CAPTURE_INTERVAL_SECONDS",
                    label: String(localized: "In a meeting, every", comment: "Setting"),
                    choices: [60, 120, 300, 600], current: model.config.meetingCaptureIntervalSeconds
                )
            }
            SettingsRow(
                String(localized: "On battery", comment: "Setting"),
                detail: Self.sentence(for: model.config.captureOnBattery),
                note: model.settingNote("CAPTURE_ON_BATTERY")
            ) {
                SettingsMenu(
                    label: String(localized: "On battery", comment: "Setting"),
                    options: BatteryCaptureMode.allCases.map { ($0, Self.name(of: $0)) },
                    selection: model.config.captureOnBattery
                ) {
                    model.saveSetting("CAPTURE_ON_BATTERY", $0.rawValue, as: String(localized: "On battery", comment: "Setting"))
                }
                .disabled(model.isSettingLocked("CAPTURE_ON_BATTERY"))
            }
        }
    }

    static func name(of mode: BatteryCaptureMode) -> String {
        switch mode {
        case .normal: return String(localized: "Keep going", comment: "Setting")
        case .slow: return String(localized: "Slow down", comment: "Setting")
        case .describeLater: return String(localized: "Wait for the charger", comment: "Setting")
        }
    }

    /// What the choice does, with the real multiplier rather than the prototype's "roughly
    /// halves". Low Power Mode counts too.
    static func sentence(for mode: BatteryCaptureMode) -> String {
        switch mode {
        case .normal:
            return String(localized: "Being on battery changes nothing.", comment: "Setting detail")
        case .slow:
            return L10n.format("Worklens looks %@ times less often on battery or in Low Power Mode.", String(PowerPolicy.batteryIntervalMultiplier))
        case .describeLater:
            return String(localized: "Screenshots wait for the charger before they are summarized.", comment: "Setting detail")
        }
    }

    // MARK: Picture quality

    private var quality: some View {
        let current = PictureQuality(model.config)
        return SettingsGroup(String(localized: "Picture quality", comment: "Label")) {
            SettingsRow(
                String(localized: "Screenshot size", comment: "Setting"),
                detail: current.sentence(edge: model.config.captureMaxEdgePx),
                note: model.settingNote("CAPTURE_MAX_EDGE_PX", "CHANGE_THRESHOLD")
            ) {
                SettingsSegmented(
                    label: String(localized: "Screenshot size", comment: "Setting"),
                    options: PictureQuality.offered(model.config).map { ($0, $0.name) },
                    selection: current
                ) { picked in
                    guard let pair = picked.pair else { return }
                    model.saveSettings(
                        [("CAPTURE_MAX_EDGE_PX", String(pair.edge)), ("CHANGE_THRESHOLD", String(pair.threshold))],
                        as: String(localized: "Screenshot size", comment: "Setting")
                    )
                }
                .disabled(model.isSettingLocked("CAPTURE_MAX_EDGE_PX") || model.isSettingLocked("CHANGE_THRESHOLD"))
            }
        }
    }

    // MARK: Summaries

    /// `REPORT_LANGUAGE`, which kept its name when the reports were cut (2026-10-05).
    private var summaries: some View {
        SettingsGroup(String(localized: "Summaries", comment: "Settings group")) {
            SettingsRow(
                String(localized: "Language", comment: "Setting"),
                detail: String(localized: "Each screenshot's summary is written in this language.", comment: "Setting detail"),
                note: model.settingNote("REPORT_LANGUAGE")
            ) {
                SettingsMenu(
                    label: String(localized: "Language", comment: "Setting"),
                    options: languages.map { ($0, Self.languageName($0)) },
                    selection: model.config.reportLanguage
                ) {
                    model.saveSetting("REPORT_LANGUAGE", $0, as: String(localized: "Language", comment: "Setting"))
                }
                .disabled(model.isSettingLocked("REPORT_LANGUAGE"))
            }
        }
    }

    /// A handful the model writes well, plus whatever a layer already set.
    private var languages: [String] {
        let offered = ["en", "pt-BR", "es", "fr", "de", "it"]
        let current = model.config.reportLanguage
        return offered.contains(current) ? offered : offered + [current]
    }

    /// `English`, `português (Brasil)` — each language in the user's own words.
    static func languageName(_ code: String) -> String {
        Locale.autoupdatingCurrent.localizedString(forIdentifier: code)?.capitalized(with: .autoupdatingCurrent) ?? code
    }

    /// `(CAPTURE_MAX_EDGE_PX, CHANGE_THRESHOLD)` as one choice. A pair set by hand is `custom`:
    /// shown, and never overwritten until a preset is picked.
    enum PictureQuality: Hashable {
        case smaller, balanced, sharper, custom

        var pair: (edge: Int, threshold: Double)? {
            switch self {
            case .smaller: return (768, 0.05)
            case .balanced: return (1024, 0.03)
            case .sharper: return (1600, 0.015)
            case .custom: return nil
            }
        }

        init(_ config: Config) {
            let match = [PictureQuality.smaller, .balanced, .sharper].first {
                guard let pair = $0.pair else { return false }
                return pair.edge == config.captureMaxEdgePx && abs(pair.threshold - config.changeThreshold) < 0.0001
            }
            self = match ?? .custom
        }

        static func offered(_ config: Config) -> [PictureQuality] {
            let presets: [PictureQuality] = [.smaller, .balanced, .sharper]
            return PictureQuality(config) == .custom ? presets + [.custom] : presets
        }

        var name: String {
            switch self {
            case .smaller: return String(localized: "Smaller files", comment: "Setting")
            case .balanced: return String(localized: "Balanced", comment: "Setting")
            case .sharper: return String(localized: "Sharper", comment: "Setting")
            case .custom: return String(localized: "Custom", comment: "Setting")
            }
        }

        /// The real longest edge, in place of the prototype's invented kilobytes.
        func sentence(edge: Int) -> String {
            let pixels = Format.count(pair?.edge ?? edge, locale: .autoupdatingCurrent)
            switch self {
            case .smaller: return L10n.format("%@ px on the longest edge; very small text can blur.", pixels)
            case .balanced: return L10n.format("%@ px on the longest edge; small text stays readable.", pixels)
            case .sharper: return L10n.format("%@ px on the longest edge; crisp on large displays.", pixels)
            case .custom: return L10n.format("%@ px on the longest edge, set by hand.", pixels)
            }
        }
    }
}

/// A menu of durations for one seconds key, plus the current value when a layer set one the menu
/// does not offer — so a hand-set 45 s is shown, not silently replaced.
struct SettingsDuration: View {
    @ObservedObject var model: AppModel
    let key: String
    let label: String
    let choices: [Int]
    let current: Int
    var never: Int?

    var body: some View {
        let offered = (choices.contains(current) || current == never ? choices : (choices + [current]).sorted())
        SettingsMenu(
            label: label,
            options: offered.map { ($0, Self.words($0)) } + (never.map { [($0, String(localized: "Never", comment: "Setting"))] } ?? []),
            selection: current
        ) {
            model.saveSetting(key, String($0), as: label)
        }
        .disabled(model.isSettingLocked(key))
    }

    /// `15 seconds`, `1 minute`, `2 minutes`, `1 hour`.
    static func words(_ seconds: Int) -> String {
        if seconds < 60 { return L10n.plural(count: seconds, one: "%lld second", other: "%lld seconds") }
        if seconds % 3600 == 0 { return L10n.plural(count: seconds / 3600, one: "%lld hour", other: "%lld hours") }
        if seconds % 60 == 0 { return L10n.plural(count: seconds / 60, one: "%lld minute", other: "%lld minutes") }
        return L10n.format("%@ min", Format.decimal(Double(seconds) / 60, places: 1, locale: .autoupdatingCurrent))
    }
}

// MARK: - Access

/// The Access card: Screen Recording, Accessibility, Browsers and Notifications, each with its
/// badge and one remedy, and the two "Don't remind me" switches. From the old Permissions pane.
struct AccessCard: View {
    @ObservedObject var model: AppModel
    @State private var browsers: [AutomationPermission.BrowserStatus] = []
    /// The browser whose consent dialog is up; a second click would queue a second one.
    @State private var asking: String?
    @State private var skipAccessibility = false
    @State private var skipBrowsers = false

    var body: some View {
        SettingsGroup(String(localized: "Access", comment: "Settings group")) {
            SettingsCard {
                screenRecording
                accessibility
                browsersRow
                notifications
                SettingsRow(
                    String(localized: "Don't remind me about Accessibility", comment: "Setting"),
                    detail: String(localized: "The menu and the gear stop pointing at it.", comment: "Setting detail"),
                    minHeight: 50
                ) {
                    SettingsSwitch(
                        label: String(localized: "Don't remind me about Accessibility", comment: "Setting"),
                        isOn: Binding(get: { skipAccessibility }, set: {
                            skipAccessibility = $0
                            model.setSkipped(AppModel.skipAccessibilityAdvisoryKey, $0)
                            model.refreshSettingsHealth()
                            model.settingsToast(SettingsCopy.saved())
                        })
                    )
                }
                SettingsRow(
                    String(localized: "Don't remind me about browsers", comment: "Setting"),
                    detail: String(localized: "The menu and the gear stop pointing at them.", comment: "Setting detail"),
                    minHeight: 50
                ) {
                    SettingsSwitch(
                        label: String(localized: "Don't remind me about browsers", comment: "Setting"),
                        isOn: Binding(get: { skipBrowsers }, set: {
                            skipBrowsers = $0
                            model.setSkipped(AppModel.skipBrowserAdvisoryKey, $0)
                            model.refreshSettingsHealth()
                            model.settingsToast(SettingsCopy.saved())
                        })
                    )
                }
            }
            .settingsAnchor(.access, model: model)
        }
        .onAppear {
            // Reads only: opening this page must never prompt (#79).
            model.refreshSettingsHealth()
            browsers = AutomationPermission.browsers()
            skipAccessibility = model.isSkipped(AppModel.skipAccessibilityAdvisoryKey)
            skipBrowsers = model.isSkipped(AppModel.skipBrowserAdvisoryKey)
        }
        // Coming back from System Settings is when a grant has changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSettingsHealth()
            browsers = AutomationPermission.browsers()
        }
    }

    private var allowed: String { String(localized: "Allowed", comment: "Pill") }

    private var screenRecording: some View {
        SettingsRow(
            String(localized: "Screen Recording", comment: "Label"),
            detail: model.screenRecording == .granted
                ? String(localized: "Needed to take screenshots.", comment: "Setting detail")
                : String(localized: "Needed to take screenshots. macOS applies a yes after Worklens relaunches.", comment: "Setting detail"),
            minHeight: 50
        ) {
            switch model.screenRecording {
            case .granted:
                SettingsPill(text: "✓ " + allowed)
            case .denied, .unknown:
                SettingsPill(text: String(localized: "Off", comment: "Pill"), kind: .need)
                Button(ScreenRecordingCopy.askLabel) { model.requestScreenRecording() }
                    .buttonStyle(.settingsPrimary)
                Button(String(localized: "Open System Settings", comment: "Button")) {
                    ScreenCaptureService.openScreenRecordingSettings()
                }
                .buttonStyle(.settings)
                if model.canRelaunch {
                    Button(ScreenRecordingCopy.relaunchLabel) { model.relaunch() }
                        .buttonStyle(.settings)
                }
            }
        }
    }

    private var accessibility: some View {
        SettingsRow(
            String(localized: "Accessibility", comment: "Label"),
            detail: model.accessibilityTrusted
                ? String(localized: "Lets Worklens read window text instead of a picture.", comment: "Setting detail")
                : String(localized: "Optional. Lets Worklens read window text instead of a picture.", comment: "Setting detail"),
            minHeight: 50
        ) {
            if model.accessibilityTrusted {
                SettingsPill(text: "✓ " + allowed)
            } else {
                SettingsPill(text: String(localized: "Off", comment: "Pill"), kind: .off)
                Button(String(localized: "Open System Settings", comment: "Button")) { model.requestAccessibility() }
                    .buttonStyle(.settings)
            }
        }
    }

    private var browsersRow: some View {
        SettingsRow(
            String(localized: "Browsers", comment: "Label"),
            detail: AccessCopy.browsersLine(browsers),
            minHeight: 50
        ) {
            if let pill = AccessCopy.browsersPill(browsers) {
                SettingsPill(text: pill.allowed ? "✓ " + pill.text : pill.text, kind: pill.allowed ? .ok : .need)
            }
            if let browser = browsers.first(where: { $0.status.canRequest }) {
                Button(asking == browser.bundleID
                    ? String(localized: "Waiting for macOS…", comment: "Button")
                    : L10n.format("Ask macOS for %@…", browser.name)
                ) { ask(browser) }
                    .buttonStyle(.settings)
                    .disabled(asking != nil)
            } else if browsers.contains(where: { $0.status == .denied }) {
                Button(String(localized: "Open System Settings", comment: "Button")) { AutomationPermission.openSettings() }
                    .buttonStyle(.settings)
            }
        }
    }

    private var notifications: some View {
        SettingsRow(
            String(localized: "Notifications", comment: "Label"),
            detail: String(localized: "Optional. A banner when a permission has gone.", comment: "Setting detail"),
            minHeight: 50
        ) {
            switch model.notifications {
            case .authorized, .provisional:
                SettingsPill(text: "✓ " + allowed)
            case .denied:
                SettingsPill(text: String(localized: "Off", comment: "Pill"), kind: .off)
                Button(String(localized: "Open System Settings", comment: "Button")) { Notifier.openSettings() }
                    .buttonStyle(.settings)
            default:
                SettingsPill(text: String(localized: "Not asked", comment: "Pill"), kind: .off)
                Button(String(localized: "Ask macOS for notifications\u{2026}", comment: "Button")) { model.requestNotifications() }
                    .buttonStyle(.settings)
            }
        }
    }

    /// Raises one browser's consent dialog, off the main thread, and moves that row's badge and
    /// the status line when it is answered — no relaunch.
    @MainActor private func ask(_ browser: AutomationPermission.BrowserStatus) {
        asking = browser.bundleID
        Task {
            let status = await AutomationPermission.request(forBundleID: browser.bundleID)
            browsers = AutomationPermission.applying(status, toBundleID: browser.bundleID, in: browsers)
            asking = nil
            model.refreshSettingsHealth()
            if status == .allowed {
                model.settingsToast(L10n.format("%@ now shares page addresses", browser.name))
            }
        }
    }
}
