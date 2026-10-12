import Foundation
import Testing
@testable import WorklensCore

private let t0 = Date(timeIntervalSince1970: 1_757_000_000)   // 2025-09-04T15:33:20Z

private func block(_ day: String, offset: TimeInterval, source: ActivitySource = .screen) -> ActivityBlock {
    ActivityBlock(
        day: day,
        startAt: t0.addingTimeInterval(offset),
        endAt: t0.addingTimeInterval(offset + 600),
        appKey: "slack",
        taskKey: "reading",
        title: "#general",
        captureCount: 4,
        source: source,
        createdAt: t0,
        updatedAt: t0
    )
}

@Suite("ActivityBlockStore")
struct ActivityBlockStoreTests {
    @Test("upsert inserts, then replaces by id and refreshes updated_at")
    func upsertReplaces() throws {
        let db = try Database.inMemory()
        let store = ActivityBlockStore(db)
        var b = block("2025-09-04", offset: 0)
        try store.upsert(b)
        #expect(try store.fetch(day: "2025-09-04").count == 1)

        b.summaryMd = "You caught up on #general."
        b.captureCount = 9
        try store.upsert(b)

        let fetched = try store.fetch(day: "2025-09-04")
        #expect(fetched.count == 1)
        #expect(fetched.first?.captureCount == 9)
        #expect(fetched.first?.summaryMd == "You caught up on #general.")
        #expect((fetched.first?.updatedAt ?? .distantPast) > t0)
    }

    @Test("blocks come back in start order")
    func ordering() throws {
        let db = try Database.inMemory()
        let store = ActivityBlockStore(db)
        try store.upsert(block("2025-09-04", offset: 1200))
        try store.upsert(block("2025-09-04", offset: 0))
        let starts = try store.fetch(day: "2025-09-04").map(\.startAt)
        #expect(starts == starts.sorted())
    }

    @Test("deleteScreenBlocks spares blocks from context sources")
    func deleteScreenOnly() throws {
        let db = try Database.inMemory()
        let store = ActivityBlockStore(db)
        try store.upsert(block("2025-09-04", offset: 0, source: .screen))
        try store.upsert(block("2025-09-04", offset: 600, source: .granola))
        try store.upsert(block("2025-09-05", offset: 0, source: .screen))

        try store.deleteScreenBlocks(day: "2025-09-04")
        #expect(try store.fetch(day: "2025-09-04").map(\.source) == [.granola])
        #expect(try store.fetch(day: "2025-09-05").count == 1)
    }

    @Test("fetchRange is inclusive on both ends")
    func range() throws {
        let db = try Database.inMemory()
        let store = ActivityBlockStore(db)
        for day in ["2025-09-03", "2025-09-04", "2025-09-05", "2025-09-06"] {
            try store.upsert(block(day, offset: 0))
        }
        let days = try store.fetchRange(from: "2025-09-04", to: "2025-09-05").map(\.day)
        #expect(days == ["2025-09-04", "2025-09-05"])
    }
}

@Suite("LLMCallStore")
struct LLMCallStoreTests {
    private func call(_ offset: TimeInterval, cost: Double, purpose: LLMPurpose = .describe) -> LLMCall {
        LLMCall(provider: "gemini", model: "gemini-3.5-flash-lite", purpose: purpose,
                promptTokens: 1200, outputTokens: 150, thoughtTokens: 0, cachedTokens: 0,
                costUsd: cost, latencyMs: 800, httpStatus: 200,
                createdAt: t0.addingTimeInterval(offset))
    }

    @Test("insert and read back, including a failed call")
    func roundTrip() throws {
        let db = try Database.inMemory()
        let store = LLMCallStore(db)
        try store.insert(call(0, cost: 0.001))
        var failure = call(60, cost: 0)
        failure.httpStatus = 429
        failure.error = "rate limited"
        try store.insert(failure)

        #expect(try store.spend(from: t0, to: t0.addingTimeInterval(3600)) == 0.001)
    }

    @Test("spend is bounded by [from, to)")
    func spendWindow() throws {
        let db = try Database.inMemory()
        let store = LLMCallStore(db)
        try store.insert(call(0, cost: 0.10))
        try store.insert(call(100, cost: 0.20))
        try store.insert(call(1000, cost: 0.40))

        #expect(abs(try store.spend(from: t0, to: t0.addingTimeInterval(1000)) - 0.30) < 1e-9)
        #expect(try store.spend(from: t0.addingTimeInterval(2000), to: t0.addingTimeInterval(3000)) == 0)
    }

    /// The window is the last N **local** days ending today, so the fixture's own instants are
    /// what "now" has to be — days are not a substring of a UTC timestamp any more (#17).
    @Test("summary groups by local day, newest first, split by purpose")
    func dailySummary() throws {
        let db = try Database.inMemory()
        let store = LLMCallStore(db)
        try store.insert(call(0, cost: 0.10))
        try store.insert(call(60, cost: 0.05))
        try store.insert(call(60 * 60 * 24, cost: 0.20, purpose: .reportDaily))

        let utc = TimeZone(identifier: "UTC")!
        let secondDay = t0.addingTimeInterval(60 * 60 * 24)
        let summary = try store.summary(days: 7, timeZone: utc, now: secondDay)
        #expect(summary.map(\.day) == ["2025-09-05", "2025-09-04"])
        #expect(summary.first?.calls == 1)
        #expect(summary.first?.usd(.reportDaily) == 0.20)
        #expect(summary.first?.usd(.describe) == 0)
        #expect(summary.last?.calls == 2)
        #expect(abs((summary.last?.usd(.describe) ?? 0) - 0.15) < 1e-9)
        #expect(abs((summary.last?.costUsd ?? 0) - 0.15) < 1e-9)
        #expect(try store.summary(days: 1, timeZone: utc, now: secondDay).count == 1)
    }

    @Test("a failed call counts as a call, costs nothing, and is tallied separately")
    func failuresAreCounted() throws {
        let db = try Database.inMemory()
        let store = LLMCallStore(db)
        try store.insert(call(0, cost: 0.10))
        try store.insert(LLMCall(
            provider: "gemini", model: "gemini-3.5-flash-lite", purpose: .describe,
            costUsd: 0, httpStatus: 429, error: "rate limited", createdAt: t0
        ))

        let utc = TimeZone(identifier: "UTC")!
        let day = try #require(try store.summary(days: 1, timeZone: utc, now: t0).first)
        #expect(day.calls == 2)
        #expect(day.failures == 1)
        #expect(abs(day.costUsd - 0.10) < 1e-9)
        // The estimate is what the menu quotes before a paid call, so a 429 must not drag it
        // towards zero exactly when the provider is unhappy.
        let average = try store.averageCost(purpose: .describe, days: 1, timeZone: utc, now: t0)
        #expect(abs((average ?? 0) - 0.10) < 1e-9)
    }

    @Test("every inserted call is stamped with the price table it was costed against")
    func pricingVersionIsStamped() throws {
        let db = try Database.inMemory()
        try LLMCallStore(db).insert(call(0, cost: 0.10))
        let stored = try db.writer.read { try LLMCall.fetchAll($0) }
        #expect(stored.first?.pricingVersion == ModelPricing.pricingVersion)
    }
}

@Suite("ContextEventStore")
struct ContextEventStoreTests {
    private func event(
        _ source: ContextSource,
        _ externalId: String,
        offset: TimeInterval = 0,
        title: String = "Standup"
    ) -> ContextEvent {
        ContextEvent(source: source, externalId: externalId,
                     startAt: t0.addingTimeInterval(offset),
                     endAt: t0.addingTimeInterval(offset + 1800),
                     title: title, isMeeting: true, syncedAt: t0)
    }

    @Test("upsert on (source, external_id) updates instead of duplicating")
    func upsertUpdates() throws {
        let db = try Database.inMemory()
        let store = ContextEventStore(db)
        let first = event(.granola, "note-1", title: "Standup")
        try store.upsert(first)

        var second = event(.granola, "note-1", title: "Standup (renamed)")
        second.bodyMd = "notes"
        try store.upsert(second)

        let all = try store.fetch(from: t0.addingTimeInterval(-1), to: t0.addingTimeInterval(10_000))
        #expect(all.count == 1)
        #expect(all.first?.title == "Standup (renamed)")
        #expect(all.first?.bodyMd == "notes")
        // The row keeps its original id, so anything referencing it stays valid.
        #expect(all.first?.id == first.id)
    }

    @Test("the same external id under a different source is a separate event")
    func scopedBySource() throws {
        let db = try Database.inMemory()
        let store = ContextEventStore(db)
        try store.upsert(event(.granola, "shared-id"))
        try store.upsert(event(.calendar, "shared-id"))
        #expect(try store.fetch(from: t0.addingTimeInterval(-1), to: t0.addingTimeInterval(10_000)).count == 2)
    }

    @Test("fetch filters by window and by source")
    func filtering() throws {
        let db = try Database.inMemory()
        let store = ContextEventStore(db)
        try store.upsert(event(.granola, "a", offset: 0))
        try store.upsert(event(.calendar, "b", offset: 3600))
        try store.upsert(event(.calendar, "c", offset: 100_000))

        let window = try store.fetch(from: t0, to: t0.addingTimeInterval(7200))
        #expect(window.map(\.externalId) == ["a", "b"])

        let onlyCalendar = try store.fetch(from: t0, to: t0.addingTimeInterval(7200), sources: [.calendar])
        #expect(onlyCalendar.map(\.externalId) == ["b"])

        let emptyFilterMeansAll = try store.fetch(from: t0, to: t0.addingTimeInterval(7200), sources: [])
        #expect(emptyFilterMeansAll.count == 2)
    }
}

@Suite("AppStateStore")
struct AppStateStoreTests {
    @Test("get, set, overwrite and delete")
    func basics() throws {
        let db = try Database.inMemory()
        let store = AppStateStore(db)
        #expect(try store.get("missing") == nil)

        try store.set("cursor", "abc")
        #expect(try store.get("cursor") == "abc")
        try store.set("cursor", "def")
        #expect(try store.get("cursor") == "def")
        try store.delete("cursor")
        #expect(try store.get("cursor") == nil)
    }

    @Test("dates round trip to the second")
    func dates() throws {
        let db = try Database.inMemory()
        let store = AppStateStore(db)
        #expect(try store.getDate("last_report") == nil)
        try store.setDate("last_report", t0)
        #expect(try store.getDate("last_report") == t0)
    }

    @Test("codable values round trip")
    func codable() throws {
        struct Cursor: Codable, Equatable { let page: Int; let token: String }
        let db = try Database.inMemory()
        let store = AppStateStore(db)
        let none: Cursor? = try store.getCodable("sync_cursor")
        #expect(none == nil)

        try store.setCodable("sync_cursor", Cursor(page: 3, token: "xyz"))
        let read: Cursor? = try store.getCodable("sync_cursor")
        #expect(read == Cursor(page: 3, token: "xyz"))
    }
}
