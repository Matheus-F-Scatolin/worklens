import Foundation

/// Everything Settings → Integrations needs to *set a source up*, as values rather than as views
/// (#135).
///
/// Before this, the pane's whole answer to "how do I turn Granola on?" was the string
/// "Set GRANOLA_API_KEY" — the name of a variable in a file the app never named, in an app that
/// could not write it. The setup steps, the deep links, what a pasted credential must look like,
/// what the source sends and what it keeps all live here, in the one target with tests, so the
/// SwiftUI in `IntegrationsSettingsView` is only the drawing.
///
/// Three rules this file exists to keep:
/// * **Nothing here ever holds or logs a credential.** `entryError` and `shapeWarning` take a
///   typed string, answer with a sentence about its *shape*, and keep nothing. The sentences they
///   return never quote the value (`CLAUDE.md`: never log an API key).
/// * **The refusals are the ones the sources already knew**, moved to where a paste can be refused
///   *before* a sync fails minutes later: Google's secret-in-the-id-field sentence, and Granola's
///   Business-plan requirement stated before the field rather than after the first 401.
/// * **What a card claims about privacy is what `PRIVACY.md` claims.** `host(for:)` is checked
///   against that document's "What leaves your machine" table by `IntegrationSetupTests`.
public enum IntegrationSetup {
    // MARK: What a source is for

    /// The one sentence that says why you would connect this at all, in the second person.
    public static func value(for source: ContextSource) -> String {
        switch source {
        case .granola:
            return "Meeting titles, attendees and summaries on your timeline."
        case .calendar:
            return "What was scheduled, so capture slows down while a call is running."
        }
    }

    /// The "What is stored" disclosure: what leaves the Mac, and what stays on it. These are
    /// `PRIVACY.md`'s rows in the second person, and the host they name is `host(for:)`.
    public static func stored(for source: ContextSource) -> [String] {
        switch source {
        case .granola:
            return [
                "Sent to public-api.granola.ai: your Granola API key and a request for your own "
                    + "recent notes and their transcripts. Nothing about your screen goes out.",
                "Kept on this Mac: each meeting's title, time and attendees, its summary in the "
                    + "database, and its transcript in a file under data/context/granola/. A "
                    + "transcript never goes into a report prompt, only the first 300 characters "
                    + "of the summary do.",
            ]
        case .calendar:
            return [
                "Sent to www.googleapis.com: your Google access token and a request for your "
                    + "primary calendar's events in a date window.",
                "Kept on this Mac: each event's title, time and attendees, so the timeline can "
                    + "say which call a screen belongs to.",
                gmailGrantNote,
            ]
        }
    }

    /// The host this source reaches, exactly as `PRIVACY.md`'s table spells it.
    public static func host(for source: ContextSource) -> String {
        switch source {
        case .granola: return "public-api.granola.ai"
        case .calendar: return "www.googleapis.com"
        }
    }

    /// Said once, on the Google card (#285). A sign-in made while the Gmail source existed also
    /// granted `gmail.metadata`; that grant still works for Calendar, so nothing forces a
    /// reconnect, and taking the mail scope away is Google's page to do, not Worklens's.
    public static let gmailGrantNote =
        "Worklens no longer reads Gmail. If you connected Google before, that sign-in also allows "
        + "mail metadata; you can remove it at myaccount.google.com/permissions."

    /// What a Testing consent screen costs you, said once and plainly (#139). Google expires a
    /// refresh token issued by an unpublished screen after seven days, so Calendar stops on its
    /// own about weekly and Worklens asks you to press Reconnect. Publishing the screen would end
    /// that, and publishing a screen that asks for `calendar.readonly`, a sensitive scope, means
    /// Google's verification review — which is why Worklens does not ask you to.
    public static var googleTestingNote: String {
        L10n.string(
            "While your consent screen stays in Testing, Google expires the sign-in every 7 days. Worklens then pauses Calendar and shows a Reconnect button: one click, no terminal."
        )
    }

    /// What a 401 or 403 from Google says. `ContextSyncError.unauthorized` carries this into
    /// `SourceStatus.lastError`, which is drawn verbatim on the Integrations card and in the
    /// menu, so it names the button that fixes it and never a terminal command (#139).
    public static func googleUnauthorizedHint(_ api: String) -> String {
        "Google rejected the \(api) request. Press Reconnect in Settings \u{2192} Integrations."
    }

    /// What has to be true before the steps below can work at all — stated *before* the field,
    /// not discovered by a rejected key. Nil where there is no such condition.
    public static func requirement(for source: ContextSource) -> String? {
        switch source {
        case .granola:
            return "Granola only issues personal API keys on a Business plan. Check your plan "
                + "first: without one there is no key to paste, and no other way in: current "
                + "Granola builds encrypt their own on-disk cache."
        case .calendar:
            return nil
        }
    }

    // MARK: The steps

    /// The numbered walkthrough the setup sheet shows, in order. The same instructions as
    /// `docs/user/integrations/{granola,google}.md`, with the links clickable
    /// (`docs/user/integrations.md` is only the index over those two).
    public static func steps(for source: ContextSource) -> [IntegrationStep] {
        let texts: [(String, URL?)]
        switch source {
        case .granola:
            texts = [
                ("In Granola, open Settings → API keys and create a personal key.", nil),
                ("Copy the key. It starts with grn_.", nil),
                ("Paste it below and press Test: Worklens asks Granola for one note and stores "
                    + "nothing.", nil),
            ]
        case .calendar:
            texts = [
                ("Open the Google Cloud console and create or pick a project.", Links.googleCloud),
                ("APIs & Services → Library: enable the Google Calendar API.",
                    Links.googleCalendarAPI),
                ("OAuth consent screen → External: fill in the app name and your email, and add "
                    + "your own address under Test users.", Links.googleConsentScreen),
                ("Credentials → Create credentials → OAuth client ID → Desktop app. Paste the "
                    + "client id and secret below.", Links.googleCredentials),
                ("Press Connect Google below: that opens your browser and is the only step that "
                    + "can grant anything.", nil),
            ]
        }
        return texts.enumerated().map {
            IntegrationStep(number: $0.offset + 1, text: $0.element.0, link: $0.element.1)
        }
    }

    /// The two pages a setup step sends you to. They open in your browser; Worklens itself sends
    /// them nothing, which is what `PRIVACY.md`'s setup-links row says.
    public enum Links {
        public static let googleCloud = URL(string: "https://console.cloud.google.com")!
        /// The three console pages the Google steps send you to, each straight to the page rather
        /// than to a console front door you then have to navigate (#139).
        public static let googleCalendarAPI = URL(
            string: "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com")!
        public static let googleConsentScreen = URL(
            string: "https://console.cloud.google.com/apis/credentials/consent")!
        public static let googleCredentials = URL(
            string: "https://console.cloud.google.com/apis/credentials")!
    }

    // MARK: The fields

    /// The credentials this source's sheet can write, in the order it shows them.
    public static func fields(for source: ContextSource) -> [IntegrationField] {
        switch source {
        case .granola:
            return [
                IntegrationField(
                    key: "GRANOLA_API_KEY",
                    label: "Personal API key",
                    prompt: "grn_…",
                    expectedPrefix: "grn_"
                )
            ]
        case .calendar:
            return [
                IntegrationField(
                    key: "GOOGLE_CLIENT_ID",
                    label: "OAuth client id",
                    prompt: "…apps.googleusercontent.com",
                    expectedPrefix: nil,
                    // #139: a client id has no stable prefix but always ends this way, and the
                    // commonest paste error is the *secret* into this field.
                    expectedSuffix: ".apps.googleusercontent.com",
                    rejected: [
                        IntegrationField.Rejection(
                            prefix: "GOCSPX-",
                            message: "That is the client secret. The client id is the longer "
                                + "value ending in .apps.googleusercontent.com."
                        )
                    ]
                ),
                IntegrationField(
                    key: "GOOGLE_CLIENT_SECRET",
                    label: "OAuth client secret",
                    prompt: "GOCSPX-…",
                    expectedPrefix: "GOCSPX-"
                ),
            ]
        }
    }

    /// What this field currently holds, or nil when no layer set it.
    ///
    /// Spelled out per key rather than read through `ConfigKey.read`, which masks a secret: the
    /// Test button has to send the real value, and a masked one would be tested instead. The value
    /// is returned to the sheet and to the tester and goes nowhere else — nothing logs it.
    public static func storedValue(_ field: IntegrationField, in config: Config) -> String? {
        let value: String?
        switch field.key {
        case "GRANOLA_API_KEY": value = config.granolaAPIKey
        case "GOOGLE_CLIENT_ID": value = config.googleClientID
        case "GOOGLE_CLIENT_SECRET": value = config.googleClientSecret
        default: value = nil
        }
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// Whether this source can be asked, right now, whether its credential works — one cheap call
    /// that writes nothing. Google's grant is proved by connecting, not by a probe.
    public static func isTestable(_ source: ContextSource) -> Bool {
        switch source {
        case .granola: return true
        case .calendar: return false
        }
    }

    // MARK: Entry

    /// What a pasted value becomes before anything else looks at it — the same rule
    /// `Accounts.normalize` uses for the two model keys, because a token copied out of a web page
    /// arrives with a newline either way.
    public static func normalize(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why this value cannot be saved at all, as the sentence the field shows. A wrong-looking
    /// prefix is *not* one of these reasons unless it means a credential of the wrong kind — see
    /// `shapeWarning`.
    public static func entryError(_ field: IntegrationField, _ typed: String) -> String? {
        let value = normalize(typed)
        if value.isEmpty { return "Nothing to save: paste it first." }
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return "That has a space in the middle of it: the paste probably picked up more than "
                + "the value."
        }
        for rejection in field.rejected where value.hasPrefix(rejection.prefix) {
            return rejection.message
        }
        return nil
    }

    /// The soft half of the shape check: saved, but it does not start the way this credential
    /// usually does. A warning rather than a refusal — a provider that changes its prefix must not make the app refuse a working key.
    public static func shapeWarning(_ field: IntegrationField, _ typed: String) -> String? {
        let value = normalize(typed)
        guard !value.isEmpty else { return nil }
        if let prefix = field.expectedPrefix, !value.hasPrefix(prefix) {
            return "Saved, but \(field.key) usually starts with \(prefix): check you pasted the "
                + "whole thing, then press Test."
        }
        if let suffix = field.expectedSuffix, !value.hasSuffix(suffix) {
            return "Saved, but \(field.key) usually ends with \(suffix): check you pasted the "
                + "whole thing."
        }
        return nil
    }

    /// The same check, but under a field you are still typing in: present tense, and in the words
    /// the sheet uses rather than the name of an environment variable.
    ///
    /// `shapeWarning` is the sentence for *after* a write, and the sheet used to show it live —
    /// so a half-typed key was answered with "Saved, but GRANOLA_API_KEY…" while the Save button
    /// was still waiting and nothing had been written. Two separate wrongs: it claimed a write
    /// that had not happened, and it put back the config-key jargon this pane exists to remove.
    public static func shapeNote(_ field: IntegrationField, _ typed: String) -> String? {
        let value = normalize(typed)
        guard !value.isEmpty else { return nil }
        if let prefix = field.expectedPrefix, !value.hasPrefix(prefix) {
            return "The \(field.label) usually starts with \(prefix): check you pasted the whole "
                + "thing."
        }
        if let suffix = field.expectedSuffix, !value.hasSuffix(suffix) {
            return "The \(field.label) usually ends with \(suffix): check you pasted the whole "
                + "thing."
        }
        return nil
    }
}

// MARK: - One step

/// One numbered instruction, and the page it sends you to if it has one.
public struct IntegrationStep: Sendable, Equatable, Identifiable {
    public let number: Int
    public let text: String
    public let link: URL?

    public init(number: Int, text: String, link: URL? = nil) {
        self.number = number
        self.text = text
        self.link = link
    }

    public var id: Int { number }

    /// What a link reads as: the host and path, without the scheme.
    public var linkLabel: String? {
        guard let link, let host = link.host() else { return nil }
        let path = link.path()
        return path.isEmpty || path == "/" ? host : host + path
    }
}

// MARK: - One field

/// One credential a setup sheet can write, described once.
public struct IntegrationField: Sendable, Equatable, Identifiable {
    /// A prefix that means the value is the wrong *kind* of credential, and what to say about it.
    public struct Rejection: Sendable, Equatable {
        public let prefix: String
        public let message: String

        public init(prefix: String, message: String) {
            self.prefix = prefix
            self.message = message
        }
    }

    /// The `.env` / `settings.json` name. `Config.key(named:)` must know it.
    public let key: String
    public let label: String
    /// The `SecureField`'s placeholder — the shape, never something that could be mistaken for a
    /// real value.
    public let prompt: String
    /// What this credential normally starts with, for `shapeWarning`. Nil where there is no stable
    /// prefix.
    public let expectedPrefix: String?
    /// What it normally *ends* with (#139: a Google client id has no prefix worth checking and a
    /// suffix that never varies). Checked exactly as softly as the prefix.
    public let expectedSuffix: String?
    public let rejected: [Rejection]

    public init(
        key: String,
        label: String,
        prompt: String,
        expectedPrefix: String?,
        expectedSuffix: String? = nil,
        rejected: [Rejection] = []
    ) {
        self.key = key
        self.label = label
        self.prompt = prompt
        self.expectedPrefix = expectedPrefix
        self.expectedSuffix = expectedSuffix
        self.rejected = rejected
    }

    public var id: String { key }
}

// MARK: - One card

/// Where a source stands, as the pane draws it.
public enum IntegrationState: String, Sendable, Equatable, CaseIterable {
    /// No credential at all. Greyed, not red: nothing is wrong, it was simply never connected.
    case notSetUp
    /// The credential is present, and the last round either worked or has not run yet.
    case connected
    /// The credential was refused. Its own state rather than a red "Error:" line, because it is
    /// something you fix here in one paste — and because Granola answers the same way for a key
    /// that is wrong and for a plan that does not include API access, which is not a failure for
    /// the app to report as one.
    case refused
    /// Anything else the last sync hit: a network problem, a rate limit, an outage.
    case failed

    public var level: StatusLevel {
        switch self {
        case .notSetUp: return .muted
        case .connected: return .ok
        case .refused: return .attention
        case .failed: return .problem
        }
    }
}

/// One source as Settings → Integrations draws it: a state, what it is for, what it stores, and
/// what to do about it. Pure — the view is a function of this, and the tests are its only other
/// reader.
public struct IntegrationCard: Sendable, Equatable, Identifiable {
    public let source: ContextSource
    public let displayName: String
    public let state: IntegrationState
    /// The status line under the name: the sync line, or the sentence the last failure carried.
    public let detail: String
    public let warnings: [String]

    public init(
        source: ContextSource,
        displayName: String,
        state: IntegrationState,
        detail: String,
        warnings: [String] = []
    ) {
        self.source = source
        self.displayName = displayName
        self.state = state
        self.detail = detail
        self.warnings = warnings
    }

    public var id: ContextSource { source }
    public var level: StatusLevel { state.level }
    public var value: String { IntegrationSetup.value(for: source) }
    public var stored: [String] { IntegrationSetup.stored(for: source) }
    public var requirement: String? { IntegrationSetup.requirement(for: source) }
    public var isConfigured: Bool { state != .notSetUp }

    /// The badge's word. A refusal says which half of the problem it is, in the source's own
    /// terms, so "not accepted" never has to be decoded.
    public var statusText: String {
        switch state {
        case .notSetUp: return "Not set up"
        case .connected: return "Connected"
        case .refused:
            switch source {
            case .granola: return "Key or plan not accepted"
            case .calendar: return "Sign in again"
            }
        case .failed: return "Last sync failed"
        }
    }

    /// What the card's own button offers. The sheet is also where a token is replaced, so a
    /// source that is already set up still has one.
    public var setUpTitle: String { isConfigured ? "Change\u{2026}" : "Set up\u{2026}" }
}

/// Builds the cards. One per known source, always — a pane that shows nothing because no source
/// is configured is a pane that cannot be used to configure one.
public enum IntegrationCards {
    public static func build(config: Config, statuses: [SourceStatus]) -> [IntegrationCard] {
        ContextSources.all(config: config).map { source in
            card(
                source: source.id,
                displayName: source.displayName,
                isConfigured: source.isConfigured(config),
                status: statuses.first { $0.id == source.id }
            )
        }
    }

    public static func card(
        source: ContextSource,
        displayName: String,
        isConfigured: Bool,
        status: SourceStatus?
    ) -> IntegrationCard {
        guard isConfigured else {
            return IntegrationCard(
                source: source,
                displayName: displayName,
                state: .notSetUp,
                detail: "Not set up yet."
            )
        }
        // #139: not an error and not a refused credential — the grant simply ran out of the seven
        // days a Testing consent screen gets, and one click fixes it.
        if status?.needsReconnect == true {
            return IntegrationCard(
                source: source,
                displayName: displayName,
                state: .refused,
                detail: SourceStatus.pausedLine,
                warnings: status?.lastWarnings ?? []
            )
        }
        if let error = status?.lastError {
            return IntegrationCard(
                source: source,
                displayName: displayName,
                state: (status?.lastErrorWasCredential ?? false) ? .refused : .failed,
                detail: error,
                warnings: status?.lastWarnings ?? []
            )
        }
        return IntegrationCard(
            source: source,
            displayName: displayName,
            state: .connected,
            detail: status?.line() ?? "Connected \u{b7} never synced",
            warnings: status?.lastWarnings ?? []
        )
    }
}

// MARK: - Which layer won

public extension ConfigLayer {
    /// False when this layer outranks Worklens's own settings file, so writing the key in the app
    /// would change a file nobody reads (#108). `AccountRow.isEditable` draws the same line; a
    /// control on the wrong side of it shows itself disabled rather than lying about the edit.
    var isWritableInApp: Bool {
        switch self {
        case .process, .explicitFile: return false
        case .appSettings, .appSupport, .cwd, .fallback: return true
        }
    }

    /// Why a control is disabled, in the second person. Nil when it is not.
    var lockedNote: String? {
        switch self {
        case .process:
            return "Set in the environment Worklens was launched with: that wins, so there is "
                + "nothing to change here."
        case .explicitFile:
            return "Set in the file WORKLENS_ENV_FILE names: that wins, so there is nothing to "
                + "change here."
        case .appSettings, .appSupport, .cwd, .fallback:
            return nil
        }
    }
}

// MARK: - Identity

extension ContextSource: Identifiable {
    /// The setup sheet is presented by `sheet(item:)`, and the raw value is already the stable
    /// spelling — it is what `context_events.source` holds.
    public var id: String { rawValue }
}
