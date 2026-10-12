import Foundation
import GRDB
import Testing
@testable import WorklensCore

/// A fixed instant so day-boundary arithmetic in the tests is not clock-dependent.
private let t0 = Date(timeIntervalSince1970: 1_757_000_000)   // 2025-09-04T15:33:20Z

private func capture(
    _ offset: TimeInterval,
    status: DescribeStatus = .pending,
    imagePath: String? = nil,
    app: String? = "Slack"
) -> Capture {
    Capture(
        capturedAt: t0.addingTimeInterval(offset),
        imagePath: imagePath,
        appBundleId: "com.tinyspeck.slackmacgap",
        appName: app,
        describeStatus: status,
        createdAt: t0.addingTimeInterval(offset)
    )
}

private func description(for captureId: String, task: String = "reading") -> Description {
    Description(
        captureId: captureId,
        provider: "gemini",
        model: "gemini-3.5-flash-lite",
        appKey: "slack",
        taskKey: task,
        summaryMd: "You were reading a thread.",
        createdAt: t0
    )
}

@Suite("Database")
struct DatabaseTests {
    @Test("in-memory database has the whole v1 schema")
    func schema() throws {
        let db = try Database.inMemory()
        let counts = try db.tableCounts()
        #expect(counts.map(\.table) == Migrations.tableNames)
        #expect(counts.allSatisfy { $0.rows == 0 })
        #expect(try db.integrityCheck() == "ok")
    }

    @Test("v4 adds capture_source and ax_snapshots, and a v3 database keeps its rows")
    func migrationV4() throws {
        let queue = try DatabaseQueue(configuration: Database.configuration())
        try Migrations.migrator.migrate(queue, upTo: "v3")

        // A frame written before #53: pixels only, and no column to say so.
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO captures (id, captured_at, describe_status, describe_attempts,
                                      is_idle, is_redacted, is_meeting, created_at)
                VALUES ('before-v4', ?, 'described', 0, 0, 0, 0, ?)
                """, arguments: [t0, t0])
        }
        #expect(try queue.read { try $0.tableExists("ax_snapshots") } == false)

        try Migrations.migrator.migrate(queue)

        let columns = try queue.read { try $0.columns(in: "ax_snapshots").map(\.name) }
        #expect(columns == [
            "capture_id", "coverage", "node_count", "text_chars", "elapsed_ms",
            "text_hash", "document_url", "text", "redactions_json", "created_at",
        ])
        // Nullable, because nothing is known about how a pre-#53 frame was captured.
        let old = try queue.read { try Capture.fetchOne($0, key: "before-v4") }
        #expect(old?.captureSource == nil)

        // And the new column round-trips the enum.
        try queue.write { db in
            var row = try #require(try Capture.fetchOne(db, key: "before-v4"))
            row.captureSource = .both
            try row.update(db)
        }
        #expect(try queue.read { try Capture.fetchOne($0, key: "before-v4") }?.captureSource == .both)
    }

    @Test("#286: the first capture of a day, and nil for a day with none")
    func firstCaptureOfTheDay() throws {
        let db = try Database.inMemory()
        let store = CaptureStore(db)
        let utc = TimeZone(identifier: "UTC")!
        let day = DayBoundaries.dayString(t0, timeZone: utc)
        #expect(try store.firstCaptureAt(day: day, timeZone: utc) == nil)
        try store.insert(Capture(capturedAt: t0.addingTimeInterval(600), appBundleId: "com.apple.Terminal"))
        try store.insert(Capture(capturedAt: t0.addingTimeInterval(60), appBundleId: "com.apple.Terminal"))
        let first = try store.firstCaptureAt(day: day, timeZone: utc)
        #expect(abs((first ?? .distantPast).timeIntervalSince(t0.addingTimeInterval(60))) < 0.01)
    }

    @Test("#64: today's browsers with no URL at all, straight from url_source")
    func browsersWithoutURLs() throws {
        let db = try Database.inMemory()
        let store = CaptureStore(db)
        func frame(_ offset: TimeInterval, _ bundleID: String, _ url: ForegroundContext.Source) -> Capture {
            Capture(
                capturedAt: t0.addingTimeInterval(offset),
                appBundleId: bundleID,
                titleSource: .ax,
                urlSource: url
            )
        }
        try store.insert(frame(0, "com.google.Chrome", .none))
        try store.insert(frame(60, "com.google.Chrome", .none))
        // Safari answered, so it has nothing to complain about.
        try store.insert(frame(120, "com.apple.Safari", .ax))
        // A non-browser frame is `.none` by definition and must not turn into a warning.
        try store.insert(frame(180, "com.apple.Terminal", .none))

        let day = DayBoundaries.dayString(t0)
        #expect(try store.browserBundlesWithoutURL(day: day) == ["com.google.Chrome"])

        // Another day's frames are another day's problem.
        #expect(try store.browserBundlesWithoutURL(
            day: DayBoundaries.dayString(t0.addingTimeInterval(-86_400))
        ).isEmpty)

        // One frame from either reader is proof the path works, and it clears the day: a line
        // saying URLs are unavailable while they are arriving would be worse than no line.
        // Found live on 2026-09-09, where Accessibility was granted after four blind frames.
        try store.insert(frame(240, "com.google.Chrome", .applescript))
        #expect(try store.browserBundlesWithoutURL(day: day).isEmpty)

        // A row that recorded no source at all — a pre-#55 build, or a blocked frame — cannot
        // say whether a URL was read, so it is evidence of nothing in either direction.
        try store.insert(Capture(
            capturedAt: t0.addingTimeInterval(300), appBundleId: "com.brave.Browser"
        ))
        #expect(try store.browserBundlesWithoutURL(day: day).isEmpty)

        // A null URL source on a row that *did* record a title is a missing URL, counted the way
        // the day's split counts it, and Brave has nothing else today to clear it.
        try store.insert(Capture(
            capturedAt: t0.addingTimeInterval(360), appBundleId: "com.brave.Browser",
            titleSource: .ax, urlSource: nil
        ))
        #expect(try store.browserBundlesWithoutURL(day: day) == ["com.brave.Browser"])
    }

    @Test("an ax_snapshots row is keyed by its capture and goes when the capture does")
    func axSnapshotCascade() throws {
        let db = try Database.inMemory()
        let store = AXSnapshotStore(db)
        let frame = capture(0, status: .described)
        try CaptureStore(db).insert(frame)
        try store.insert(AXSnapshotRecord(
            captureId: frame.id, coverage: .full, nodeCount: 40, textChars: 12,
            textHash: AXOutline.hash("hello"), text: "hello", createdAt: t0
        ))
        #expect(try store.fetch(captureId: frame.id)?.coverage == .full)

        // Only the text goes when retention asks; the hash and the grade stay.
        try store.clearText(captureId: frame.id)
        let trimmed = try #require(try store.fetch(captureId: frame.id))
        #expect(trimmed.text == nil)
        #expect(trimmed.textHash == AXOutline.hash("hello"))
        #expect(trimmed.coverage == .full)
        #expect(trimmed.textChars == 12)

        _ = try CaptureStore(db).deleteRange(from: t0.addingTimeInterval(-1), to: t0.addingTimeInterval(1))
        #expect(try store.fetch(captureId: frame.id) == nil)
    }

    @Test("opening an on-disk database twice is a no-op the second time")
    func reopen() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-db-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try Database(dataDir: dir)
        try CaptureStore(first).insert(capture(0))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("worklens.sqlite").path))

        let second = try Database(dataDir: dir)
        #expect(try CaptureStore(second).fetchPendingDescribe(limit: 10).count == 1)
    }

    @Test("foreign keys are enforced")
    func foreignKeys() throws {
        let db = try Database.inMemory()
        #expect(throws: (any Error).self) {
            try DescriptionStore(db).insert(description(for: "no-such-capture"))
        }
    }

    @Test("reading while another task writes never raises SQLITE_BUSY")
    func concurrentReadWhileWriting() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-db-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(dataDir: dir)
        let captures = CaptureStore(db)

        async let writes: Void = {
            for i in 0..<200 {
                try captures.insert(capture(Double(i)))
            }
        }()
        async let reads: Int = {
            var seen = 0
            for _ in 0..<200 {
                seen = try captures.fetchPendingDescribe(limit: 500).count
            }
            return seen
        }()

        try await writes
        _ = try await reads
        #expect(try captures.fetchPendingDescribe(limit: 500).count == 200)
    }
}

@Suite("CaptureStore")
struct CaptureStoreTests {
    @Test("insert and fetch round trip preserves every field")
    func roundTrip() throws {
        let db = try Database.inMemory()
        let store = CaptureStore(db)
        var c = capture(0, imagePath: "screenshots/2025-09-04/153320_abc.jpg")
        c.displayId = 1
        c.width = 1024
        c.height = 640
        c.dhash = "0f1e2d3c4b5a6978"
        c.changeScore = 0.42
        c.windowTitle = "#general"
        c.browserUrl = "https://example.test/x"
        c.urlHost = "example.test"
        c.contextSignature = "slack|#general"
        c.isMeeting = true
        c.skipReason = .unchanged
        c.describeAttempts = 2

        try store.insert(c)
        let fetched = try store.fetch(id: c.id)
        #expect(fetched == c)
    }

    @Test("pending frames come back oldest first and exclude other statuses")
    func pendingOrdering() throws {
        let db = try Database.inMemory()
        let store = CaptureStore(db)
        let later = capture(120)
        let earlier = capture(60)
        let done = capture(90, status: .described)
        try store.insert(later)
        try store.insert(done)
        try store.insert(earlier)

        let pending = try store.fetchPendingDescribe(limit: 10)
        #expect(pending.map(\.id) == [earlier.id, later.id])
        #expect(try store.fetchPendingDescribe(limit: 1).map(\.id) == [earlier.id])
    }

    @Test("fetchLastDescribed returns the newest described or inherited frame")
    func lastDescribed() throws {
        let db = try Database.inMemory()
        let store = CaptureStore(db)
        try store.insert(capture(0, status: .described))
        let newest = capture(600, status: .inherited)
        try store.insert(newest)
        try store.insert(capture(900, status: .pending))
        try store.insert(capture(1200, status: .failed))

        #expect(try store.fetchLastDescribed()?.id == newest.id)
    }

    @Test("markDescribed updates only the named row")
    func markDescribed() throws {
        let db = try Database.inMemory()
        let store = CaptureStore(db)
        let a = capture(0)
        let b = capture(60)
        try store.insert(a)
        try store.insert(b)

        try store.markDescribed(id: a.id, status: .described)
        #expect(try store.fetch(id: a.id)?.describeStatus == .described)
        #expect(try store.fetch(id: b.id)?.describeStatus == .pending)
    }

    @Test("update writes changed fields back")
    func update() throws {
        let db = try Database.inMemory()
        let store = CaptureStore(db)
        var c = capture(0)
        try store.insert(c)
        c.imagePath = nil
        c.describeAttempts = 3
        c.skipReason = .budget
        try store.update(c)

        let fetched = try store.fetch(id: c.id)
        #expect(fetched?.describeAttempts == 3)
        #expect(fetched?.skipReason == .budget)
        #expect(fetched?.imagePath == nil)
    }

    @Test("day queries use local day boundaries")
    func dayQueries() throws {
        let db = try Database.inMemory()
        let store = CaptureStore(db)
        let utc = TimeZone(identifier: "UTC")!
        try store.insert(capture(0))                    // 2025-09-04T15:33:20Z
        try store.insert(capture(3600))                 // same day
        try store.insert(capture(60 * 60 * 24))         // next day

        #expect(try store.fetch(day: "2025-09-04", timeZone: utc).count == 2)
        #expect(try store.count(day: "2025-09-05", timeZone: utc) == 1)
        #expect(try store.fetch(day: "not-a-day", timeZone: utc).isEmpty)
    }

    @Test("countToday counts what was captured today")
    func countToday() throws {
        let db = try Database.inMemory()
        let store = CaptureStore(db)
        try store.insert(capture(0))                                  // 2025
        try store.insert(Capture(capturedAt: Date(), createdAt: Date()))
        #expect(try store.countToday() == 1)
    }

    @Test("the last fingerprint survives a round trip through app_state")
    func fingerprintRoundTrip() throws {
        struct Fake: Codable, Equatable { let dhash: UInt64; let thumb: [UInt8] }
        let db = try Database.inMemory()
        let store = CaptureStore(db)

        let none: Fake? = try store.fetchLastFingerprint()
        #expect(none == nil)

        let value = Fake(dhash: 0xDEAD_BEEF_CAFE_F00D, thumb: [1, 2, 3])
        try store.setLastFingerprint(value)
        let read: Fake? = try store.fetchLastFingerprint()
        #expect(read == value)

        // Stored under app_state, not as a captures column.
        #expect(try AppStateStore(db).get(CaptureStore.lastFingerprintKey) != nil)
    }

    @Test("deleteRange returns image paths and cascades to descriptions")
    func deleteRangeCascades() throws {
        let db = try Database.inMemory()
        let captures = CaptureStore(db)
        let descriptions = DescriptionStore(db)

        let doomedA = capture(0, imagePath: "screenshots/a.jpg")
        let doomedB = capture(60, imagePath: nil)
        let survivor = capture(6000, imagePath: "screenshots/c.jpg")
        for c in [doomedA, doomedB, survivor] { try captures.insert(c) }
        try descriptions.insert(description(for: doomedA.id))
        try descriptions.insert(description(for: survivor.id))

        let paths = try captures.deleteRange(from: t0, to: t0.addingTimeInterval(120))
        #expect(paths == ["screenshots/a.jpg"])
        #expect(try captures.fetch(id: doomedA.id) == nil)
        #expect(try captures.fetch(id: survivor.id) != nil)
        #expect(try descriptions.fetch(captureId: doomedA.id) == nil)
        #expect(try descriptions.fetch(captureId: survivor.id) != nil)
    }
}

@Suite("DescriptionStore")
struct DescriptionStoreTests {
    @Test("insert and fetch by capture id")
    func roundTrip() throws {
        let db = try Database.inMemory()
        let c = capture(0)
        try CaptureStore(db).insert(c)
        var d = description(for: c.id)
        d.detailsJson = #"{"project_hint":"worklens"}"#
        d.confidence = 0.87
        d.promptTokens = 1200
        d.outputTokens = 150
        d.thoughtTokens = 0
        d.costUsd = 0.00073
        d.latencyMs = 900
        try DescriptionStore(db).insert(d)

        #expect(try DescriptionStore(db).fetch(captureId: c.id) == d)
    }

    @Test("one description per capture")
    func uniquePerCapture() throws {
        let db = try Database.inMemory()
        let c = capture(0)
        try CaptureStore(db).insert(c)
        try DescriptionStore(db).insert(description(for: c.id))
        #expect(throws: (any Error).self) {
            try DescriptionStore(db).insert(description(for: c.id, task: "writing"))
        }
    }

    @Test("fetchRecent joins capture time and app, newest first")
    func recentJoin() throws {
        let db = try Database.inMemory()
        let older = capture(0, app: "Slack")
        let newer = capture(600, app: "Xcode")
        try CaptureStore(db).insert(older)
        try CaptureStore(db).insert(newer)
        try DescriptionStore(db).insert(description(for: older.id))
        try DescriptionStore(db).insert(description(for: newer.id))

        let recent = try DescriptionStore(db).fetchRecent(limit: 10)
        #expect(recent.map(\.appName) == ["Xcode", "Slack"])
        #expect(recent.first?.capturedAt == newer.capturedAt)
        #expect(recent.first?.description.captureId == newer.id)
        #expect(try DescriptionStore(db).fetchRecent(limit: 1).count == 1)
    }

    @Test("fetchBetween keeps only the captures inside the window, newest first")
    func betweenWindow() throws {
        let db = try Database.inMemory()
        let older = capture(0, app: "Slack")
        let newer = capture(600, app: "Xcode")
        try CaptureStore(db).insert(older)
        try CaptureStore(db).insert(newer)
        try DescriptionStore(db).insert(description(for: older.id))
        try DescriptionStore(db).insert(description(for: newer.id))

        let both = try DescriptionStore(db).fetchBetween(older.capturedAt, newer.capturedAt)
        #expect(both.map(\.appName) == ["Xcode", "Slack"])
        let tail = try DescriptionStore(db).fetchBetween(older.capturedAt.addingTimeInterval(1), newer.capturedAt)
        #expect(tail.map(\.appName) == ["Xcode"])
        let after = try DescriptionStore(db).fetchBetween(
            newer.capturedAt.addingTimeInterval(1), newer.capturedAt.addingTimeInterval(60))
        #expect(after.isEmpty)
    }

    @Test("fetch(day:) is bounded by the local day")
    func byDay() throws {
        let db = try Database.inMemory()
        let utc = TimeZone(identifier: "UTC")!
        let today = capture(0)
        let tomorrow = capture(60 * 60 * 24)
        try CaptureStore(db).insert(today)
        try CaptureStore(db).insert(tomorrow)
        try DescriptionStore(db).insert(description(for: today.id))
        try DescriptionStore(db).insert(description(for: tomorrow.id))

        #expect(try DescriptionStore(db).fetch(day: "2025-09-04", timeZone: utc).count == 1)
        #expect(try DescriptionStore(db).fetch(day: "2025-09-05", timeZone: utc).count == 1)
    }
}
