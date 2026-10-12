import Foundation
import Testing
@testable import WorklensCore

/// `byDocument` (#319), through `StatsAggregator.daily` the way `StatsService` reaches it.
private let zone = TimeZone(identifier: "UTC")!
private let day = "2026-09-08"
private let pr = "https://github.com/o/r/pull/12/files"
private let prKey = "github.com/o/r/pull/12"

private func at(_ hour: Int, _ minute: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(
        timeZone: zone, year: 2026, month: 9, day: 8, hour: hour, minute: minute
    ))!
}

private func block(
    _ from: (Int, Int), _ to: (Int, Int), _ appKey: String = "browser", source: ActivitySource = .screen
) -> ActivityBlock {
    ActivityBlock(
        day: day, startAt: at(from.0, from.1), endAt: at(to.0, to.1),
        appKey: appKey, taskKey: "working", source: source
    )
}

private func frame(
    _ hour: Int, _ minute: Int, id: String = Identifiers.new(), url: String? = nil,
    title: String? = nil, redacted: Bool = false, skip: SkipReason? = nil
) -> Capture {
    Capture(
        id: id, capturedAt: at(hour, minute), appName: "Chrome", windowTitle: title,
        browserUrl: url, isRedacted: redacted, skipReason: skip, describeStatus: .described
    )
}

private func daily(
    _ blocks: [ActivityBlock], _ captures: [Capture],
    documents: [String: String] = [:], documentURLs: [String: String] = [:]
) -> DailyStats {
    StatsAggregator.daily(
        day: day, blocks: blocks, captures: captures, frameDocuments: documents,
        frameDocumentURLs: documentURLs, timeZone: zone
    )
}

@Suite("Time per document (#319)")
struct DocumentTimeTests {
    @Test("idle and blocked screenshots add nothing")
    func idleAndBlocked() {
        let stats = daily(
            [block((9, 0), (9, 30), "idle"), block((10, 0), (10, 30))],
            [
                frame(9, 10, url: pr),
                frame(10, 5, url: pr),
                frame(10, 20, url: pr, redacted: true, skip: .blockedHost),
            ]
        )
        // The 10:00 block is two frames, 15 minutes each; the blocked one keys nothing.
        #expect(stats.byDocument.map(\.key) == [prKey])
        #expect(stats.byDocument.first?.minutes == 15)
    }

    @Test("a document_url fills in where the browser URL names nothing")
    func documentURL() {
        let stats = daily(
            [block((10, 0), (10, 30), "vscode")],
            [frame(10, 5, id: "f1")],
            documentURLs: ["f1": "file:///Users/someone/notes/a%20b.md"]
        )
        #expect(stats.byDocument.first?.minutes == 30)
        #expect(stats.byDocument.first?.name == "a b.md")
    }

    @Test("the describer's document names a row, then a window title, then the short form")
    func nameOrder() {
        let doc = "https://docs.google.com/document/d/doc1/edit"
        let sheet = "https://docs.google.com/spreadsheets/d/s1/edit"
        let stats = daily(
            [block((10, 0), (11, 0))],
            [
                frame(10, 0, id: "a", url: doc, title: "Plan - Google Docs"),
                frame(10, 10, id: "b", url: doc, title: "Plan - Google Docs"),
                frame(10, 20, id: "c", url: doc, title: "Plan - Google Docs"),
                frame(10, 30, id: "d", url: sheet, title: "Budget - Google Sheets"),
                frame(10, 40, id: "e", url: pr),
            ],
            documents: ["a": "Q4 plan", "b": "Q4 plan", "c": "Draft"]
        )
        let names = Dictionary(uniqueKeysWithValues: stats.byDocument.map { ($0.key, $0.name) })
        #expect(names["docs.google.com/document/d/doc1"] == "Q4 plan")
        #expect(names["docs.google.com/spreadsheets/d/s1"] == "Budget - Google Sheets")
        #expect(names[prKey] == "o/r#12")
    }

    @Test("a redacted screenshot adds minutes but never names a row")
    func redactedNeverNames() {
        let stats = daily(
            [block((10, 0), (10, 20))],
            [frame(10, 5, id: "r", url: pr, title: "Secret plans", redacted: true)],
            documents: ["r": "Secret doc"]
        )
        #expect(stats.byDocument.first?.minutes == 20)
        #expect(stats.byDocument.first?.name == "o/r#12")
    }

    @Test("eleven documents keep ten rows and fold one into other")
    func foldsIntoOther() {
        let frames = (0..<11).map { frame(10, $0 * 5, url: "https://github.com/o/r/issues/\($0 + 1)") }
        let stats = daily([block((10, 0), (10, 55))], frames)
        #expect(stats.byDocument.count == 11)
        #expect(stats.byDocument.last?.key == StatsAggregator.otherKey)
        #expect(stats.byDocument.reduce(0) { $0 + $1.minutes } == 55)
    }

    @Test("a day with no keys gives no rows")
    func noKeys() {
        let stats = daily([block((10, 0), (10, 30))], [frame(10, 5, url: "https://example.com/x")])
        #expect(stats.byDocument.isEmpty)
        #expect(daily([], []).byDocument.isEmpty)
    }

    @Test("the week merges documents by key")
    func weekMerges() {
        let monday = daily([block((10, 0), (10, 30))], [frame(10, 5, url: pr)])
        var tuesday = daily([block((10, 0), (10, 20))], [frame(10, 5, url: "https://github.com/O/R/pull/12")])
        tuesday.day = "2026-09-09"
        let week = StatsAggregator.weekly(days: [monday, tuesday], timeZone: zone)
        #expect(week.totals.byDocument.map(\.key) == [prKey])
        #expect(week.totals.byDocument.first?.minutes == 50)
    }

    @Test("seconds stay uncapped for the shipped join")
    func uncapped() {
        let frames = (0..<12).map { frame(10, $0 * 5, url: "https://github.com/o/r/issues/\($0 + 1)") }
        let weights = DocumentTime.onScreenWeights(blocks: [block((10, 0), (11, 0))], captures: frames, now: nil)
        let seconds = DocumentTime.seconds(weights: weights, documentURLs: [:])
        #expect(seconds.count == 12)
        #expect(seconds.values.reduce(0, +) == 3600)
    }
}
