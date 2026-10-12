import Foundation
import Testing

@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!
private let day = "2026-09-09"
private let dayStart = DayBoundaries.range(day: day, timeZone: utc)!.start
private let noon = dayStart.addingTimeInterval(12 * 3600)

@Suite("The menu while something is running (#150)")
struct MenuActivityTests {
    private func rendered(
        _ activities: [Activity], scheduler: SchedulerState = .running, notices: [Notice] = []
    ) -> MenuModel {
        MenuModel(
            state: MenuState(
                scheduler: scheduler,
                counts: MenuCounts(captures: 12, described: 12),
                notices: notices,
                activities: activities
            ),
            now: noon.addingTimeInterval(42),
            timeZone: utc
        )
    }

    private var syncing: Activity {
        Activity(id: "sync", kind: .sync, label: "Syncing integrations", startedAt: noon)
    }

    @Test("nothing running is not busy")
    func quiet() {
        let menu = rendered([])
        #expect(!menu.isBusy)
        #expect(menu.icon == .capturing)
    }

    @Test("busy travels beside the state rather than replacing it (#252)")
    func iconPrecedence() {
        // Busy used to overwrite the state, so the minute a long job took was the one minute
        // the menu bar stopped answering "is Worklens watching?".
        #expect(rendered([syncing]).icon == .capturing)
        #expect(rendered([syncing]).isBusy)
        #expect(rendered([syncing], scheduler: .paused(until: nil)).icon == .paused)
        #expect(rendered([syncing], scheduler: .paused(until: nil)).isBusy)
        #expect(rendered([syncing], scheduler: .idle).icon == .resting)
        #expect(rendered([], scheduler: .idle).isBusy == false)
        // A missing Gemini key is the thing the user has to act on; a sync must not hide it for
        // as long as it runs.
        let noKey = [Notice(.noGeminiKey, at: dayStart)]
        #expect(rendered([syncing], notices: noKey).icon == .attention)
        #expect(rendered([syncing], notices: noKey).isBusy)
        #expect(rendered([], notices: noKey).icon == .attention)
        #expect(MenuState(activities: [syncing]).isBusy)
    }
}

@Suite("Coming back from an update (#150)")
struct UpdatePendingTests {
    @Test("a new commit is announced, and nothing else is")
    func notice() {
        #expect(
            UpdatePending.notice(pending: "0ae882e1234", running: "9f3c1aa5678")
                == "Worklens is back: now on 9f3c1aa"
        )
        // No update was started.
        #expect(UpdatePending.notice(pending: nil, running: "9f3c1aa") == nil)
        #expect(UpdatePending.notice(pending: "", running: "9f3c1aa") == nil)
        // The update failed and the same build relaunched: say nothing rather than lie.
        #expect(UpdatePending.notice(pending: "9f3c1aa", running: "9f3c1aa") == nil)
        // An unstamped build cannot be compared with anything.
        #expect(UpdatePending.notice(pending: "9f3c1aa", running: nil) == nil)
        #expect(UpdatePending.notice(pending: "9f3c1aa", running: "") == nil)
    }

    @Test("the key is one word, so a reader of app_state can find it")
    func key() {
        #expect(UpdatePending.key == "update_pending")
    }
}
