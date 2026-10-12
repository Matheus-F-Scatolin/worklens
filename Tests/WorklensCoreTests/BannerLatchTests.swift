import Foundation
import Testing

@testable import WorklensCore

/// The two decisions behind the scheduler's own banners, which used to sit inline in `AppModel`
/// where nothing could reach them.
@Suite("Banner latches (#149)")
struct BannerLatchTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let day = "2026-09-07"
    private var noon: Date { DayBoundaries.range(day: "2026-09-07", timeZone: utc)!.start.addingTimeInterval(12 * 3600) }

    // MARK: A pause that ran out

    @Test("a pause with no deadline never announces anything")
    func openEndedPauseIsSilent() {
        #expect(!BannerLatch.announcesPauseEnded(until: nil, now: noon, permissionIncident: false))
    }

    @Test("resuming before the deadline is something you just did, so it stays quiet")
    func manualResumeIsSilent() {
        let until = noon.addingTimeInterval(1800)
        #expect(!BannerLatch.announcesPauseEnded(until: until, now: noon, permissionIncident: false))
    }

    @Test("a deadline that has arrived announces the pause ending")
    func expiryAnnounces() {
        let until = noon.addingTimeInterval(-1)
        #expect(BannerLatch.announcesPauseEnded(until: until, now: noon, permissionIncident: false))
        // The deadline itself counts: the scheduler resumes on `>=`, and so does this.
        #expect(BannerLatch.announcesPauseEnded(until: noon, now: noon, permissionIncident: false))
    }

    @Test("a permission incident ending has its own banner, and this must not double it")
    func permissionIncidentWins() {
        let until = noon.addingTimeInterval(-60)
        #expect(!BannerLatch.announcesPauseEnded(until: until, now: noon, permissionIncident: true))
    }

    // MARK: The budget banner's day

    @Test("the first budget banner of a day is posted, the rest of that day is not")
    func budgetLatchesOnTheDay() {
        let first = BannerLatch.budgetBannerDay(lastPosted: nil, now: noon, timeZone: utc)
        #expect(first == day)
        #expect(BannerLatch.budgetBannerDay(lastPosted: first, now: noon, timeZone: utc) == nil)
        // The scheduler flaps between `.budgetExceeded` and `.running` once per frame; the day
        // is what makes that one banner rather than dozens.
        let later = noon.addingTimeInterval(3 * 3600)
        #expect(BannerLatch.budgetBannerDay(lastPosted: first, now: later, timeZone: utc) == nil)
    }

    @Test("a new day is a new banner, and yesterday's latch does not hold it back")
    func nextDayPostsAgain() {
        let tomorrow = noon.addingTimeInterval(24 * 3600)
        #expect(
            BannerLatch.budgetBannerDay(lastPosted: day, now: tomorrow, timeZone: utc)
                == "2026-09-08"
        )
    }

    @Test("the day is the local one, not UTC's")
    func respectsTheTimeZone() {
        let honolulu = TimeZone(identifier: "Pacific/Honolulu")!
        // 02:00 UTC on the 8th is still the 7th in Honolulu, which is the day a user there
        // would say their budget was spent on.
        let earlyUTC = DayBoundaries.range(day: "2026-09-08", timeZone: utc)!.start
            .addingTimeInterval(2 * 3600)
        #expect(
            BannerLatch.budgetBannerDay(lastPosted: nil, now: earlyUTC, timeZone: honolulu) == day
        )
    }
}
