import SwiftUI
import WorklensCore

/// Settings → Advanced (#286): tuning and troubleshooting, always in the list below the hairline.
/// There is no "Show advanced settings" switch any more.
///
/// From the old window: the Advanced pane and `ConfigProvenanceSection`, plus every read-only
/// row the other panes carried — the model names and the prices — and the Setup row General had.
/// The provenance table is the one place in Settings where a configuration key's name appears.
struct AdvancedSection: View {
    @ObservedObject var model: AppModel
    @StateObject private var integrations: IntegrationsModel
    @StateObject private var mcp: MCPClientModel
    @State private var jsonShown = false
    @State private var provenanceShown = false
    @State private var pictureSize = ""
    @FocusState private var pictureFocused: Bool

    init(model: AppModel) {
        self.model = model
        _integrations = StateObject(wrappedValue: IntegrationsModel(app: model))
        _mcp = StateObject(wrappedValue: MCPClientModel(app: model, client: .claudeDesktop))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            capture
            models
            privacyAndSync
            configuration
        }
        .task {
            await integrations.refresh()
        }
        .onAppear {
            pictureSize = String(model.config.captureMaxEdgePx)
        }
        .onChange(of: model.config.captureMaxEdgePx) { _, value in
            if !pictureFocused { pictureSize = String(value) }
        }
    }

    // MARK: Capture

    private var capture: some View {
        SettingsGroup(String(localized: "Capture", comment: "Settings group")) {
            SettingsRow(
                String(localized: "Stop after you have been away for", comment: "Setting"),
                detail: String(localized: "No keyboard or mouse for this long pauses capture.", comment: "Setting detail"),
                note: model.settingNote("CAPTURE_IDLE_SECONDS")
            ) {
                SettingsDuration(
                    model: model, key: "CAPTURE_IDLE_SECONDS",
                    label: String(localized: "Stop after you have been away for", comment: "Setting"),
                    choices: [60, 120, 300, 600, 1800], current: model.config.captureIdleSeconds
                )
            }
            SettingsRow(
                String(localized: "Screenshot even when nothing changes, every", comment: "Setting"),
                detail: String(localized: "Keeps a long read or a video on the timeline.", comment: "Setting detail"),
                note: model.settingNote("CAPTURE_HEARTBEAT_SECONDS")
            ) {
                SettingsDuration(
                    model: model, key: "CAPTURE_HEARTBEAT_SECONDS",
                    label: String(localized: "Screenshot even when nothing changes, every", comment: "Setting"),
                    choices: [300, 600, 1800, 3600], current: model.config.captureHeartbeatSeconds
                )
            }
            SettingsRow(
                String(localized: "Picture size", comment: "Setting"),
                detail: L10n.format(
                    "The longest edge, in pixels. Balanced on Capture is %@.",
                    Format.count(CaptureSection.PictureQuality.balanced.pair?.edge ?? 1024, locale: .autoupdatingCurrent)
                ),
                note: model.settingNote("CAPTURE_MAX_EDGE_PX")
            ) {
                TextField(String(localized: "Picture size in pixels", comment: "VoiceOver"), text: $pictureSize)
                    .textFieldStyle(SettingsFieldStyle(width: 78, alignment: .trailing))
                    .focused($pictureFocused)
                    .onSubmit(commitPictureSize)
                    .onChange(of: pictureFocused) { _, focused in if !focused { commitPictureSize() } }
                    .disabled(model.isSettingLocked("CAPTURE_MAX_EDGE_PX"))
                SettingsValueText("px")
            }
        }
    }

    private func commitPictureSize() {
        let typed = pictureSize.trimmingCharacters(in: .whitespaces)
        guard typed != String(model.config.captureMaxEdgePx), !typed.isEmpty else {
            pictureSize = String(model.config.captureMaxEdgePx)
            return
        }
        if !model.saveSetting("CAPTURE_MAX_EDGE_PX", typed, as: String(localized: "Picture size", comment: "Setting")) {
            pictureSize = String(model.config.captureMaxEdgePx)
        }
    }

    // MARK: Models (read-only)

    private var models: some View {
        SettingsGroup(String(localized: "Models", comment: "Settings group")) {
            SettingsRow(String(localized: "Summaries", comment: "Setting")) {
                SettingsValueText(model.config.describeModel)
            }
            SettingsRow(
                String(localized: "Prices checked", comment: "Setting"),
                detail: String(localized: "The spend on Usage uses these prices.", comment: "Setting detail")
            ) {
                SettingsValueText(ModelPricing.pricingVersion)
            }
            SettingsRow(
                String(localized: "Summarizing", comment: "Setting"),
                detail: model.describeHealthLine
            ) { EmptyView() }
        }
    }

    // MARK: Privacy and sync

    private var privacyAndSync: some View {
        SettingsGroup(String(localized: "Privacy and sync", comment: "Settings group")) {
            SettingsRow(
                String(localized: "Extra redaction patterns", comment: "Setting"),
                detail: String(localized: "Blanked out of a window title and an address before either leaves your Mac.", comment: "Setting detail")
            ) {
                SettingsValueText(L10n.plural(count: model.config.redactExtraPatterns.count, one: "%lld pattern", other: "%lld patterns"))
                Button(String(localized: "Edit…", comment: "Button")) { model.openConfigFile(model.settings.url) }
                    .buttonStyle(.settingsLink)
            }
            SettingsRow(
                String(localized: "Sync sources every", comment: "Setting"),
                note: model.settingNote("CONTEXT_SYNC_MINUTES")
            ) {
                SettingsMenu(
                    label: String(localized: "Sync sources every", comment: "Setting"),
                    options: syncChoices.map { ($0, SettingsDuration.words($0 * 60)) },
                    selection: model.config.contextSyncMinutes
                ) {
                    model.saveSetting("CONTEXT_SYNC_MINUTES", String($0), as: String(localized: "Sync sources every", comment: "Setting"))
                }
                .disabled(model.isSettingLocked("CONTEXT_SYNC_MINUTES"))
            }
            SettingsRow(
                String(localized: "Keep the Google sign-in in", comment: "Picker"),
                detail: integrations.storeError ?? integrations.tokenStore.detail,
                note: model.settingNote("GOOGLE_TOKEN_STORE")
            ) {
                SettingsMenu(
                    label: String(localized: "Keep the Google sign-in in", comment: "Picker"),
                    options: GoogleTokenStorage.allCases.map { ($0, $0.label) },
                    selection: integrations.tokenStore
                ) { store in
                    Task {
                        await integrations.chooseTokenStore(store)
                        if integrations.storeError == nil {
                            model.settingsToast(SettingsCopy.saved(String(localized: "Google sign-in", comment: "Toast")))
                        }
                    }
                }
                .disabled(model.isSettingLocked("GOOGLE_TOKEN_STORE") || integrations.isSwitchingStore)
            }
            SettingsRow(
                String(localized: "Another MCP client", comment: "Label"),
                detail: String(localized: "The JSON to paste into any other app that speaks MCP.", comment: "Setting detail")
            ) {
                SettingsDisclosureButton(
                    title: jsonShown ? String(localized: "Hide", comment: "Button") : String(localized: "Show", comment: "Button"),
                    isOpen: $jsonShown,
                    accessibilityName: String(localized: "Another MCP client", comment: "Label")
                )
            }
            if jsonShown {
                VStack(alignment: .leading, spacing: 8) {
                    Text(mcp.plan.json)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: ReaderTheme.Radius.panel).fill(ReaderTheme.list))
                        .overlay(RoundedRectangle(cornerRadius: ReaderTheme.Radius.panel).strokeBorder(ReaderTheme.line))
                    Button(String(localized: "Copy JSON", comment: "Button")) {
                        mcp.copyJSON()
                        model.settingsToast(String(localized: "Copied JSON", comment: "Toast"))
                    }
                    .buttonStyle(.settings)
                }
                .padding(.vertical, 10)
            }
        }
    }

    private var syncChoices: [Int] {
        let offered = [5, 15, 30, 60]
        let current = model.config.contextSyncMinutes
        return offered.contains(current) ? offered : (offered + [current]).sorted()
    }

    // MARK: Configuration

    private var configuration: some View {
        SettingsGroup(String(localized: "Configuration", comment: "Label")) {
            SettingsRow(
                String(localized: "Settings file", comment: "Setting"),
                detail: String(localized: "Everything on these pages, as plain text.", comment: "Setting detail")
            ) {
                Button(String(localized: "Open", comment: "Button")) { model.openConfigFile(model.settings.url) }
                    .buttonStyle(.settingsLink)
                Button(String(localized: "Reload", comment: "Button")) {
                    model.reloadConfig()
                    model.settingsToast(String(localized: "Configuration reloaded", comment: "Toast"))
                }
                .buttonStyle(.settingsMutedLink)
            }
            .help(model.settings.url.path)
            SettingsRow(
                String(localized: "Every value and where it comes from", comment: "Setting"),
                note: model.configProvenance.devOverrideLine.map { SettingsRowNote(text: $0, tone: .attention) }
            ) {
                SettingsDisclosureButton(
                    title: provenanceShown ? String(localized: "Hide", comment: "Button") : String(localized: "Show", comment: "Button"),
                    isOpen: $provenanceShown,
                    accessibilityName: String(localized: "Every value and where it comes from", comment: "Setting")
                )
            }
            if provenanceShown {
                ProvenanceTable(model: model)
                    .padding(.vertical, 10)
            }
            SettingsRow(
                String(localized: "Run setup again", comment: "Setting"),
                detail: String(localized: "Walks through keys and permissions from the start.", comment: "Setting detail")
            ) {
                Button(String(localized: "Run setup…", comment: "Button")) { model.openSetup() }
                    .buttonStyle(.settings)
            }
            // #349: the invented week, any time; it is rebuilt for today and never reaches Claude.
            SettingsRow(SampleWeekCopy.settingTitle, detail: SampleWeekCopy.settingDetail) {
                Button(SampleWeekCopy.show) { model.showSampleWeek() }
                    .buttonStyle(.settings)
            }
            // #351: the spotlight tour, again. Finishing or skipping it the first time is
            // remembered (`TourMemory`), and nothing ever offers it a second time on its own.
            SettingsRow(TourCopy.settingsRow, detail: TourCopy.settingsDetail) {
                Button(TourCopy.settingsButton) { model.startTour() }
                    .buttonStyle(.settings)
            }
            SettingsRow(
                String(localized: "Log level", comment: "Label"),
                detail: String(localized: "How much Worklens writes to its log file.", comment: "Setting detail"),
                note: model.settingNote("LOG_LEVEL")
            ) {
                SettingsMenu(
                    label: String(localized: "Log level", comment: "Label"),
                    options: LogLevel.allCases.map { ($0, $0.rawValue.capitalized) },
                    selection: model.config.logLevel
                ) {
                    model.saveSetting("LOG_LEVEL", $0.rawValue, as: String(localized: "Log level", comment: "Label"))
                }
                .disabled(model.isSettingLocked("LOG_LEVEL"))
            }
        }
    }
}

// MARK: - Every value and where it comes from

/// The files Worklens read, highest precedence first, then every key, its value and the layer
/// that supplied it — the one place Settings names a configuration key (#286). Secrets arrive
/// masked from `dumpLines`, the same strings `worklens config dump` prints.
private struct ProvenanceTable: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let provenance = model.configProvenance
        let winners = Set(provenance.sources.values)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(provenance.files, id: \.layer) { file in
                    HStack(spacing: 8) {
                        SettingsChip(text: file.layer.label)
                        Text(file.url.path)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(file.url.path)
                        Spacer(minLength: 0)
                        SettingsValueText(file.exists
                            ? (winners.contains(file.layer) ? String(localized: "winning", comment: "Provenance") : String(localized: "read", comment: "Provenance"))
                            : String(localized: "missing", comment: "Provenance"))
                        if file.exists {
                            Button(String(localized: "Open", comment: "Button")) { model.openConfigFile(file.url) }
                                .buttonStyle(.settingsLink)
                        }
                    }
                }
            }
            if !provenance.retiredKeys.isEmpty {
                Text(L10n.format("These keys no longer do anything and can be deleted: %@", provenance.retiredKeys.joined(separator: ", ")))
                    .font(ReaderTheme.Size.rowDetail)
                    .foregroundStyle(ReaderTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !provenance.appSupportOverrides.isEmpty {
                Text(L10n.format(
                    "The Application Support .env outranks this checkout's and disagrees with it about %@. Run worklens install-env from the checkout this app should read.",
                    provenance.appSupportOverrides.joined(separator: ", ")
                ))
                .font(ReaderTheme.Size.rowDetail)
                .foregroundStyle(ReaderTheme.warn)
                .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    header(String(localized: "Key", comment: "Provenance"))
                    header(String(localized: "Value", comment: "Provenance"))
                    header(String(localized: "From", comment: "Provenance"))
                }
                ForEach(model.config.dumpLines(provenance: provenance), id: \.key) { line in
                    Divider().gridCellColumns(3)
                    GridRow {
                        Text(line.key)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Text(line.value)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(line.value)
                        SettingsChip(text: line.source.label)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: ReaderTheme.Radius.panel).strokeBorder(ReaderTheme.line))
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(ReaderTheme.Size.rowDetail.weight(.medium))
            .foregroundStyle(ReaderTheme.muted)
            .padding(.bottom, 6)
    }
}
