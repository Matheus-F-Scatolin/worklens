import Foundation
import Testing
@testable import WorklensCore

/// Wall time the test controls.
private final class TestNow: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var date: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// Every line the sync logged, with its level.
private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(OutputSync.LogLevel, String)] = []
    func append(_ level: OutputSync.LogLevel, _ line: String) { lock.withLock { lines.append((level, line)) } }
    var all: [String] { lock.withLock { lines.map(\.1) } }
}

@Suite("OutputSync")
struct OutputSyncTests {
    private func harness(
        _ gh: FakeGHRunner = FakeGHRunner()
    ) throws -> (OutputSync, Database, TestNow, FakeGHRunner, Lines) {
        let db = try Database.inMemory()
        let clock = TestNow(GHFixtures.syncedAt)
        let lines = Lines()
        let sync = OutputSync(db: db, runner: gh, now: { clock.date }, log: { lines.append($0, $1) })
        return (sync, db, clock, gh, lines)
    }

    private func rows(_ db: Database) throws -> [Output] {
        try OutputStore(db).outputs(from: .distantPast, to: .distantFuture)
    }

    @Test("the first round looks back 30 days, the next from a day before the last success")
    func windows() async throws {
        let (sync, db, clock, gh, _) = try harness()

        _ = try await sync.sync().get()
        #expect(gh.windows == ["2026-08-08..2026-09-06", ">=2026-09-07"])
        // Merged and closed PRs, two opened issues and one closed, two reviews on Ana's PR.
        #expect(try rows(db).count == 7)
        #expect(OutputSyncStatus.load(db).lastSuccessAt == GHFixtures.syncedAt)

        clock.advance(15 * 60)
        let before = gh.windows.count
        _ = try await sync.sync().get()
        #expect(Array(gh.windows.dropFirst(before)) == [">=2026-09-06"])
    }

    @Test("a re-sync changes no row")
    func resyncChangesNothing() async throws {
        let (sync, db, clock, _, _) = try harness()
        _ = try await sync.sync().get()
        let first = try rows(db)

        clock.advance(15 * 60)
        let again = try await sync.sync().get()
        #expect(again.changed == 0)
        #expect(again.removed == 0)
        #expect(try rows(db) == first)
    }

    @Test("reopening a PR or an issue drops the terminal row it had")
    func reopening() async throws {
        let (sync, db, clock, gh, _) = try harness()
        _ = try await sync.sync().get()
        #expect(try rows(db).contains { $0.externalId == "pr:acme/widgets#12" })

        gh.setAuthored(
            prs: GHFixtures.list([GHFixtures.pr(12, state: "open")]),
            issues: GHFixtures.list([GHFixtures.issue(5, state: "open")])
        )
        clock.advance(15 * 60)
        let result = try await sync.sync().get()
        #expect(result.removed == 2)
        let ids = try rows(db).map(\.externalId)
        #expect(!ids.contains("pr:acme/widgets#12"))
        #expect(!ids.contains("issue:acme/widgets#5:closed"))
        // Opening it is still something you did.
        #expect(ids.contains("issue:acme/widgets#5:opened"))
    }

    @Test("gh missing, logged out or rate-limited is a status and a backoff, not a throw", arguments: [
        (FakeGHRunner.Mode.missing, "not installed"),
        (FakeGHRunner.Mode.loggedOut, "gh auth login"),
        (FakeGHRunner.Mode.rateLimited, "rate limit"),
    ])
    func failures(mode: FakeGHRunner.Mode, words: String) async throws {
        let (sync, db, clock, gh, _) = try harness()
        gh.mode = mode

        let outcome = await sync.syncIfDue()
        guard case .failure? = outcome else {
            Issue.record("expected a failure")
            return
        }
        let status = OutputSyncStatus.load(db)
        #expect(status.lastError?.contains(words) == true)
        #expect(status.consecutiveFailures == 1)
        #expect(status.retryAfter == GHFixtures.syncedAt.addingTimeInterval(60))
        #expect(status.sentence().contains(words))

        // Inside the backoff nothing runs.
        let calls = gh.calls.count
        clock.advance(30)
        #expect(await sync.syncIfDue() == nil)
        #expect(gh.calls.count == calls)

        // After it, the round runs again and a success clears the status.
        gh.mode = .ok
        clock.advance(31)
        guard case .success? = await sync.syncIfDue() else {
            Issue.record("expected a success")
            return
        }
        #expect(OutputSyncStatus.load(db).lastError == nil)
        #expect(OutputSyncStatus.load(db).consecutiveFailures == 0)
    }

    @Test("the round's log lines name no title, URL, repo or login")
    func logsHoldNoContent() async throws {
        let (sync, _, clock, gh, lines) = try harness()
        _ = try await sync.sync().get()
        gh.mode = .loggedOut
        clock.advance(60)
        _ = await sync.sync()

        #expect(lines.all.count == 2)
        for line in lines.all {
            for secret in ["Add the ledger", "Fix the thing", "https://", "github.com", "acme", "widgets",
                           "other/thing", "ana"] {
                #expect(!line.contains(secret), "\(line) contains \(secret)")
            }
        }
    }

    @Test("GITHUB_SHIPPED=false deletes the ledger and wires no sync; forget deletes it too")
    func turningItOff() async throws {
        let (sync, db, _, _, _) = try harness()
        _ = try await sync.sync().get()
        #expect(try !rows(db).isEmpty)

        var config = Config.defaults()
        #expect(OutputSync.forConfig(config, db: db) != nil)
        #expect(try !rows(db).isEmpty)

        config.githubShipped = false
        #expect(OutputSync.forConfig(config, db: db) == nil)
        #expect(try rows(db).isEmpty)
        #expect(OutputSyncStatus.load(db) == OutputSyncStatus())

        _ = try await sync.sync().get()
        #expect(OutputSync.forget(db: db) == 7)
        #expect(try rows(db).isEmpty)
    }

    @Test("a forget from another process makes the running sync start over at 30 days")
    func forgetWhileRunning() async throws {
        let (sync, db, clock, _, _) = try harness()
        _ = try await sync.sync().get()
        #expect(OutputSync.forget(db: db) == 7)

        clock.advance(3600)
        let again = try await sync.sync().get()
        let at = GHFixtures.syncedAt.addingTimeInterval(3600)
        #expect(again.since == at.addingTimeInterval(-Double(OutputSync.firstSyncDays) * 24 * 3600))
        #expect(OutputSyncStatus.load(db).lastSuccessAt == at)
    }

    @Test("Sync now skips the ledger's backoff; Sync now for one source leaves GitHub alone")
    func syncNowAndOutputs() async throws {
        let (sync, db, _, gh, _) = try harness()
        gh.mode = .loggedOut
        _ = await sync.sync()
        #expect(OutputSyncStatus.load(db).retryAfter != nil)
        gh.mode = .ok

        var config = Config.defaults()
        config.dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-shipped-\(UUID().uuidString)")
        let scheduler = ContextSyncScheduler(
            sources: [], db: db, config: config, now: { GHFixtures.syncedAt }, outputs: sync
        )
        let calls = gh.calls.count
        _ = await scheduler.syncDue()
        #expect(gh.calls.count == calls)

        _ = await scheduler.syncNow(source: .granola)
        #expect(gh.calls.count == calls)

        _ = await scheduler.syncNow()
        #expect(gh.calls.count > calls)
        #expect(OutputSyncStatus.load(db).lastError == nil)
    }

    @Test("the context sync round awaits the ledger before it publishes meetings")
    func scheduler() async throws {
        let (sync, db, _, gh, _) = try harness()
        var config = Config.defaults()
        config.dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-shipped-\(UUID().uuidString)")
        let seen = Seen()
        let scheduler = ContextSyncScheduler(
            sources: [], db: db, config: config, now: { GHFixtures.syncedAt },
            onMeetings: { _ in await seen.set((try? OutputStore(db).count(source: Output.github)) ?? -1) },
            outputs: sync
        )
        _ = await scheduler.syncDue()
        #expect(!gh.calls.isEmpty)
        #expect(await seen.value == 7)
    }

    private actor Seen {
        var value: Int?
        func set(_ new: Int) { value = new }
    }
}
