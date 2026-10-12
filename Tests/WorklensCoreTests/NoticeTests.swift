import Foundation
import Testing
@testable import WorklensCore

@Suite("Notices")
struct NoticeTests {
    private let at = Date(timeIntervalSince1970: 1_757_000_000)

    @Test("each kind keeps its own lifetime")
    func lifetimes() {
        let problem = Notice(kind: .problem, message: "Report failed", at: at)
        let done = Notice(kind: .done, message: "Deleted 12 frames.", at: at)
        let info = Notice(kind: .info, message: "No report yet.", at: at)

        // Eleven minutes: what the old single slot used to forget at ten.
        let eleven = at.addingTimeInterval(11 * 60)
        #expect(problem.isLive(at: eleven))
        #expect(!done.isLive(at: at.addingTimeInterval(61)))
        #expect(done.isLive(at: at.addingTimeInterval(59)))
        #expect(!info.isLive(at: eleven))
        #expect(info.isLive(at: at.addingTimeInterval(599)))
    }

    @Test("a dismissed problem is not live and is not open, whatever the clock says")
    func dismissal() {
        var problem = Notice(kind: .problem, message: "Sync failed", at: at)
        #expect(problem.isOpen)
        problem.dismissedAt = at
        #expect(!problem.isLive(at: at))
        #expect(!problem.isOpen)
    }

    @Test("an issue carries its own wording and button")
    func issueNotice() {
        let notice = Notice(.noGeminiKey, at: at)
        #expect(notice.kind == .problem)
        #expect(notice.issue == .noGeminiKey)
        // #124: the key issues lead to Settings → Accounts, where a key can now be typed.
        #expect(notice.action == .openAccountSettings)
        #expect(notice.message == SetupIssue.noGeminiKey.message)
        #expect(notice.level == .problem)
    }

    /// A missing key means nothing is described; a denied Screen Recording grant is
    /// already the scheduler's own state, and the icon comes from there.
    @Test("only the key issues block work")
    func blocking() {
        #expect(SetupIssue.noGeminiKey.blocksWork)
        #expect(SetupIssue.keyRejected.blocksWork)
        #expect(!SetupIssue.screenRecordingDenied.blocksWork)
        // #122: capture is refused outright, so this one earns the icon. The machine-name
        // mismatch does not — nothing has stopped, and the folder may just have been copied.
        #expect(SetupIssue.dataDirNotLocal.blocksWork)
        #expect(!SetupIssue.dataDirAnotherMac.blocksWork)
        #expect(SetupIssue.bySeverity.first == .screenRecordingDenied)
    }

    /// The reports were cut on 2026-10-05, but a notice log an older build stored can still hold
    /// a report notice. An unknown raw value would fail the whole log, so the three cases stay
    /// decodable and `AppModel` drops them on load.
    @Test("a stored log holding a report notice still decodes")
    func legacyReportNoticesDecode() throws {
        let stored = [
            Notice(.noAnthropicKey, at: at),
            Notice(kind: .problem, message: "Report failed", at: at, action: .retryDailyReport),
            Notice(kind: .problem, message: "Report failed", at: at, action: .retryWeeklyReport),
            Notice(.noGeminiKey, at: at),
        ]
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode([Notice].self, from: data)
        #expect(decoded == stored)
        #expect(!SetupIssue.noAnthropicKey.blocksWork)
    }

    @Test("the key issue names the section it sends people to")
    func keyIssueNamesConnections() {
        // The section is called Connections everywhere (#286).
        #expect(SetupIssue.keyRejected.message.contains("Settings → Connections"))
        #expect(!SetupIssue.keyRejected.message.contains("Models & cost"))
    }

    /// #122. The condition knows it is a synced folder; only the caller knows *which* one, so a
    /// condition-backed notice has to be able to carry a message of its own.
    @Test("a condition-backed notice can name what the condition alone cannot")
    func issueWithMessage() {
        let message = "DATA_DIR is in iCloud Drive (~/Library/Mobile Documents/data)."
        let notice = Notice(.dataDirNotLocal, message: message, at: at)
        #expect(notice.issue == .dataDirNotLocal)
        #expect(notice.message == message)
        #expect(notice.kind == .problem)
        #expect(notice.action == .openEnvFile)
        // It never expires: a synced folder is still synced ten minutes later.
        #expect(notice.isLive(at: at.addingTimeInterval(3600)))
    }

    @Test("a notice survives a round trip through the log")
    func codable() throws {
        let notice = Notice(
            kind: .problem, message: "Report failed", at: at, action: .retryDailyReport
        )
        let data = try JSONEncoder().encode([notice])
        let back = try JSONDecoder().decode([Notice].self, from: data)
        #expect(back == [notice])
    }

    /// Trimming must not be "newest 30": a problem nobody has dealt with is exactly the thing a
    /// quiet, chatty day would push out.
    @Test("the log keeps open problems when it overflows")
    func trimming() {
        let problem = Notice(kind: .problem, message: "Report failed", at: at)
        let chatter = (1...40).map {
            Notice(kind: .info, message: "notice \($0)", at: at.addingTimeInterval(Double($0)))
        }
        let trimmed = NoticeStore.trimmed(chatter + [problem])
        #expect(trimmed.count == NoticeStore.limit)
        #expect(trimmed.contains { $0.id == problem.id })
        #expect(trimmed.contains { $0.message == "notice 40" })
        #expect(!trimmed.contains { $0.message == "notice 1" })
        // Newest first, so the Activity list and the menu agree on what "latest" means.
        #expect(trimmed == trimmed.sorted { $0.at > $1.at })
    }

    @Test("a short log is left alone")
    func trimmingShortLog() {
        let two = [
            Notice(kind: .info, message: "a", at: at),
            Notice(kind: .done, message: "b", at: at.addingTimeInterval(1)),
        ]
        #expect(NoticeStore.trimmed(two) == two)
    }
}

// MARK: - The Google reconnect issue (#139)

@Suite("The Google reconnect notice")
struct GoogleReconnectNoticeTests {
    @Test("it says what is paused and carries the button that fixes it")
    func issueCarriesItsButton() {
        let issue = SetupIssue.googleReconnect
        #expect(issue.message.contains("Calendar is paused"))
        #expect(issue.action == .reconnectGoogle)
        #expect(NoticeAction.reconnectGoogle.label.hasPrefix("Reconnect Google"))
        // Nothing has stopped except two context sources, so the menu-bar icon is left alone.
        #expect(!issue.blocksWork)
        // And no surface a menu-bar user reads sends them to a terminal.
        #expect(!issue.message.contains("worklens google"))
    }

    @Test("a condition-backed notice, so a sync that works again clears it")
    func noticeIsConditionBacked() {
        let notice = Notice(SetupIssue.googleReconnect)
        #expect(notice.issue == .googleReconnect)
        #expect(notice.kind == .problem)
        #expect(notice.action == .reconnectGoogle)
    }
}
