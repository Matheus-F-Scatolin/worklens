import Foundation
import Testing
@testable import WorklensCore

/// #324: the instants `projects assign --from/--to` reads.
@Suite("LocalInstant")
struct LocalInstantTests {
    private let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!

    private func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    @Test("with no offset the time is local")
    func localTime() {
        #expect(LocalInstant("2026-10-06T15:00", timeZone: saoPaulo)?.date == utc("2026-10-06T18:00:00Z"))
        #expect(LocalInstant("2026-10-06 15:00:30", timeZone: saoPaulo)?.date == utc("2026-10-06T18:00:30Z"))
        #expect(LocalInstant("2026-10-06T15:00", timeZone: saoPaulo)?.text == "2026-10-06T15:00")
    }

    @Test("an offset or Z names the instant wherever you are")
    func offsets() {
        #expect(LocalInstant("2026-10-06T15:00Z", timeZone: saoPaulo)?.date == utc("2026-10-06T15:00:00Z"))
        #expect(LocalInstant("2026-10-06T15:00:00+02:00", timeZone: saoPaulo)?.date == utc("2026-10-06T13:00:00Z"))
        #expect(LocalInstant("2026-10-06T15:00-0300", timeZone: TimeZone(identifier: "UTC")!)?.date == utc("2026-10-06T18:00:00Z"))
    }

    @Test("anything else is refused, including days and times that do not exist")
    func refused() {
        for text in [
            "", "2026-10-06", "15:00", "yesterday", "2026-10-06T15", "2026-02-30T10:00",
            "2026-13-01T10:00", "2026-10-06T25:00", "2026-10-06T15:60", "2026-10-06T15:00+25:00",
            "2026-10-06T15:00 extra",
        ] {
            #expect(LocalInstant(text, timeZone: saoPaulo) == nil, "\(text)")
        }
    }
}
