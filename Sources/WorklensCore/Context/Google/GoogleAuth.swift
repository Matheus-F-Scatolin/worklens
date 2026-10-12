import AppKit
import Foundation

/// OAuth for the Google sources: Authorization Code + PKCE through a loopback redirect, with the
/// refresh token in the Keychain.
///
/// No SDK and no embedded web view — the user signs in in their own browser, sees their own
/// address bar, and can revoke Worklens at myaccount.google.com like any other app. The only
/// thing kept afterwards is a refresh token under `dev.worklens.google`, keyed by the Google
/// address it belongs to.
///
/// The scope is deliberately the narrowest that works: `calendar.readonly`. A grant made before
/// 2026-09-23 also carries a mail scope for the source that was removed then; its refresh token
/// keeps working for Calendar, and the grant can be narrowed at myaccount.google.com/permissions.
public actor GoogleAuth {
    public static let service = "dev.worklens.google"
    public static let authorizeEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    public static let userInfoEndpoint = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!

    public static let scopes = [
        "https://www.googleapis.com/auth/calendar.readonly",
        "openid",
        "email",
    ]

    /// Refresh this long before the access token actually expires.
    public static let refreshMargin: TimeInterval = 60

    /// What the Keychain holds, as one JSON blob.
    public struct Tokens: Codable, Sendable, Equatable {
        public var accessToken: String
        public var refreshToken: String
        public var expiresAt: Date
        public var email: String
        public var scope: String?

        public func isFresh(at now: Date, margin: TimeInterval = GoogleAuth.refreshMargin) -> Bool {
            expiresAt.timeIntervalSince(now) > margin
        }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notConfigured
        case notConnected
        case stateMismatch
        case declined(String)
        case noRefreshToken
        case invalidGrant

        public var description: String {
            switch self {
            case .notConfigured:
                return "GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET are not set"
            case .notConnected:
                return "Google is not connected yet."
            case .stateMismatch:
                return "the OAuth callback did not match the request it answered; nothing was stored"
            case let .declined(reason):
                return "authorization was declined (\(reason))"
            case .noRefreshToken:
                return "Google returned no refresh token. Revoke Worklens at "
                    + "myaccount.google.com/permissions and connect again."
            case .invalidGrant:
                // #139: no terminal command. The consent screen stays in Testing, so Google
                // expires the grant every seven days, and the answer is a button in Settings.
                return "Your Google sign-in expired: reconnect to start syncing again."
            }
        }
    }

    /// Whether this failure means the stored grant is dead and only a new consent fixes it —
    /// the one condition Settings and the menu offer a Reconnect button for (#139). A typed
    /// question, never a match on a rendered sentence: `SourceStatus.lastError` is a `String`
    /// that exists to be read, not to be parsed.
    public static func needsReconnect(_ error: any Error) -> Bool {
        guard let failure = error as? Failure else { return false }
        switch failure {
        case .invalidGrant: return true
        case .notConfigured, .notConnected, .stateMismatch, .declined, .noRefreshToken: return false
        }
    }

    private let config: Config
    private let http: ContextHTTP
    private let now: @Sendable () -> Date
    private let openURL: @Sendable (URL) -> Void
    /// Injected so tests can drive the flow without a browser or a socket.
    private let makeReceiver: @Sendable () throws -> LoopbackReceiver
    /// Whichever store `GOOGLE_TOKEN_STORE` names in production, memory in tests — a test suite
    /// must not write to the login keychain, and certainly must not prompt for it. Left nil it is
    /// built from the config, which is why that default is in the body and not the signature.
    private nonisolated let tokens: any GoogleTokenStore
    /// Where the connected address is kept outside the Keychain, so status can name the account
    /// without a decrypt that a rebuilt, ad-hoc-signed binary would prompt for (#36).
    private nonisolated let account: any GoogleAccountRecord
    /// The listener of the flow that is running right now, held so `cancelConnect()` can stop it
    /// while `connect` is suspended in `await receiver.wait` (#139). The actor is reentrant at
    /// that suspension, which is the only reason a cancel can get in at all; it is cleared on
    /// every exit path — success, decline, timeout and cancel alike — so a stale receiver can
    /// never be handed a second flow's cancel.
    /// A Cancel that arrived before `connect` had a receiver to hand it to. Cleared at the top
    /// of every flow, so a stale one cannot cancel the next.
    private var cancelRequested = false

    private var liveReceiver: LoopbackReceiver?
    /// The consent URL of that flow, so "Open the consent page again" reopens the same one
    /// rather than starting a second listener.
    private var liveConsentURL: URL?

    public init(
        config: Config,
        http: ContextHTTP = ContextHTTP(minimumSpacing: 0),
        tokens: (any GoogleTokenStore)? = nil,
        account: (any GoogleAccountRecord)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        openURL: @escaping @Sendable (URL) -> Void = { NSWorkspace.shared.open($0) },
        makeReceiver: @escaping @Sendable () throws -> LoopbackReceiver = { try LoopbackReceiver() }
    ) {
        self.config = config
        self.http = http
        self.tokens = tokens ?? GoogleAuth.store(for: config)
        self.account = account ?? AppStateGoogleAccountRecord(dataDir: config.dataDir)
        self.now = now
        self.openURL = openURL
        self.makeReceiver = makeReceiver
    }

    public nonisolated var isConfigured: Bool {
        !(config.googleClientID ?? "").isEmpty && !(config.googleClientSecret ?? "").isEmpty
    }

    /// The store `GOOGLE_TOKEN_STORE` asks for. Switching the key does not move an existing
    /// grant: the new store simply has none, so connecting runs again — which is also the
    /// only way to revoke the old one at Google, hence the order docs/user/integrations.md gives.
    public static func store(for config: Config) -> any GoogleTokenStore {
        switch config.googleTokenStore {
        case .keychain: KeychainTokenStore()
        case .file: FileTokenStore(dataDir: config.dataDir)
        }
    }

    /// Which store actually holds a grant on this Mac, or nil when neither does.
    ///
    /// Switching `GOOGLE_TOKEN_STORE` does not move a grant, so the configured store and the one
    /// a grant is really in can disagree — and a control that names the store has to name the
    /// real one (#139). Asks the configured store first, so a grant in both is reported as the
    /// configured one. Neither question decrypts anything, so neither can raise a prompt.
    public static func storeHoldingGrant(config: Config) -> GoogleTokenStorage? {
        let ordered = [config.googleTokenStore]
            + GoogleTokenStorage.allCases.filter { $0 != config.googleTokenStore }
        return ordered.first { candidate in
            var probe = config
            probe.googleTokenStore = candidate
            return ((try? store(for: probe).hasGrant()) ?? false)
        }
    }

    /// Whether a grant is on this machine, without touching the network — and, on the Keychain
    /// path, without decrypting the secret either, so asking cannot raise an access prompt.
    /// Sync and nonisolated so `CalendarSource.isConfigured` can ask it.
    public nonisolated var hasStoredGrant: Bool { (try? tokens.hasGrant()) ?? false }

    /// The connected address as recorded in `app_state` — never a Keychain read.
    public nonisolated var accountOnRecord: String? { account.address() }

    // MARK: Connect

    /// Runs the whole browser flow and stores the result. Returns the connected address.
    @discardableResult
    public func connect(timeout: TimeInterval = LoopbackReceiver.defaultTimeout) async throws -> String {
        guard let clientID = config.googleClientID, !clientID.isEmpty,
              let clientSecret = config.googleClientSecret, !clientSecret.isEmpty
        else { throw Failure.notConfigured }

        let pkce = PKCE()
        let state = PKCE.randomState()
        cancelRequested = false
        let receiver = try makeReceiver()
        let redirectURI = try await receiver.start()
        if cancelRequested {
            // Cancel arrived while the listener was still coming up, before there was a receiver
            // to hand it. Nothing has been opened yet, and nothing will be (#139).
            cancelRequested = false
            await receiver.stop()
            throw LoopbackReceiver.Failure.cancelled
        }

        let url = GoogleAuth.authorizationURL(
            clientID: clientID, redirectURI: redirectURI, challenge: pkce.challenge, state: state
        )
        liveReceiver = receiver
        liveConsentURL = url
        Log.net.info("opening the Google consent screen in your browser")
        openURL(url)

        let callback: LoopbackReceiver.Callback
        do {
            callback = try await receiver.wait(timeout: timeout)
            endFlow(receiver)
        } catch {
            await receiver.stop()
            endFlow(receiver)
            throw error
        }

        if let error = callback.error { throw Failure.declined(error) }
        guard callback.state == state else { throw Failure.stateMismatch }
        guard let code = callback.code else { throw Failure.declined("no authorization code") }

        let response = try await http.postForm(GoogleAuth.tokenEndpoint, fields: [
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": pkce.verifier,
        ], unauthorizedHint: "Google rejected the client credentials; check GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET")

        guard let accessToken = response["access_token"]?.stringValue else {
            throw ContextSyncError.decode("the token response carried no access_token")
        }
        guard let refreshToken = response["refresh_token"]?.stringValue else {
            throw Failure.noRefreshToken
        }
        let email = try await email(accessToken: accessToken)
        let tokens = Tokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(response["expires_in"]?.numberValue ?? 3600),
            email: email,
            scope: response["scope"]?.stringValue
        )
        try store(tokens)
        account.remember(email)
        Log.net.info("Google connected")
        return email
    }

    /// Stop the flow that is running: the Cancel button in Settings → Integrations. The suspended
    /// `connect` throws `LoopbackReceiver.Failure.cancelled`, and nothing is stored.
    public func cancelConnect() async {
        guard let receiver = liveReceiver else {
            // `connect` is inside `receiver.start()`, whose readiness loop can poll for two
            // seconds: there is no receiver to hand the cancel to yet, so leave it a note rather
            // than returning silently and stranding the pane on the spinner (#139).
            cancelRequested = true
            return
        }
        await receiver.cancel()
        endFlow(receiver)
    }

    /// Reopen the consent page of the flow that is still waiting — the browser tab was closed,
    /// or the redirect went to a window the user has since lost. Same listener, same state, so
    /// the callback that comes back is still the one `connect` is waiting for.
    /// Returns false when no flow is running.
    @discardableResult
    public func reopenConsentPage() -> Bool {
        guard let url = liveConsentURL else { return false }
        openURL(url)
        return true
    }

    /// Whether a browser flow is waiting for its callback right now.
    public var isConnecting: Bool { liveReceiver != nil }

    /// Clears the live flow, but only when it is still this one: `connect` and `cancelConnect`
    /// both come through here, and a late `connect` must not wipe a newer flow's receiver.
    private func endFlow(_ receiver: LoopbackReceiver) {
        guard liveReceiver === receiver else { return }
        liveReceiver = nil
        liveConsentURL = nil
    }

    /// The consent URL. `access_type=offline` + `prompt=consent` is what makes Google hand over a
    /// refresh token rather than an access token that dies in an hour.
    public static func authorizationURL(
        clientID: String, redirectURI: String, challenge: String, state: String
    ) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    // MARK: Using the connection

    /// A valid access token, refreshing first when the stored one is about to expire.
    public func token() async throws -> String {
        guard var tokens = try stored() else { throw Failure.notConnected }
        if tokens.isFresh(at: now()) { return tokens.accessToken }
        tokens = try await refresh(tokens)
        return tokens.accessToken
    }

    private func refresh(_ tokens: Tokens) async throws -> Tokens {
        guard let clientID = config.googleClientID, let clientSecret = config.googleClientSecret else {
            throw Failure.notConfigured
        }
        let response: JSONValue
        do {
            response = try await http.postForm(GoogleAuth.tokenEndpoint, fields: [
                "client_id": clientID,
                "client_secret": clientSecret,
                "refresh_token": tokens.refreshToken,
                "grant_type": "refresh_token",
            ])
        } catch let error as ContextSyncError {
            // Google answers a dead refresh token with 400 `invalid_grant`, not a 401.
            if case let .http(status, body) = error, status == 400, body.contains("invalid_grant") {
                throw Failure.invalidGrant
            }
            throw error
        }

        guard let accessToken = response["access_token"]?.stringValue else {
            throw ContextSyncError.decode("the refresh response carried no access_token")
        }
        var refreshed = tokens
        refreshed.accessToken = accessToken
        refreshed.expiresAt = now().addingTimeInterval(response["expires_in"]?.numberValue ?? 3600)
        // A refresh usually returns no new refresh token; keep the one we have when it does not.
        if let rotated = response["refresh_token"]?.stringValue { refreshed.refreshToken = rotated }
        try store(refreshed)
        return refreshed
    }

    private func email(accessToken: String) async throws -> String {
        let json = try await http.get(
            GoogleAuth.userInfoEndpoint, headers: ["Authorization": "Bearer \(accessToken)"]
        )
        return json["email"]?.stringValue?.nonEmpty ?? "unknown"
    }

    // MARK: Disconnect

    /// Revokes the grant at Google, then forgets it locally. The local half happens even if the
    /// network half fails — "Disconnect" must always disconnect.
    public func disconnect() async throws {
        guard let grant = try stored() else {
            // Nothing to revoke, but a record from an older connect should not outlive the item.
            account.forget()
            return
        }
        defer {
            try? tokens.clear(email: grant.email)
            account.forget()
        }
        _ = try? await http.postForm(GoogleAuth.revokeEndpoint, fields: ["token": grant.refreshToken])
        Log.net.info("Google disconnected")
    }

    // MARK: Keychain

    func stored() throws -> Tokens? { try tokens.load() }

    func store(_ value: Tokens) throws { try tokens.save(value) }
}

// MARK: - Where the grant lives

/// Somewhere to keep one Google grant. One implementation writes the Keychain; the other is a
/// dictionary, so tests can exercise refresh without a login-keychain prompt.
public protocol GoogleTokenStore: Sendable {
    /// Is there a grant here? Answered without reading the secret where that is possible.
    func hasGrant() throws -> Bool
    func load() throws -> GoogleAuth.Tokens?
    func save(_ tokens: GoogleAuth.Tokens) throws
    func clear(email: String) throws
}

public struct KeychainTokenStore: GoogleTokenStore {
    public init() {}

    /// Attributes only — `kSecReturnAttributes` does not touch the encrypted payload, so this
    /// never prompts for Keychain access the way reading the secret can.
    public func hasGrant() throws -> Bool {
        try Keychain.firstAccount(service: GoogleAuth.service) != nil
    }

    public func load() throws -> GoogleAuth.Tokens? {
        guard let account = try Keychain.firstAccount(service: GoogleAuth.service),
              let data = try Keychain.get(service: GoogleAuth.service, account: account)
        else { return nil }
        return try? JSONDecoder.google.decode(GoogleAuth.Tokens.self, from: data)
    }

    public func save(_ tokens: GoogleAuth.Tokens) throws {
        try Keychain.set(
            try JSONEncoder.google.encode(tokens),
            service: GoogleAuth.service,
            account: tokens.email
        )
    }

    public func clear(email: String) throws {
        try Keychain.delete(service: GoogleAuth.service, account: email)
    }
}

/// For tests, and for a `--dry-run` that must not touch the Keychain.
public final class InMemoryTokenStore: GoogleTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: GoogleAuth.Tokens?

    public init(_ tokens: GoogleAuth.Tokens? = nil) { self.tokens = tokens }

    public func hasGrant() throws -> Bool { lock.withLock { tokens != nil } }
    public func load() throws -> GoogleAuth.Tokens? { lock.withLock { tokens } }
    public func save(_ value: GoogleAuth.Tokens) throws { lock.withLock { tokens = value } }
    public func clear(email: String) throws { lock.withLock { tokens = nil } }
}

extension JSONEncoder {
    static let google: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let google: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
