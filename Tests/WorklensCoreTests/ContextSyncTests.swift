import Foundation
import Testing
@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!
private let day = "2026-09-07"
private let dayStart = DayBoundaries.range(day: day, timeZone: utc)!.start
private func at(_ hour: Int, _ minute: Int) -> Date {
    dayStart.addingTimeInterval(Double(hour) * 3600 + Double(minute) * 60)
}

// MARK: - Fakes

/// A clock whose sleeps only return when the test says so, so "syncs on start and on interval"
/// is an assertion rather than a wait.
private final class SleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var credits = 0
    private(set) var sleeps = 0

    func wait() async {
        let immediate: Bool = lock.withLock {
            sleeps += 1
            if credits > 0 { credits -= 1; return true }
            return false
        }
        if immediate { return }
        await withCheckedContinuation { continuation in
            lock.withLock { waiters.append(continuation) }
        }
    }

    /// Lets one sleeping caller through, now or as soon as it arrives.
    func release() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            waiters.isEmpty ? nil : waiters.removeFirst()
        }
        if let waiter { waiter.resume() } else { lock.withLock { credits += 1 } }
    }
}

private struct GatedClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration = .zero
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    let gate: SleepGate
    var now: Instant { Instant() }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        await gate.wait()
        try Task.checkCancellation()
    }
}

/// Wall time the test controls, so backoff is arithmetic rather than waiting.
private final class FakeNow: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var date: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private final class FakeSource: ContextSyncSource, @unchecked Sendable {
    let id: ContextSource
    let displayName: String

    private let lock = NSLock()
    private var events: [ContextEvent] = []
    private var error: (any Error)?
    private var configured = true
    private var windows: [DateInterval] = []
    private(set) var calls = 0

    init(id: ContextSource = .granola, displayName: String = "Fake") {
        self.id = id
        self.displayName = displayName
    }

    func setEvents(_ value: [ContextEvent]) { lock.withLock { events = value } }
    func setError(_ value: (any Error)?) { lock.withLock { error = value } }
    func setConfigured(_ value: Bool) { lock.withLock { configured = value } }
    var callCount: Int { lock.withLock { calls } }
    var lastWindow: DateInterval? { lock.withLock { windows.last } }

    func isConfigured(_ config: Config) -> Bool { lock.withLock { configured } }

    func sync(window: DateInterval, into store: ContextEventStore, config: Config) async throws -> SyncResult {
        let (pending, failure) = lock.withLock { () -> ([ContextEvent], (any Error)?) in
            calls += 1
            windows.append(window)
            return (events, error)
        }
        if let failure { throw failure }

        var result = SyncResult()
        for event in pending {
            switch try store.save(event) {
            case .inserted: result.inserted += 1
            case .updated: result.updated += 1
            case .unchanged: result.skipped += 1
            }
        }
        return result
    }
}

private func temporaryConfig() -> Config {
    var config = Config.defaults()
    config.dataDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("worklens-context-\(UUID().uuidString)")
    return config
}

/// Polls `condition` for up to a second. Used only where the assertion is about a background
/// task having run at all — never to wait out a timer.
private func eventually(
    _ condition: @Sendable () async -> Bool,
    _ comment: Comment = "condition never became true"
) async {
    for _ in 0..<1000 {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    Issue.record(comment)
}

private func meetingEvent(
    _ externalId: String,
    source: ContextSource = .calendar,
    from: Date,
    to: Date?,
    title: String,
    body: String? = nil,
    participants: [String] = []
) -> ContextEvent {
    ContextEvent(
        source: source, externalId: externalId, startAt: from, endAt: to, title: title,
        participantsJson: ContextEvent.encodeParticipants(participants),
        bodyMd: body, isMeeting: true, syncedAt: at(0, 0)
    )
}

// MARK: - Store

@Suite("ContextEventStore sync helpers")
struct ContextEventStoreSyncTests {
    @Test("saving the same event twice inserts once and then reports it unchanged")
    func idempotent() throws {
        let db = try Database.inMemory()
        let store = ContextEventStore(db)
        let event = meetingEvent("evt-1", from: at(10, 0), to: at(11, 0), title: "Portfolio review")

        #expect(try store.save(event) == .inserted)
        #expect(try store.save(event) == .unchanged)

        var later = event
        later.id = Identifiers.new()
        later.syncedAt = at(12, 0)
        #expect(try store.save(later) == .unchanged, "a newer sync time alone is not a change")

        var renamed = event
        renamed.title = "Portfolio review (moved)"
        #expect(try store.save(renamed) == .updated)
        #expect(try store.count(source: .calendar) == 1)
        #expect(try store.find(source: .calendar, externalId: "evt-1")?.title == "Portfolio review (moved)")
    }

    @Test("the stored row keeps the id it was first given")
    func stableId() throws {
        let db = try Database.inMemory()
        let store = ContextEventStore(db)
        let first = meetingEvent("evt-1", from: at(10, 0), to: at(11, 0), title: "Standup")
        try store.save(first)

        var second = first
        second.id = Identifiers.new()
        second.title = "Standup (renamed)"
        try store.save(second)

        #expect(try store.find(source: .calendar, externalId: "evt-1")?.id == first.id)
    }

    @Test("deleting removes the row and its body file")
    func deleteRemovesBody() throws {
        let config = temporaryConfig()
        defer { try? FileManager.default.removeItem(at: config.dataDir) }
        let db = try Database.inMemory()
        let store = ContextEventStore(db)

        let path = try ContextBody.write("# notes", source: .granola, externalId: "n1", config: config)
        var event = meetingEvent("n1", source: .granola, from: at(9, 0), to: at(10, 0), title: "Kickoff")
        event.bodyPath = path
        try store.save(event)

        #expect(FileManager.default.fileExists(atPath: config.dataDir.appendingPathComponent(path).path))
        #expect(try store.delete(source: .granola, externalId: "n1", config: config))
        #expect(try store.count(source: .granola) == 0)
        #expect(!FileManager.default.fileExists(atPath: config.dataDir.appendingPathComponent(path).path))
    }

    @Test("a meeting that started before the window still overlaps it")
    func overlappingMeetings() throws {
        let db = try Database.inMemory()
        let store = ContextEventStore(db)
        try store.save(meetingEvent("running", from: at(9, 30), to: at(10, 30), title: "Long call"))
        try store.save(meetingEvent("later", from: at(14, 0), to: at(15, 0), title: "Later call"))
        // No end time: covered by the 45-minute assumption, so it reaches 10:15.
        try store.save(meetingEvent("open", from: at(9, 30), to: nil, title: "Open-ended"))

        let overlapping = try store.meetings(overlapping: at(10, 0), to: at(10, 5))
        #expect(overlapping.map(\.externalId).sorted() == ["open", "running"])
    }

    @Test("a call that crossed midnight belongs to both days")
    func crossMidnightBelongsToBothDays() throws {
        let db = try Database.inMemory()
        let store = ContextEventStore(db)
        try store.save(meetingEvent("late", from: at(23, 30), to: at(24, 30), title: "Late call"))
        try store.save(meetingEvent("morning", source: .granola, from: at(9, 0), to: at(9, 30), title: "Standup"))

        // `fetch(day:)` is start_at-based, which is right for an instant and wrong for this call.
        #expect(try store.fetch(day: "2026-09-08", timeZone: utc).isEmpty)
        // The timeline gives 09-08 a meeting block for it, so the day's events must include it too.
        #expect(try store.events(day: "2026-09-08", timeZone: utc).map(\.externalId) == ["late"])
        #expect(try store.events(day: day, timeZone: utc).map(\.externalId) == ["morning", "late"])
    }

    @Test("a source's own failures reach the Integrations panel as sentences")
    func failuresReadAsSentences() {
        // Not `localizedDescription`: a plain Swift `Error` renders as "The operation couldn't be
        // completed. (WorklensCore.GoogleAuth.Failure error 2.)", which tells the user nothing.
        #expect(ContextSyncScheduler.describe(GoogleAuth.Failure.notConnected)
            == "Google is not connected yet.")
        #expect(ContextSyncScheduler.describe(ContextSyncError.notConfigured("SLACK_USER_TOKEN"))
            == "SLACK_USER_TOKEN is not set")
        #expect(ContextSyncScheduler.describe(LoopbackReceiver.Failure.timedOut(seconds: 300))
            == "Google did not come back in 5 minutes.")
        // #139: not one of these sentences sends a menu-bar user to a terminal any more.
        for failure in [GoogleAuth.Failure.notConnected, .invalidGrant] {
            #expect(!ContextSyncScheduler.describe(failure).contains("worklens google"))
        }
    }

    @Test("a meeting longer than the assumed duration is still running an hour into it")
    func longMeetingStillOverlaps() throws {
        let db = try Database.inMemory()
        let store = ContextEventStore(db)
        // Three hours: `end_at` has to decide the left edge, because the 45-minute fallback
        // would have stopped looking back at 10:15 and dropped the offsite entirely.
        try store.save(meetingEvent("offsite", from: at(9, 0), to: at(12, 0), title: "Offsite"))
        try store.save(meetingEvent("morning", from: at(8, 0), to: at(8, 30), title: "Standup"))

        #expect(try store.meetings(overlapping: at(11, 0), to: at(11, 5)).map(\.externalId) == ["offsite"])
        #expect(try store.meetings(overlapping: at(12, 30), to: at(12, 35)).isEmpty)
    }
}

// MARK: - Bodies

@Suite("ContextBody")
struct ContextBodyTests {
    @Test("a body over the inline limit is trimmed for the row and written whole to a file")
    func longBodyGoesToDisk() throws {
        let config = temporaryConfig()
        defer { try? FileManager.default.removeItem(at: config.dataDir) }

        let transcript = String(repeating: "spoken words ", count: 500)
        #expect(transcript.count > ContextBody.inlineLimit)

        let inline = ContextBody.inline(transcript)
        #expect(inline!.count <= ContextBody.inlineLimit)
        #expect(inline!.hasSuffix("…"))

        let path = try ContextBody.write(transcript, source: .granola, externalId: "note-1", config: config)
        #expect(path == "context/granola/note-1.md")
        #expect(try ContextBody.read(path, config: config) == transcript)
    }

    @Test("a short body is returned untouched and an empty one becomes nil")
    func shortBody() {
        #expect(ContextBody.inline("  hello  ") == "hello")
        #expect(ContextBody.inline("   ") == nil)
        #expect(ContextBody.inline(nil) == nil)
    }

    @Test("external ids with punctuation become safe file names")
    func fileNames() {
        #expect(ContextBody.fileName("C123ABC:1757260800.000200") == "C123ABC-1757260800-000200")
        #expect(ContextBody.relativePath(source: .granola, externalId: "C1:2") == "context/granola/C1-2.md")
    }
}

// MARK: - Scheduler

@Suite("ContextSyncScheduler")
struct ContextSyncSchedulerTests {
    private func harness(
        _ source: FakeSource, now: FakeNow, gate: SleepGate = SleepGate()
    ) throws -> (ContextSyncScheduler, Database, Config, SleepGate) {
        let config = temporaryConfig()
        let db = try Database.inMemory()
        let scheduler = ContextSyncScheduler(
            sources: [source], db: db, config: config,
            clock: GatedClock(gate: gate), now: { now.date }
        )
        return (scheduler, db, config, gate)
    }

    @Test("a sync window is the last 48 h and the next 24 h")
    func window() async throws {
        let source = FakeSource()
        let now = FakeNow(at(12, 0))
        let (scheduler, _, _, _) = try harness(source, now: now)

        _ = await scheduler.syncNow()
        let window = source.lastWindow
        #expect(window?.start == at(12, 0).addingTimeInterval(-48 * 3600))
        #expect(window?.end == at(12, 0).addingTimeInterval(24 * 3600))
    }

    @Test("re-syncing the same events inserts nothing the second time")
    func idempotentRound() async throws {
        let source = FakeSource()
        source.setEvents([
            meetingEvent("a", source: .granola, from: at(10, 0), to: at(11, 0), title: "One"),
            meetingEvent("b", source: .granola, from: at(11, 0), to: at(12, 0), title: "Two"),
        ])
        let now = FakeNow(at(12, 0))
        let (scheduler, _, _, _) = try harness(source, now: now)

        let first = await scheduler.syncNow()
        #expect(try first[.granola]?.get() == SyncResult(inserted: 2))

        let second = await scheduler.syncNow()
        #expect(try second[.granola]?.get() == SyncResult(skipped: 2))

        let status = await scheduler.status[.granola]
        #expect(status?.eventCount == 2)
        #expect(status?.lastError == nil)
        #expect(status?.lastSyncAt == at(12, 0))
    }

    @Test("an expired Google grant is a typed flag, not a sentence to parse (#139)")
    func needsReconnectIsTyped() async throws {
        let source = FakeSource(id: .calendar, displayName: "Calendar")
        source.setError(GoogleAuth.Failure.invalidGrant)
        let now = FakeNow(at(12, 0))
        let (scheduler, _, _, _) = try harness(source, now: now)

        _ = await scheduler.syncDue()
        var status = await scheduler.status[.calendar]
        #expect(status?.needsReconnect == true)
        #expect(status?.line() == "Paused until you reconnect")
        #expect(await scheduler.sourcesNeedingReconnect == [.calendar])

        // Any other failure leaves the flag alone — only a dead grant asks for a new consent.
        source.setError(ContextSyncError.rateLimited(retryAfter: 30))
        now.advance(3600)
        _ = await scheduler.syncDue()
        status = await scheduler.status[.calendar]
        #expect(status?.needsReconnect == false)

        // And a round that works clears it without anybody remembering to.
        source.setError(GoogleAuth.Failure.invalidGrant)
        now.advance(3600)
        _ = await scheduler.syncDue()
        #expect(await scheduler.status[.calendar]?.needsReconnect == true)
        source.setError(nil)
        now.advance(3600)
        _ = await scheduler.syncDue()
        #expect(await scheduler.status[.calendar]?.needsReconnect == false)
        #expect(await scheduler.sourcesNeedingReconnect.isEmpty)

        // And disconnecting takes the line with it: a source that is no longer set up is not
        // waiting for anything.
        source.setError(GoogleAuth.Failure.invalidGrant)
        now.advance(3600)
        _ = await scheduler.syncDue()
        #expect(await scheduler.status[.calendar]?.needsReconnect == true)
        source.setConfigured(false)
        now.advance(3600)
        _ = await scheduler.syncDue()
        #expect(await scheduler.sourcesNeedingReconnect.isEmpty)
    }

    @Test("a failure backs off 1, then 5, then 15, then 60 minutes")
    func backoff() async throws {
        let source = FakeSource()
        source.setError(ContextSyncError.unauthorized("key rejected"))
        let now = FakeNow(at(12, 0))
        let (scheduler, _, _, _) = try harness(source, now: now)

        _ = await scheduler.syncDue()
        var status = await scheduler.status[.granola]
        #expect(status?.lastError == "key rejected")
        #expect(status?.consecutiveFailures == 1)
        #expect(status?.retryAfter == at(12, 1))

        // Still inside the backoff: the routine round leaves the source alone.
        now.advance(30)
        _ = await scheduler.syncDue()
        #expect(source.callCount == 1)

        // Past it: one more attempt, and the next wait is five minutes.
        now.advance(60)
        _ = await scheduler.syncDue()
        #expect(source.callCount == 2)
        status = await scheduler.status[.granola]
        #expect(status?.consecutiveFailures == 2)
        // The second attempt happened at 12:01:30, so the five-minute wait ends at 12:06:30.
        #expect(status?.retryAfter == at(12, 6).addingTimeInterval(30))

        #expect(ContextSyncScheduler.backoff(after: 3) == 15 * 60)
        #expect(ContextSyncScheduler.backoff(after: 4) == 60 * 60)
        #expect(ContextSyncScheduler.backoff(after: 99) == 60 * 60)
    }

    @Test("an explicit sync ignores the backoff a failure set")
    func syncNowIgnoresBackoff() async throws {
        let source = FakeSource()
        source.setError(ContextSyncError.unauthorized("nope"))
        let now = FakeNow(at(12, 0))
        let (scheduler, _, _, _) = try harness(source, now: now)

        _ = await scheduler.syncDue()
        _ = await scheduler.syncNow()
        #expect(source.callCount == 2)
    }

    @Test("a success clears the error and the backoff")
    func recovery() async throws {
        let source = FakeSource()
        source.setError(ContextSyncError.unavailable("down"))
        let now = FakeNow(at(12, 0))
        let (scheduler, _, _, _) = try harness(source, now: now)

        _ = await scheduler.syncDue()
        source.setError(nil)
        now.advance(120)
        _ = await scheduler.syncDue()

        let status = await scheduler.status[.granola]
        #expect(status?.lastError == nil)
        #expect(status?.retryAfter == nil)
        #expect(status?.consecutiveFailures == 0)
    }

    @Test("an unconfigured source is never called")
    func skipsUnconfigured() async throws {
        let source = FakeSource()
        source.setConfigured(false)
        let now = FakeNow(at(12, 0))
        let (scheduler, _, _, _) = try harness(source, now: now)

        _ = await scheduler.syncDue()
        #expect(source.callCount == 0)
        #expect(await scheduler.status[.granola]?.isConfigured == false)
    }

    @Test("start syncs immediately and again on every interval")
    func startAndInterval() async throws {
        let source = FakeSource()
        let now = FakeNow(at(12, 0))
        let gate = SleepGate()
        let (scheduler, _, _, _) = try harness(source, now: now, gate: gate)

        await scheduler.start()
        await eventually({ source.callCount >= 1 }, "the first round never ran")

        gate.release()
        await eventually({ source.callCount >= 2 }, "the interval never fired a second round")

        gate.release()
        await eventually({ source.callCount >= 3 }, "the interval never fired a third round")

        await scheduler.stop()
        #expect(await scheduler.isRunning == false)
    }

    @Test("each round hands the meetings around now to the detector")
    func publishesMeetings() async throws {
        let source = FakeSource()
        source.setEvents([
            meetingEvent("now", from: at(11, 45), to: at(12, 15), title: "Happening"),
            meetingEvent("ancient", from: at(2, 0), to: at(3, 0), title: "This morning"),
        ])
        let now = FakeNow(at(12, 0))
        let config = temporaryConfig()
        let db = try Database.inMemory()
        let published = Published()
        let scheduler = ContextSyncScheduler(
            sources: [source], db: db, config: config,
            clock: GatedClock(gate: SleepGate()), now: { now.date },
            onMeetings: { events in await published.set(events) }
        )

        _ = await scheduler.syncNow()
        #expect(await published.titles == ["Happening"])
    }

    @Test("start publishes what the database already knows before its first round")
    func publishesStoredMeetingsOnStart() async throws {
        let source = FakeSource()
        // The round itself never finishes: the point is that the detector is fed anyway.
        source.setError(ContextSyncError.unavailable("network is down"))
        let now = FakeNow(at(12, 0))
        let config = temporaryConfig()
        let db = try Database.inMemory()
        try ContextEventStore(db).save(
            meetingEvent("stored", from: at(11, 45), to: at(12, 15), title: "From a previous run")
        )

        let published = Published()
        let scheduler = ContextSyncScheduler(
            sources: [source], db: db, config: config,
            clock: GatedClock(gate: SleepGate()), now: { now.date },
            onMeetings: { events in await published.set(events) }
        )

        await scheduler.start()
        await eventually({ await published.titles == ["From a previous run"] },
                         "the stored meeting was never handed to the detector")
        await scheduler.stop()
    }

    private actor Published {
        private var events: [ContextEvent] = []
        func set(_ value: [ContextEvent]) { events = value }
        var titles: [String] { events.compactMap(\.title) }
    }
}
