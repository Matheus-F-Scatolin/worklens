import Foundation
import Testing
@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!
/// 2026-09-07T12:00:00Z.
private let now = Date(timeIntervalSince1970: 1_788_782_400)
private let today = DayBoundaries.dayString(now, timeZone: utc)

// MARK: - Classifying

@Suite("Describe health (#125)")
struct DescribeHealthTests {
    @Test("a rejected key is named as one, whatever status the provider chose to say it with")
    func rejectedKey() {
        for error in [
            LLMError.badRequest(401, "unauthorized"),
            LLMError.badRequest(403, "forbidden"),
            // Gemini's own answer to a mistyped key.
            LLMError.badRequest(400, #"{"error":{"status":"INVALID_ARGUMENT","message":"API key not valid"}}"#),
            LLMError.badRequest(400, #"{"error":{"reason":"API_KEY_INVALID"}}"#),
        ] {
            let failure = DescribeHealth.classify(error, provider: GeminiClient.provider)
            #expect(failure.reason == "Gemini rejected the key")
            #expect(failure.isRefusal)
            #expect(!failure.isUnreachable)
        }
    }

    @Test("a spent quota is a refusal too: retrying the frame cannot help")
    func quota() {
        let limited = DescribeHealth.classify(LLMError.rateLimited, provider: "gemini")
        #expect(limited.reason == "Gemini's quota is spent")
        #expect(limited.httpStatus == 429)
        #expect(limited.isRefusal)

        let asStatus = DescribeHealth.classify(LLMError.badRequest(429, "slow down"), provider: "gemini")
        #expect(asStatus.isRefusal)
    }

    @Test("an unreachable provider and a failing one are neither of them refusals")
    func notRefusals() {
        let offline = DescribeHealth.classify(LLMError.network("offline"), provider: "gemini")
        #expect(offline.reason == "Gemini is unreachable")
        #expect(offline.isUnreachable)
        #expect(!offline.isRefusal)

        let urlError = DescribeHealth.classify(URLError(.notConnectedToInternet), provider: "gemini")
        #expect(urlError.isUnreachable)

        let server = DescribeHealth.classify(LLMError.serverError(503), provider: "gemini")
        #expect(server.reason == "Gemini is having trouble")
        #expect(server.httpStatus == 503)
        #expect(!server.isRefusal)

        // A 400 that says nothing about the key is about the request, so the frame keeps paying
        // for it — that is the existing three-attempts path and #125 does not change it.
        let badRequest = DescribeHealth.classify(LLMError.badRequest(400, "bad json"), provider: "gemini")
        #expect(badRequest.reason == "Gemini refused the request")
        #expect(!badRequest.isRefusal)
    }

    @Test("no classification ever carries the provider's response body")
    func noBodies() {
        let secret = "quota_metric: generativelanguage.googleapis.com/secret-project-42"
        let failure = DescribeHealth.classify(LLMError.badRequest(403, secret), provider: "gemini")
        #expect(!failure.reason.contains("secret-project-42"))
        let health = DescribeHealth.failing(message: failure.reason, httpStatus: failure.httpStatus)
        #expect(!(health.line() ?? "").contains("secret-project-42"))
    }

    // MARK: Rendering

    @Test("each health state renders its own line")
    func lines() {
        #expect(DescribeHealth.ok.line(now: now, timeZone: utc) == nil)
        #expect(DescribeHealth.ok.settingsLine(now: now, timeZone: utc) == "Running normally")

        let rejected = DescribeHealth.failing(message: "Gemini rejected the key", httpStatus: 403)
        #expect(rejected.line(now: now, timeZone: utc)
            == "Not summarizing: Gemini rejected the key (HTTP 403)")
        #expect(rejected.isFailing)
        #expect(rejected.isKeyRejection)

        let schema = DescribeHealth.failing(
            message: "Gemini's answers did not fit the schema", httpStatus: nil
        )
        #expect(schema.line(now: now, timeZone: utc)
            == "Not summarizing: Gemini's answers did not fit the schema")
        #expect(!schema.isKeyRejection)

        let holding = DescribeHealth.holding(
            until: now.addingTimeInterval(300), reason: "Gemini is unreachable"
        )
        #expect(holding.line(now: now, timeZone: utc)
            == "Not summarizing: Gemini is unreachable; trying again at 12:05")
        // A hold clears itself, so it is not the state that earns the attention icon.
        #expect(!holding.isFailing)
    }

    @Test("the banner is owed on the failing edge, including the stall reached through a hold")
    func stallEdge() {
        let rejected = DescribeHealth.failing(message: "Gemini rejected the key", httpStatus: 403)
        let unreachable = DescribeHealth.holding(
            until: now.addingTimeInterval(300), reason: "Gemini is unreachable"
        )
        let trouble = DescribeHealth.failing(message: "Gemini is having trouble", httpStatus: 503)

        // The plain case: working, then not.
        #expect(rejected.startsStall(after: .ok))
        // The case that used to go silent — offline for a while, then a key the provider will
        // not accept. Nothing is being summarized and the user has heard nothing about it.
        #expect(rejected.startsStall(after: unreachable))

        // One stretch, one banner: a stall that changes its mind about why does not say it twice.
        #expect(!trouble.startsStall(after: rejected))
        #expect(!rejected.startsStall(after: rejected))

        // A hold is not a stall, whatever it follows: it clears itself.
        #expect(!unreachable.startsStall(after: .ok))
        #expect(!DescribeHealth.ok.startsStall(after: rejected))
    }

    @Test("a quota refusal is not a key problem, however loudly it fails")
    func quotaIsNotAKeyProblem() {
        let quota = DescribeHealth.failing(message: "Gemini's quota is spent", httpStatus: 429)
        #expect(quota.isFailing)
        #expect(!quota.isKeyRejection)
    }

    @Test("the last summary time reads as a time, and says so when there has never been one")
    func lastSummary() {
        #expect(DescribeHealth.lastSummaryLine(nil, now: now, timeZone: utc)
            == "No frames summarized yet")
        #expect(DescribeHealth.lastSummaryLine(
            now.addingTimeInterval(-1800), now: now, timeZone: utc
        ) == "Today at 11:30")
        #expect(DescribeHealth.lastSummaryLine(
            now.addingTimeInterval(-26 * 3600), now: now, timeZone: utc
        ) == "2026-09-06 at 10:00")
    }
}

// MARK: - Reading a ledger row back

@Suite("Was it the key or the frame? (#189)")
struct KeyWasRejectedTests {
    @Test("401 and 403 are about the caller whatever the body says")
    func authStatuses() {
        #expect(DescribeHealth.keyWasRejected(httpStatus: 401, error: nil))
        #expect(DescribeHealth.keyWasRejected(httpStatus: 403, error: "forbidden"))
    }

    @Test("a 400 counts only when the stored text names the key")
    func fourHundredNeedsTheMarker() {
        #expect(DescribeHealth.keyWasRejected(
            httpStatus: 400, error: #"{"error":{"details":[{"reason":"API_KEY_INVALID"}]}}"#
        ))
        #expect(DescribeHealth.keyWasRejected(httpStatus: 400, error: "API key not valid"))
        // The money-leak shape: the provider looked at the frame and said no to the frame.
        #expect(!DescribeHealth.keyWasRejected(
            httpStatus: 400, error: "Request payload size exceeds the limit"
        ))
        #expect(!DescribeHealth.keyWasRejected(httpStatus: 400, error: "HTTP 400"))
        #expect(!DescribeHealth.keyWasRejected(httpStatus: 400, error: nil))
    }

    @Test("a spent quota, a provider having trouble and a statusless row are all no")
    func everythingElse() {
        for status in [200, 404, 429, 500, 503] {
            #expect(!DescribeHealth.keyWasRejected(httpStatus: status, error: "API_KEY_INVALID"))
        }
        #expect(!DescribeHealth.keyWasRejected(httpStatus: nil, error: "API_KEY_INVALID"))
    }

    @Test("it agrees with the live classification of the same failure")
    func agreesWithClassify() {
        for (status, body) in [(401, ""), (403, ""), (400, "API_KEY_INVALID")] {
            let failure = DescribeHealth.classify(
                LLMError.badRequest(status, body), provider: "gemini"
            )
            #expect(failure.reason.contains("rejected the key"))
            #expect(DescribeHealth.keyWasRejected(httpStatus: status, error: body))
        }
        let frameFailure = DescribeHealth.classify(
            LLMError.badRequest(400, "Request payload size exceeds the limit"),
            provider: "gemini"
        )
        #expect(!frameFailure.reason.contains("rejected the key"))
        #expect(!DescribeHealth.keyWasRejected(
            httpStatus: 400, error: "Request payload size exceeds the limit"
        ))
    }
}

// MARK: - The repair

@Suite("Re-queueing the frames a rejected key failed (#125)")
struct RequeueRejectedFailuresTests {
    private func harness() throws -> (Database, DescribeQueries, CaptureStore) {
        let db = try Database.inMemory()
        return (db, DescribeQueries(db), CaptureStore(db))
    }

    @discardableResult
    private func addFailed(_ captures: CaptureStore, at: Date, attempts: Int = 3) throws -> Capture {
        let capture = Capture(
            capturedAt: at, appBundleId: "com.mitchellh.ghostty", appName: "Ghostty",
            describeStatus: .failed, describeAttempts: attempts
        )
        try captures.insert(capture)
        return capture
    }

    private func addRejection(
        _ db: Database, at: Date, status: Int = 403, error: String? = nil
    ) throws {
        try LLMCallStore(db).insert(LLMCall(
            provider: "gemini", model: "gemini-3.5-flash-lite", purpose: .describe,
            costUsd: 0, httpStatus: status, error: error ?? "HTTP \(status)", createdAt: at
        ))
    }

    /// What Gemini's body looks like when the key is the problem.
    private static let keyInvalidBody =
        #"{"error":{"code":400,"status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#

    /// What it looks like when the *frame* is the problem: the money-leak case.
    private static let oversizedImageBody =
        #"{"error":{"code":400,"status":"INVALID_ARGUMENT","message":"Request payload size exceeds the limit"}}"#

    @Test("today's failed frames go back to pending once the ledger shows a rejected key")
    func requeues() throws {
        let (db, queries, captures) = try harness()
        let first = try addFailed(captures, at: now)
        let second = try addFailed(captures, at: now.addingTimeInterval(-3600))
        try addRejection(db, at: now)

        #expect(try queries.requeueRejectedFailures(day: today, timeZone: utc) == 2)
        for id in [first.id, second.id] {
            let reloaded = try #require(try captures.fetch(id: id))
            #expect(reloaded.describeStatus == .pending)
            // Attempts back at zero, or the very next failure would give up on the frame again.
            #expect(reloaded.describeAttempts == 0)
        }
    }

    @Test("401, 403 and a 400 that named the key count; every other status is left alone")
    func onlyAuthStatuses() throws {
        for status in [401, 403] {
            let (db, queries, captures) = try harness()
            try addFailed(captures, at: now)
            try addRejection(db, at: now, status: status)
            #expect(try queries.requeueRejectedFailures(day: today, timeZone: utc) == 1)
        }
        do {
            let (db, queries, captures) = try harness()
            try addFailed(captures, at: now)
            try addRejection(db, at: now, status: 400, error: Self.keyInvalidBody)
            #expect(try queries.requeueRejectedFailures(day: today, timeZone: utc) == 1)
        }
        for status in [429, 500, 503] {
            let (db, queries, captures) = try harness()
            try addFailed(captures, at: now)
            try addRejection(db, at: now, status: status)
            #expect(try queries.requeueRejectedFailures(day: today, timeZone: utc) == 0)
        }
    }

    // MARK: - #189: a 400 about the frame is not a rejected key

    @Test("a 400 the frame itself caused leaves the frame failed, reload after reload")
    func nonAuth400IsNotRequeued() throws {
        let (db, queries, captures) = try harness()
        let capture = try addFailed(captures, at: now)
        // Three attempts, three identical 400 rows — exactly what `DescribeWorker.recordFailure`
        // leaves behind for an oversized frame before it gives up.
        for _ in 0..<3 {
            try addRejection(db, at: now, status: 400, error: Self.oversizedImageBody)
        }

        // The money leak was here: every configuration reload put the frame back, it spent three
        // more paid describe calls, wrote three more 400 rows, and the next reload saw those.
        #expect(try queries.requeueRejectedFailures(day: today, timeZone: utc) == 0)
        #expect(try captures.fetch(id: capture.id)?.describeStatus == .failed)

        // A second reload, with the ledger unchanged, must be just as quiet.
        #expect(try queries.requeueRejectedFailures(day: today, timeZone: utc) == 0)
        let reloaded = try #require(try captures.fetch(id: capture.id))
        #expect(reloaded.describeStatus == .failed)
        #expect(reloaded.describeAttempts == 3)
    }

    @Test("a 400 with no stored body is not a rejected key either")
    func blank400IsNotRequeued() throws {
        let (db, queries, captures) = try harness()
        try addFailed(captures, at: now)
        try LLMCallStore(db).insert(LLMCall(
            provider: "gemini", model: "gemini-3.5-flash-lite", purpose: .describe,
            costUsd: 0, httpStatus: 400, error: nil, createdAt: now
        ))
        #expect(try queries.requeueRejectedFailures(day: today, timeZone: utc) == 0)
    }

    @Test("a real rejection still wins when a frame-shaped 400 sits beside it")
    func realRejectionAmongNoise() throws {
        let (db, queries, captures) = try harness()
        let capture = try addFailed(captures, at: now)
        try addRejection(db, at: now, status: 400, error: Self.oversizedImageBody)
        try addRejection(db, at: now, status: 400, error: Self.keyInvalidBody)

        #expect(try queries.requeueRejectedFailures(day: today, timeZone: utc) == 1)
        #expect(try captures.fetch(id: capture.id)?.describeStatus == .pending)
    }

    @Test("without a rejection in the ledger nothing is touched: a failed frame stays failed")
    func noRejectionNoRepair() throws {
        let (_, queries, captures) = try harness()
        let capture = try addFailed(captures, at: now)

        #expect(try queries.requeueRejectedFailures(day: today, timeZone: utc) == 0)
        #expect(try captures.fetch(id: capture.id)?.describeStatus == .failed)
    }

    @Test("a frame that already has a description, and another day's frames, are left alone")
    func narrowScope() throws {
        let (db, queries, captures) = try harness()
        try addRejection(db, at: now)

        let described = try addFailed(captures, at: now)
        try DescriptionStore(db).insert(Description(
            captureId: described.id, provider: "gemini", model: "gemini-3.5-flash-lite",
            appKey: "terminal", taskKey: "coding_with_agent", summaryMd: "Already summarized."
        ))
        let yesterday = try addFailed(captures, at: now.addingTimeInterval(-26 * 3600))

        #expect(try queries.requeueRejectedFailures(day: today, timeZone: utc) == 0)
        #expect(try captures.fetch(id: described.id)?.describeStatus == .failed)
        #expect(try captures.fetch(id: yesterday.id)?.describeStatus == .failed)
    }

    @Test("a day that is not a day is not a repair")
    func badDay() throws {
        let (db, queries, captures) = try harness()
        try addFailed(captures, at: now)
        try addRejection(db, at: now)
        #expect(try queries.requeueRejectedFailures(day: "not-a-day", timeZone: utc) == 0)
    }

    @Test("the last summary time comes back from the descriptions table")
    func lastDescribedAt() throws {
        let (db, queries, captures) = try harness()
        #expect(try queries.lastDescribedAt() == nil)

        let capture = Capture(capturedAt: now, describeStatus: .described)
        try captures.insert(capture)
        try DescriptionStore(db).insert(Description(
            captureId: capture.id, provider: "gemini", model: "gemini-3.5-flash-lite",
            appKey: "terminal", taskKey: "coding_with_agent", summaryMd: "A summary.",
            createdAt: now
        ))
        let at = try #require(try queries.lastDescribedAt())
        #expect(abs(at.timeIntervalSince(now)) < 1)
    }
}
