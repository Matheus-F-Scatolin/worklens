import Foundation

// MARK: - Errors

/// Something in the configuration that is wrong enough to refuse.
///
/// #126 gave these provenance: a value is wrong *in a file*, and the file is the thing the user
/// has to open. `located` carries the layer and the path, `multiple` carries every error one
/// load found rather than only the first, and `description` stays one sentence per error.
public enum ConfigError: Error, CustomStringConvertible, Equatable {
    case invalidInt(key: String, value: String)
    case invalidDouble(key: String, value: String)
    case invalidBool(key: String, value: String)
    case invalidEnum(key: String, value: String, allowed: [String])
    case outOfRange(key: String, value: String, range: String)
    /// A name that is in no `Config.keys` entry — a typo, or a key that was retired (#87).
    case unknownKey(key: String)
    /// Empty is how a layer says "not set", so it cannot also be a value. `worklens config
    /// unset` is the way to go back to the layer below.
    case emptyValue(key: String)
    /// One of the above, plus the layer and file that supplied the value (#126).
    indirect case located(ConfigError, layer: ConfigLayer, file: URL?)
    /// Every error one load found, in registry order (#126). Never empty in practice; a load
    /// that found exactly one error throws that one rather than wrapping it.
    indirect case multiple([ConfigError])

    public var description: String {
        switch self {
        case let .invalidInt(key, value):
            return "\(key): expected an integer, got \"\(value)\""
        case let .invalidDouble(key, value):
            return "\(key): expected a number, got \"\(value)\""
        case let .invalidBool(key, value):
            return "\(key): expected true/false, got \"\(value)\""
        case let .invalidEnum(key, value, allowed):
            return "\(key): expected one of \(allowed.joined(separator: "|")), got \"\(value)\""
        case let .outOfRange(key, value, range):
            return "\(key): \(value) is outside \(range)"
        case let .unknownKey(key):
            return Config.retiredKeys.contains(key)
                ? "\(key) is no longer a setting: `worklens config-dump` lists the ones that are"
                : "\(key) is not a Worklens setting: `worklens config-dump` lists every key"
        case let .emptyValue(key):
            return "\(key): an empty value means \"not set\", use `worklens config unset \(key)` instead"
        case let .located(inner, layer, file):
            return "\(inner) \(ConfigError.whereText(layer: layer, file: file))"
        case let .multiple(errors):
            guard errors.count != 1 else { return errors[0].description }
            return "\(errors.count) settings need fixing: "
                + errors.map(\.description).joined(separator: "; ")
        }
    }

    /// `in /Users/you/.env`, or the layer's own name when no file backs it.
    private static func whereText(layer: ConfigLayer, file: URL?) -> String {
        if let file { return "(in \(file.path))" }
        switch layer {
        case .process: return "(set in this process's environment)"
        default: return "(from \(layer.label))"
        }
    }

    /// Every leaf error, `multiple` flattened. One element for anything else.
    public var errors: [ConfigError] {
        if case let .multiple(list) = self { return list.flatMap(\.errors) }
        return [self]
    }

    /// One sentence per error, each already carrying its file — what the Settings banner lists
    /// and what `config-dump` prints.
    public var sentences: [String] { errors.map(\.description) }

    /// A single line short enough for the menu: the one sentence, or how many there are.
    public var summary: String {
        let all = errors
        guard all.count > 1 else { return all.first?.description ?? description }
        return "\(all.count) settings need fixing: the first is \(all[0].description)"
    }

    /// The file the user has to open: the first error's, since a fix starts somewhere.
    public var file: URL? {
        for error in errors {
            if case let .located(_, _, file) = error, let file { return file }
        }
        return nil
    }

    /// The layer that supplied the first located value.
    public var layer: ConfigLayer? {
        for error in errors {
            if case let .located(_, layer, _) = error { return layer }
        }
        return nil
    }

    /// The key the first error is about.
    public var key: String? {
        switch self {
        case let .invalidInt(key, _), let .invalidDouble(key, _), let .invalidBool(key, _):
            return key
        case let .invalidEnum(key, _, _): return key
        case let .outOfRange(key, _, _): return key
        case let .unknownKey(key): return key
        case let .emptyValue(key): return key
        case let .located(inner, _, _): return inner.key
        case let .multiple(list): return list.first?.key
        }
    }

    /// Every key some error is about, in order, no duplicates. What "use defaults for these
    /// keys and start" drops.
    public var keys: [String] {
        var seen: Set<String> = []
        return errors.compactMap(\.key).filter { seen.insert($0).inserted }
    }

    /// What the loader said, minus the key it said it about — for a pane whose every control is
    /// already named in words, and where #242 asked that nothing put a configuration key in
    /// front of a person. The rest of the sentence is unchanged: it is the same check
    /// `worklens config set` runs. Takes any `Error`, because a Settings pane catches whatever
    /// the store throws, and leaves a sentence that does not start with a key alone.
    public static func note(_ error: Error) -> String {
        let text = "\(error)"
        guard let colon = text.firstIndex(of: ":") else { return text }
        let head = text[text.startIndex..<colon]
        let looksLikeAKey = !head.isEmpty && head.allSatisfy {
            $0.isNumber || $0 == "_" || ($0.isLetter && $0.isUppercase)
        }
        guard looksLikeAKey else { return text }
        return String(text[text.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Warnings

/// Something worth telling the user that must never stop the app from starting.
///
/// The split is the whole point of #126. A value that cannot be parsed is fatal; a value that
/// parses but is probably not what you meant is a sentence. An unknown model id in particular
/// must stay advisory: `ModelPricing.default` is a pinned, date-verified table, and making a
/// missing row fatal would refuse to launch the day a new Gemini or Claude id ships.
public enum ConfigWarning: Sendable, Equatable, CustomStringConvertible {
    /// A model id that is in no price-table row, so its calls are costed at $0.
    case unknownModel(key: String, model: String)
    /// A key nothing in Worklens reads. Non-fatal by long-standing decision (#87,
    /// `docs/decisions.md`): named, never applied, never a reason to refuse a launch.
    case unknownKey(name: String, suggestion: String?, file: URL?)
    /// A regex list whose value has a comma and no semicolon — probably the wrong separator.
    case listSeparator(key: String)
    /// A key the lenient load dropped: its built-in default is in use for this session only,
    /// and the file still says what it said.
    case usingDefault(key: String)
    /// #317: a repo list entry with no owner, which matches no repo.
    case repoWithoutOwner(key: String)

    public var description: String {
        switch self {
        case let .unknownModel(key, model):
            return "\(key) is set to \"\(model)\", which is not in the price table, so its calls "
                + "will be costed at $0"
        case let .unknownKey(name, suggestion, file):
            let did = suggestion.map { ", did you mean \($0)?" } ?? ""
            let place = file.map { " in \($0.path)" } ?? ""
            return "\(name)\(place) is not a Worklens setting, so nothing reads it\(did)"
        case let .listSeparator(key):
            return "\(key) is separated by semicolons, so the comma in its value is being read as "
                + "part of one pattern"
        case let .usingDefault(key):
            return "\(key) is using its built-in default for this session: your file still says "
                + "what it said"
        case let .repoWithoutOwner(key):
            return "\(key) has a repo with no owner, so it matches nothing: write each one as owner/name"
        }
    }
}

// MARK: - Enums

/// What one tick collects — the `CAPTURE_SOURCE` key (#54).
///
/// Deliberately not `CaptureSource`, which is what a *row* ended up carrying: `auto` writes
/// either `accessibility` or `both` depending on how much of the window the walk covered, so the
/// setting and the outcome are two different vocabularies.
public enum CaptureSourceMode: String, Sendable, CaseIterable, Codable {
    /// Walk the window first; take a screenshot only when the outline did not cover it.
    case auto
    /// Never screenshot. A window that exposes nothing is written `skipped` / `no_text`.
    case accessibility
    /// Pixels only, with no accessibility read at all — the A/B control, and what a machine
    /// without the Accessibility grant effectively does anyway.
    case screenshot
    /// Both artifacts every tick: the shipped default (see `docs/decisions.md`, "Accessibility
    /// first").
    case both
}

/// Where the Google refresh token is kept — the `GOOGLE_TOKEN_STORE` key.
///
/// Not a matter of taste: a login-keychain item is authorised per code *hash* when the signature
/// carries no Apple Developer Team ID, so every rebuild raises the access dialog again and
/// nothing Worklens writes can pre-authorise it (`docs/decisions.md`, "The Keychain dialog after
/// a rebuild cannot be fixed in code").
public enum GoogleTokenStorage: String, Sendable, CaseIterable, Codable {
    /// The login keychain, `dev.worklens.google` — visible and revocable in Keychain Access, and
    /// unreadable by another user of the Mac even when they are root-less admins. The default,
    /// and the reason for the dialog.
    case keychain
    /// `DATA_DIR/google-token.json`, mode 0600. No dialog, ever, for any build or worktree; as
    /// exposed as the `.env` that already holds `GOOGLE_CLIENT_SECRET`.
    case file

    /// What the connect sheet calls this option (#139).
    public var label: String {
        switch self {
        case .keychain: return "Login Keychain"
        case .file: return "Data folder"
        }
    }

    /// The one line under it — the trade, in the second person, with no jargon to decode.
    public var detail: String {
        switch self {
        case .keychain:
            return "Visible and revocable in Keychain Access. Asks for your login password the "
                + "first time each new build of Worklens reads it."
        case .file:
            return "DATA_DIR/google-token.json, readable only by you (0600). No password "
                + "dialogs, and it is in the folder your backups already copy."
        }
    }

    /// Which one to pre-select for a binary whose signature carries `teamID` (#139).
    ///
    /// Not a silent resolution of the configured default: `docs/decisions.md` kept `keychain` as
    /// the default precisely so the DATA_DIR-backup trade would be chosen rather than inherited,
    /// and this is the pre-selection on a choice the user still makes and can still change.
    /// Without a team in the signature the keychain re-asks for the login password after every
    /// rebuild and nothing in the app can pre-authorise it, so the file store is the one that
    /// works.
    public static func recommended(teamID: String?) -> GoogleTokenStorage {
        (teamID?.isEmpty ?? true) ? .file : .keychain
    }
}

public enum LogLevel: String, Sendable, CaseIterable, Codable, Comparable {
    case debug, info, warn, error

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

// MARK: - Provenance

/// Which layer supplied a key's value. The raw values are the labels `config-dump` prints.
public enum ConfigLayer: String, Sendable, CaseIterable, Codable {
    /// The process environment.
    case process = "env"
    /// The file `$WORKLENS_ENV_FILE` names.
    case explicitFile = "WORKLENS_ENV_FILE"
    /// `~/Library/Application Support/Worklens/settings.json` — the layer Worklens itself
    /// writes, from Settings and from `worklens config set`. Below `WORKLENS_ENV_FILE` on
    /// purpose: that variable is how worktrees, tests and scripts pin `DATA_DIR`, and a file
    /// the GUI rewrites must not be able to outrank it (#34). It still beats both `.env` files.
    case appSettings = "settings"
    /// `~/Library/Application Support/Worklens/.env`.
    case appSupport = "app-support"
    /// `<cwd>/.env`.
    case cwd = "cwd"
    /// No layer set it, so the built-in default applies.
    case fallback = "default"

    public var label: String { rawValue }
}

/// One resolved layer with the file it came from, if any.
///
/// #126 added the name: `load(layers:)` used to take bare dictionaries, so an error could say
/// which key was wrong but never which of five files to open — and "CAPTURE_INTERVAL_SECONDS:
/// expected an integer" is a poor thing to hand somebody with an `.env` in the checkout, one in
/// Application Support and a `settings.json` between them.
public struct ConfigSource: Sendable, Equatable {
    /// Nil for a layer nobody named — the unnamed `load(layers:)` overload tests use.
    public let layer: ConfigLayer?
    /// The file this layer was read from. Nil for the process environment.
    public let url: URL?
    public let values: [String: String]

    public init(layer: ConfigLayer?, url: URL?, values: [String: String]) {
        self.layer = layer
        self.url = url
        self.values = values
    }
}

/// Where each key's value came from, and which keys the App Support file quietly took away
/// from the working directory's `.env` (#34).
public struct ConfigProvenance: Sendable, Equatable {
    /// One file that was consulted — an `.env`, or `settings.json` — whether or not it exists.
    public struct File: Sendable, Equatable {
        public let layer: ConfigLayer
        public let url: URL
        public let exists: Bool

        public init(layer: ConfigLayer, url: URL, exists: Bool) {
            self.layer = layer
            self.url = url
            self.exists = exists
        }
    }

    /// Keyed by env-var name. Only keys that some layer actually set appear; ask through
    /// `source(of:)` so a key nobody set reads as `.fallback`.
    public var sources: [String: ConfigLayer]
    /// Keys the App Support file won while `<cwd>/.env` set them too. Key names only — a
    /// value here could be an API key.
    public var appSupportOverrides: [String]
    /// The files that were consulted, highest precedence first.
    public var files: [File]
    /// Keys some layer set that Worklens no longer reads (#87), in `Config.retiredKeys` order.
    /// Nothing breaks — they are simply dead lines the developer can delete from their `.env`.
    public var retiredKeys: [String]
    /// The three blocklists as the layers supplied them, *before* the app's own overlay, keyed
    /// by `Blocklist.rawValue` (#128). It is what tells "you added this" from "your `.env` did",
    /// and so whether removing a row has to leave a tombstone behind.
    public var blocklistBase: [String: [String]]
    /// Names a file set that are in no `Config.keys` entry at all — a typo, most often (#126).
    /// Never fatal: unknown keys have always been ignored, and this only stops them being
    /// ignored *silently*, which is how `CAPTURE_INTERVAL_SECS=30` looked applied for weeks.
    public var unknownKeys: [UnknownKey]
    /// Everything advisory this load found, in the order it found it: unknown keys, model ids
    /// that are in no price-table row, a regex list with the wrong separator, and any key a
    /// lenient load dropped. Key names and model ids only — a value could be an API key.
    public var warnings: [ConfigWarning]

    /// One name no layer of Worklens knows, with the closest key it does know (#126).
    public struct UnknownKey: Sendable, Equatable {
        public let name: String
        /// The nearest known key within an edit distance of three, or nil when nothing is close.
        public let suggestion: String?
        public let layer: ConfigLayer
        /// The file that set it. File layers only, so this is nil only for a layer with no path.
        public let url: URL?

        public init(name: String, suggestion: String?, layer: ConfigLayer, url: URL?) {
            self.name = name
            self.suggestion = suggestion
            self.layer = layer
            self.url = url
        }
    }

    public init(
        sources: [String: ConfigLayer] = [:],
        appSupportOverrides: [String] = [],
        files: [File] = [],
        retiredKeys: [String] = [],
        blocklistBase: [String: [String]] = [:],
        unknownKeys: [UnknownKey] = [],
        warnings: [ConfigWarning] = []
    ) {
        self.sources = sources
        self.appSupportOverrides = appSupportOverrides
        self.files = files
        self.retiredKeys = retiredKeys
        self.blocklistBase = blocklistBase
        self.unknownKeys = unknownKeys
        self.warnings = warnings
    }

    /// One sentence per advisory, ready to print or show. Same order as `warnings`.
    public var warningLines: [String] { warnings.map(\.description) }

    public func source(of key: String) -> ConfigLayer { sources[key] ?? .fallback }

    /// What `.env` and the built-in defaults said about one list, overlay aside.
    public func base(of list: Blocklist) -> [String] { blocklistBase[list.rawValue] ?? [] }

    /// True when not one of the files above exists: nothing but the built-in defaults is in
    /// play. This is a first run — `worklens config-dump` says so in a line, and the app writes
    /// a starter `.env` rather than leaving the user to guess where one goes (#116).
    /// False for a provenance that consulted nothing (the empty value a failed load leaves
    /// behind): "we looked and there was nothing" is a different fact from "we never looked".
    public var noFilesFound: Bool { !files.isEmpty && !files.contains { $0.exists } }

    /// The file `WORKLENS_ENV_FILE` named, when the variable was set at all. Nil otherwise,
    /// which is the ordinary case: an installed app is opened by Finder, Spotlight or the login
    /// item, none of which pass an environment.
    public var devOverrideFile: File? { files.first { $0.layer == .explicitFile } }

    /// True when `WORKLENS_ENV_FILE` named a file that is really there, so this process is
    /// reading a developer's checkout rather than the installed configuration (#129).
    ///
    /// `<cwd>/.env` is deliberately not part of this. A bundled app's working directory is `/`,
    /// so that layer only ever applies to a CLI run from a checkout, and calling it a "dev
    /// override" in the menu would describe something the app can never be doing.
    public var devOverrideActive: Bool { devOverrideFile?.exists == true }

    /// The one line the menu and Settings show while an override is in play, or nil when there
    /// is none. A path, never a value — the file it names is where the API keys live (#129).
    public var devOverrideLine: String? {
        guard let file = devOverrideFile else { return nil }
        guard file.exists else {
            return "Dev override: WORKLENS_ENV_FILE names \(file.url.path), which does not exist"
        }
        return "Dev override: reading \(file.url.path)"
    }
}

// MARK: - Config

/// Every runtime setting, typed, with defaults. Loaded from the process environment and
/// `.env` files; see `load(environment:cwd:appSupportEnv:)` for precedence.
public struct Config: Sendable, Equatable {
    // Credentials
    public var geminiAPIKey: String?
    public var granolaAPIKey: String?
    public var googleClientID: String?
    public var googleClientSecret: String?

    // Models
    public var describeModel: String
    /// #157: `REPORT_LANGUAGE`, the language the describe prompt asks for. A constant default
    /// of `en` rather than the current locale's language, because a default read from System
    /// Settings would make the prompt — and every test that pins its bytes — depend on the
    /// machine. See `ReportLanguage`.
    public var reportLanguage: String = ReportLanguage.english

    // Capture
    public var captureIntervalSeconds: Int
    public var meetingCaptureIntervalSeconds: Int
    public var captureIdleSeconds: Int
    public var captureHeartbeatSeconds: Int
    public var changeThreshold: Double
    public var captureMaxEdgePx: Int
    /// Which artifacts a tick collects (#54). Ships as `both`; see `docs/decisions.md`
    /// "Accessibility first".
    public var captureSource: CaptureSourceMode
    /// What happens on battery or in Low Power Mode (#145). Ships as `slow`.
    public var captureOnBattery: BatteryCaptureMode

    // Privacy
    public var deleteScreenshotsAfterDescribe: Bool
    public var deleteSensitiveScreenshots: Bool
    public var collectBrowserURL: Bool
    public var blockedBundleIDs: [String]
    public var blockedTitlePatterns: [String]
    /// Hosts whose pages are never looked at. Suffix match on the frontmost tab's host, so
    /// `nubank.com.br` also covers `app.nubank.com.br`.
    public var blockedURLHosts: [String]
    /// Extra regexes for `TextRedactor` (#49), semicolon-separated, each hit replaced by
    /// `[CUSTOM_n]` — for the one account number the built-in shapes cannot know about.
    public var redactExtraPatterns: [String]
    /// Where the Google grant lives (`keychain` or `file`). `file` exists to escape the Keychain
    /// access dialog, which a rebuild re-raises no matter how the item was stored.
    public var googleTokenStore: GoogleTokenStorage
    /// How many days of history to keep, today included. 0 keeps everything, which is what
    /// Worklens did before #144. Older screenshots, descriptions, window outlines and
    /// foreground sessions are deleted by the quarter-hourly pass; see `Retention`.
    public var retentionDays: Int
    /// Whether a retention pass leaves the derived record — the activity blocks, any
    /// friction rows and timeline files written before #299 — standing for the days it aged
    /// out. True by default:
    /// the summaries are the reason the raw frames were collected at all.
    public var retentionKeepReports: Bool

    // Context sources
    public var contextSyncMinutes: Int
    /// #314: `GITHUB_SHIPPED`, the shipped ledger read through `gh`. On by default; off deletes
    /// the ledger and stops the sync. A default value rather than a memberwise argument, so every
    /// `Config(...)` written before it still compiles.
    public var githubShipped: Bool = true
    /// #317: `MEMO_REPOS`, the `owner/name` repos whose merged PRs of yours are read for company
    /// memo changes. Empty (the default) is off.
    public var memoRepos: [String] = []
    /// #321: `AGENT_SESSIONS`, Claude Code and Codex session metadata read from their own logs.
    /// On by default; off deletes what was read and stops reading. A default value, like
    /// `githubShipped`, so every `Config(...)` written before it still compiles.
    public var agentSessions: Bool = true

    // Staying current
    /// Poll `origin/main` and run the same pull → build → sign → relaunch round trip the menu's
    /// "Update and restart…" runs, without being asked.
    public var autoUpdateEnabled: Bool
    /// How often to ask the remote what `main` points at. Clamped to
    /// `AutoUpdatePolicy.minimumPollMinutes` — a tighter loop only spends network on an answer
    /// that changes a few times a day.
    public var autoUpdatePollMinutes: Int

    // The kill switch
    /// How often to remind you that capture is still paused, in hours. A pause survives a quit
    /// and an auto-update now (#113), so an afternoon can quietly go unrecorded; 0 turns the
    /// reminder off. See `PauseReminder`.
    public var pauseReminderHours: Int

    // Budgets & storage
    public var dailyBudgetUSD: Double
    public var screenshotDiskBudgetGB: Double
    public var dataDir: URL
    /// The escape hatch for `DataDirLocation`: run anyway with `DATA_DIR` in a synced folder.
    public var allowNonLocalDataDir: Bool
    public var logLevel: LogLevel

    // MARK: Defaults

    public static let defaultBlockedBundleIDs = ["com.1password.1password", "com.apple.keychainaccess"]
    public static let defaultBlockedTitlePatterns = ["Private Browsing", "Incognito", "1Password", "Password"]
    /// Empty by default: which banks and clinics you use is yours to name, and guessing at a
    /// list would be both wrong and a claim about you.
    public static let defaultBlockedURLHosts: [String] = []

    /// A config with every default applied.
    ///
    /// `dataDir` is the one default that is not a constant. A checkout keeps `./data` resolved
    /// against `cwd`; the bundled app cannot, because LaunchServices gives it `/` as its working
    /// directory and `/data` is not creatable — that is the "Configuration error" a Finder,
    /// Spotlight or login-item launch used to open with (#116). So the bundled app defaults to
    /// `~/Library/Application Support/Worklens/data` instead. Any layer that sets `DATA_DIR`
    /// still wins over both: this is only where the value comes from when nobody said.
    public static func defaults(
        cwd: URL = Config.currentDirectory,
        isBundledApp: Bool = Config.isBundledApp
    ) -> Config {
        Config(
            geminiAPIKey: nil,
            granolaAPIKey: nil,
            googleClientID: nil,
            googleClientSecret: nil,
            describeModel: "gemini-3.5-flash-lite",
            captureIntervalSeconds: 60,
            meetingCaptureIntervalSeconds: 300,
            captureIdleSeconds: 120,
            captureHeartbeatSeconds: 300,
            changeThreshold: 0.03,
            captureMaxEdgePx: 1024,
            captureSource: .both,
            captureOnBattery: .slow,
            deleteScreenshotsAfterDescribe: false,
            deleteSensitiveScreenshots: true,
            collectBrowserURL: true,
            blockedBundleIDs: defaultBlockedBundleIDs,
            blockedTitlePatterns: defaultBlockedTitlePatterns,
            blockedURLHosts: defaultBlockedURLHosts,
            redactExtraPatterns: [],
            googleTokenStore: .keychain,
            retentionDays: 0,
            retentionKeepReports: true,
            contextSyncMinutes: 15,
            autoUpdateEnabled: false,
            autoUpdatePollMinutes: 15,
            pauseReminderHours: 4,
            dailyBudgetUSD: 1.50,
            screenshotDiskBudgetGB: 20,
            dataDir: isBundledApp ? Config.appSupportDataDir() : Config.expandPath("./data", cwd: cwd),
            allowNonLocalDataDir: false,
            logLevel: .info
        )
    }

    // MARK: Loading

    /// Resolution order, first hit wins **per key**:
    /// 1. process environment
    /// 2. `$WORKLENS_ENV_FILE` (if set)
    /// 3. `~/Library/Application Support/Worklens/settings.json` — what Settings writes
    /// 4. `~/Library/Application Support/Worklens/.env`
    /// 5. `<cwd>/.env`
    ///
    /// Missing keys take their default. Missing API keys are allowed here; the features that
    /// need them fail later with a clear message. `worklens config-dump` prints which of these
    /// layers supplied each value; see `loadWithProvenance`.
    ///
    /// The three blocklists are the one exception to "first hit wins", and it is not a layer:
    /// `blocklists.json` adds to and subtracts from whichever layer won them (#128).
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cwd: URL = Config.currentDirectory,
        appSupportEnv: URL = Config.appSupportEnvURL(),
        settingsFile: URL = SettingsStore.defaultURL,
        blocklistsFile: URL? = nil
    ) throws -> Config {
        try loadWithProvenance(
            environment: environment, cwd: cwd, appSupportEnv: appSupportEnv,
            settingsFile: settingsFile, blocklistsFile: blocklistsFile
        ).config
    }

    /// `load(environment:cwd:appSupportEnv:)` plus a record of which layer supplied each key,
    /// which is what `worklens config-dump` prints. Logs at info when the App Support file
    /// overrides a key that `<cwd>/.env` also sets: that override is how two agents' captures
    /// ended up in another worktree's database (#34). Key names only are logged, never values.
    public static func loadWithProvenance(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cwd: URL = Config.currentDirectory,
        appSupportEnv: URL = Config.appSupportEnvURL(),
        settingsFile: URL = SettingsStore.defaultURL,
        blocklistsFile: URL? = nil,
        lenient: Bool = false
    ) throws -> (config: Config, provenance: ConfigProvenance) {
        let read = readLayers(
            environment: environment, cwd: cwd, appSupportEnv: appSupportEnv, settingsFile: settingsFile
        )
        let cwdEnv = cwd.appendingPathComponent(".env")
        let loaded = try load(sources: read.named, cwd: cwd, lenient: lenient)
        var config = loaded.config
        // #128: the single seam where what you blocked in the app meets what the files said.
        // Both processes load through here, so the menu-bar app, the CLI and
        // `PrivacyPolicy` cannot disagree about the three lists. It defaults to sitting beside
        // the settings file rather than to a fixed path, so a test or a worktree that points
        // `settingsFile` at a scratch directory never reads the real one.
        let base = Dictionary(
            uniqueKeysWithValues: Blocklist.allCases.map { ($0.rawValue, $0.entries(in: config)) }
        )
        BlocklistStore(url: blocklistsFile ?? BlocklistStore.url(besideSettings: settingsFile))
            .load()
            .apply(to: &config)
        var provenance = describe(read)
        provenance.blocklistBase = base
        provenance.warnings += loaded.warnings
        for warning in provenance.warnings {
            Log.config.warn("\(warning)")
        }
        if !provenance.retiredKeys.isEmpty {
            Log.config.warn(
                "these keys no longer do anything and can be deleted from your .env files: "
                    + provenance.retiredKeys.joined(separator: ", ")
            )
        }
        if !provenance.appSupportOverrides.isEmpty {
            Log.config.info(
                "\(appSupportEnv.path) outranks \(cwdEnv.path) and disagrees with it about "
                    + "\(provenance.appSupportOverrides.joined(separator: ", "))"
                    + ", run `worklens config-dump` to see every value's source"
            )
        }
        return (config, provenance)
    }

    /// Which file supplied what, worked out *without* validating a single value.
    ///
    /// A degraded start is exactly when "which file am I reading?" matters most: `loadWithProvenance`
    /// throws on the first bad value, so the app would otherwise show an empty provenance — no dev
    /// override line, and `.launch-env` recorded as though there were no override at all (#129).
    public static func provenance(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cwd: URL = Config.currentDirectory,
        appSupportEnv: URL = Config.appSupportEnvURL(),
        settingsFile: URL = SettingsStore.defaultURL
    ) -> ConfigProvenance {
        describe(
            readLayers(
                environment: environment, cwd: cwd, appSupportEnv: appSupportEnv,
                settingsFile: settingsFile
            )
        )
    }

    /// Every layer in precedence order, with the files behind them. Reading a file never throws:
    /// a missing or unreadable one is an empty layer.
    private static func readLayers(
        environment: [String: String],
        cwd: URL,
        appSupportEnv: URL,
        settingsFile: URL
    ) -> (named: [ConfigSource], files: [ConfigProvenance.File]) {
        var named: [ConfigSource] = [ConfigSource(layer: .process, url: nil, values: environment)]
        var files: [ConfigProvenance.File] = []
        if let explicit = environment["WORKLENS_ENV_FILE"], !explicit.isEmpty {
            let url = expandPath(explicit, cwd: cwd)
            named.append(ConfigSource(layer: .explicitFile, url: url, values: fileLayer(url)))
            files.append(describeFile(.explicitFile, url))
        }
        let cwdEnv = cwd.appendingPathComponent(".env")
        named.append(
            ConfigSource(
                layer: .appSettings, url: settingsFile, values: SettingsStore(url: settingsFile).layerValues()
            )
        )
        files.append(describeFile(.appSettings, settingsFile))
        named.append(ConfigSource(layer: .appSupport, url: appSupportEnv, values: fileLayer(appSupportEnv)))
        named.append(ConfigSource(layer: .cwd, url: cwdEnv, values: fileLayer(cwdEnv)))
        files.append(describeFile(.appSupport, appSupportEnv))
        files.append(describeFile(.cwd, cwdEnv))
        return (named, files)
    }

    /// The provenance of already-read layers, including the advisory warnings a read can raise
    /// without validating anything: a key no `Config.keys` entry names (#126).
    private static func describe(
        _ read: (named: [ConfigSource], files: [ConfigProvenance.File])
    ) -> ConfigProvenance {
        let unknown = unknownKeysSet(sources: read.named)
        return ConfigProvenance(
            sources: sources(namedLayers: read.named),
            appSupportOverrides: appSupportOverrides(namedLayers: read.named),
            files: read.files,
            retiredKeys: retiredKeysSet(namedLayers: read.named),
            unknownKeys: unknown,
            warnings: unknown.map {
                ConfigWarning.unknownKey(name: $0.name, suggestion: $0.suggestion, file: $0.url)
            }
        )
    }

    private static func describeFile(_ layer: ConfigLayer, _ url: URL) -> ConfigProvenance.File {
        ConfigProvenance.File(
            layer: layer,
            url: url,
            exists: FileManager.default.fileExists(atPath: url.path)
        )
    }

    /// Every key `config-dump` prints, in that order. Derived from `dumpLines` so the two
    /// cannot drift, and it is the set provenance is tracked over — the process environment
    /// holds hundreds of variables that are none of Worklens's business.
    public static var knownKeys: [String] {
        Config
            .defaults(cwd: URL(fileURLWithPath: "/", isDirectory: true), isBundledApp: false)
            .dumpLines.map(\.key)
    }

    /// Keys some layer may still set that Worklens no longer reads (#87), in registry order.
    /// The entries themselves live in `Config.keys`; this is the tail of it.
    public static let retiredKeys: [String] = Config.keys.filter(\.retired).map(\.name)

    /// Which retired keys the `.env` layers still set. The process environment is not searched:
    /// it holds hundreds of variables that are none of Worklens's business, and a shell that
    /// exported one of these is not a file anyone can clean up.
    static func retiredKeysSet(
        namedLayers: [ConfigSource]
    ) -> [String] {
        let fileValues = namedLayers.filter { $0.layer != .process }.map(\.values)
        return retiredKeys.filter { key in
            fileValues.contains { !($0[key] ?? "").isEmpty }
        }
    }

    /// The first layer with a non-empty value for each known key — the same "first hit wins
    /// per key" walk `load(layers:cwd:)` does, recorded instead of applied.
    static func sources(
        namedLayers: [ConfigSource]
    ) -> [String: ConfigLayer] {
        var result: [String: ConfigLayer] = [:]
        for key in knownKeys {
            for source in namedLayers where !(source.values[key] ?? "").isEmpty {
                result[key] = source.layer ?? .fallback
                break
            }
        }
        return result
    }

    /// Keys the App Support file supplied a *different* value for than `<cwd>/.env` did.
    ///
    /// Two exclusions keep this to the cases worth saying out loud. A key an earlier layer wins
    /// is not listed: nothing is being taken away from the checkout. Neither is a key the two
    /// files agree on — after `make install-env` they agree on nearly everything, and warning
    /// about a value that is the same either way would bury the one that is not. Both `DATA_DIR`
    /// values are already absolute here (`fileLayer` resolved them), so the comparison is fair.
    static func appSupportOverrides(
        namedLayers: [ConfigSource]
    ) -> [String] {
        let winners = sources(namedLayers: namedLayers)
        let appSupportValues = namedLayers.first { $0.layer == .appSupport }?.values ?? [:]
        let cwdValues = namedLayers.first { $0.layer == .cwd }?.values ?? [:]
        return knownKeys.filter { key in
            guard winners[key] == .appSupport, let mine = cwdValues[key], !mine.isEmpty else {
                return false
            }
            return appSupportValues[key] != mine
        }
    }

    /// One `.env` file as a layer. A relative `DATA_DIR` in a file means "next to this file",
    /// not "wherever the process happens to be running": the bundled app is launched by
    /// LaunchServices with `/` as its working directory, so the documented default `./data` in
    /// `~/Library/Application Support/Worklens/.env` (or in the file `WORKLENS_ENV_FILE` names)
    /// would otherwise resolve to `/data` and the app would come up unable to open it. For the
    /// `<cwd>/.env` layer the two readings are the same path.
    static func fileLayer(_ url: URL) -> [String: String] {
        var values = DotEnv.load(contentsOf: url)
        if let dir = values["DATA_DIR"], !dir.isEmpty, !dir.hasPrefix("/"), !dir.hasPrefix("~") {
            values["DATA_DIR"] = expandPath(dir, cwd: url.deletingLastPathComponent()).path
        }
        return values
    }

    /// Loads from already-resolved layers, unnamed — the shape tests use. Errors carry the key
    /// and the value but no file, because these layers have none.
    public static func load(
        layers: [[String: String]],
        cwd: URL = Config.currentDirectory,
        isBundledApp: Bool = Config.isBundledApp
    ) throws -> Config {
        try load(
            sources: layers.map { ConfigSource(layer: nil, url: nil, values: $0) },
            cwd: cwd,
            isBundledApp: isBundledApp
        ).config
    }

    /// Loads from named layers, collecting **every** error before throwing (#126).
    ///
    /// Two things changed here and both matter to the person with the typo. The loop no longer
    /// stops at the first bad key — a `.env` with three mistakes used to take three edit-and-
    /// relaunch rounds to fix — and each error is wrapped in `.located`, so the message names
    /// the file to open rather than leaving the user to guess which of five layers it came from.
    ///
    /// `lenient` is "use defaults for these keys and start": a key whose value does not parse is
    /// dropped, its built-in default stands for this session, every other value is kept, and the
    /// drop is recorded as a warning. Nothing is written anywhere — `.env` stays the source of
    /// truth and still says exactly what it said.
    public static func load(
        sources: [ConfigSource],
        cwd: URL = Config.currentDirectory,
        isBundledApp: Bool = Config.isBundledApp,
        lenient: Bool = false
    ) throws -> (config: Config, warnings: [ConfigWarning], droppedKeys: [String]) {
        func raw(_ key: String) -> (value: String, source: ConfigSource)? {
            for source in sources {
                if let value = source.values[key], !value.isEmpty { return (value, source) }
            }
            return nil
        }
        var c = Config.defaults(cwd: cwd, isBundledApp: isBundledApp)
        var errors: [ConfigError] = []
        var warnings: [ConfigWarning] = []
        var dropped: [String] = []
        // One dispatch over `Config.keys`, so a key that is in the registry is parsed and a key
        // that is not cannot be read by accident. Empty means "not set" (that is what `raw`
        // enforces), so a key no layer sets keeps its default rather than being overwritten.
        for key in Config.keys {
            guard let apply = key.apply, let hit = raw(key.name) else { continue }
            let checked = check(key, value: hit.value)
            warnings.append(contentsOf: checked.warnings)
            do {
                if let rule = checked.error { throw rule }
                try apply(&c, hit.value, cwd)
            } catch let error as ConfigError {
                if lenient {
                    dropped.append(key.name)
                    warnings.append(.usingDefault(key: key.name))
                } else if let layer = hit.source.layer {
                    errors.append(.located(error, layer: layer, file: hit.source.url))
                } else {
                    errors.append(error)
                }
            }
        }
        if let first = errors.first {
            throw errors.count == 1 ? first : ConfigError.multiple(errors)
        }
        return (c, warnings, dropped)
    }

    /// The registry's own rules, beyond "does it parse" (#126).
    ///
    /// Split by severity on purpose. An interval below the floor the code silently clamps to
    /// is a value the user has to fix — fatal. A
    /// model id that is in no price-table row is not: `ModelPricing.default` is a pinned,
    /// date-verified table, so a brand-new Gemini or Claude id is a row nobody has added yet,
    /// and refusing to launch over it would be the worst possible answer. It costs calls at $0,
    /// and saying so in the menu, the banner and `config-dump` is the fix.
    static func check(_ key: ConfigKey, value: String) -> (error: ConfigError?, warnings: [ConfigWarning]) {
        var warnings: [ConfigWarning] = []
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        switch key.kind {
        case .model:
            if ModelPricing.default.rate(for: trimmed) == nil {
                warnings.append(.unknownModel(key: key.name, model: trimmed))
            }
        case let .regexList(separator):
            // A comma is legal inside a quantifier such as `{2,3}`, so these two keys can never
            // accept it as a separator. When the value has one and no separator at all, the user
            // has almost certainly written a list the way the other list keys take one.
            if trimmed.contains(","), !trimmed.contains(separator) {
                warnings.append(.listSeparator(key: key.name))
            }
        default:
            break
        }
        if key.name == "MEMO_REPOS",
           (Config.list(trimmed, separator: ",") ?? []).map(MemoOutputs.repoName).contains(where: { !$0.contains("/") }) {
            warnings.append(.repoWithoutOwner(key: key.name))
        }
        // #242: one bounds check for both ends, so the stepper that reads `key.range` and
        // `worklens config set` refuse the same number with the same sentence.
        if key.minimum != nil || key.maximum != nil, let number = Double(trimmed),
           number < (key.minimum ?? -.infinity) || number > (key.maximum ?? .infinity) {
            return (
                .outOfRange(
                    key: key.name,
                    value: value,
                    range: ConfigKey.rangeText(minimum: key.minimum, maximum: key.maximum)
                ),
                warnings
            )
        }
        return (nil, warnings)
    }

    /// Names some **file** set that are in no `Config.keys` entry (#126).
    ///
    /// Non-fatal, and deliberately so: `Config` has always ignored what it does not know
    /// (`docs/decisions.md`, #87), and that stays true. All this does is stop the ignoring being
    /// silent, the same way the retired-key warning already does — a `CAPTURE_INTERVAL_SECS=30`
    /// looks applied until something names it.
    ///
    /// The process environment is not searched, for the same reason `retiredKeysSet` does not:
    /// a shell holds hundreds of variables that are none of Worklens's business, and flagging
    /// `PATH` would bury the one line worth reading. Retired keys are excluded too — they have
    /// their own #87 sentence, which says more than "unknown" would.
    static func unknownKeysSet(sources: [ConfigSource]) -> [ConfigProvenance.UnknownKey] {
        let known = Set(knownKeys)
        let retired = Set(retiredKeys)
        var seen: Set<String> = []
        var result: [ConfigProvenance.UnknownKey] = []
        for source in sources {
            guard let layer = source.layer, layer != .process else { continue }
            for name in source.values.keys.sorted() {
                guard !known.contains(name), !retired.contains(name),
                      !Config.ignoredUnknownKeys.contains(name),
                      !(source.values[name] ?? "").isEmpty,
                      seen.insert(name).inserted
                else { continue }
                result.append(
                    ConfigProvenance.UnknownKey(
                        name: name,
                        suggestion: nearestKnownKey(name),
                        layer: layer,
                        url: source.url
                    )
                )
            }
        }
        return result
    }

    /// Names a `.env` may legitimately carry that are not settings. `WORKLENS_ENV_FILE` is read
    /// from the process environment only, but writing it in a file is a reasonable mistake and
    /// calling it a typo would be wrong.
    static let ignoredUnknownKeys: Set<String> = ["WORKLENS_ENV_FILE"]

    /// The closest known key within an edit distance of three, or nil. Three is what turns
    /// `CAPTURE_INTERVAL_SECS` into a suggestion and leaves `MY_OWN_VARIABLE` alone.
    static func nearestKnownKey(_ name: String) -> String? {
        let upper = name.uppercased()
        var best: (key: String, distance: Int)?
        for candidate in knownKeys {
            let distance = editDistance(upper, candidate.uppercased())
            guard distance <= 3 else { continue }
            if best == nil || distance < best!.distance { best = (candidate, distance) }
        }
        return best?.key
    }

    /// Levenshtein distance, two rows rather than a matrix. Key names are short.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let first = Array(a), second = Array(b)
        if first.isEmpty { return second.count }
        if second.isEmpty { return first.count }
        var previous = Array(0...second.count)
        var current = previous
        for i in 1...first.count {
            current[0] = i
            for j in 1...second.count {
                let substitution = previous[j - 1] + (first[i - 1] == second[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[second.count]
    }

    /// Whether `value` is a legal setting for `key`, without touching any file. `SettingsStore`
    /// runs this before every write, so an invalid value is refused where it is typed rather
    /// than at the next launch.
    public static func validate(key: String, value: String) throws {
        guard let entry = Config.key(named: key), let apply = entry.apply else {
            throw ConfigError.unknownKey(key: key)
        }
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ConfigError.emptyValue(key: key)
        }
        // #126: the same rules the loader applies, so a `LOG_LEVEL=shouty` is refused where it
        // is typed rather than accepted here and silently ignored for weeks.
        if let rule = check(entry, value: value).error { throw rule }
        var probe = Config.defaults(cwd: Config.currentDirectory)
        try apply(&probe, value, Config.currentDirectory)
    }

    // MARK: Paths

    /// The process working directory as a URL. (Foundation only exposes `currentDirectoryPath`.)
    public static var currentDirectory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    /// The identifier `Resources/Info.plist` gives the bundled app. Matching on it — rather than
    /// on "has any bundle identifier at all" — is what keeps `swift run`, the CLI and the test
    /// runner on `./data`: those either have no identifier or have somebody else's.
    public static let bundleIdentifier = "dev.worklens.app"

    /// True in `Worklens.app`, false under `swift run`, the CLI and the tests.
    public static var isBundledApp: Bool {
        Bundle.main.bundleIdentifier == Config.bundleIdentifier
    }

    /// `~/Library/Application Support/Worklens` — the app's own corner of the disk, and the only
    /// place it writes without being told to.
    public static func appSupportDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Worklens")
    }

    public static func appSupportEnvURL() -> URL {
        appSupportDir().appendingPathComponent(".env")
    }

    /// Where a bundled app keeps its data when no layer says otherwise (#116).
    public static func appSupportDataDir() -> URL {
        appSupportDir().appendingPathComponent("data")
    }

    /// Expands a leading `~`, then resolves relative paths against `cwd`.
    public static func expandPath(_ path: String, cwd: URL) -> URL {
        var p = path
        if p == "~" || p.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            p = home + String(p.dropFirst(1))
        }
        if p.hasPrefix("/") { return URL(fileURLWithPath: p).standardizedFileURL }
        return URL(fileURLWithPath: p, relativeTo: cwd).standardizedFileURL
    }

    // MARK: Derived data-directory paths

    public var screenshotsDir: URL { dataDir.appendingPathComponent("screenshots") }
    public var timelineDir: URL { dataDir.appendingPathComponent("timeline") }
    public var contextDir: URL { dataDir.appendingPathComponent("context") }
    public var logsDir: URL { dataDir.appendingPathComponent("logs") }
    public var databaseURL: URL { dataDir.appendingPathComponent("worklens.sqlite") }

    // MARK: Parsing helpers

    static func int(_ key: String, _ value: String?, default def: Int) throws -> Int {
        guard let value else { return def }
        guard let parsed = Int(value.trimmingCharacters(in: .whitespaces)) else {
            throw ConfigError.invalidInt(key: key, value: value)
        }
        return parsed
    }

    static func double(_ key: String, _ value: String?, default def: Double) throws -> Double {
        guard let value else { return def }
        guard let parsed = Double(value.trimmingCharacters(in: .whitespaces)) else {
            throw ConfigError.invalidDouble(key: key, value: value)
        }
        return parsed
    }

    static func unitDouble(_ key: String, _ value: String?, default def: Double) throws -> Double {
        let parsed = try double(key, value, default: def)
        guard (0...1).contains(parsed) else {
            throw ConfigError.outOfRange(key: key, value: value ?? "\(parsed)", range: "0...1")
        }
        return parsed
    }

    static func bool(_ key: String, _ value: String?, default def: Bool) throws -> Bool {
        guard let value else { return def }
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: throw ConfigError.invalidBool(key: key, value: value)
        }
    }

    static func enumValue<T: RawRepresentable & CaseIterable>(
        _ key: String, _ value: String?, default def: T
    ) throws -> T where T.RawValue == String {
        guard let value else { return def }
        guard let parsed = T(rawValue: value.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw ConfigError.invalidEnum(key: key, value: value, allowed: T.allCases.map(\.rawValue))
        }
        return parsed
    }

    static func list(_ value: String?, separator: Character) -> [String]? {
        list(value, separators: [separator])
    }

    /// #126: the two plain list keys — bundle ids and URL hosts — take either `,` or `;`,
    /// because neither a bundle id nor a hostname can legitimately contain one and everybody
    /// mistypes the separator eventually. The two regex keys are **not** given this: a comma is
    /// legal inside a quantifier such as `{2,3}`, so splitting on one would quietly corrupt the
    /// pattern. Those stay single-separator and warn when a value looks comma-separated.
    static func list(_ value: String?, separators: [Character]) -> [String]? {
        guard let value else { return nil }
        let parts = value.split(whereSeparator: { separators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [] : parts
    }
}

// MARK: - Redacted dump

public extension Config {
    /// Masks a secret so it is safe to print: keeps a short prefix, replaces the rest.
    static func mask(_ secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return "(unset)" }
        let prefix = String(secret.prefix(7))
        return "\(prefix)****"
    }

    /// Every key with its resolved value and the layer that supplied it, secrets masked.
    func dumpLines(provenance: ConfigProvenance) -> [(key: String, value: String, source: ConfigLayer)] {
        dumpLines.map { ($0.key, $0.value, provenance.source(of: $0.key)) }
    }

    /// Every key with its resolved value, secrets masked, in `Config.keys` order — which is
    /// `.env.example`'s order, so the dump and the documented file read the same way down.
    var dumpLines: [(key: String, value: String)] {
        Config.keys.compactMap { key in key.read.map { (key.name, $0(self)) } }
    }
}
