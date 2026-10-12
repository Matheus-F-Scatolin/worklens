import Foundation
import Testing
@testable import WorklensCore

private let zone = TimeZone(identifier: "UTC")!

@Suite("Day boundaries")
struct DayBoundariesTests {
    @Test("a day shifts across a month boundary")
    func shift() {
        #expect(DayBoundaries.shift(day: "2026-09-01", by: -1, timeZone: zone) == "2026-08-31")
        #expect(DayBoundaries.shift(day: "2026-08-31", by: 1, timeZone: zone) == "2026-09-01")
        #expect(DayBoundaries.shift(day: "not-a-day", by: 1, timeZone: zone) == nil)
    }
}
