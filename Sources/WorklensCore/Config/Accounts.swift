import Foundation

/// The two API keys Worklens cannot run without, as the Settings window shows them (#124).
///
/// Everything here is pure: a row is a function of the loaded `Config` and its `ConfigProvenance`,
/// so the view draws it and the tests assert it. The secret itself never appears — a row carries
/// `Config.mask`'s seven-character prefix, the same string `config-dump` prints — and nothing in
/// this file logs anything at all.
///
/// **Where a key is written.** Settings writes `SettingsStore`
/// (`~/Library/Application Support/Worklens/settings.json`, mode 0600), which is its own
/// `ConfigLayer` so the app, the CLI and the MCP server — one binary — agree about what the key
/// is. That layer outranks both `.env` files and loses to the process environment and to
/// `WORKLENS_ENV_FILE`, which is what worktrees, tests and `make install-env` rely on (#34). When
/// a layer *above* the store supplies the key the row says so and offers no edit; when a layer
/// *below* it does, the row says which file it came from rather than silently shadowing it.
///
/// The Keychain would be the better home and is not usable here: keychain access is bound to the
/// reading binary's exact code hash, so every rebuild of a self-signed build raises the access
/// dialog again. See `docs/decisions.md`, "The Keychain dialog after a rebuild cannot be fixed in
/// code" — when a Developer ID exists, move these two values there.
public enum Accounts {
    /// The rows the section shows. Gemini is the one key left since the reports were cut
    /// (2026-10-05) and the Anthropic key with them.
    public static let providers: [KeyProvider] = [.gemini]

    public static func rows(config: Config, provenance: ConfigProvenance) -> [AccountRow] {
        providers.map { row($0, config: config, provenance: provenance) }
    }

    public static func row(
        _ provider: KeyProvider, config: Config, provenance: ConfigProvenance
    ) -> AccountRow {
        let value = provider.value(in: config)
        let isSet = !(value ?? "").isEmpty
        return AccountRow(
            provider: provider,
            masked: isSet ? Config.mask(value) : AccountRow.unsetText,
            isSet: isSet,
            source: isSet ? provenance.source(of: provider.envKey) : .fallback
        )
    }

    // MARK: Entry

    /// What a pasted key becomes before anything else looks at it. Whitespace and newlines go —
    /// a key copied out of a console or a web page arrives with both — and nothing else is
    /// touched: a key is an opaque string and Worklens is not in a position to correct it.
    public static func normalize(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why a typed value cannot be saved at all. Shape is *not* one of these reasons — see
    /// `shapeWarning`.
    public static func entryError(_ value: String) -> String? {
        let normalized = normalize(value)
        if normalized.isEmpty { return "Nothing to save: paste the key first." }
        if normalized.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return "That has a space in the middle of it: the paste probably picked up more "
                + "than the key."
        }
        return nil
    }

    // MARK: One paste, one step (#246)

    /// How long a value has to be before arriving in one change is a paste rather than typing.
    /// Both keys are longer than this by a wide margin, and a person cannot type 16 characters
    /// between two `onChange`s.
    public static let pasteLength = 16

    /// True when a key field went from empty to a whole key in one change — a paste, ⌘V, or a
    /// drop. It is what lets the field save and verify with no button pressed, which is the
    /// two-step this collapsed: before it, the likeliest first run left a saved, unverified,
    /// silently wrong key.
    ///
    /// Conservative on purpose: typing never trips it, and Return still submits.
    public static func looksPasted(from old: String, to new: String) -> Bool {
        guard old.isEmpty else { return false }
        return normalize(new).count >= pasteLength
    }

    /// What a submitted value does, in the order it does it (#246): save it, say something about
    /// its shape, then ask the provider itself.
    ///
    /// The sequence is this function rather than the view's `@State` so that it is tested: the
    /// field writes `key` when there is one, draws `caption`, and asks the provider when
    /// `verifies` is true.
    public static func entry(_ typed: String, for provider: KeyProvider) -> AccountEntry {
        if let refusal = entryError(typed) {
            // Nothing saved and nothing asked: the field stays open on what was typed.
            return AccountEntry(
                key: nil, caption: AccountCaption(refusal, .problem), verifies: false
            )
        }
        let key = normalize(typed)
        guard key.hasPrefix(provider.expectedPrefix) else {
            // Saved anyway — providers change their prefixes, and a window that refuses a
            // working key is worse than one that says it looks wrong — and asked anyway,
            // because the provider's answer is the only one that settles it.
            return AccountEntry(
                key: key,
                caption: AccountCaption(
                    L10n.format(
                        "That does not look like a %1$@ key: they start with %2$@. It has been saved; check you pasted the whole thing.",
                        provider.displayName, provider.expectedPrefix
                    ),
                    .attention
                ),
                verifies: true
            )
        }
        return AccountEntry(key: key, caption: nil, verifies: true)
    }

    /// The one sentence the field shows once the provider has answered. It names the provider
    /// and the HTTP status the ledger row carries, and never a fragment of the key.
    public static func verdict(_ verification: AccountVerification) -> AccountCaption {
        let name = verification.provider.displayName
        switch verification.verdict {
        case .accepted:
            return AccountCaption(L10n.format("%@ recognises this key.", name), .ok)
        case .rejected:
            return AccountCaption(
                L10n.format(
                    "%1$@ refused this key (%2$@). Check you pasted the whole thing, and that its project has billing enabled.",
                    name, verification.line
                ),
                .problem
            )
        case .unreachable:
            return AccountCaption(
                L10n.format(
                    "Could not ask %1$@ (%2$@): a network problem, not necessarily the key.",
                    name, verification.line
                ),
                .attention
            )
        }
    }

    /// The shape check, as a caption rather than a refusal (the scope's "validates shape on
    /// save"). It is a warning on purpose: providers change their prefixes, and a Settings window
    /// that refuses a working key is worse than one that says "this does not look like the usual shape" and saves it.
    /// No network call — `Verify` is the thing that asks the provider.
    public static func shapeWarning(_ provider: KeyProvider, _ value: String) -> String? {
        let normalized = normalize(value)
        guard !normalized.isEmpty, !normalized.hasPrefix(provider.expectedPrefix) else { return nil }
        return "Saved, but \(provider.envKey) usually starts with \(provider.expectedPrefix): "
            + "check you pasted the whole key, then Verify."
    }
}

/// One sentence a key field shows, and how loud it is (#246). Never the key, never logged.
public struct AccountCaption: Sendable, Equatable {
    public let text: String
    public let level: StatusLevel

    public init(_ text: String, _ level: StatusLevel) {
        self.text = text
        self.level = level
    }
}

/// What a submitted key does next (#246). `key` is what to write — nil when nothing can be
/// saved — `caption` is what to say now, and `verifies` is whether to ask the provider.
public struct AccountEntry: Sendable, Equatable {
    public let key: String?
    public let caption: AccountCaption?
    public let verifies: Bool

    public init(key: String?, caption: AccountCaption?, verifies: Bool) {
        self.key = key
        self.caption = caption
        self.verifies = verifies
    }
}

/// A typed value that cannot be a key at all. Carries the sentence the field shows; it is never
/// the value, and it is never logged.
public struct AccountEntryError: Error, CustomStringConvertible, Equatable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

// MARK: - One row

/// One credential as the Accounts section draws it. No secret, ever: `masked` is
/// `Config.mask`'s prefix and nothing here can be turned back into a key.
public struct AccountRow: Sendable, Equatable {
    /// What the value column says when no layer sets the key.
    public static let unsetText = "Not set"

    public let provider: KeyProvider
    public let masked: String
    public let isSet: Bool
    /// Which layer won the key, or `.fallback` when nothing set it.
    public let source: ConfigLayer

    public init(provider: KeyProvider, masked: String, isSet: Bool, source: ConfigLayer) {
        self.provider = provider
        self.masked = masked
        self.isSet = isSet
        self.source = source
    }

    /// The row's own heading.
    public var label: String { provider.displayName }
    /// One line under the label: what this key buys.
    public var purpose: String { provider.purpose }

    /// False when a layer Worklens cannot write past supplies the value. Editing then would
    /// change a file nobody reads, which is worse than saying so.
    public var isEditable: Bool {
        switch source {
        case .process, .explicitFile: return false
        default: return true
        }
    }

    /// True when Worklens's own settings file is what holds this key — the only case where
    /// "Remove" has anything to remove.
    public var isStored: Bool { isSet && source == .appSettings }

    /// Whether the row needs a **Verify** button of its own (#246).
    ///
    /// A key pasted here is verified as it is pasted, so the button would be a second press for
    /// an answer the field has already given. A key that came from `.env`, from the environment
    /// or from the file `WORKLENS_ENV_FILE` names had no paste to hook onto — that is the one
    /// case where asking the provider has to stay something you can press.
    public var offersVerify: Bool { isSet && source != .appSettings }

    public var status: StatusLevel { isSet ? .ok : .problem }

    public var statusText: String { isSet ? "Set" : "Missing" }

    /// Where the winning value comes from, in words — the row's honest answer to "did my paste
    /// take?". Nil when Worklens's own store supplies it and there is nothing to explain.
    public var sourceNote: String? {
        guard isSet else { return provider.missingNote }
        switch source {
        case .appSettings, .fallback:
            return nil
        case .appSupport:
            return "Coming from ~/Library/Application Support/Worklens/.env. Saving here writes "
                + "Worklens's own settings file, which outranks it."
        case .cwd:
            return "Coming from the .env beside this checkout. Saving here writes Worklens's own "
                + "settings file, which outranks it."
        case .process:
            return "Set in the environment Worklens was launched with: that wins, so there is "
                + "nothing to change here."
        case .explicitFile:
            return "Set in the file WORKLENS_ENV_FILE names: that wins, so there is nothing to "
                + "change here."
        }
    }
}

// MARK: - The providers, as a person reads them

public extension KeyProvider {
    var displayName: String {
        switch self {
        case .gemini: return "Google Gemini"
        }
    }

    var purpose: String {
        switch self {
        case .gemini: return "Describes each screenshot."
        }
    }

    /// The one sentence a row with no key carries: what stops.
    var missingNote: String {
        switch self {
        case .gemini:
            // One key per provider rather than a translated frame around an English clause:
            // the interpolated half never reached a translator (#240 review).
            return L10n.string("Worklens cannot describe your screenshots until this is set.")
        }
    }

    func value(in config: Config) -> String? {
        switch self {
        case .gemini: return config.geminiAPIKey
        }
    }
}

// MARK: - Verify

/// One `Verify` press: what the provider answered, with the HTTP status the ledger row carries.
public struct AccountVerification: Sendable, Equatable {
    public let provider: KeyProvider
    public let verdict: KeyVerdict
    public let httpStatus: Int?

    public init(provider: KeyProvider, verdict: KeyVerdict, httpStatus: Int?) {
        self.provider = provider
        self.verdict = verdict
        self.httpStatus = httpStatus
    }

    /// What the button says afterwards: "OK", or the status the provider answered with. Never
    /// the key, and never a provider message that might quote the request.
    public var line: String {
        switch verdict {
        case .accepted:
            return httpStatus.map { $0 == 200 ? "OK" : "OK (HTTP \($0))" } ?? "OK"
        case .rejected:
            return httpStatus.map { "Rejected: HTTP \($0)" } ?? "Rejected"
        case .unreachable:
            return httpStatus.map { "Could not ask: HTTP \($0)" } ?? "Could not reach the provider"
        }
    }

    public var status: StatusLevel {
        switch verdict {
        case .accepted: return .ok
        case .rejected: return .problem
        case .unreachable: return .attention
        }
    }
}

/// The `Verify` button's logic: ask the provider's free models-list endpoint whether it knows
/// this key, and write the attempt to the ledger.
///
/// It goes through `KeyProbing`, so `make test` makes no network call — not once, not behind a
/// flag. Nothing is generated: both endpoints are `GET`s that bill no tokens, so the ledger row is
/// $0 and exists only so that a key check is as auditable as every other call Worklens makes.
public struct AccountVerifier: Sendable {
    /// Where a row goes. `CostTracker.record(_:)` in the app; a closure so the verifier needs no
    /// database to be tested, and so an actor's isolation stays the caller's problem.
    public typealias Recorder = @Sendable (LLMCall) async -> Void

    /// The `model` column for a call that names no model. The ledger is a table of calls, not of
    /// completions, and this is the endpoint that was called.
    public static let endpointName = "models"

    private let probes: any KeyProbing
    private let record: Recorder?
    private let now: @Sendable () -> Date
    private let identifier: @Sendable () -> String

    public init(
        probes: any KeyProbing = LiveKeyProbe(),
        record: Recorder? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        identifier: @escaping @Sendable () -> String = { Identifiers.new() }
    ) {
        self.probes = probes
        self.record = record
        self.now = now
        self.identifier = identifier
    }

    public func verify(_ provider: KeyProvider, key: String) async -> AccountVerification {
        let started = now()
        let probe = await probes.probeKey(provider, key: key)
        let elapsed = Int(now().timeIntervalSince(started) * 1000)
        let verification = AccountVerification(
            provider: provider, verdict: probe.verdict, httpStatus: probe.httpStatus
        )
        await record?(AccountVerifier.ledgerRow(
            verification,
            latencyMs: probe.latencyMs ?? max(elapsed, 0),
            at: started,
            id: identifier()
        ))
        return verification
    }

    /// The row a verify writes. Pure, so a test can read every field of it.
    ///
    /// Zero tokens and `costUsd: 0` — the endpoint bills nothing, and a purpose that cannot cost
    /// anything keeps `CostTracker.estimate` honest. A failure carries the status and nothing
    /// else: the provider's own words could quote the request.
    public static func ledgerRow(
        _ verification: AccountVerification, latencyMs: Int, at: Date, id: String
    ) -> LLMCall {
        let failure: String?
        switch verification.verdict {
        case .accepted: failure = nil
        case .rejected: failure = verification.httpStatus.map { "HTTP \($0)" } ?? "rejected"
        case .unreachable: failure = verification.httpStatus.map { "HTTP \($0)" } ?? "unreachable"
        }
        return LLMCall(
            id: id,
            provider: verification.provider.rawValue,
            model: AccountVerifier.endpointName,
            purpose: .verify,
            promptTokens: 0,
            outputTokens: 0,
            costUsd: 0,
            latencyMs: latencyMs,
            httpStatus: verification.httpStatus,
            error: failure,
            createdAt: at
        )
    }
}
