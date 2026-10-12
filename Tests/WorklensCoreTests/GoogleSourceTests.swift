import Foundation
import Testing
@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!
private let noon = ContextDates.parseISO8601("2026-09-07T12:00:00Z")!
private let window = DateInterval(
    start: ContextDates.parseISO8601("2026-09-06T00:00:00Z")!,
    end: ContextDates.parseISO8601("2026-09-08T00:00:00Z")!
)

private func googleConfig() -> Config {
    var config = Config.defaults()
    config.dataDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("worklens-google-\(UUID().uuidString)")
    config.googleClientID = "client-id.apps.googleusercontent.com"
    config.googleClientSecret = "GOCSPX-secret"
    return config
}

private func tokens(expiresAt: Date) -> GoogleAuth.Tokens {
    GoogleAuth.Tokens(
        accessToken: "ya29.old", refreshToken: "1//refresh",
        expiresAt: expiresAt, email: "you@example.com", scope: nil
    )
}

/// An auth that is already connected and whose token is fresh *at the fixed test clock* — pass
/// `now` or the real date makes the fixture token look expired and the source tries to refresh.
private func connectedAuth(_ config: Config) -> GoogleAuth {
    GoogleAuth(
        config: config,
        tokens: InMemoryTokenStore(tokens(expiresAt: noon.addingTimeInterval(3600))),
        now: { noon }
    )
}

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

// MARK: - PKCE

@Suite("PKCE")
struct PKCETests {
    @Test("the challenge is the base64url SHA-256 of the verifier")
    func knownVector() {
        // RFC 7636 §A.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCE(verifier: verifier).challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("a generated verifier is unreserved, long enough, and never repeats")
    func generation() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var seen: Set<String> = []
        for _ in 0..<50 {
            let verifier = PKCE.randomVerifier()
            #expect((43...128).contains(verifier.count))
            #expect(verifier.allSatisfy { allowed.contains($0) })
            #expect(seen.insert(verifier).inserted)
        }
    }

    @Test("base64url drops padding and swaps the URL-unsafe characters")
    func encoding() {
        #expect(!PKCE.base64URL(Data([251, 255, 190])).contains("="))
        #expect(!PKCE.base64URL(Data([251, 255, 190])).contains("+"))
        #expect(!PKCE.base64URL(Data([251, 255, 190])).contains("/"))
    }
}

// MARK: - Loopback callback

@Suite("LoopbackReceiver parsing")
struct LoopbackReceiverTests {
    private func request(_ target: String) -> String {
        "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:52341\r\nUser-Agent: test\r\n\r\n"
    }

    @Test("a well-formed callback yields the code and the state")
    func happyPath() {
        let callback = LoopbackReceiver.parse(request("/callback?code=4/abc&state=xyz"))
        #expect(callback?.code == "4/abc")
        #expect(callback?.state == "xyz")
        #expect(callback?.error == nil)
    }

    @Test("a declined consent screen comes back as an error, not a code")
    func declined() {
        let callback = LoopbackReceiver.parse(request("/callback?error=access_denied&state=xyz"))
        #expect(callback?.error == "access_denied")
        #expect(callback?.code == nil)
    }

    @Test("anything that is not a GET of /callback is not a callback")
    func rejectsOtherRequests() {
        #expect(LoopbackReceiver.parse(request("/favicon.ico")) == nil)
        #expect(LoopbackReceiver.parse(request("/")) == nil)
        #expect(LoopbackReceiver.parse("POST /callback?code=1 HTTP/1.1\r\n\r\n") == nil)
        #expect(LoopbackReceiver.parse("") == nil)
    }

    @Test("the page shown in the browser matches what happened")
    func responsePage() {
        #expect(LoopbackReceiver.page(for: .init(code: "1", state: "s", error: nil)).contains("connected"))
        #expect(LoopbackReceiver.page(for: .init(code: nil, state: nil, error: "access_denied"))
            .contains("declined"))
        #expect(LoopbackReceiver.page(for: nil).contains("not a Google callback"))
    }

    @Test("the callback page is themed, named and dark-mode aware (#139)")
    func responsePageIsThemed() {
        for page in [
            LoopbackReceiver.page(for: .init(code: "1", state: "s", error: nil)),
            LoopbackReceiver.page(for: .init(code: nil, state: nil, error: "access_denied")),
            LoopbackReceiver.page(for: nil),
        ] {
            #expect(page.contains("Worklens"))
            #expect(page.contains("prefers-color-scheme: dark"))
            #expect(page.contains("<!doctype html>"))
            // Nothing is fetched to render it: no script, no network font, no image.
            #expect(!page.contains("<script"))
            #expect(!page.contains("http://") && !page.contains("https://"))
        }
    }

    @Test("the connect window is five minutes, and the timeout says so in minutes (#139)")
    func timeoutIsFiveMinutes() {
        #expect(LoopbackReceiver.defaultTimeout == 300)
        #expect(LoopbackReceiver.Failure.timedOut(seconds: 300).description
            == "Google did not come back in 5 minutes.")
        #expect(LoopbackReceiver.Failure.timedOut(seconds: 60).description
            == "Google did not come back in 1 minute.")
        #expect(LoopbackReceiver.Failure.timedOut(seconds: 90).description
            == "Google did not come back in 90 seconds.")
    }
}

// MARK: - GoogleAuth

@Suite("GoogleAuth")
struct GoogleAuthTests {
    @Test("the authorization URL asks for S256, offline access and the narrow scopes")
    func authorizationURL() throws {
        let url = GoogleAuth.authorizationURL(
            clientID: "cid", redirectURI: "http://127.0.0.1:5000/callback",
            challenge: "chal", state: "st"
        )
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })

        #expect(url.absoluteString.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth"))
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"] == "chal")
        #expect(query["access_type"] == "offline")
        #expect(query["prompt"] == "consent")
        #expect(query["state"] == "st")
        #expect(query["response_type"] == "code")
        #expect(query["redirect_uri"] == "http://127.0.0.1:5000/callback")

        let scopes = (query["scope"] ?? "").split(separator: " ").map(String.init)
        #expect(scopes.contains("https://www.googleapis.com/auth/calendar.readonly"))
        // #285: the mail scope went with the Gmail source. Calendar is the only Google API asked.
        #expect(scopes == ["https://www.googleapis.com/auth/calendar.readonly", "openid", "email"])
    }

    @Test("a fresh token is used as-is; an expiring one is refreshed first")
    func refreshPath() async throws {
        let stub = Stub([.json("""
        {"access_token": "ya29.new", "expires_in": 3599, "scope": "openid email", "token_type": "Bearer"}
        """)])
        let store = InMemoryTokenStore(tokens(expiresAt: noon.addingTimeInterval(30)))
        let auth = GoogleAuth(
            config: googleConfig(),
            http: ContextHTTP(session: stub.session, minimumSpacing: 0, maxRetries: 0, sleeper: { _ in }),
            tokens: store,
            now: { noon }
        )

        #expect(try await auth.token() == "ya29.new", "30 s left is inside the refresh margin")
        let saved = try #require(try store.load())
        #expect(saved.accessToken == "ya29.new")
        #expect(saved.refreshToken == "1//refresh", "a refresh that returns no new refresh token keeps the old one")
        #expect(saved.expiresAt == noon.addingTimeInterval(3599))

        let body = try #require(stub.sent.first?.httpBody.map { String(decoding: $0, as: UTF8.self) })
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=1%2F%2Frefresh"))
    }

    @Test("a token with time left costs no request at all")
    func noNeedlessRefresh() async throws {
        let stub = Stub([])
        let auth = GoogleAuth(
            config: googleConfig(),
            http: ContextHTTP(session: stub.session, minimumSpacing: 0, maxRetries: 0, sleeper: { _ in }),
            tokens: InMemoryTokenStore(tokens(expiresAt: noon.addingTimeInterval(3600))),
            now: { noon }
        )
        #expect(try await auth.token() == "ya29.old")
        #expect(stub.sent.isEmpty)
    }

    @Test("a dead refresh token asks the user to reconnect instead of retrying forever")
    func invalidGrant() async throws {
        let stub = Stub([.json("""
        {"error": "invalid_grant", "error_description": "Token has been expired or revoked."}
        """, status: 400)])
        let auth = GoogleAuth(
            config: googleConfig(),
            http: ContextHTTP(session: stub.session, minimumSpacing: 0, maxRetries: 0, sleeper: { _ in }),
            tokens: InMemoryTokenStore(tokens(expiresAt: noon.addingTimeInterval(-10))),
            now: { noon }
        )
        await #expect(throws: GoogleAuth.Failure.invalidGrant) { _ = try await auth.token() }
    }

    @Test("with nothing stored, token() says to connect rather than throwing something opaque")
    func notConnected() async throws {
        let auth = GoogleAuth(config: googleConfig(), tokens: InMemoryTokenStore())
        #expect(!auth.hasStoredGrant)
        await #expect(throws: GoogleAuth.Failure.notConnected) { _ = try await auth.token() }
    }

    @Test("a callback whose state does not match is refused and stores nothing")
    func stateMismatch() async throws {
        let store = InMemoryTokenStore()
        // The receiver answers with a state the flow never issued.
        let receiver = try LoopbackReceiver()
        let auth = GoogleAuth(
            config: googleConfig(),
            http: ContextHTTP(session: Stub([]).session, minimumSpacing: 0, maxRetries: 0, sleeper: { _ in }),
            tokens: store,
            now: { noon },
            openURL: { _ in },
            makeReceiver: { receiver }
        )

        // Bring the listener up first so the test knows the port, then drive a real loopback
        // request at it — the same path a browser takes.
        let redirect = try await receiver.start()
        let connect = Task { try await auth.connect(timeout: 5) }

        var request = URLRequest(url: URL(string: "\(redirect)?code=4/abc&state=not-the-one")!)
        request.timeoutInterval = 5
        _ = try? await URLSession(configuration: .ephemeral).data(for: request)

        await #expect(throws: GoogleAuth.Failure.stateMismatch) { _ = try await connect.value }
        #expect(try store.load() == nil)
    }

    @Test("Cancel stops the flow that is waiting, and stores nothing (#139)")
    func cancelConnect() async throws {
        let store = InMemoryTokenStore()
        let receiver = try LoopbackReceiver()
        let auth = GoogleAuth(
            config: googleConfig(),
            http: ContextHTTP(session: Stub([]).session, minimumSpacing: 0, maxRetries: 0, sleeper: { _ in }),
            tokens: store,
            now: { noon },
            openURL: { _ in },
            makeReceiver: { receiver }
        )

        // A generous timeout: what ends this flow is the cancel, not the clock.
        let connect = Task { try await auth.connect(timeout: 300) }
        while await !auth.isConnecting { try await Task.sleep(nanoseconds: 5_000_000) }
        await auth.cancelConnect()

        await #expect(throws: LoopbackReceiver.Failure.cancelled) { _ = try await connect.value }
        #expect(try store.load() == nil)
        #expect(await !auth.isConnecting, "the receiver is cleared on every exit path")
        // Cancelling twice is not an error, and there is nothing left to cancel.
        await auth.cancelConnect()
    }

    @Test("the consent page can be reopened while the listener is still alive (#139)")
    func reopenConsentPage() async throws {
        let opened = OpenedURLs()
        let receiver = try LoopbackReceiver()
        let auth = GoogleAuth(
            config: googleConfig(),
            http: ContextHTTP(session: Stub([]).session, minimumSpacing: 0, maxRetries: 0, sleeper: { _ in }),
            tokens: InMemoryTokenStore(),
            now: { noon },
            openURL: { opened.append($0) },
            makeReceiver: { receiver }
        )
        // Nothing is running yet, so there is nothing to reopen.
        #expect(await auth.reopenConsentPage() == false)

        let connect = Task { try await auth.connect(timeout: 300) }
        while await !auth.isConnecting { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(await auth.reopenConsentPage())

        // The same URL both times: same listener, same state, same flow.
        #expect(opened.all.count == 2)
        #expect(opened.all.first == opened.all.last)
        #expect(opened.all.first?.absoluteString.contains("accounts.google.com") == true)

        await auth.cancelConnect()
        _ = try? await connect.value
        #expect(await auth.reopenConsentPage() == false)
    }

    @Test("only a dead grant asks for a new consent (#139)")
    func needsReconnectIsTyped() {
        #expect(GoogleAuth.needsReconnect(GoogleAuth.Failure.invalidGrant))
        for other: GoogleAuth.Failure in [
            .notConfigured, .notConnected, .stateMismatch, .declined("access_denied"), .noRefreshToken,
        ] {
            #expect(!GoogleAuth.needsReconnect(other))
        }
        #expect(!GoogleAuth.needsReconnect(ContextSyncError.unauthorized("key rejected")))
        // The sentence is for a person to read; the flag is what the UI switches on.
        #expect(!GoogleAuth.Failure.invalidGrant.description.contains("worklens google"))
    }

    @Test("missing client credentials fail before anything opens")
    func notConfigured() async throws {
        var config = googleConfig()
        config.googleClientSecret = nil
        let auth = GoogleAuth(config: config, tokens: InMemoryTokenStore())
        #expect(!auth.isConfigured)
        await #expect(throws: GoogleAuth.Failure.notConfigured) { _ = try await auth.connect(timeout: 1) }
    }
}

// MARK: - The account on record (#36)

@Suite("Google account on record")
struct GoogleAccountRecordTests {
    @Test("status names the account from the record, without ever reading the grant")
    func addressFromRecord() {
        let auth = GoogleAuth(
            config: googleConfig(),
            tokens: InMemoryTokenStore(tokens(expiresAt: noon)),
            account: InMemoryGoogleAccountRecord("you@example.com")
        )
        #expect(auth.accountOnRecord == "you@example.com")
        #expect(auth.hasStoredGrant)
    }

    @Test("an item with no recorded address says so instead of decrypting it")
    func addressUnknown() {
        let auth = GoogleAuth(
            config: googleConfig(),
            tokens: InMemoryTokenStore(tokens(expiresAt: noon)),
            account: InMemoryGoogleAccountRecord()
        )
        #expect(auth.accountOnRecord == nil)
        #expect(auth.hasStoredGrant, "the grant is there; only its address is unknown")
        #expect(GoogleGrantStatus.addressUnknownNote == "Connected \u{b7} account unknown: Reconnect to confirm")
    }

    @Test("with no grant at all, a recorded address is not mistaken for a connection")
    func noGrant() {
        let auth = GoogleAuth(
            config: googleConfig(),
            tokens: InMemoryTokenStore(),
            account: InMemoryGoogleAccountRecord("stale@example.com")
        )
        #expect(!auth.hasStoredGrant)
    }

    @Test("disconnecting forgets the address as well as the grant")
    func disconnectForgets() async throws {
        let stub = Stub([.json("{}")])
        let record = InMemoryGoogleAccountRecord("you@example.com")
        let store = InMemoryTokenStore(tokens(expiresAt: noon))
        let auth = GoogleAuth(
            config: googleConfig(),
            http: ContextHTTP(session: stub.session, minimumSpacing: 0, maxRetries: 0, sleeper: { _ in }),
            tokens: store,
            account: record,
            now: { noon }
        )

        try await auth.disconnect()
        #expect(try store.load() == nil)
        #expect(record.address() == nil)
        #expect(!auth.hasStoredGrant)
    }

    @Test("the app_state record survives a reopen and the address is never a secret")
    func appStateRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-google-record-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = AppStateGoogleAccountRecord(dataDir: dir)
        #expect(record.address() == nil)
        record.remember("you@example.com")
        #expect(record.address() == "you@example.com")

        // A second process — the CLI after the app wrote it — reads the same row.
        #expect(AppStateGoogleAccountRecord(dataDir: dir).address() == "you@example.com")
        #expect(
            try AppStateStore(Database(dataDir: dir)).get(AppStateGoogleAccountRecord.key)
                == "you@example.com"
        )

        record.forget()
        #expect(record.address() == nil)
        #expect(AppStateGoogleAccountRecord(dataDir: dir).address() == nil)
    }
}

// MARK: - Calendar

@Suite("CalendarSource mapping")
struct CalendarSourceTests {
    private let timed = """
    {"id": "evt-1", "status": "confirmed", "summary": "Portfolio review",
     "start": {"dateTime": "2026-09-07T10:00:00Z"}, "end": {"dateTime": "2026-09-07T11:00:00Z"},
     "hangoutLink": "https://meet.google.com/abc-defg-hij",
     "description": "Quarterly marks.",
     "attendees": [{"email": "you@example.com", "self": true, "responseStatus": "accepted"},
                   {"email": "ana@example.com", "responseStatus": "tentative"}]}
    """

    @Test("a timed event with a Meet link is a meeting, with attendees and their answers")
    func timedConference() throws {
        let event = try #require(CalendarSource.map(try json(timed)))
        #expect(event.source == .calendar)
        #expect(event.externalId == "evt-1")
        #expect(event.title == "Portfolio review")
        #expect(event.isMeeting)
        #expect(event.startAt == ContextDates.parseISO8601("2026-09-07T10:00:00Z"))
        #expect(event.endAt == ContextDates.parseISO8601("2026-09-07T11:00:00Z"))
        #expect(event.participants == ["you@example.com (accepted)", "ana@example.com (tentative)"])
        #expect(event.bodyMd == "Quarterly marks.")
    }

    @Test("an all-day entry is a label on the day, never an eight-hour meeting")
    func allDay() throws {
        let event = try #require(CalendarSource.map(try json("""
        {"id": "evt-2", "status": "confirmed", "summary": "Ana out of office",
         "start": {"date": "2026-09-07"}, "end": {"date": "2026-09-08"}}
        """)))
        #expect(!event.isMeeting)
        #expect(event.endAt?.timeIntervalSince(event.startAt) == 86400)
    }

    @Test("a meeting you declined is not time you spent")
    func declined() throws {
        let event = try #require(CalendarSource.map(try json("""
        {"id": "evt-3", "status": "confirmed", "summary": "Optional sync",
         "start": {"dateTime": "2026-09-07T10:00:00Z"}, "end": {"dateTime": "2026-09-07T10:30:00Z"},
         "hangoutLink": "https://meet.google.com/x",
         "attendees": [{"email": "you@example.com", "self": true, "responseStatus": "declined"}]}
        """)))
        #expect(!event.isMeeting)
    }

    @Test("conferencing is detected from conferenceData and from the location, not just hangoutLink")
    func conferenceDetection() throws {
        #expect(CalendarSource.isConference(try json("""
        {"conferenceData": {"conferenceId": "abc"}}
        """)))
        #expect(CalendarSource.isConference(try json("""
        {"location": "https://acme.zoom.us/j/123"}
        """)))
        #expect(CalendarSource.isConference(try json("""
        {"location": "Meeting room 4"}
        """)) == false)
        #expect(CalendarSource.isConference(try json("{}")) == false)
    }

    @Test("a cancelled event deletes the row it used to have")
    func cancelledIsRemoved() async throws {
        let config = googleConfig()
        defer { try? FileManager.default.removeItem(at: config.dataDir) }
        let db = try Database.inMemory()
        let store = ContextEventStore(db)

        let firstStub = Stub([.json("{\"items\": [\(timed)]}")])
        let source = CalendarSource(
            auth: connectedAuth(config),
            http: ContextHTTP(session: firstStub.session, minimumSpacing: 0, maxRetries: 0, sleeper: { _ in })
        )
        #expect(try await source.sync(window: window, into: store, config: config).inserted == 1)

        let secondStub = Stub([.json("""
        {"items": [{"id": "evt-1", "status": "cancelled"}]}
        """)])
        let after = CalendarSource(
            auth: connectedAuth(config),
            http: ContextHTTP(session: secondStub.session, minimumSpacing: 0, maxRetries: 0, sleeper: { _ in })
        )
        #expect(try await after.sync(window: window, into: store, config: config).updated == 1)
        #expect(try store.find(source: .calendar, externalId: "evt-1") == nil)
    }

    @Test("pages are followed and the window is passed as RFC 3339")
    func pagination() async throws {
        let config = googleConfig()
        defer { try? FileManager.default.removeItem(at: config.dataDir) }
        let stub = Stub([
            .json("{\"items\": [\(timed)], \"nextPageToken\": \"page-2\"}"),
            .json("""
            {"items": [{"id": "evt-9", "status": "confirmed", "summary": "Later",
                        "start": {"dateTime": "2026-09-07T14:00:00Z"},
                        "end": {"dateTime": "2026-09-07T14:30:00Z"}}]}
            """),
        ])
        let source = CalendarSource(
            auth: connectedAuth(config),
            http: ContextHTTP(session: stub.session, minimumSpacing: 0, maxRetries: 0, sleeper: { _ in })
        )
        let db = try Database.inMemory()
        #expect(try await source.sync(window: window, into: ContextEventStore(db), config: config).inserted == 2)

        let first = try #require(stub.sent.first?.url?.query)
        #expect(first.contains("singleEvents=true"))
        #expect(first.contains("timeMin=2026-09-06T00:00:00Z"))
        #expect(stub.sent[1].url?.query?.contains("pageToken=page-2") == true)
    }
}

/// Records what a flow asked the browser to open, for the tests that count it.
private final class OpenedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) { lock.withLock { urls.append(url) } }
    var all: [URL] { lock.withLock { urls } }
}
