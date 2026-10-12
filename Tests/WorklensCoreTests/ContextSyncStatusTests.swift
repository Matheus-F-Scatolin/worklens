import Foundation
import Testing

@testable import WorklensCore

/// #141: what Settings → Integrations says about a source, and whether it still says it after a
/// relaunch.
private let utc = TimeZone(identifier: "UTC")!
private let day = "2026-09-07"
private let noon = DayBoundaries.range(day: day, timeZone: utc)!.start.addingTimeInterval(12 * 3600)

private func temporaryConfig() -> Config {
    var config = Config.defaults()
    config.dataDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("worklens-status-\(UUID().uuidString)")
    return config
}

/// A source the test drives: it inserts what it is told to insert, or throws what it is told to
/// throw.
private final class StubSource: ContextSyncSource, @unchecked Sendable {
    let id: ContextSource = .granola
    let displayName = "Granola"

    private let lock = NSLock()
    private var events: [ContextEvent] = []
    private var failure: (any Error)?
    private var configured = true

    func setEvents(_ value: [ContextEvent]) { lock.withLock { events = value } }
    func setError(_ value: (any Error)?) { lock.withLock { failure = value } }
    func setConfigured(_ value: Bool) { lock.withLock { configured = value } }

    func isConfigured(_ config: Config) -> Bool { lock.withLock { configured } }

    func sync(window: DateInterval, into store: ContextEventStore, config: Config) async throws -> SyncResult {
        let (pending, error) = lock.withLock { (events, failure) }
        if let error { throw error }
        var result = SyncResult()
        for event in pending where try store.save(event) == .inserted { result.inserted += 1 }
        return result
    }
}

private func meeting(_ id: String, at start: Date, syncedAt: Date) -> ContextEvent {
    ContextEvent(
        source: .granola, externalId: id, startAt: start, endAt: start.addingTimeInterval(1800),
        title: "Standup", isMeeting: true, syncedAt: syncedAt
    )
}

@Suite("Sync status survives a relaunch (#141)")
struct SourceStatusPersistenceTests {
    @Test("a successful round is still there after the scheduler is rebuilt")
    func successRoundTrips() async throws {
        let db = try Database.inMemory()
        let config = temporaryConfig()
        let source = StubSource()
        source.setEvents([
            meeting("a", at: noon, syncedAt: noon),
            meeting("b", at: noon.addingTimeInterval(3600), syncedAt: noon),
        ])
        let scheduler = ContextSyncScheduler(
            sources: [source], db: db, config: config, now: { noon }
        )
        _ = await scheduler.syncNow()

        let relaunched = ContextSyncScheduler(
            sources: [StubSource()], db: db, config: config, now: { noon }
        )
        let status = await relaunched.statusList[0]
        #expect(status.lastSyncAt == noon)
        #expect(status.lastInserted == 2)
        #expect(status.eventCount == 2)
        #expect(status.lastError == nil)
        // The bug this fixes: two events stored and a card reading "never synced".
        #expect(status.line(timeZone: utc, now: noon) == "Synced just now · 2 new meetings")
    }

    @Test("a failure keeps its count, and the backoff is re-derived rather than stored")
    func failureRoundTrips() async throws {
        let db = try Database.inMemory()
        let config = temporaryConfig()
        let source = StubSource()
        source.setError(ContextSyncError.unauthorized("Granola refused the key."))
        let scheduler = ContextSyncScheduler(
            sources: [source], db: db, config: config, now: { noon }
        )
        _ = await scheduler.syncNow()
        _ = await scheduler.syncNow()

        let relaunched = ContextSyncScheduler(
            sources: [StubSource()], db: db, config: config, now: { noon }
        )
        let status = await relaunched.statusList[0]
        #expect(status.consecutiveFailures == 2)
        #expect(status.lastError == "Granola refused the key.")
        #expect(status.lastErrorIsActionable)
        #expect(status.lastFailureAt == noon)
        #expect(
            status.retryAfter == noon.addingTimeInterval(ContextSyncScheduler.backoff(after: 2)),
            "the deadline is arithmetic on the failure count, not a stored instant"
        )
    }

    @Test("a source that was configured and is not any more raises an actionable status")
    func unconfiguredAfterSyncingIsActionable() async throws {
        let db = try Database.inMemory()
        let config = temporaryConfig()
        let source = StubSource()
        source.setEvents([meeting("a", at: noon, syncedAt: noon)])
        let scheduler = ContextSyncScheduler(
            sources: [source], db: db, config: config, now: { noon }
        )
        _ = await scheduler.syncNow()
        source.setConfigured(false)
        _ = await scheduler.syncNow()

        let status = await scheduler.statusList[0]
        #expect(status.lastErrorIsActionable, "the menu line and the notification hang off this")
        #expect(status.lastError != nil)
    }

    @Test("a source that was never set up records nothing to complain about")
    func neverConfiguredRecordsNothing() async throws {
        let db = try Database.inMemory()
        let config = temporaryConfig()
        let source = StubSource()
        source.setConfigured(false)
        let scheduler = ContextSyncScheduler(
            sources: [source], db: db, config: config, now: { noon }
        )
        let results = await scheduler.syncNow()

        #expect(results[.granola] != nil)
        let status = await scheduler.statusList[0]
        #expect(!status.lastErrorIsActionable)
        #expect(status.consecutiveFailures == 0)
    }

    @Test("a grant made before this change falls back to the newest row it stored")
    func fallsBackToTheNewestEvent() async throws {
        let db = try Database.inMemory()
        let config = temporaryConfig()
        let store = ContextEventStore(db)
        // A calendar event a day in the future, synced this morning: the fallback must report
        // when the sync happened, never when the meeting starts.
        _ = try store.save(
            ContextEvent(
                source: .granola, externalId: "old", startAt: noon.addingTimeInterval(86_400),
                title: "Tomorrow", isMeeting: true, syncedAt: noon
            )
        )
        let scheduler = ContextSyncScheduler(
            sources: [StubSource()], db: db, config: config, now: { noon }
        )
        let status = await scheduler.statusList[0]
        #expect(status.lastSyncAt == noon)
        #expect(status.lastInserted == 0)
    }

    @Test("a success clears the failure, the attention flag and the notified stamp")
    func successClearsTheIncident() async throws {
        let db = try Database.inMemory()
        let config = temporaryConfig()
        let source = StubSource()
        source.setError(ContextSyncError.unauthorized("refused"))
        let scheduler = ContextSyncScheduler(
            sources: [source], db: db, config: config, now: { noon }
        )
        _ = await scheduler.syncNow()
        await scheduler.markAttentionNotified(.granola, at: noon)
        #expect(await scheduler.statusList[0].notifiedFailureAt == noon)

        source.setError(nil)
        source.setEvents([meeting("a", at: noon, syncedAt: noon)])
        _ = await scheduler.syncNow()

        let relaunched = ContextSyncScheduler(
            sources: [StubSource()], db: db, config: config, now: { noon }
        )
        let status = await relaunched.statusList[0]
        #expect(status.lastError == nil)
        #expect(!status.lastErrorIsActionable)
        #expect(status.notifiedFailureAt == nil, "the next incident gets its own notification")
        #expect(status.retryAfter == nil)
    }

    @Test("forgetting a source leaves nothing behind in app_state")
    func forgetClearsTheStoredStatus() async throws {
        let db = try Database.inMemory()
        let config = temporaryConfig()
        let source = StubSource()
        source.setEvents([meeting("a", at: noon, syncedAt: noon)])
        let scheduler = ContextSyncScheduler(
            sources: [source], db: db, config: config, now: { noon }
        )
        _ = await scheduler.syncNow()
        await scheduler.forget(.granola)

        #expect(try AppStateStore(db).get(SourceStatus.statusKey(.granola)) == nil)
        let status = await scheduler.statusList[0]
        #expect(status.lastSyncAt == nil)
        // The events themselves are not Disconnect's to remove.
        #expect(status.eventCount == 1)
    }
}

@Suite("A failure is actionable or it is transient (#141)")
struct ContextSyncErrorClassificationTests {
    @Test("waiting will not fix these")
    func actionable() {
        #expect(ContextSyncError.isActionable(ContextSyncError.unauthorized("x"), hadSynced: false))
        #expect(ContextSyncError.isActionable(ContextSyncError.http(401, "x"), hadSynced: false))
        #expect(ContextSyncError.isActionable(ContextSyncError.http(403, "x"), hadSynced: false))
        #expect(ContextSyncError.isActionable(GoogleAuth.Failure.invalidGrant, hadSynced: false))
        #expect(ContextSyncError.isActionable(GoogleAuth.Failure.noRefreshToken, hadSynced: false))
        #expect(ContextSyncError.isActionable(GoogleAuth.Failure.notConnected, hadSynced: false))
    }

    @Test("waiting will")
    func transient() {
        #expect(!ContextSyncError.isActionable(ContextSyncError.rateLimited(retryAfter: 30), hadSynced: true))
        #expect(!ContextSyncError.isActionable(ContextSyncError.http(503, "x"), hadSynced: true))
        #expect(!ContextSyncError.isActionable(ContextSyncError.decode("x"), hadSynced: true))
        #expect(!ContextSyncError.isActionable(ContextSyncError.unavailable("x"), hadSynced: true))
        #expect(!ContextSyncError.isActionable(GoogleAuth.Failure.stateMismatch, hadSynced: true))
    }

    @Test("a source that was configured and is not any more is actionable; one that never was is not")
    func wasConfiguredNowNot() {
        let gone = ContextSyncError.notConfigured("Granola")
        #expect(ContextSyncError.isActionable(gone, hadSynced: true))
        #expect(!ContextSyncError.isActionable(gone, hadSynced: false), "never set up is not a fault")
        #expect(!ContextSyncError.isActionable(GoogleAuth.Failure.notConfigured, hadSynced: false))
    }

    @Test("the credential question and the actionable question are not the same question")
    func notTheSameAsIsCredential() {
        // A 500 is neither; a missing key is a credential problem but not an incident to announce.
        let missing = ContextSyncError.notConfigured("GRANOLA_API_KEY")
        #expect(ContextSyncError.isCredential(missing))
        #expect(!ContextSyncError.isActionable(missing, hadSynced: false))
    }
}

@Suite("The Integrations line (#141)")
struct SourceStatusLineTests {
    private func status(
        lastSyncAt: Date? = nil, inserted: Int = 0, error: String? = nil, retryAfter: Date? = nil,
        source: ContextSource = .granola, configured: Bool = true
    ) -> SourceStatus {
        SourceStatus(
            id: source, displayName: "Granola", isConfigured: configured, lastSyncAt: lastSyncAt,
            lastError: error, eventCount: 12, lastInserted: inserted, retryAfter: retryAfter
        )
    }

    @Test("a recent round reads as minutes, and counts what it added")
    func recent() {
        let line = status(lastSyncAt: noon.addingTimeInterval(-180), inserted: 4)
            .line(timeZone: utc, now: noon)
        #expect(line == "Synced 3 min ago · 4 new meetings")
    }

    @Test("yesterday says which day it was, which a bare HH:mm never did")
    func yesterday() {
        let at = noon.addingTimeInterval(-(17 * 3600 + 20 * 60))  // 18:40 the day before
        #expect(status(lastSyncAt: at).line(timeZone: utc, now: noon) == "Yesterday 18:40 · 0 new")
    }

    @Test("older than that carries the date")
    func older() {
        let at = noon.addingTimeInterval(-5 * 86_400)
        #expect(status(lastSyncAt: at).line(timeZone: utc, now: noon) == "Sep 2 12:00 · 0 new")
    }

    @Test("a source in backoff says when it will try again")
    func retrying() {
        let line = status(error: "rate limited", retryAfter: noon.addingTimeInterval(900))
            .line(timeZone: utc, now: noon)
        #expect(line == "Error: rate limited · Retrying at 12:15")
    }

    @Test("a backoff that has passed is not advertised")
    func retryPassed() {
        let line = status(error: "rate limited", retryAfter: noon.addingTimeInterval(-60))
            .line(timeZone: utc, now: noon)
        #expect(line == "Error: rate limited")
    }

    @Test("the unconnected and never-synced lines are unchanged")
    func edges() {
        #expect(status(configured: false).line(timeZone: utc, now: noon) == "Not configured")
        #expect(status().line(timeZone: utc, now: noon) == "Connected · never synced")
    }

    @Test("each source counts the thing it actually stores")
    func nouns() {
        #expect(SourceStatus.noun(.granola, count: 1) == "meeting")
        #expect(SourceStatus.noun(.calendar, count: 2) == "meetings")
    }
}

@Suite("The menu's integration line (#141)")
struct MenuIntegrationAttentionTests {
    @Test("one source, then two, then none")
    func wording() {
        #expect(MenuModel.integrationAttentionLine([]) == nil)
        #expect(
            MenuModel.integrationAttentionLine(["Granola"])
                == "Granola needs attention: reconnect it in Settings"
        )
        #expect(
            MenuModel.integrationAttentionLine(["Granola", "Google Calendar"])
                == "Granola and Google Calendar need attention: reconnect them in Settings"
        )
    }

    @Test("the line reaches the menu, and a degraded menu has room for nothing else")
    func row() {
        let state = MenuState(scheduler: .running, integrationsNeedingAttention: ["Granola"])
        let menu = MenuModel(state: state)
        #expect(menu.integrationAttentionLine != nil)

        let broken = MenuState(configError: "DATA_DIR is not a folder")
        #expect(MenuModel(state: broken).integrationAttentionLine == nil)
    }
}
