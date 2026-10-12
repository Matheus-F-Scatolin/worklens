import Foundation
import Testing

@testable import WorklensCore

/// #149: banners are the only sentences Worklens says to somebody who is not looking at it, so
/// the rules about them are tested rather than remembered — no ISO date, no price, no commit SHA,
/// a title of at most four words, a body of one sentence.
@Suite("Notification copy (#149)")
struct NotificationCopyTests {
    /// Every title and body the helper can produce, for the rules that hold across all of them.
    private var everyTitle: [String] {
        [
            NotificationCopy.budgetReachedTitle,
            NotificationCopy.pauseEndedTitle,
            NotificationCopy.pausedTitle,
            NotificationCopy.capturingTitle,
            NotificationCopy.updatingTitle,
            NotificationCopy.databaseRecoveredTitle,
            NotificationCopy.describeStalledTitle,
            NotificationCopy.integrationAttentionTitle("Granola"),
            NotificationCopy.googleReconnectTitle,
            NotificationCopy.permissionRestoredTitle,
        ]
    }

    private var everyBody: [String] {
        [
            NotificationCopy.budgetReachedBody,
            NotificationCopy.pauseEndedBody,
            NotificationCopy.pausedBody,
            NotificationCopy.capturingBody,
            NotificationCopy.updatingBody,
            NotificationCopy.databaseRecoveredBody(movedTo: "worklens-corrupt-1.db"),
            NotificationCopy.describeStalledBody("nothing has been described for two hours"),
            NotificationCopy.describeStalledBody(nil),
            NotificationCopy.integrationAttentionBody("the token was refused"),
            NotificationCopy.integrationAttentionBody(nil),
            NotificationCopy.googleReconnectBody(SetupIssue.googleReconnect.message),
            NotificationCopy.googleReconnectBody(nil),
            NotificationCopy.permissionRestoredBody,
        ]
    }

    @Test("A title is at most four words")
    func titlesAreShort() {
        for title in everyTitle {
            #expect(title.split(separator: " ").count <= 4, "too long: \(title)")
        }
    }

    @Test("No title repeats the app name unless the app is the subject")
    func titlesDoNotShout() {
        let allowed = [
            NotificationCopy.pausedTitle,
            NotificationCopy.capturingTitle,
            NotificationCopy.updatingTitle,
        ]
        for title in everyTitle where !allowed.contains(title) {
            #expect(!title.contains("Worklens"), "says the app name: \(title)")
        }
    }

    @Test("No body carries a price, an ISO date or a commit SHA")
    func bodiesStayClean() {
        for body in everyBody {
            #expect(!body.contains("$"), "has a price: \(body)")
            #expect(
                body.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) == nil,
                "has an ISO date: \(body)"
            )
            #expect(
                body.range(of: #"\b[0-9a-f]{7,40}\b"#, options: .regularExpression) == nil,
                "looks like a SHA: \(body)"
            )
        }
    }

    @Test("Every body is one sentence that ends in a full stop")
    func bodiesAreOneSentence() {
        for body in everyBody {
            #expect(body.hasSuffix("."), "does not end a sentence: \(body)")
            // A full stop followed by a space is a second sentence; one inside `corrupt-1.db` is not.
            #expect(!body.contains(". "), "more than one sentence: \(body)")
        }
    }

    @Test("The budget banner says screenshots are still saved")
    func budgetBody() {
        #expect(NotificationCopy.budgetReachedBody.contains("still saved and on hold"))
        #expect(NotificationCopy.budgetReachedBody.contains("midnight"))
    }

    @Test("The updater says what happens, not which commit")
    func updateBody() {
        #expect(NotificationCopy.updatingBody.contains("A new build is available"))
        #expect(!NotificationCopy.updatingBody.lowercased().contains("main"))
    }

    @Test("The database banner names the file it kept")
    func databaseBody() {
        let body = NotificationCopy.databaseRecoveredBody(movedTo: "worklens-corrupt-1.db")
        #expect(body.contains("worklens-corrupt-1.db"))
    }

    @Test("A reason written elsewhere is passed through, punctuated, never left empty")
    func passedThroughReasons() {
        #expect(
            NotificationCopy.describeStalledBody("  the key was refused  ")
                == "the key was refused."
        )
        #expect(
            NotificationCopy.integrationAttentionBody("The token was refused.")
                == "The token was refused."
        )
        // Nothing to pass through is a whole sentence of its own rather than a blank line.
        #expect(NotificationCopy.integrationAttentionBody("   ") == "Worklens could not sync it.")
        #expect(
            NotificationCopy.describeStalledBody(nil)
                == "Worklens is not summarizing your screenshots."
        )
    }

    @Test("The integration banner lets the source name itself")
    func integrationTitle() {
        #expect(NotificationCopy.integrationAttentionTitle("Granola") == "Granola needs attention")
        #expect(!NotificationCopy.integrationAttentionTitle("Granola").contains("Worklens"))
    }
}
