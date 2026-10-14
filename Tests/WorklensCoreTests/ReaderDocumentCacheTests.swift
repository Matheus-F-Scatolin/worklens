import Foundation
import Testing
@testable import WorklensCore

/// The pages the reader keeps so a step lands at once (2026-10-14): what is served, what is
/// dropped, and which pages are built ahead.
@Suite("ReaderDocumentCache")
struct ReaderDocumentCacheTests {
    private let utc = TimeZone(identifier: "UTC")!

    private func page(_ selection: ReaderSelection) -> ReaderDocument {
        ReaderDocument(selection: selection, kind: .daily, title: "\(selection)")
    }

    private func row(_ day: String, frames: Int = 10) -> DayIndexEntry {
        DayIndexEntry(day: day, frames: frames, described: frames)
    }

    @Test func servesAPageWhileItsDayIsUnchanged() {
        var cache = ReaderDocumentCache(timeZone: utc)
        let index = ["2026-10-08": row("2026-10-08")]
        cache.store(page(.day("2026-10-08")), builtFrom: index)
        #expect(cache.document(for: .day("2026-10-08"), index: index) == page(.day("2026-10-08")))
        #expect(cache.document(for: .day("2026-10-09"), index: index) == nil)
    }

    @Test func aDayThatMovedIsBuiltAgain() {
        var cache = ReaderDocumentCache(timeZone: utc)
        cache.store(page(.day("2026-10-08")), builtFrom: ["2026-10-08": row("2026-10-08")])
        let moved = ["2026-10-08": row("2026-10-08", frames: 11)]
        #expect(cache.document(for: .day("2026-10-08"), index: moved) == nil)
    }

    @Test func aWeekIsStampedWithAllSevenOfItsDays() {
        var cache = ReaderDocumentCache(timeZone: utc)
        let monday = "2026-10-05"
        var index = ["2026-10-07": row("2026-10-07")]
        cache.store(page(.week(monday)), builtFrom: index)
        #expect(cache.document(for: .week(monday), index: index) != nil)
        // Sunday got its first frame: the week is read again.
        index["2026-10-11"] = row("2026-10-11")
        #expect(cache.document(for: .week(monday), index: index) == nil)
        // A day outside the week does not touch it.
        cache.store(page(.week(monday)), builtFrom: index)
        index["2026-10-12"] = row("2026-10-12")
        #expect(cache.document(for: .week(monday), index: index) != nil)
    }

    @Test func nothingIsServedPastItsAge() {
        var cache = ReaderDocumentCache(timeZone: utc)
        let built = Date(timeIntervalSince1970: 1_000_000)
        cache.store(page(.day("2026-10-08")), builtFrom: [:], at: built)
        let later = built.addingTimeInterval(ReaderDocumentCache.maxAge + 1)
        #expect(cache.document(for: .day("2026-10-08"), index: [:], now: built) != nil)
        #expect(cache.document(for: .day("2026-10-08"), index: [:], now: later) == nil)
    }

    @Test func theTickDropsTodayAndTheWeekHoldingIt() {
        var cache = ReaderDocumentCache(timeZone: utc)
        for selection: ReaderSelection in [
            .day("2026-10-14"), .day("2026-10-13"), .week("2026-10-12"), .week("2026-10-05"),
        ] {
            cache.store(page(selection), builtFrom: [:])
        }
        cache.dropHoldingToday("2026-10-14")
        #expect(cache.document(for: .day("2026-10-14"), index: [:]) == nil)
        #expect(cache.document(for: .week("2026-10-12"), index: [:]) == nil)
        #expect(cache.document(for: .day("2026-10-13"), index: [:]) != nil)
        #expect(cache.document(for: .week("2026-10-05"), index: [:]) != nil)
    }

    @Test func theLeastRecentlyStoredPageGoesFirst() {
        var cache = ReaderDocumentCache(timeZone: utc)
        let days = (0...ReaderDocumentCache.capacity).map { String(format: "2026-09-%02d", $0 + 1) }
        for day in days { cache.store(page(.day(day)), builtFrom: [:]) }
        #expect(cache.count == ReaderDocumentCache.capacity)
        #expect(cache.document(for: .day(days[0]), index: [:]) == nil)
        #expect(cache.document(for: .day(days.last!), index: [:]) != nil)
    }

    @Test func neighboursAreOneStepEitherSide() {
        let days = ["2026-10-14", "2026-10-13", "2026-10-10"]
        #expect(ReaderDocumentCache.neighbours(of: .day("2026-10-13"), days: days, mondays: [])
            == [.day("2026-10-14"), .day("2026-10-10")])
        #expect(ReaderDocumentCache.neighbours(of: .day("2026-10-14"), days: days, mondays: [])
            == [.day("2026-10-13")])
        #expect(ReaderDocumentCache.neighbours(of: .day("2026-09-01"), days: days, mondays: []).isEmpty)
        let mondays = ["2026-10-12", "2026-10-05"]
        #expect(ReaderDocumentCache.neighbours(of: .week("2026-10-05"), days: days, mondays: mondays)
            == [.week("2026-10-12")])
    }

    @Test func sideBySideKeepsOrderAndThrowsTheFailure() throws {
        let days = (1...7).map { "2026-10-0\($0)" }
        #expect(try StatsService.sideBySide(days) { $0 + "!" } == days.map { $0 + "!" })
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try StatsService.sideBySide(days) { day -> String in
                if day == "2026-10-04" { throw Boom() }
                return day
            }
        }
    }
}
