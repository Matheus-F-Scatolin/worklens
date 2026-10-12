import AppKit
import SwiftUI
import WorklensCore

// #286: the models behind Settings → Connections, and the one sheet it opens, moved out of the old
// Integrations and Claude panes when those views were replaced. Nothing in them changed.

// MARK: - The setup sheet

/// One source's walkthrough: what it needs, numbered steps with the pages they send you to, the
/// credential fields, a Test and a Save.
struct IntegrationSetupSheet: View {
    @ObservedObject var model: AppModel
    /// #139: the Google half of the sheet — Connect, Cancel, the store choice — is the same
    /// controls the pane shows, so it reads the same model rather than a copy of its state.
    @ObservedObject var integrations: IntegrationsModel
    let source: ContextSource

    @Environment(\.dismiss) private var dismiss
    /// What has been typed, per key. Cleared the moment it is written, so nothing holds a
    /// credential in memory for longer than the save takes.
    @State private var typed: [String: String] = [:]
    @State private var caption: String?
    @State private var captionLevel: StatusLevel = .neutral
    @State private var testing = false
    @State private var outcome: IntegrationTester.Outcome?
    @ScaledMetric(relativeTo: .body) private var fieldWidth = Theme.Layout.field

    private var fields: [IntegrationField] { IntegrationSetup.fields(for: source) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    if let requirement = IntegrationSetup.requirement(for: source) {
                        SettingsNote(text: requirement, level: .attention)
                    }
                    steps
                    credentials
                    if isGoogle { google }
                    if let caption {
                        SettingsNote(text: caption, level: captionLevel)
                    }
                    if let outcome {
                        SettingsNote(text: outcome.line, level: outcome.level)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(Theme.Space.pane)
        .frame(width: 520, height: isGoogle ? 680 : 560)
    }

    // MARK: Pieces

    private var isGoogle: Bool { source == .calendar }

    /// Connect in the same sheet as the steps that create the client id — the pane's Google
    /// section used to be the only place it could be done, three scrolls away from step 5 (#139).
    private var google: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            Divider()
            Text(String(localized: "Connect your Google account", comment: "Label"))
                .font(Theme.Text.sectionHeader).foregroundStyle(.secondary)
            SettingsNote(text: IntegrationSetup.googleTestingNote, level: .attention)
            GoogleConnectControls(model: model, integrations: integrations)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Set up \(displayName)")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(IntegrationSetup.value(for: source))
                .font(Theme.Text.rowBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            ForEach(IntegrationSetup.steps(for: source)) { step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(step.number).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.text).fixedSize(horizontal: false, vertical: true)
                        if let link = step.link, let label = step.linkLabel {
                            Link(label, destination: link).font(Theme.Text.rowBody)
                        }
                    }
                }
                .font(Theme.Text.rowBody)
            }
        }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent(field.label) {
                        // `SecureField`, never a `TextField` with a reveal toggle: paste works,
                        // the value is never drawn, and this app takes screenshots for a living.
                        SecureField(field.prompt, text: binding(for: field))
                            .labelsHidden()
                            .frame(width: fieldWidth)
                            .disabled(!isEditable(field))
                    }
                    if let note = layer(of: field).lockedNote {
                        Text(note)
                            .font(Theme.Text.rowBody)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let problem = liveProblem(field) {
                        SettingsNote(text: problem, level: .problem)
                    } else if let warning = liveWarning(field) {
                        SettingsNote(text: warning, level: .attention)
                    } else if isSet(field) {
                        Text(String(localized: "Already set. Paste a new one to replace it.", comment: "Label"))
                            .font(Theme.Text.rowBody)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if IntegrationSetup.isTestable(source) {
                Button(testing ? "Testing\u{2026}" : "Test", action: test)
                    .disabled(testing || !hasSomethingToTest)
            }
            Spacer(minLength: 0)
            Button(String(localized: "Close", comment: "Button")) { dismiss() }
            Button(String(localized: "Save", comment: "Button"), action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
    }

    // MARK: Values

    private var displayName: String {
        ContextSources.all(config: model.config).first { $0.id == source }?.displayName
            ?? source.rawValue.capitalized
    }

    private func binding(for field: IntegrationField) -> Binding<String> {
        Binding(
            get: { typed[field.key] ?? "" },
            set: { value in
                typed[field.key] = value
                outcome = nil
                caption = nil
            }
        )
    }

    private func layer(of field: IntegrationField) -> ConfigLayer {
        model.configProvenance.source(of: field.key)
    }

    private func isEditable(_ field: IntegrationField) -> Bool { layer(of: field).isWritableInApp }

    private func isSet(_ field: IntegrationField) -> Bool {
        !(IntegrationSetup.storedValue(field, in: model.config) ?? "").isEmpty
    }

    /// The shape check as you type: a refusal while the field holds something that cannot be this
    /// credential at all — a bot token, a rotating token, a paste that picked up a line of prose.
    private func liveProblem(_ field: IntegrationField) -> String? {
        let value = typed[field.key] ?? ""
        guard !IntegrationSetup.normalize(value).isEmpty else { return nil }
        return IntegrationSetup.entryError(field, value)
    }

    /// The soft half, live. `shapeNote` rather than `shapeWarning`: nothing has been saved yet,
    /// and the caption under an unsaved field must not say it has (#135).
    private func liveWarning(_ field: IntegrationField) -> String? {
        let value = typed[field.key] ?? ""
        guard !IntegrationSetup.normalize(value).isEmpty else { return nil }
        return IntegrationSetup.shapeNote(field, value)
    }

    /// Every field that has something typed in it, with nothing that cannot be saved.
    private var pending: [(field: IntegrationField, value: String)] {
        fields.compactMap { field in
            let value = IntegrationSetup.normalize(typed[field.key] ?? "")
            guard !value.isEmpty, isEditable(field) else { return nil }
            return (field, value)
        }
    }

    private var canSave: Bool {
        !pending.isEmpty && pending.allSatisfy { IntegrationSetup.entryError($0.field, $0.value) == nil }
    }

    /// Test what is typed, or — when nothing is — what is already stored, so a token that stopped
    /// working can be checked without retyping it.
    private var credentialToTest: String? {
        guard let field = fields.first else { return nil }
        let value = IntegrationSetup.normalize(typed[field.key] ?? "")
        if !value.isEmpty { return value }
        let stored = IntegrationSetup.storedValue(field, in: model.config) ?? ""
        return stored.isEmpty ? nil : stored
    }

    private var hasSomethingToTest: Bool { credentialToTest != nil }

    // MARK: Acting

    private func save() {
        var warnings: [String] = []
        for (field, value) in pending {
            do {
                try model.applySetting(field.key, value)
                if let warning = IntegrationSetup.shapeWarning(field, value) {
                    warnings.append(warning)
                }
            } catch {
                caption = "\(error)"
                captionLevel = .problem
                return
            }
        }
        // Gone as soon as it is written: nothing holds a credential for longer than the save.
        typed = [:]
        outcome = nil
        if warnings.isEmpty {
            caption = IntegrationSetup.isTestable(source)
                ? "Saved. Press Test to have \(displayName) confirm it."
                : "Saved."
            captionLevel = .ok
        } else {
            caption = warnings.joined(separator: " ")
            captionLevel = .attention
        }
    }

    private func test() {
        guard let credential = credentialToTest else { return }
        testing = true
        caption = nil
        Task {
            outcome = await model.testIntegration(source, credential: credential)
            testing = false
        }
    }
}


// MARK: - The Google connect flow (#139)

/// Connect, cancel, reconnect and disconnect, plus the one choice that decides whether macOS will
/// ask for your login password after every rebuild.
///
/// Drawn in two places — the Google account section of the pane, and the Calendar setup
/// sheet, where the steps that create the client id sit right above it. Both read the same
/// `IntegrationsModel`, so a flow started in the sheet is still cancellable from the pane after
/// the sheet is closed.
struct GoogleConnectControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var integrations: IntegrationsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            switch integrations.google {
            case .notConfigured:
                SettingsNote(text: "Save the OAuth client id and secret first.")
            case .disconnected:
                storePicker
                HStack {
                    Button(String(localized: "Connect Google\u{2026}", comment: "Button")) { Task { await integrations.connectGoogle() } }
                    Text(String(localized: "Opens your browser. Scope: calendar.readonly.", comment: "Label"))
                        .font(Theme.Text.rowBody)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .connecting:
                connecting
            case let .connected(email):
                connected(email)
            case let .failed(message):
                SettingsNote(text: message, level: .problem)
                Button(String(localized: "Try again", comment: "Button")) { Task { await integrations.connectGoogle() } }
            }
        }
    }

    // MARK: States

    /// The listener is alive for five minutes, so this is where the two things a stuck user needs
    /// live: a way out, and a way back to the page they lost.
    private var connecting: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Waiting for you to approve Worklens in the browser. There are five minutes to do it in: Google shows an \u{201c}unverified app\u{201d} screen first; Advanced, then continue, is the way through it.", comment: "Label"))
                    .font(Theme.Text.rowBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(String(localized: "Cancel", comment: "Button")) { Task { await integrations.cancelGoogleConnect() } }
                Button(String(localized: "Open the consent page again", comment: "Button")) {
                    Task { await integrations.reopenGoogleConsent() }
                }
            }
        }
    }

    private func connected(_ email: String?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            HStack {
                StatusBadge(level: badgeLevel, text: email ?? "Connected", subject: "Google")
                if integrations.googleNeedsReconnect || email == nil {
                    Button(String(localized: "Reconnect", comment: "Button")) { Task { await integrations.connectGoogle() } }
                }
                Button(String(localized: "Disconnect", comment: "Button")) { Task { await integrations.disconnectGoogle() } }
            }
            if integrations.googleNeedsReconnect {
                SettingsNote(text: expiredNote, level: .attention)
            } else if email == nil {
                // `connect` records the address in app_state; a grant from before it did has
                // none, and reading it off the item would prompt on a rebuilt binary (#36).
                Text(GoogleGrantStatus.addressUnknownNote)
                    .font(Theme.Text.rowBody)
                    .foregroundStyle(.secondary)
            }
            Text(integrations.storeLine)
                .font(Theme.Text.rowBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            storePicker
        }
    }

    private var badgeLevel: StatusLevel { integrations.googleNeedsReconnect ? .attention : .ok }

    private var expiredNote: String {
        String(
            localized: "Your Google sign-in expired, so Calendar is paused.",
            comment: "Label") + " " + IntegrationSetup.googleTestingNote
    }

    // MARK: Where the grant is kept

    /// The choice `docs/decisions.md` asked for: made here, at connect time, pre-selected to the
    /// store an existing grant is in — and otherwise to the one that works on a binary with no
    /// Team ID — and never changed behind your back.
    @ViewBuilder
    private var storePicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker(String(localized: "Keep the sign-in in", comment: "Picker"), selection: storeBinding) {
                ForEach(GoogleTokenStorage.allCases, id: \.self) { store in
                    Text(store.label).tag(store)
                }
            }
            .pickerStyle(.radioGroup)
            .disabled(!storeLayer.isWritableInApp || integrations.isSwitchingStore)
            Text(integrations.tokenStore.detail)
                .font(Theme.Text.rowBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = storeLayer.lockedNote {
                SettingsNote(text: note)
            }
            if let problem = integrations.storeError {
                SettingsNote(text: problem, level: .problem)
            }
        }
    }

    private var storeLayer: ConfigLayer {
        model.configProvenance.source(of: "GOOGLE_TOKEN_STORE")
    }

    /// Switching while a grant exists is a disconnect and a reconnect, in that order and in one
    /// click: only a disconnect revokes the old grant at Google, and it has to happen while the
    /// old store is still the configured one.
    private var storeBinding: Binding<GoogleTokenStorage> {
        Binding(
            get: { integrations.tokenStore },
            set: { store in Task { await integrations.chooseTokenStore(store) } }
        )
    }
}


// MARK: - The model

/// The state behind Settings → Integrations.
///
/// It holds the `AppModel` rather than a `Config` and a scheduler taken in `init` (#135). That
/// snapshot was the bug: `@StateObject` survives the body re-evaluation a reload causes, so the
/// pane went on reading a configuration that had been replaced and calling a scheduler that had
/// been stopped. Everything here re-reads `app.config` and `app.contextSync` at call time, and
/// `AppModel.configGeneration` is what tells the view to call `refresh()` again.
@MainActor
final class IntegrationsModel: ObservableObject {
    /// Where the Google grant stands, for the Connect / Disconnect control.
    enum GoogleState: Equatable, Sendable {
        case notConfigured
        case disconnected
        case connecting
        /// The grant is stored (Keychain or file, per `GOOGLE_TOKEN_STORE`). The address comes
        /// from `app_state`, where `connect` records it; it is nil only for a grant from a connect
        /// that predates #36, since reading it back off the item would mean a decrypt, and a
        /// prompt.
        case connected(String?)
        case failed(String)
    }

    @Published private(set) var cards: [IntegrationCard] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var google: GoogleState = .notConfigured
    /// #139: the scheduler saw `invalid_grant`, so Calendar is paused. A typed flag
    /// read off `SourceStatus`, never a match on the sentence beside it.
    @Published private(set) var googleNeedsReconnect = false
    /// Which store the radio group is showing: what the configuration says once someone has
    /// chosen, and the one that works on this binary until they have.
    @Published var tokenStore: GoogleTokenStorage = .keychain
    @Published private(set) var isSwitchingStore = false
    @Published private(set) var storeError: String?

    /// The `GoogleAuth` of the flow that is running, so Cancel and "Open the consent page again"
    /// reach the receiver that is actually listening — a fresh `GoogleAuth(config:)` holds none.
    private var connectingAuth: GoogleAuth?

    /// Weak: the window outlives nothing, but the pane must never be the reason the app model
    /// stays alive.
    private weak var app: AppModel?

    init(app: AppModel?) {
        self.app = app
        tokenStore = IntegrationsModel.preselectedStore(app: app)
    }

    /// The configured store once someone has actually set the key, and otherwise the one that
    /// works on the binary that is running: with no Apple Developer Team ID in the signature the
    /// login keychain re-asks for the login password after every rebuild, and nothing in the app
    /// can pre-authorise it. `docs/decisions.md` asked for this to be chosen rather than
    /// inherited, so it is a pre-selection on a control, not a silent resolution of the default.
    static func preselectedStore(app: AppModel?) -> GoogleTokenStorage {
        guard let app else { return .keychain }
        // Where a grant already is outranks both: switching the key never moved one, so a grant
        // from before this control existed can sit in a store neither the key nor the signature
        // would point at — and the line above the radio group names the store it is in.
        if let holding = GoogleAuth.storeHoldingGrant(config: app.config) { return holding }
        let layer = app.configProvenance.source(of: "GOOGLE_TOKEN_STORE")
        if layer != .fallback { return app.config.googleTokenStore }
        return GoogleTokenStorage.recommended(teamID: SigningIdentity.runningTeamIdentifier)
    }

    /// The one line that names where the grant actually is — the same store the radio group
    /// under it is showing, never the configured one when a grant is somewhere else.
    var storeLine: String {
        "Kept in the \(tokenStore.label.lowercased()). \(tokenStore.detail)"
    }

    var config: Config { app?.config ?? Config.defaults() }

    /// The configuration with one key pinned: `GoogleAuth` snapshots the store at init, and the
    /// settings write that precedes a connect has not been reloaded yet when it does.
    func config(storing store: GoogleTokenStorage) -> Config {
        var pinned = config
        pinned.googleTokenStore = store
        return pinned
    }

    var syncMinutes: Int { config.contextSyncMinutes }

    func refresh() async {
        await refreshGoogle()
        var statuses: [SourceStatus] = []
        if let scheduler = app?.contextSync {
            statuses = await scheduler.statusList
        }
        googleNeedsReconnect = statuses.contains { $0.needsReconnect }
        if !isSwitchingStore { tokenStore = IntegrationsModel.preselectedStore(app: app) }
        cards = IntegrationCards.build(config: config, statuses: statuses)
    }

    // MARK: Google (#22)

    /// Reads the grant's state without touching the network or the Keychain's secret: opening
    /// Settings must never raise a Keychain prompt, `hasStoredGrant` is the one question the item
    /// answers without being decrypted, and the address comes from `app_state` (#36). A flow in
    /// progress, or an address learned from a connect in this process, is left alone.
    func refreshGoogle() async {
        if case .connecting = google { return }
        let auth = GoogleAuth(config: config)
        guard auth.isConfigured else {
            google = .notConfigured
            return
        }
        guard auth.hasStoredGrant else {
            google = .disconnected
            return
        }
        if case .connected = google { return }
        google = .connected(auth.accountOnRecord)
    }

    /// Runs the browser flow, then syncs so the Calendar card fills in straight away.
    ///
    /// Writes the chosen store first, when it is not the one the configuration already holds:
    /// the grant has to land where the radio group says it will, and `applySetting` reloads the
    /// configuration this method then builds its `GoogleAuth` from.
    func connectGoogle() async {
        if !writeStoreIfNeeded(tokenStore) { return }
        // `applySetting` reloads the configuration on an enqueued task, so `config` can still be
        // the old one here — and `GoogleAuth` snapshots its store at init. Pin the chosen store
        // on the copy this flow uses, so the grant lands where the radio group said it would.
        let auth = GoogleAuth(config: config(storing: tokenStore))
        guard auth.isConfigured else {
            google = .notConfigured
            return
        }
        google = .connecting
        connectingAuth = auth
        defer { connectingAuth = nil }
        do {
            let email = try await auth.connect()
            google = .connected(email)
            googleNeedsReconnect = false
            // #139: the browser has been in front for five minutes. Come back, on the pane that
            // asked for this, rather than leaving the answer behind a menu-bar icon.
            app?.openSettings(SettingsTarget(.sources))
            await syncNow(nil)
        } catch {
            google = .failed(ContextSyncScheduler.describe(error))
        }
    }

    /// Cancel, while the listener is still alive. The suspended `connect` throws
    /// `LoopbackReceiver.Failure.cancelled` and lands on `.failed`, which carries Try again.
    func cancelGoogleConnect() async {
        await connectingAuth?.cancelConnect()
    }

    /// The consent tab was closed, or went to a window the user has since lost. Same listener,
    /// same state: the callback that comes back is still the one `connect` is waiting for.
    func reopenGoogleConsent() async {
        await connectingAuth?.reopenConsentPage()
    }

    /// Picking the other store. With a grant on this Mac that is a disconnect and a reconnect, in
    /// that order and in one click — only a disconnect revokes the old grant at Google, and it
    /// has to run while the old store is still the configured one.
    func chooseTokenStore(_ store: GoogleTokenStorage) async {
        guard store != tokenStore else { return }
        storeError = nil
        // The old store is the one the radio group was showing, which is where the grant is —
        // not necessarily the configured one.
        let old = config(storing: tokenStore)
        let hadGrant = GoogleAuth(config: old).hasStoredGrant
        tokenStore = store
        guard hadGrant else {
            _ = writeStoreIfNeeded(store)
            return
        }
        isSwitchingStore = true
        do {
            try await GoogleAuth(config: old).disconnect()
        } catch {
            // The local half happens either way; a revoke that could not reach Google is not a
            // reason to leave the grant in the store the user just moved away from.
            Log.ui.warn("could not revoke the old Google grant while switching stores")
        }
        google = .disconnected
        isSwitchingStore = false
        guard writeStoreIfNeeded(store) else { return }
        await connectGoogle()
    }

    /// Writes `GOOGLE_TOKEN_STORE` when the configuration does not already say this. False when
    /// the write failed, and the caller stops: connecting into a store the user did not pick is
    /// exactly the silent resolution this control exists to avoid.
    private func writeStoreIfNeeded(_ store: GoogleTokenStorage) -> Bool {
        guard config.googleTokenStore != store else { return true }
        do {
            try app?.applySetting("GOOGLE_TOKEN_STORE", store.rawValue)
            storeError = nil
            return true
        } catch {
            storeError = "\(error)"
            return false
        }
    }

    func disconnectGoogle() async {
        do {
            // The store the radio group is showing is the one the grant is in.
            try await GoogleAuth(config: config(storing: tokenStore)).disconnect()
            google = .disconnected
        } catch {
            google = .failed(ContextSyncScheduler.describe(error))
        }
        await refresh()
    }

    // MARK: Taking a source back out (#141)

    /// What "Delete synced data…" would remove, counted before it is offered.
    ///
    /// Off the main actor: the count is three SQLite scans over every row a source owns, and a
    /// frozen Settings window is not what "counted first" should cost.
    func plan(_ source: ContextSource) async -> IntegrationRemoval.Plan? {
        guard let db = app?.db else { return nil }
        let config = config
        return await Task.detached {
            try? IntegrationRemoval.plan(source: source, db: db, config: config)
        }.value
    }

    /// Removes the rows, the transcript files and the timeline blocks, then redraws every day
    /// they were on — `rebuildRecentDays()` covers today and yesterday, and this can reach back
    /// years.
    ///
    /// The removal itself runs off the main actor: a source with thousands of transcript files
    /// is a long loop of `FileManager.removeItem`, and Settings has to stay usable through it.
    func deleteSyncedData(_ plan: IntegrationRemoval.Plan) async {
        guard let app, let db = app.db, !plan.isEmpty else { return }
        let config = config
        let source = plan.source
        do {
            let done = try await Task.detached {
                try IntegrationRemoval.deleteSyncedData(source: source, db: db, config: config)
            }.value
            if let writer = app.timeline {
                for day in done.days { _ = try? await writer.rebuild(day: day) }
            }
            app.note(done: "Deleted \(done.summary).")
        } catch {
            app.note(error: "Could not delete: \(ContextSyncScheduler.describe(error))")
        }
        await refresh()
    }

    /// Stops the syncing: the credential Worklens itself wrote and the stored status. Never the
    /// events: disconnecting a source is not a request to rewrite your own timeline, and "Delete
    /// synced data…" is the separate item that is.
    ///
    /// Google reuses `disconnectGoogle()` unchanged: its connection is an OAuth grant, and
    /// `GoogleAuth.disconnect()` already revokes it and removes the stored token.
    func disconnect(_ source: ContextSource) async {
        guard let app, let db = app.db else { return }
        if source == .calendar {
            await disconnectGoogle()
            try? IntegrationRemoval.clearState(source: source, db: db)
            await app.contextSync?.forget(source)
            await refresh()
            return
        }

        try? IntegrationRemoval.clearState(source: source, db: db)
        await app.contextSync?.forget(source)
        // `clearSetting` reloads the configuration, which rebuilds the scheduler — so the
        // credentials go last, after everything that needed the old one.
        let keys = IntegrationRemoval.credentialKeys(for: source)
        for key in keys { try? app.clearSetting(key) }

        await refresh()
        // A key can also live in a `.env` or in the environment, and neither is Worklens's to
        // rewrite. Say so, and open the file — the alternative is a card that says "Not set up"
        // and reconnects itself on the next launch.
        if cards.first(where: { $0.source == source })?.isConfigured == true {
            app.note(
                notice: "\(keys.joined(separator: ", ")) is set in a .env or in the environment: "
                    + "remove it there too, or this source reconnects on the next launch.",
                action: .openEnvFile
            )
        }
    }

    func syncNow(_ source: ContextSource?) async {
        guard let scheduler = app?.contextSync, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        _ = await scheduler.syncNow(source: source)
        await refresh()
    }
}

// MARK: - The MCP client model

/// One client's state and the four things a person can do to it. `client` is the only difference
/// between the rows: the file it reads and writes, what the row is called, and how the Mac
/// says whether that client is here at all.
@MainActor
final class MCPClientModel: ObservableObject {
    /// The download page, opened in the user's own browser. Worklens sends it nothing; it is the
    /// same row `PRIVACY.md` gives the other setup links. Claude Desktop's, for the setup flow,
    /// which asks for it by name.
    static let downloadURL = MCPClientConfig.Client.claudeDesktop.downloadURL!

    @Published private(set) var health: MCPClientConfig.Health = .notInstalled
    /// Whether this client is on the Mac. Named for the first one there was; true for either.
    @Published private(set) var claudeInstalled = false
    @Published private(set) var claudeRunning = false
    @Published private(set) var configFileExists = false
    @Published private(set) var note: String?
    @Published private(set) var problem: String?
    @Published private(set) var busy = false
    @Published private(set) var copied = false

    let client: MCPClientConfig.Client
    let configURL: URL
    let plan: MCPClientConfig.Plan
    /// The app, not the directory it had when this row was built: a `@StateObject` outlives a
    /// configuration reload, and a snapshot taken in `init` would have the smoke test comparing
    /// the client's `DATA_DIR` against one this app stopped using (#140).
    private let app: AppModel
    private var appDataDir: URL { app.config.dataDir }
    /// What the app itself was launched with, if anything. `scripts/update.sh` sets it; the
    /// client sets nothing, which is exactly why it has to be written into the entry.
    private let envFile: URL?
    /// Puts the Copy button's label back, so a second copy can say "Copied" too.
    private var copiedReset: Task<Void, Never>?

    init(app: AppModel, client: MCPClientConfig.Client = .claudeDesktop) {
        self.app = app
        self.client = client
        configURL = client.configURL()
        envFile = ProcessInfo.processInfo.environment["WORKLENS_ENV_FILE"].map {
            URL(fileURLWithPath: $0)
        }
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "Worklens")
        plan = MCPClientConfig.plan(executable: executable, envFile: envFile)
    }

    // MARK: What is there now

    func refresh() {
        health = MCPClientConfig.health(entry: MCPClientConfig.read(at: configURL), expecting: plan)
        configFileExists = FileManager.default.fileExists(atPath: configURL.path)
        if let bundleID = client.bundleID {
            claudeInstalled = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleID
            ) != nil
            claudeRunning = !NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).isEmpty
        } else {
            // A command, not an application: its own files are what say it is here, and there is
            // no "it is open" to warn about.
            claudeInstalled = client.presencePaths().contains {
                FileManager.default.fileExists(atPath: $0.path)
            }
            claudeRunning = false
        }
        if case .pointsHere = health { app.noteMCPConnected(client) }
    }

    /// One clause, about forty characters: what the file says, without the path in it.
    var statusText: String {
        switch health {
        case .notInstalled:
            return String(localized: "Not connected", comment: "Status")
        case .pointsHere:
            return String(localized: "Connected to this app", comment: "Status")
        case .pointsElsewhere:
            return String(localized: "Connected to another build", comment: "Status")
        case .outOfDate:
            return String(localized: "Connected, with other settings", comment: "Status")
        case .stalePath:
            return String(localized: "Points at a build that is gone", comment: "Status")
        case .unparseable:
            return String(localized: "Its configuration file cannot be read", comment: "Status")
        }
    }

    /// The path the entry launches, for the three states where it is the useful fact. Kept out of
    /// the status row, which is read at a glance, and out of every log.
    var commandNote: String? {
        switch health {
        case .pointsElsewhere(let command), .outOfDate(let command), .stalePath(let command):
            return String(
                format: String(localized: "It launches %@.", comment: "Label"), command)
        case .notInstalled, .pointsHere:
            return nil
        case .unparseable(let why):
            return why
        }
    }

    var level: StatusLevel {
        switch health {
        case .pointsHere: return .ok
        case .notInstalled, .pointsElsewhere, .outOfDate: return .attention
        case .stalePath, .unparseable: return .problem
        }
    }

    var actionTitle: String {
        switch health {
        case .notInstalled, .unparseable: return String(localized: "Connect", comment: "Button")
        case .pointsHere: return String(localized: "Check it works", comment: "Button")
        case .pointsElsewhere, .outOfDate, .stalePath:
            return String(localized: "Reconnect", comment: "Button")
        }
    }

    /// There is an entry of ours in that file to take out.
    var canDisconnect: Bool {
        switch health {
        case .pointsHere, .pointsElsewhere, .outOfDate, .stalePath: return true
        case .notInstalled, .unparseable: return false
        }
    }

    /// Said when the client is not on this Mac: the entry is still worth copying elsewhere.
    var missingClientNote: String {
        switch client {
        case .claudeDesktop:
            return String(
                localized: "Claude Desktop is not on this Mac. The entry to paste elsewhere is under Another MCP client, below.",
                comment: "Label")
        case .claudeCode:
            return String(
                localized: "Claude Code is not set up on this Mac yet. The entry to paste elsewhere is under Another MCP client, below.",
                comment: "Label")
        case .codex:
            return String(
                localized: "Codex is not set up on this Mac yet. The entry to paste elsewhere is under Another MCP client, below.",
                comment: "Label")
        }
    }

    // MARK: Acting

    func copyJSON() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plan.json, forType: .string)
        copied = true
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    func showFile() {
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    func install() async {
        refresh()
        // Claude Desktop keeps its settings in memory and writes the file back out while it is
        // open, so an entry written now is undone within minutes and the link "breaks" again
        // (2026-10-09: three Reconnects in a row, each reverted). Written while it is closed, the
        // entry is what it reads at its next launch.
        if client == .claudeDesktop, claudeRunning {
            note = nil
            problem = String(
                localized: "Nothing was written. Quit Claude Desktop first: while it is open, it puts its old settings back.",
                comment: "Setting note")
            return
        }
        busy = true
        problem = nil
        note = nil
        do {
            // The row already says it is connected; the note is only what to do next. The
            // backup is still written beside the file, it just is not read out here.
            try MCPClientConfig.install(plan, at: configURL)
            note = restartLine
        } catch {
            problem = "Nothing was written. \(error)"
            busy = false
            refresh()
            return
        }
        await runSmokeTest()
        busy = false
        refresh()
    }

    /// Takes our own entry back out, under whatever name it is in there — the mirror of
    /// `install`, with the same backup and the same promise about everything else in the file.
    func disconnect() async {
        busy = true
        problem = nil
        note = nil
        guard let key = MCPClientConfig.installedKey(at: configURL) else {
            busy = false
            refresh()
            return
        }
        do {
            try MCPClientConfig.remove(key: key, at: configURL)
            note = nil
        } catch {
            problem = "Nothing was written. \(error)"
        }
        busy = false
        refresh()
    }

    /// The "Check it works" button: the same round trip with no write in front of it.
    func check() async {
        busy = true
        problem = nil
        note = nil
        await runSmokeTest()
        busy = false
        refresh()
    }

    /// Each client reads that file when it starts, and neither is restarted by Worklens.
    private var restartLine: String {
        switch client {
        case .claudeDesktop:
            return String(localized: "Open Claude Desktop to use it.", comment: "Label")
        case .claudeCode, .codex:
            return String(localized: "Start a new session to use it.", comment: "Label")
        }
    }

    /// Resolves configuration the way the client will — no inherited environment, cwd `/` — and
    /// runs `initialize` + `tools/list` in process, off the main actor because it opens the
    /// database.
    private func runSmokeTest() async {
        let envFile = envFile
        let appDataDir = appDataDir
        let outcome: (summary: String?, mismatch: String?, failure: String?) =
            await Task.detached {
                do {
                    let config = try MCPSmokeTest.clientConfig(envFile: envFile)
                    let result = try MCPSmokeTest.run(config: config, appDataDir: appDataDir)
                    return (result.summary, result.mismatchNote, nil)
                } catch {
                    return (nil, nil, "\(error)")
                }
            }.value

        // A server that came up is the expected outcome, so only a failure is worth a line;
        // "Check it works" with nothing to report says so in one.
        if outcome.summary != nil, note == nil {
            note = String(localized: "Working.", comment: "Label")
        }
        if let mismatch = outcome.mismatch {
            problem = mismatch
        }
        if let failure = outcome.failure {
            problem = "The server did not come up: \(failure)"
        }
    }
}

/// The name the setup flow's ready page asks for (`Sources/Worklens/Setup/SetupPages.swift`),
/// which another issue owns this wave. One client, its own default, same model.
typealias ClaudeDesktopModel = MCPClientModel
