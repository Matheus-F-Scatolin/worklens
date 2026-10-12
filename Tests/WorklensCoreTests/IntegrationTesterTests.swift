import Foundation
import Testing
@testable import WorklensCore

// MARK: - Fixtures

private func granola(_ session: URLSession) -> GranolaSource {
    GranolaSource(http: ContextHTTP(session: session, minimumSpacing: 0, maxRetries: 0, sleeper: { _ in }))
}

/// A source that fails in a way the test picks, so the scheduler's bookkeeping can be asserted
/// without a network.
private final class FailingSource: ContextSyncSource, @unchecked Sendable {
    let id: ContextSource
    let displayName = "Failing"
    private let failure: any Error

    init(id: ContextSource = .granola, failure: any Error) {
        self.id = id
        self.failure = failure
    }

    func isConfigured(_ config: Config) -> Bool { true }

    func sync(window: DateInterval, into store: ContextEventStore, config: Config) async throws -> SyncResult {
        throw failure
    }
}

// MARK: - The probes

@Suite("Integration Test button")
struct IntegrationTesterTests {
    @Test("Granola's check asks for one note and stores nothing")
    func granolaCheckSucceeds() async throws {
        let stub = Stub([.json("""
            {"notes": [{"id": "note-1", "created_at": "2026-09-07T10:00:00Z"}], "hasMore": false}
            """)])
        let outcome = await IntegrationTester(granola: granola(stub.session))
            .test(.granola, credential: "grn_abc")

        #expect(outcome == .ok("Granola answered, and your notes are reachable."))
        #expect(stub.sent.count == 1)
        #expect(stub.sent[0].url?.path == "/v1/notes")
        #expect(stub.sent[0].url?.query == "page_size=1")
    }

    @Test("a Granola account with no notes still counts as reachable")
    func granolaCheckEmpty() async {
        let stub = Stub([.json("""
            {"notes": [], "hasMore": false}
            """)])
        let outcome = await IntegrationTester(granola: granola(stub.session))
            .test(.granola, credential: "grn_abc")

        #expect(outcome == .ok("Granola answered, and has no finished meeting notes yet."))
    }

    @Test("Granola's 401 is a refusal whose sentence names the Business plan")
    func granolaCheckRefused() async {
        let stub = Stub([.json("{\"error\": \"unauthorized\"}", status: 401)])
        let outcome = await IntegrationTester(granola: granola(stub.session))
            .test(.granola, credential: "grn_wrong")

        #expect(outcome.level == .attention)
        #expect(outcome.line.contains("Business plan"))
        #expect(outcome.verdict == "refused")
    }

    @Test("an outage is a failure, not a refusal — retyping the key would not help")
    func granolaCheckFails() async {
        let stub = Stub([.json("{}", status: 503)])
        let outcome = await IntegrationTester(granola: granola(stub.session))
            .test(.granola, credential: "grn_abc")

        #expect(outcome.level == .problem)
        #expect(outcome.verdict == "could not ask")
    }

    @Test("an empty value and a source with nothing to probe both stay offline")
    func nothingToTest() async {
        let stub = Stub([.json("{}")])
        let tester = IntegrationTester(granola: granola(stub.session))

        #expect(await tester.test(.granola, credential: "   ").level == .attention)
        #expect(await tester.test(.calendar, credential: "anything").level == .problem)
        #expect(stub.sent.isEmpty, "neither case may reach the network")
    }
}

// MARK: - What the scheduler remembers

@Suite("Sync failures remember whether the credential was the problem")
struct SourceStatusCredentialTests {
    @Test("a refused credential is recorded as one, so the card can offer a paste")
    func recordsCredentialFailure() async throws {
        let db = try Database.inMemory()
        let scheduler = ContextSyncScheduler(
            sources: [FailingSource(failure: ContextSyncError.unauthorized("nope"))],
            db: db,
            config: Config.defaults()
        )
        await scheduler.syncNow()
        let status = try #require(await scheduler.statusList.first)

        #expect(status.lastError == "nope")
        #expect(status.lastErrorWasCredential)
    }

    @Test("a rate limit is not")
    func recordsOtherFailure() async throws {
        let db = try Database.inMemory()
        let scheduler = ContextSyncScheduler(
            sources: [FailingSource(failure: ContextSyncError.rateLimited(retryAfter: 30))],
            db: db,
            config: Config.defaults()
        )
        await scheduler.syncNow()
        let status = try #require(await scheduler.statusList.first)

        #expect(status.lastError != nil)
        #expect(!status.lastErrorWasCredential)
    }
}
