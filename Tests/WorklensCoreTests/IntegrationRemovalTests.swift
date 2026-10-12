import Foundation
import Testing

@testable import WorklensCore

/// #141: taking one integration back out — the count, the delete, and the state it forgets.
private let utc = TimeZone(identifier: "UTC")!
private let day = "2026-09-07"
private let noon = DayBoundaries.range(day: day, timeZone: utc)!.start.addingTimeInterval(12 * 3600)

private func temporaryConfig() -> Config {
    var config = Config.defaults()
    config.dataDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("worklens-removal-\(UUID().uuidString)")
    return config
}

@Suite("Removing one integration (#141)")
struct IntegrationRemovalTests {
    private func seed(_ db: Database, _ config: Config) throws {
        let store = ContextEventStore(db)
        let transcript = try ContextBody.write(
            "# Standup\nnotes", source: .granola, externalId: "g-1", config: config
        )
        _ = try store.save(
            ContextEvent(
                source: .granola, externalId: "g-1", startAt: noon, endAt: noon.addingTimeInterval(1800),
                title: "Standup", bodyPath: transcript, isMeeting: true, syncedAt: noon
            )
        )
        _ = try store.save(
            ContextEvent(
                source: .granola, externalId: "g-2", startAt: noon.addingTimeInterval(-86_400),
                title: "Retro", isMeeting: true, syncedAt: noon
            )
        )
        // Another source's row, which none of this may touch.
        _ = try store.save(
            ContextEvent(
                source: .calendar, externalId: "c-1", startAt: noon, title: "Lunch", isMeeting: false,
                syncedAt: noon
            )
        )
        try ActivityBlockStore(db).upsert(
            ActivityBlock(
                day: day, startAt: noon, endAt: noon.addingTimeInterval(1800), appKey: "granola",
                taskKey: "meeting", title: "Standup", source: .granola
            )
        )
    }

    @Test("the plan counts before anything is removed")
    func counts() throws {
        let db = try Database.inMemory()
        let config = temporaryConfig()
        defer { try? FileManager.default.removeItem(at: config.dataDir) }
        try seed(db, config)

        let plan = try IntegrationRemoval.plan(
            source: .granola, db: db, config: config, timeZone: utc
        )
        #expect(plan.events == 2)
        #expect(plan.files == 1)
        #expect(plan.blocks == 1)
        #expect(plan.days == ["2026-09-06", "2026-09-07"])
        #expect(plan.summary == "2 meetings, 1 transcript file and 1 timeline block")
        // Counting removed nothing.
        #expect(try ContextEventStore(db).count(source: .granola) == 2)
    }

    @Test("the delete takes the rows, the files and the blocks, and only this source's")
    func deletes() throws {
        let db = try Database.inMemory()
        let config = temporaryConfig()
        defer { try? FileManager.default.removeItem(at: config.dataDir) }
        try seed(db, config)
        let transcript = config.dataDir.appendingPathComponent(
            ContextBody.relativePath(source: .granola, externalId: "g-1")
        )
        #expect(FileManager.default.fileExists(atPath: transcript.path))

        let done = try IntegrationRemoval.deleteSyncedData(
            source: .granola, db: db, config: config, timeZone: utc
        )

        #expect(done.events == 2)
        #expect(done.days == ["2026-09-06", "2026-09-07"])
        #expect(try ContextEventStore(db).count(source: .granola) == 0)
        #expect(try ContextEventStore(db).count(source: .calendar) == 1, "another source is untouched")
        #expect(!FileManager.default.fileExists(atPath: transcript.path))
        #expect(try ActivityBlockStore(db).fetch(day: day).isEmpty)
    }

    @Test("a meeting across midnight is planned for both days it has a block on")
    func acrossMidnight() throws {
        let db = try Database.inMemory()
        let config = temporaryConfig()
        defer { try? FileManager.default.removeItem(at: config.dataDir) }
        let start = DayBoundaries.range(day: day, timeZone: utc)!.end.addingTimeInterval(-1800)
        _ = try ContextEventStore(db).save(
            ContextEvent(
                source: .granola, externalId: "g-late", startAt: start,
                endAt: start.addingTimeInterval(3600), title: "Handover", isMeeting: true,
                syncedAt: start
            )
        )

        let plan = try IntegrationRemoval.plan(
            source: .granola, db: db, config: config, timeZone: utc
        )
        #expect(
            plan.days == ["2026-09-07", "2026-09-08"],
            "the next day carries a clamped block too, and it has to be deleted and redrawn"
        )
    }

    @Test("a source with nothing synted deletes nothing and says so")
    func empty() throws {
        let db = try Database.inMemory()
        let config = temporaryConfig()
        let plan = try IntegrationRemoval.plan(source: .calendar, db: db, config: config, timeZone: utc)
        #expect(plan.isEmpty)
        #expect(plan.summary == "nothing")
    }

    @Test("clearing state forgets the stored status, not the events")
    func clearsState() throws {
        let db = try Database.inMemory()
        let config = temporaryConfig()
        defer { try? FileManager.default.removeItem(at: config.dataDir) }
        try seed(db, config)
        let state = AppStateStore(db)
        try state.setCodable(
            SourceStatus.statusKey(.granola), SourceStatus.Persisted(lastSyncAt: noon)
        )

        try IntegrationRemoval.clearState(source: .granola, db: db)

        #expect(try state.get(SourceStatus.statusKey(.granola)) == nil)
        #expect(try ContextEventStore(db).count(source: .granola) == 2, "disconnecting keeps history")
    }

    @Test("Worklens only offers to remove the credentials it can write")
    func credentials() {
        #expect(IntegrationRemoval.credentialKeys(for: .granola) == ["GRANOLA_API_KEY"])
        // Google's connection is the OAuth grant, which `GoogleAuth.disconnect()` revokes; the
        // client id and secret are the app registration and stay.
        #expect(IntegrationRemoval.credentialKeys(for: .calendar).isEmpty)
    }

    @Test("every source names a page where the grant can be revoked")
    func revokeLinks() {
        #expect(IntegrationRemoval.revokeURL(for: .calendar).host == "myaccount.google.com")
        #expect(IntegrationRemoval.revokeURL(for: .granola).host == "app.granola.ai")
        #expect(IntegrationRemoval.revokeTitle(for: .calendar) == "Revoke at Google\u{2026}")
    }

    @Test("each source owns the timeline blocks of its own name")
    func blockSources() {
        #expect(IntegrationRemoval.activitySource(.granola) == .granola)
        #expect(IntegrationRemoval.activitySource(.calendar) == .calendar)
    }
}
