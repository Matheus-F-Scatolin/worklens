import Foundation
import Testing
@testable import WorklensCore

@Suite("Pause reminder (#113)")
struct PauseReminderTests {
    private let start = Date(timeIntervalSince1970: 1_757_260_800)

    @Test("Nothing is said before the interval is up")
    func notDueYet() {
        #expect(!PauseReminder.isDue(since: start, now: start, everyHours: 4))
        #expect(
            !PauseReminder.isDue(since: start, now: start.addingTimeInterval(4 * 3600 - 1), everyHours: 4)
        )
    }

    @Test("The reminder is due once the interval has passed")
    func due() {
        #expect(PauseReminder.isDue(since: start, now: start.addingTimeInterval(4 * 3600), everyHours: 4))
        #expect(PauseReminder.isDue(since: start, now: start.addingTimeInterval(86_400), everyHours: 4))
    }

    @Test("Zero hours turns the reminder off entirely")
    func off() {
        #expect(!PauseReminder.isDue(since: start, now: start.addingTimeInterval(86_400), everyHours: 0))
        #expect(!PauseReminder.isDue(since: start, now: start.addingTimeInterval(86_400), everyHours: -1))
    }

    @Test("The body always names the deadline")
    func body() {
        let until = Date(timeIntervalSince1970: 1_757_260_800 + 3600)
        let timed = PauseReminder.body(until: until, timeZone: TimeZone(identifier: "UTC")!)
        #expect(timed == "Nothing is being captured until 17:00.")
        #expect(PauseReminder.body(until: nil).contains("until you resume"))
    }
}
