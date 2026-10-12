import Foundation
import Testing
@testable import WorklensCore

/// #320 through the MCP `stats` and `span` tools, over a seeded in-memory store. Its own registry:
/// `MCPToolsTests`' harness is private to that file.
private let day = "2026-09-09"
private let start = DayBoundaries.range(day: day, timeZone: .current)!.start
private func at(_ hour: Int, _ minute: Int) -> Date {
    start.addingTimeInterval(Double(hour) * 3600 + Double(minute) * 60)
}

private struct Seeded {
    let db: Database
    let registry: MCPToolRegistry

    init() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-accounting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        var config = Config.defaults()
        config.dataDir = dataDir
        db = try Database.inMemory()
        registry = WorklensMCPTools.registry(
            config: config, db: db, taxonomy: try TaxonomyStore(dataDir: dataDir), timeZone: .current
        )
        // 09:00–09:30 on screen, locked from 12:00 until a frame at 13:00, 13:00–13:10 on screen.
        try CaptureStore(db).insert(Capture(capturedAt: at(9, 0), appName: "Xcode", intervalSeconds: 60))
        try CaptureStore(db).insert(Capture(capturedAt: at(12, 0), isIdle: true, skipReason: .locked))
        try CaptureStore(db).insert(Capture(capturedAt: at(13, 0), appName: "Xcode", intervalSeconds: 60))
        for (from, to) in [(at(9, 0), at(9, 30)), (at(13, 0), at(13, 10))] {
            try ActivityBlockStore(db).upsert(ActivityBlock(
                day: day, startAt: from, endAt: to, appKey: "xcode", taskKey: "coding",
                captureCount: 1, source: .screen
            ))
        }
    }

    func json(_ name: String, _ arguments: JSONValue) throws -> [String: Any] {
        let result = try registry.call(name: name, arguments: arguments)
        #expect(!result.isError, "\(name) failed: \(result.text)")
        return try #require(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
    }
}

/// A bare store and a registry over it, with the capture interval the config says.
private func registry(_ db: Database, captureInterval: Int? = nil) throws -> MCPToolRegistry {
    let dataDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("worklens-accounting-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    var config = Config.defaults()
    config.dataDir = dataDir
    if let captureInterval { config.captureIntervalSeconds = captureInterval }
    return WorklensMCPTools.registry(
        config: config, db: db, taxonomy: try TaxonomyStore(dataDir: dataDir), timeZone: .current
    )
}

private func dayMinutes(_ registry: MCPToolRegistry) throws -> [String: Any] {
    let result = try registry.call(name: "stats", arguments: .object(["day": .string(day)]))
    #expect(!result.isError, "stats failed: \(result.text)")
    let stats = try #require(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
    let accounting = try #require(stats["accounting"] as? [String: Any])
    return try #require(accounting["day"] as? [String: Any])
}

private func total(_ minutes: Any?) -> Int? {
    (minutes as? [String: Any])?["total"] as? Int
}

@Suite("Day accounting over MCP (#320)")
struct DayAccountingMCPTests {
    @Test("stats for a day carries its spans, and the old fields do not move")
    func statsDay() throws {
        let seeded = try Seeded()
        let stats = try seeded.json("stats", .object(["day": .string(day)]))
        let accounting = try #require(stats["accounting"] as? [String: Any])
        let dayMinutes = try #require(accounting["day"] as? [String: Any])
        let length = Int((DayBoundaries.range(day: day, timeZone: .current)!.end.timeIntervalSince(start) / 60).rounded())
        #expect(dayMinutes["total"] as? Int == length)
        #expect(dayMinutes["screen"] as? Int == 40)
        #expect(dayMinutes["locked"] as? Int == 60)
        #expect(total(accounting["window"]) == 250)
        #expect((accounting["spans"] as? [Any])?.isEmpty == false)
        // The numbers that were there before #320 read as they did.
        #expect(stats["trackedMinutes"] as? Int == 40)
        #expect(stats["activeMinutes"] as? Int == 40)
        #expect(stats["idleMinutes"] as? Int == 0)
    }

    @Test("span and week days carry no spans, and the range total sums its days")
    func spanAndWeek() throws {
        let seeded = try Seeded()
        let previous = DayBoundaries.dayString(start.addingTimeInterval(-3600))
        let next = DayBoundaries.dayString(start.addingTimeInterval(36 * 3600))
        let span = try seeded.json("span", .object(["from": .string(previous), "to": .string(next)]))
        let days = try #require(span["days"] as? [[String: Any]])
        #expect(days.count == 3)
        var sum = 0
        for entry in days {
            let accounting = try #require(entry["accounting"] as? [String: Any])
            #expect(accounting["spans"] == nil)
            sum += try #require(total(accounting["day"]))
        }
        let totals = try #require(span["accounting"] as? [String: Any])
        #expect(total(totals["day"]) == sum)
        #expect(total(totals["window"]) == 250)
        #expect(span["trackedMinutes"] as? Int == 40)

        let week = try #require(ISOWeek.containing(dayString: day))
        let weekly = try seeded.json("stats", .object(["week": .string(week.identifier)]))
        let weekDays = try #require(weekly["days"] as? [[String: Any]])
        #expect(!weekDays.isEmpty)
        for entry in weekDays {
            let accounting = try #require(entry["accounting"] as? [String: Any])
            #expect(accounting["spans"] == nil)
        }
    }

    @Test("a lock from last night carries in through the store, and a stopped transition ends it")
    func carryInAndStop() throws {
        let db = try Database.inMemory()
        try CaptureStore(db).insert(Capture(
            capturedAt: start.addingTimeInterval(-3600), isIdle: true, skipReason: .locked
        ))
        try CoverageEventStore(db).insert(CoverageEvent(at: at(2, 0), kind: .stopped))
        try CoverageEventStore(db).insert(CoverageEvent(at: at(8, 0), kind: .started))
        let minutes = try dayMinutes(try registry(db))
        #expect(minutes["locked"] as? Int == 120)
        #expect(minutes["notRunning"] as? Int == 360)
    }

    @Test("MCP compares a frame's interval with the configured capture interval, not the shipped one")
    func configuredInterval() throws {
        let db = try Database.inMemory()
        try CaptureStore(db).insert(Capture(capturedAt: at(10, 0), appName: "Xcode", intervalSeconds: 300))
        try ActivityBlockStore(db).upsert(ActivityBlock(
            day: day, startAt: at(10, 0), endAt: at(10, 30), appKey: "xcode", taskKey: "coding",
            captureCount: 1, source: .screen
        ))
        let shipped = try dayMinutes(try registry(db))
        #expect(shipped["batterySparse"] as? Int == 30)
        let configured = try dayMinutes(try registry(db, captureInterval: 120))
        #expect(configured["screen"] as? Int == 30)
        #expect(configured["batterySparse"] as? Int == 0)
    }
}
