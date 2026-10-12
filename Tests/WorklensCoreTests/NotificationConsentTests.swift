import Foundation
import Testing

@testable import WorklensCore

/// When Worklens may ask macOS for Notifications (#246).
///
/// The page #232 deleted was the only place the app ever asked, so a fresh install never asked
/// at all — and the outage-recovery story from #117 is announced by a banner. The other way
/// round is what #131 removed: a dialog as the first act of a first launch. This value is the
/// line between the two, and every case of it is here rather than in a view.
@Suite("Notification consent (#246)")
struct NotificationConsentTests {
    private func decide(
        _ moment: NotificationMoment,
        _ system: NotificationConsent.SystemState,
        alreadyAsked: Bool = false,
        welcomeOnScreen: Bool = false
    ) -> NotificationConsent.Answer {
        NotificationConsent.decide(
            moment: moment, system: system,
            alreadyAsked: alreadyAsked, welcomeOnScreen: welcomeOnScreen
        )
    }

    /// The one moment a banner earns the question, since the report banner went (2026-10-05).
    @Test("the first outage is what raises the dialog")
    func theTriggerMoment() {
        #expect(decide(.screenRecordingOutage, .notAsked) == .ask)
        #expect(decide(.other, .notAsked) == .quiet)
        #expect(NotificationMoment.screenRecordingOutage.earnsTheDialog)
        #expect(!NotificationMoment.other.earnsTheDialog)
    }

    /// Once macOS has said yes, every banner is simply posted — the question is over.
    @Test("an allowed install posts and is never asked again")
    func allowedPosts() {
        for moment in NotificationMoment.allCases {
            #expect(decide(moment, .allowed) == .post)
            #expect(decide(moment, .allowed, alreadyAsked: true) == .post)
            #expect(decide(moment, .allowed, welcomeOnScreen: true) == .post)
        }
    }

    /// Declining is answered once. macOS asks once too: a second request draws nothing, so
    /// asking again would only lose the banner that prompted it. Settings → Permissions keeps
    /// the button for somebody who changes their mind.
    @Test("a declined answer is never asked about again, from either moment")
    func declinedStaysQuiet() {
        for moment in NotificationMoment.allCases {
            #expect(decide(moment, .denied) == .quiet)
            #expect(decide(moment, .denied, alreadyAsked: true) == .quiet)
        }
    }

    /// A dialog that was raised and closed without an answer leaves the status `.notAsked`.
    /// That is still an answer as far as this is concerned.
    @Test("the dialog is raised once, whatever came of it")
    func neverTwice() {
        #expect(decide(.screenRecordingOutage, .notAsked, alreadyAsked: true) == .quiet)
    }

    /// Never at launch and never during the welcome: a permission dialog stacked on the window
    /// that is explaining the app is the first-launch pile-up #131 took apart.
    @Test("the welcome window is never interrupted by the dialog")
    func notDuringTheWelcome() {
        for moment in NotificationMoment.allCases {
            #expect(decide(moment, .notAsked, welcomeOnScreen: true) == .quiet)
        }
    }

    /// Nothing is drawn under `.notAsked` or `.denied`, so `quiet` costs the user nothing the
    /// menu is not already saying — which is what lets this value say no so often.
    @Test("quiet is only ever chosen where a banner would have reached nobody")
    func quietOnlyWhereNothingWouldBeDrawn() {
        for moment in NotificationMoment.allCases {
            for system in NotificationConsent.SystemState.allCases {
                for asked in [false, true] {
                    for welcome in [false, true] {
                        let answer = decide(
                            moment, system, alreadyAsked: asked, welcomeOnScreen: welcome
                        )
                        if answer == .post { #expect(system == .allowed) }
                        if answer == .ask {
                            #expect(system == .notAsked)
                            #expect(moment.earnsTheDialog)
                            #expect(!asked)
                            #expect(!welcome)
                        }
                    }
                }
            }
        }
    }

    /// The two sentences that explain the rule to the user, in the second person, with no
    /// dialog behind them — so neither carries an ellipsis (`docs/copy.md`).
    @Test("the welcome line and the Settings note promise what the value does")
    func copy() {
        #expect(NotificationConsent.welcomeLine.contains("Worklens will offer notifications"))
        #expect(!NotificationConsent.welcomeLine.contains("\u{2026}"))
        #expect(!NotificationConsent.settingsNote.contains("\u{2026}"))
        // Twenty words or fewer for Settings body copy, which carries a Learn more… of its own.
        #expect(NotificationConsent.settingsNote.split(separator: " ").count <= 20)
        for sentence in [NotificationConsent.welcomeLine, NotificationConsent.settingsNote] {
            let offenders = sentence.unicodeScalars.filter { !$0.isASCII && $0.properties.isEmoji }
            #expect(offenders.isEmpty)
        }
    }
}
