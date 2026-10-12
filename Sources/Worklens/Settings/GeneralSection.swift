import SwiftUI
import WorklensCore

/// Settings → General (#286): the status line and today's notices under it, launching, the look,
/// the two shortcuts, and one Updates row.
///
/// From the old window: General's Launching and Updates, Privacy's Shortcuts, and the Activity
/// pane, which is the "See all" under the status line now. The Setup row went to Advanced ("Run
/// setup…"), and the data rows to Usage.
struct GeneralSection: View {
    @ObservedObject var model: AppModel
    @State private var startOnLaunch = true
    @State private var storedPauseHotkey: HotkeySpec?
    @State private var storedOpenHotkey: HotkeySpec?
    @State private var recordingPause = false
    @State private var recordingOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            SettingsStatusLine(model: model)
                .settingsAnchor(.status, model: model, cornerRadius: ReaderTheme.Radius.panel)
            launching
            appearance
            shortcuts
            updates
        }
        .onAppear {
            startOnLaunch = model.shouldStartCapturing()
            storedPauseHotkey = model.storedPauseHotkey()
            storedOpenHotkey = model.storedOpenHotkey()
            model.refreshLaunchAtLogin()
            model.refreshSettingsHealth()
        }
    }

    // MARK: Launching

    private var launching: some View {
        SettingsGroup(String(localized: "Launching", comment: "Settings group")) {
            SettingsRow(
                String(localized: "Launch at login", comment: "Setting"),
                detail: String(localized: "Worklens opens in the menu bar when you log in.", comment: "Setting detail"),
                note: model.launchAtLogin.explanation.map {
                    SettingsRowNote(text: $0, tone: model.launchAtLogin == .requiresApproval ? .attention : .muted)
                }
            ) {
                if model.launchAtLogin == .requiresApproval {
                    Button(String(localized: "Open Login Items", comment: "Button")) { model.openLoginItemsSettings() }
                        .buttonStyle(.settings)
                }
                SettingsSwitch(
                    label: String(localized: "Launch at login", comment: "Setting"),
                    isOn: Binding(
                        get: { model.launchAtLogin.isOn },
                        set: {
                            model.setLaunchAtLogin($0)
                            model.settingsToast(SettingsCopy.saved(String(localized: "Launch at login", comment: "Setting")))
                        }
                    )
                )
                .disabled(!LaunchAtLogin.isAvailable)
            }
            SettingsRow(
                String(localized: "Capture when Worklens opens", comment: "Setting"),
                detail: String(localized: "Otherwise it opens paused until you press Capture.", comment: "Setting detail")
            ) {
                SettingsSwitch(
                    label: String(localized: "Capture when Worklens opens", comment: "Setting"),
                    isOn: Binding(
                        get: { startOnLaunch },
                        set: {
                            startOnLaunch = $0
                            model.setStartCapturingOnLaunch($0)
                            model.settingsToast(SettingsCopy.saved(String(localized: "Capture when Worklens opens", comment: "Setting")))
                        }
                    )
                )
            }
            // #147: the second door, for a menu-bar item a notch or a dozen others can hide.
            SettingsRow(
                String(localized: "Keep Worklens in the Dock", comment: "Setting"),
                detail: String(localized: "It always stays in the menu bar.", comment: "Setting detail")
            ) {
                SettingsSwitch(
                    label: String(localized: "Keep Worklens in the Dock", comment: "Setting"),
                    isOn: Binding(
                        get: { model.showInDock },
                        set: {
                            model.setShowInDock($0)
                            model.settingsToast(SettingsCopy.saved(String(localized: "Keep Worklens in the Dock", comment: "Setting")))
                        }
                    )
                )
            }
        }
    }

    // MARK: Appearance

    /// #283's theme switch. Not in the prototype, which predates it; kept, because it is a real
    /// setting people have already changed.
    private var appearance: some View {
        SettingsGroup(String(localized: "Appearance", comment: "Label")) {
            SettingsRow(
                String(localized: "Theme", comment: "Picker"),
                detail: String(localized: "System follows your Mac's light or dark mode.", comment: "Setting detail")
            ) {
                SettingsSegmented(
                    label: String(localized: "Theme", comment: "Picker"),
                    options: AppearanceChoice.allCases.map { ($0, $0.name) },
                    selection: model.appearance
                ) {
                    model.setAppearance($0)
                    model.settingsToast(SettingsCopy.saved(String(localized: "Theme", comment: "Picker")))
                }
            }
        }
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        SettingsGroup(String(localized: "Shortcuts", comment: "Label")) {
            SettingsRow(
                String(localized: "Pause or resume", comment: "Setting"),
                detail: String(localized: "Works from any app.", comment: "Setting detail"),
                note: pauseNote
            ) {
                HotkeyRecorder(
                    spec: model.pauseHotkey ?? storedPauseHotkey,
                    isRecording: $recordingPause,
                    label: String(localized: "Pause or resume shortcut", comment: "VoiceOver")
                ) { spec in
                    model.setPauseHotkey(spec)
                    storedPauseHotkey = spec
                    recordingPause = false
                    model.settingsToast(SettingsCopy.saved(String(localized: "Shortcut", comment: "Toast")))
                }
                .fixedSize()
                // #154: always here, disabled at the default.
                Button(String(localized: "Reset", comment: "Button")) {
                    model.setPauseHotkey(nil)
                    storedPauseHotkey = nil
                    model.settingsToast(SettingsCopy.saved(String(localized: "Shortcut", comment: "Toast")))
                }
                .buttonStyle(.settingsMutedLink)
                .disabled(storedPauseHotkey == nil)
            }
            SettingsRow(
                String(localized: "Open Worklens", comment: "Label"),
                detail: String(localized: "Brings this window to the front.", comment: "Setting detail"),
                note: openNote
            ) {
                HotkeyRecorder(
                    spec: model.openHotkey ?? storedOpenHotkey,
                    isRecording: $recordingOpen,
                    label: String(localized: "Open Worklens shortcut", comment: "VoiceOver")
                ) { spec in
                    model.setOpenHotkey(spec)
                    storedOpenHotkey = spec
                    recordingOpen = false
                    model.settingsToast(SettingsCopy.saved(String(localized: "Shortcut", comment: "Toast")))
                }
                .fixedSize()
                Button(String(localized: "Reset", comment: "Button")) {
                    model.setOpenHotkey(nil)
                    storedOpenHotkey = nil
                    model.settingsToast(SettingsCopy.saved(String(localized: "Shortcut", comment: "Toast")))
                }
                .buttonStyle(.settingsMutedLink)
                .disabled(storedOpenHotkey == nil)
            }
        }
    }

    private var pauseNote: SettingsRowNote? {
        if model.pauseHotkeyClashesWithOpen {
            return SettingsRowNote(text: String(localized: "Worklens already uses this to open Worklens. Pick another.", comment: "Label"), tone: .attention)
        }
        if model.pauseHotkey == nil {
            return SettingsRowNote(text: String(localized: "Another app already uses this combination. Pick another.", comment: "Label"), tone: .attention)
        }
        return nil
    }

    private var openNote: SettingsRowNote? {
        if model.openHotkeyClashesWithPause {
            return SettingsRowNote(text: String(localized: "Worklens already uses this to pause and resume. Pick another.", comment: "Label"), tone: .attention)
        }
        if model.openHotkey == nil {
            return SettingsRowNote(text: String(localized: "Another app already uses this combination. Pick another.", comment: "Label"), tone: .attention)
        }
        return nil
    }

    // MARK: Updates

    /// One row: the version, what the last check said, and Check now. "Update and restart…" only
    /// when Worklens runs out of the checkout it was built from — there is nothing to pull for a
    /// copy that was moved.
    private var updates: some View {
        SettingsGroup(String(localized: "Updates", comment: "Label")) {
            SettingsRow(
                L10n.format("Worklens %@", WorklensVersion.short),
                detail: updateLine
            ) {
                Button(model.checkingForUpdates
                    ? String(localized: "Checking…", comment: "Button")
                    : String(localized: "Check now", comment: "Button")
                ) {
                    model.checkForUpdates()
                }
                .buttonStyle(.settings)
                .disabled(model.checkingForUpdates)
                if AppModel.repoRoot != nil, model.updateOffered {
                    Button(String(localized: "Update and restart…", comment: "Button")) { model.updateAndRestart() }
                        .buttonStyle(.settings)
                }
            }
        }
    }

    private var updateLine: String {
        if let available = model.updateAvailableLine { return available }
        if let checked = model.updateCheckLine { return checked }
        return model.config.autoUpdateEnabled
            ? L10n.format("Checks for a new version every %@", Format.cadence(model.config.autoUpdatePollMinutes * 60, locale: .autoupdatingCurrent))
            : String(localized: "Worklens checks only when you press Check now.", comment: "Setting detail")
    }
}

// MARK: - The status line

/// One row, one clause (`SettingsStatus`), and under it "See all (n)": the same n things the
/// headline counts, and nothing that is already over.
struct SettingsStatusLine: View {
    @ObservedObject var model: AppModel
    @State private var showsAll = false
    /// The notices you have had in front of you on this visit: the one the line names, and every
    /// row while "See all" is open. Leaving General marks the ones that asked for nothing as
    /// reviewed, so they are there to read this time and gone the next.
    @State private var seen: Set<UUID> = []

    var body: some View {
        let status = model.settingsStatus
        let needs = SettingsStatus.needs(state: model.state)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(dot(status.kind))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                (Text(status.headline).fontWeight(.semibold)
                    + Text(" · " + status.detail).foregroundColor(ReaderTheme.muted))
                    .font(ReaderTheme.Size.rowTitle)
                    .foregroundStyle(ReaderTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let label = status.remedyLabel, let remedy = status.remedy {
                    Button(label) { model.performSettingsRemedy(remedy) }
                        .buttonStyle(.settingsLink)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: ReaderTheme.Radius.panel).fill(ReaderTheme.list))
            .overlay(RoundedRectangle(cornerRadius: ReaderTheme.Radius.panel).strokeBorder(ReaderTheme.line))
            .accessibilityElement(children: .combine)
            .onAppear { seen.formUnion(needs.prefix(1).compactMap(\.noticeID)) }
            .onChange(of: needs.first?.noticeID) { _, id in if let id { seen.insert(id) } }

            if !needs.isEmpty {
                SettingsDisclosureButton(
                    title: L10n.format("See all (%@)", Format.count(needs.count, locale: .autoupdatingCurrent)),
                    isOpen: $showsAll,
                    accessibilityName: String(localized: "Everything that needs you", comment: "VoiceOver")
                )
                if showsAll {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(needs.enumerated()), id: \.offset) { row($0.element) }
                    }
                    .onAppear { seen.formUnion(needs.compactMap(\.noticeID)) }
                }
            }
        }
        .onDisappear { model.markNoticesSeen(seen) }
    }

    private func dot(_ kind: SettingsStatus.Kind) -> Color {
        switch kind {
        case .needsYou: return ReaderTheme.accent
        case .working: return ReaderTheme.ok
        }
    }

    private func row(_ need: SettingsNeed) -> some View {
        // The sentence is worded as a clause, to follow the line's " · "; a row of its own
        // starts with a capital.
        SettingsRow(
            need.sentence.prefix(1).uppercased() + need.sentence.dropFirst(),
            detail: need.at.map { Format.clock($0, timeZone: .current, locale: .autoupdatingCurrent) },
            minHeight: 44
        ) {
            Button(remedyLabel(need.remedy)) { model.performSettingsRemedy(need.remedy) }
                .buttonStyle(.settings)
            if let id = need.noticeID {
                Button(String(localized: "Dismiss", comment: "Button")) { model.dismissNotice(id) }
                    .buttonStyle(.settingsMutedLink)
            }
        }
    }

    private func remedyLabel(_ remedy: SettingsStatus.Remedy) -> String {
        switch remedy {
        case .review: return L10n.string("Review")
        case let .perform(action): return action.label
        }
    }
}
