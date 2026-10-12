import AppKit
import SwiftUI
import WorklensCore

/// Settings → Connections (#286): the AI provider, Claude and Codex as clients of Worklens,
/// and the context sources — Granola and Google Calendar since #285.
///
/// From the old window: `AccountsSection` (the keys, never shown masked here), the Claude pane's
/// two clients, and the Integrations pane's cards and Google account. The sync interval, where
/// the Google sign-in is kept and the "Another MCP client" JSON went to Advanced.
struct ConnectionsSection: View {
    @ObservedObject var model: AppModel
    @StateObject private var integrations: IntegrationsModel
    @StateObject private var desktop: MCPClientModel
    @StateObject private var code: MCPClientModel
    @StateObject private var codex: MCPClientModel

    init(model: AppModel) {
        self.model = model
        _integrations = StateObject(wrappedValue: IntegrationsModel(app: model))
        _desktop = StateObject(wrappedValue: MCPClientModel(app: model, client: .claudeDesktop))
        _code = StateObject(wrappedValue: MCPClientModel(app: model, client: .claudeCode))
        _codex = StateObject(wrappedValue: MCPClientModel(app: model, client: .codex))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            SettingsGroup(String(localized: "AI providers", comment: "Settings group")) {
                ForEach(model.accountRows, id: \.provider) { row in
                    ProviderRow(model: model, row: row)
                }
            }
            .settingsAnchor(.providers, model: model, cornerRadius: ReaderTheme.Radius.field)

            SettingsGroup(
                String(localized: "Use Worklens from Claude or Codex", comment: "Settings group"),
                note: String(localized: "Ask about your day. They read your Worklens data on this Mac and never change it.", comment: "Settings note")
            ) {
                AssistantRow(client: desktop)
                AssistantRow(client: code)
                AssistantRow(client: codex)
            }
            .settingsAnchor(.assistants, model: model, cornerRadius: ReaderTheme.Radius.field)

            SourcesGroup(model: model, integrations: integrations)
                .settingsAnchor(.sources, model: model, cornerRadius: ReaderTheme.Radius.field)
        }
        .task { await integrations.refresh() }
        .onChange(of: model.configGeneration) { _, _ in
            Task { await integrations.refresh() }
        }
    }
}

// MARK: - A provider glyph

/// The small bordered square in front of a connection's name: the service's own mark when it
/// has one, a symbol otherwise.
struct ConnectionGlyph: View {
    private let systemName: String?
    private let brand: BrandMark?

    init(systemName: String) {
        self.systemName = systemName
        brand = nil
    }

    init(brand: BrandMark) {
        systemName = nil
        self.brand = brand
    }

    var body: some View {
        Group {
            if let brand {
                Image(nsImage: brand.image)
                    .resizable()
                    .renderingMode(brand.isTemplate ? .template : .original)
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(ReaderTheme.ink)
            } else if let systemName {
                Image(systemName: systemName)
                    .font(ReaderTheme.Size.control)
                    .foregroundStyle(ReaderTheme.muted)
            }
        }
        .frame(width: 30, height: 30)
        .background(RoundedRectangle(cornerRadius: ReaderTheme.Radius.field).fill(ReaderTheme.canvas))
        .overlay(RoundedRectangle(cornerRadius: ReaderTheme.Radius.field).strokeBorder(ReaderTheme.line))
        .accessibilityHidden(true)
    }
}

// MARK: - AI providers

/// Gemini: a pill, and Change — an inline secure field with Save, Cancel and Disconnect. The
/// key itself is never drawn, masked or not. The Claude row went with the reports (2026-10-05).
private struct ProviderRow: View {
    @ObservedObject var model: AppModel
    let row: AccountRow
    @State private var editing = false
    @State private var typed = ""
    @State private var caption: AccountCaption?
    @State private var verifying = false
    @FocusState private var focused: Bool

    private var name: String { "Gemini" }

    var body: some View {
        SettingsRow(
            name,
            detail: row.isSet
                ? String(localized: "Summarizes each screenshot in one sentence.", comment: "Setting detail")
                : String(localized: "Screenshots wait until Gemini is connected.", comment: "Setting detail"),
            note: note,
            leading: { ConnectionGlyph(brand: .gemini) }
        ) {
            if editing {
                SecureField("AIza…", text: $typed)
                    .textFieldStyle(SettingsFieldStyle(width: 180))
                    .focused($focused)
                    .onSubmit(save)
                    .onExitCommand(perform: cancel)
                    .accessibilityLabel(L10n.format("%@ key", name))
                Button(String(localized: "Save", comment: "Button"), action: save)
                    .buttonStyle(.settingsPrimary)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(String(localized: "Cancel", comment: "Button"), action: cancel)
                    .buttonStyle(.settings)
                if row.isStored {
                    Button(String(localized: "Disconnect", comment: "Button"), action: disconnect)
                        .buttonStyle(.settingsMutedLink)
                }
            } else if row.isSet {
                if verifying {
                    ProgressView().controlSize(.small)
                }
                SettingsPill(text: String(localized: "Connected", comment: "Pill"))
                if row.isEditable {
                    Button(String(localized: "Change", comment: "Button"), action: begin)
                        .buttonStyle(.settingsLink)
                }
            } else {
                SettingsPill(text: String(localized: "Not connected", comment: "Pill"), kind: .off)
                if row.isEditable {
                    Button(String(localized: "Connect…", comment: "Button"), action: begin)
                        .buttonStyle(.settingsPrimary)
                }
            }
        }
    }

    private var note: SettingsRowNote? {
        if let lock = model.settingLock(row.provider.envKey) { return SettingsRowNote(text: lock) }
        guard let caption else { return nil }
        return SettingsRowNote(text: caption.text, tone: caption.level == .ok || caption.level == .muted ? .muted : .attention)
    }

    private func begin() {
        typed = ""
        caption = nil
        editing = true
        focused = true
    }

    private func cancel() {
        typed = ""
        editing = false
        caption = nil
    }

    /// One paste, one step (#246): save, say what the shape looks like, and ask the provider.
    private func save() {
        let entry = Accounts.entry(typed, for: row.provider)
        guard let value = entry.key else {
            caption = entry.caption
            return
        }
        do {
            try model.setCredential(row.provider, value)
            // The typed value goes as soon as it has been written.
            typed = ""
            editing = false
            caption = entry.caption
            if entry.verifies {
                verifying = true
                Task {
                    let answer = await model.verifyCredential(row.provider)
                    verifying = false
                    guard let answer else { return }
                    caption = Accounts.verdict(answer)
                    if answer.verdict == .accepted {
                        caption = nil
                        model.settingsToast(L10n.format("%@ key saved and verified", name))
                    }
                }
            } else {
                model.settingsToast(SettingsCopy.saved(L10n.format("%@ key", name)))
            }
        } catch {
            caption = AccountCaption("\(error)", .problem)
        }
    }

    private func disconnect() {
        do {
            try model.clearCredential(row.provider)
            editing = false
            caption = nil
            model.settingsToast(String(localized: "Gemini disconnected", comment: "Toast"))
        } catch {
            caption = AccountCaption("\(error)", .problem)
        }
    }
}

// MARK: - Use Worklens from Claude or Codex

/// Claude Desktop, Claude Code or Codex: whether Worklens is in its MCP configuration, and Connect
/// or Disconnect. Each writes the client's own file after copying it aside, so each asks first.
private struct AssistantRow: View {
    @ObservedObject var client: MCPClientModel
    @State private var confirmingConnect = false
    @State private var confirmingDisconnect = false

    private var connected: Bool { client.canDisconnect }

    var body: some View {
        SettingsRow(
            client.client.title,
            detail: detail,
            note: rowNote,
            leading: { ConnectionGlyph(brand: client.client == .codex ? .openAI : .claude) }
        ) {
            if client.busy { ProgressView().controlSize(.small) }
            if !client.claudeInstalled {
                SettingsPill(text: String(localized: "Not installed", comment: "Pill"), kind: .off)
                if let download = client.client.downloadURL {
                    Link(L10n.format("Get %@", client.client.title), destination: download)
                        .font(ReaderTheme.Size.control)
                        .foregroundStyle(ReaderTheme.accentInk)
                }
            } else if connected {
                if case .pointsHere = client.health {
                    SettingsPill(text: String(localized: "Connected", comment: "Pill"))
                } else {
                    // An entry of ours that points at another copy, an older build or a path
                    // that moved: say so, and offer the one fix.
                    SettingsPill(text: String(localized: "Needs reconnecting", comment: "Pill"), kind: .need)
                    Button(client.actionTitle) { confirmingConnect = true }
                        .buttonStyle(.settingsPrimary)
                        .disabled(client.busy)
                }
                Button(String(localized: "Disconnect", comment: "Button")) { confirmingDisconnect = true }
                    .buttonStyle(.settingsMutedLink)
                    .disabled(client.busy)
            } else {
                SettingsPill(text: String(localized: "Not connected", comment: "Pill"), kind: .off)
                Button(String(localized: "Connect", comment: "Button")) { confirmingConnect = true }
                    .buttonStyle(.settingsPrimary)
                    .disabled(client.busy)
            }
        }
        .task { client.refresh() }
        .confirmationDialog(
            L10n.format("Connect Worklens to %@?", client.client.title),
            isPresented: $confirmingConnect
        ) {
            Button(String(localized: "Connect", comment: "Button")) { Task { await client.install() } }
            Button(String(localized: "Cancel", comment: "Button"), role: .cancel) {}
        } message: {
            Text(String(localized: "Worklens copies that app's settings file aside, then adds only its own entry. Nothing else in it changes.", comment: "Alert body"))
        }
        .confirmationDialog(
            L10n.format("Disconnect Worklens from %@?", client.client.title),
            isPresented: $confirmingDisconnect
        ) {
            Button(String(localized: "Disconnect", comment: "Button")) { Task { await client.disconnect() } }
            Button(String(localized: "Cancel", comment: "Button"), role: .cancel) {}
        } message: {
            Text(String(localized: "Worklens copies that app's settings file aside, then takes out only its own entry.", comment: "Alert body"))
        }
    }

    private var detail: String {
        switch (client.client, connected) {
        case (.claudeDesktop, true):
            return String(localized: "Available in every new chat.", comment: "Setting detail")
        case (.claudeCode, true), (.codex, true):
            return String(localized: "Available in every new session.", comment: "Setting detail")
        case (.claudeDesktop, false):
            return String(localized: "Adds Worklens to Claude Desktop's settings.", comment: "Setting detail")
        case (.claudeCode, false):
            return String(localized: "Adds Worklens to your Claude Code settings.", comment: "Setting detail")
        case (.codex, false):
            return String(localized: "Adds Worklens to your Codex settings.", comment: "Setting detail")
        }
    }

    /// What the client model has to say, most important first: a failure, then what to do next.
    private var rowNote: SettingsRowNote? {
        if let problem = client.problem { return SettingsRowNote(text: problem, tone: .attention) }
        if let note = client.note { return SettingsRowNote(text: note) }
        // Not "reopen it afterwards": while it is open it writes its own settings back over the
        // entry, so the order is quit, connect, open (MCPClientModel.install).
        if client.claudeRunning, client.health != .pointsHere, client.client == .claudeDesktop {
            return SettingsRowNote(text: String(localized: "Quit Claude Desktop before connecting, then open it again.", comment: "Setting note"))
        }
        return nil
    }
}

// MARK: - Sources

/// Granola and Google Calendar, then the Google account Calendar signs in with.
private struct SourcesGroup: View {
    @ObservedObject var model: AppModel
    @ObservedObject var integrations: IntegrationsModel
    @State private var setupSource: ContextSource?
    @State private var deletePlan: IntegrationRemoval.Plan?
    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingsGroup(
            String(localized: "Sources", comment: "Settings group"),
            note: String(localized: "Meetings and notes that make your timeline more specific.", comment: "Settings note")
        ) {
            ForEach(integrations.cards) { card in
                sourceRow(card)
            }
            googleRow
        }
        .sheet(item: $setupSource) { source in
            IntegrationSetupSheet(model: model, integrations: integrations, source: source)
        }
        .confirmationDialog(
            String(localized: "Delete everything Worklens synced from this source?", comment: "Alert"),
            isPresented: Binding(get: { deletePlan != nil }, set: { if !$0 { deletePlan = nil } }),
            presenting: deletePlan
        ) { plan in
            Button(L10n.format("Delete %@", plan.summary), role: .destructive) {
                Task { await integrations.deleteSyncedData(plan) }
                deletePlan = nil
            }
            Button(String(localized: "Cancel", comment: "Button"), role: .cancel) { deletePlan = nil }
        } message: { plan in
            Text(L10n.format("This removes %@ from this Mac and redraws those days. It does not disconnect the source.", plan.summary))
        }
    }

    private func glyph(_ source: ContextSource) -> String {
        source == .calendar ? "calendar" : "note.text"
    }

    private func sourceRow(_ card: IntegrationCard) -> some View {
        SettingsRow(
            card.displayName,
            detail: card.detail,
            note: card.warnings.first.map { SettingsRowNote(text: $0, tone: .attention) },
            leading: { ConnectionGlyph(systemName: glyph(card.source)) }
        ) {
            switch card.state {
            case .notSetUp:
                SettingsPill(text: String(localized: "Not connected", comment: "Pill"), kind: .off)
                Button(String(localized: "Connect…", comment: "Button")) { setupSource = card.source }
                    .buttonStyle(.settingsPrimary)
            case .connected:
                SettingsPill(text: String(localized: "Connected", comment: "Pill"))
                syncButton(card)
                more(card)
            default:
                SettingsPill(text: card.statusText, kind: .need)
                syncButton(card)
                more(card)
            }
        }
    }

    private func syncButton(_ card: IntegrationCard) -> some View {
        Button(integrations.isSyncing
            ? String(localized: "Syncing…", comment: "Button")
            : String(localized: "Sync now", comment: "Button")
        ) {
            Task { await integrations.syncNow(card.source) }
        }
        .buttonStyle(.settingsLink)
        .disabled(integrations.isSyncing)
    }

    private func more(_ card: IntegrationCard) -> some View {
        Menu {
            Button(card.setUpTitle) { setupSource = card.source }
            Button(String(localized: "Disconnect", comment: "Button")) {
                Task { await integrations.disconnect(card.source) }
            }
            Button(String(localized: "Delete synced data…", comment: "Button")) {
                Task { await offerDelete(card) }
            }
            Button(IntegrationRemoval.revokeTitle(for: card.source)) {
                openURL(IntegrationRemoval.revokeURL(for: card.source))
            }
        } label: {
            Image(systemName: "ellipsis").foregroundStyle(ReaderTheme.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.format("More for %@", card.displayName))
    }

    private func offerDelete(_ card: IntegrationCard) async {
        guard let plan = await integrations.plan(card.source) else {
            model.note(error: "Could not read what \(card.displayName) has synced.")
            return
        }
        guard !plan.isEmpty else {
            model.settingsToast(L10n.format("Nothing synced from %@ to delete", card.displayName))
            return
        }
        deletePlan = plan
    }

    // MARK: The Google account

    @ViewBuilder
    private var googleRow: some View {
        switch integrations.google {
        case .notConfigured:
            EmptyView()
        case .disconnected:
            SettingsRow(
                String(localized: "Google account", comment: "Setting"),
                detail: String(localized: "Calendar reads your events with it. It opens your browser.", comment: "Setting detail"),
                leading: { ConnectionGlyph(systemName: "person.crop.circle") }
            ) {
                SettingsPill(text: String(localized: "Not connected", comment: "Pill"), kind: .off)
                Button(String(localized: "Connect Google…", comment: "Button")) { Task { await integrations.connectGoogle() } }
                    .buttonStyle(.settingsPrimary)
            }
        case .connecting:
            SettingsRow(
                String(localized: "Google account", comment: "Setting"),
                detail: String(localized: "Approve Worklens in your browser. Google shows an unverified-app screen first: Advanced, then continue.", comment: "Setting detail"),
                leading: { ConnectionGlyph(systemName: "person.crop.circle") }
            ) {
                ProgressView().controlSize(.small)
                Button(String(localized: "Open it again", comment: "Button")) { Task { await integrations.reopenGoogleConsent() } }
                    .buttonStyle(.settingsLink)
                Button(String(localized: "Cancel", comment: "Button")) { Task { await integrations.cancelGoogleConnect() } }
                    .buttonStyle(.settings)
            }
        case let .connected(email):
            SettingsRow(
                String(localized: "Google account", comment: "Setting"),
                detail: integrations.googleNeedsReconnect
                    ? String(localized: "Your Google sign-in expired, so Calendar is paused.", comment: "Setting detail")
                    : (email ?? GoogleGrantStatus.addressUnknownNote),
                leading: { ConnectionGlyph(systemName: "person.crop.circle") }
            ) {
                if integrations.googleNeedsReconnect || email == nil {
                    Button(String(localized: "Reconnect", comment: "Button")) { Task { await integrations.connectGoogle() } }
                        .buttonStyle(.settingsPrimary)
                } else {
                    SettingsPill(text: String(localized: "Connected", comment: "Pill"))
                }
                Button(String(localized: "Disconnect", comment: "Button")) { Task { await integrations.disconnectGoogle() } }
                    .buttonStyle(.settingsMutedLink)
            }
        case let .failed(message):
            SettingsRow(
                String(localized: "Google account", comment: "Setting"),
                detail: message,
                leading: { ConnectionGlyph(systemName: "person.crop.circle") }
            ) {
                Button(String(localized: "Try again", comment: "Button")) { Task { await integrations.connectGoogle() } }
                    .buttonStyle(.settings)
            }
        }
    }
}
