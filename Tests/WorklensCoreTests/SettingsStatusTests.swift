import Foundation
import Testing

@testable import WorklensCore

/// General's status line and the needs-you dot (#286). The page only lays these out; the
/// priority — a missing grant or an open notice, then everything is working — is decided here.
@Suite("Settings status line")
struct SettingsStatusTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let locale = Locale(identifier: "en_GB")
    /// 2026-09-23 10:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_790_157_600)

    private func status(_ state: MenuState, first: Date? = nil) -> SettingsStatus {
        SettingsStatus.make(
            state: state, firstActivity: first,
            captureLine: "Paused until 14:30", now: now, timeZone: utc, locale: locale
        )
    }

    @Test("with nothing wrong it says everything is working, and since when")
    func working() {
        let first = now.addingTimeInterval(-3_480)  // 09:02
        let line = status(MenuState(scheduler: .running, captureIntervalSeconds: 30), first: first)
        #expect(line.kind == .working)
        #expect(line.headline == "Everything is working")
        #expect(line.detail == "capturing since 09:02")
        #expect(line.remedy == nil)
        #expect(line.dotSection == nil)
    }

    @Test("before anything is tracked it says the cadence")
    func workingEarly() {
        let line = status(MenuState(scheduler: .running, captureIntervalSeconds: 30))
        #expect(line.detail == "capturing every 30 s")
    }

    @Test("a pause leads with the menu's own words, never with \"everything is working\"")
    func paused() {
        let line = status(MenuState(scheduler: .paused(until: nil)))
        #expect(line.kind == .working)
        #expect(line.headline == "Paused until 14:30")
        #expect(line.detail == "")
    }

    @Test("something that needs you outranks everything working")
    func needsOutranksWorking() {
        let state = MenuState(scheduler: .running, browsersNotAsked: ["Safari"])
        let line = status(state)
        #expect(line.kind == .needsYou)
        #expect(line.headline == "One thing needs you")
        #expect(line.detail == "Safari hasn't been asked to share page addresses")
        #expect(line.remedyLabel == "Review")
        #expect(line.remedy == .review(SettingsTarget(.access)))
        #expect(line.dotSection == .capture)
    }

    @Test("a missing Screen Recording grant comes first, and the count covers everything")
    func screenRecordingFirst() {
        let problem = Notice(kind: .problem, message: "Gemini refused the key.", at: now, action: .openAccountSettings)
        let state = MenuState(
            scheduler: .permissionMissing, notices: [problem], browsersNotAsked: ["Safari", "Arc"]
        )
        let line = status(state)
        #expect(line.detail == "Screen Recording is off, so nothing is being captured")
        #expect(line.needs == 3)
        #expect(line.headline == "3 things need you")
        #expect(line.dotSection == .capture)
        let needs = SettingsStatus.needs(state: state)
        #expect(needs[1].sentence == "Gemini refused the key")
        #expect(needs[1].remedy == .review(SettingsTarget(.providers)))
        #expect(needs[1].section == .connections)
        #expect(needs[2].sentence == "Arc and Safari haven't been asked to share page addresses"
            || needs[2].sentence == "Safari and Arc haven't been asked to share page addresses")
    }

    @Test("open problems come newest first; a done notice or a dismissed one needs nothing")
    func openNoticesOnly() {
        let old = Notice(kind: .problem, message: "The log could not be written.", at: now.addingTimeInterval(-600), action: .openLogFile)
        let new = Notice(kind: .problem, message: "Could not reach Gemini.", at: now)
        let done = Notice(kind: .done, message: "Deleted 3 screenshots.", at: now)
        let dismissed = Notice(kind: .problem, message: "Old.", at: now, dismissedAt: now)
        let needs = SettingsStatus.needs(state: MenuState(scheduler: .running, notices: [old, done, new, dismissed]))
        #expect(needs.map(\.sentence) == ["could not reach Gemini", "the log could not be written"])
        // No action: Review opens the notices under the status line.
        #expect(needs[0].remedy == .review(SettingsTarget(.status)))
        // An action with no row of its own is run straight from the line.
        #expect(needs[1].remedy == .perform(.openLogFile))
        #expect(needs[1].section == .advanced)
        // "See all (n)" lists these same n rows, and a notice's row can be dismissed.
        #expect(needs.map(\.noticeID) == [new.id, old.id])
        #expect(needs.map(\.at) == [new.at, old.at])
    }

    @Test("only a notice that asks for nothing is reviewed by being seen")
    func reviewedBySeeing() {
        let crash = Notice(kind: .problem, message: RunOutcomeCopy.unexpectedExitNotice(startedAt: nil), action: .openLogFile)
        let grant = Notice(kind: .problem, message: "Screen Recording is off.", action: .grantScreenRecording)
        let plain = Notice(kind: .problem, message: "Another Worklens is capturing.")
        #expect(crash.isReviewedBySeeing)
        #expect(!grant.isReviewedBySeeing)
        #expect(!plain.isReviewedBySeeing)
    }

    @Test("a condition is not a notice, so its row offers no Dismiss")
    func conditionsHaveNoNotice() {
        let needs = SettingsStatus.needs(state: MenuState(scheduler: .permissionMissing))
        #expect(needs.count == 1)
        #expect(needs[0].noticeID == nil)
    }

    @Test("a grant you said not to be reminded about needs nothing")
    func skippedAdvisories() {
        let state = MenuState(
            scheduler: .running, accessibilityMissing: true, browsersMissingURLs: ["Chrome"],
            browsersNotAsked: ["Safari"], accessibilityAdvisorySkipped: true, browserAdvisorySkipped: true
        )
        #expect(SettingsStatus.needs(state: state).isEmpty)
        #expect(status(state).kind == .working)
        let unskipped = MenuState(scheduler: .running, accessibilityMissing: true, browsersMissingURLs: ["Chrome"])
        #expect(SettingsStatus.needs(state: unskipped).map(\.sentence) == [
            "Accessibility is off, so Worklens reads no window text",
            "Chrome isn't allowed to share page addresses",
        ])
    }

    @Test("a rejected key needs you and points at the providers; a stall does not")
    func rejectedKey() {
        let rejected = MenuState(scheduler: .running, describeHealth: .failing(message: "Gemini rejected the key", httpStatus: 400))
        let needs = SettingsStatus.needs(state: rejected, now: now, timeZone: utc)
        #expect(needs.count == 1)
        #expect(needs.first?.remedy == .review(SettingsTarget(.providers)))
        #expect(needs.first?.section == .connections)
        let stalled = MenuState(scheduler: .running, describeHealth: .failing(message: "Gemini is overloaded", httpStatus: 503))
        #expect(SettingsStatus.needs(state: stalled, now: now, timeZone: utc).isEmpty)
    }

    @Test("a source that wants reconnecting points at Sources")
    func integrationAttention() {
        let needs = SettingsStatus.needs(state: MenuState(scheduler: .running, integrationsNeedingAttention: ["Google Calendar"]))
        #expect(needs.first?.sentence == "Google Calendar needs connecting again")
        #expect(needs.first?.remedy == .review(SettingsTarget(.sources)))
    }

    @Test("a notice's sentence becomes a clause without misspelling a name")
    func clauses() {
        #expect(SettingsStatus.clause("The sync failed.") == "the sync failed")
        #expect(SettingsStatus.clause("Gemini is down.") == "Gemini is down")
        #expect(SettingsStatus.clause("macOS said no") == "macOS said no")
        #expect(SettingsStatus.clause("GitHub could not be reached.") == "GitHub could not be reached")
    }
}

@Suite("Access card copy")
struct AccessCopyTests {
    private func browser(_ name: String, _ status: AutomationPermission.Status) -> AutomationPermission.BrowserStatus {
        AutomationPermission.BrowserStatus(bundleID: "id.\(name)", name: name, status: status)
    }

    @Test("the Browsers line says each answer once, allowed first, and that it is optional")
    func browsersLine() {
        let line = AccessCopy.browsersLine([browser("Safari", .notAsked), browser("Google Chrome", .allowed)])
        #expect(line == "Optional. Google Chrome shares page addresses; Safari hasn't been asked.")
        #expect(AccessCopy.browsersLine([browser("Arc", .notRunning)])
            == "Optional. Open a browser to see whether it shares page addresses.")
        #expect(AccessCopy.browsersLine([]).hasPrefix("Optional."))
    }

    @Test("the pill names the browser that wants a yes before anything else")
    func browsersPill() {
        #expect(AccessCopy.browsersPill([browser("Google Chrome", .allowed), browser("Safari", .notAsked)])?.text
            == "Safari needs a yes")
        #expect(AccessCopy.browsersPill([browser("Google Chrome", .allowed)])?.allowed == true)
        #expect(AccessCopy.browsersPill([browser("Arc", .denied)])?.allowed == false)
        #expect(AccessCopy.browsersPill([browser("Arc", .notRunning)]) == nil)
    }

    @Test("a lock note names neither a variable nor a file")
    func lockNotes() {
        #expect(SettingsCopy.lockNote(.appSettings) == nil)
        #expect(SettingsCopy.lockNote(.cwd) == nil)
        for layer in [ConfigLayer.process, .explicitFile] {
            let note = SettingsCopy.lockNote(layer) ?? ""
            #expect(!note.isEmpty)
            #expect(note.range(of: "[A-Z][A-Z0-9]+_[A-Z0-9_]+", options: .regularExpression) == nil)
            #expect(!note.contains(".env"))
        }
        #expect(SettingsCopy.saved() == "Saved")
        #expect(SettingsCopy.saved("Launch at login") == "Saved · Launch at login")
    }
}
