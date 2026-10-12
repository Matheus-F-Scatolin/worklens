import Foundation
import Testing

@testable import WorklensCore

private let now = Date(timeIntervalSince1970: 1_757_000_000)  // 2025-09-04T15:33:20Z

/// The Gemini-only install, which #232 made complete and the 2026-10-05 cut made the only one:
/// setup is complete, nothing is "remaining", and the menu says nothing about a missing step.
@Suite("Setup with one key (#232)")
struct GeminiOnlySetupTests {
    private var geminiOnly: SetupProgress {
        SetupProgress(
            screenRecording: true,
            geminiKey: true,
            onboardedAt: now
        )
    }

    @Test("setup is complete with the Gemini key alone")
    func complete() {
        #expect(geminiOnly.isComplete)
        #expect(geminiOnly.remaining.isEmpty)
        #expect(geminiOnly.done == SetupStep.allCases)
    }

    @Test("the menu says nothing about a missing step")
    func menuIsQuiet() {
        #expect(geminiOnly.menuLine == nil)
        let menu = MenuModel(
            state: MenuState(scheduler: .running, setup: geminiOnly), now: now
        )
        #expect(menu.setupLine == nil)
        #expect(menu.setupRow == nil)
    }

    /// The counter counts the three steps and stops there: a user who has granted Screen
    /// Recording and pasted a Gemini key is two thirds of the way through, not half.
    @Test("the counter counts three steps")
    func counter() {
        let midway = SetupProgress(screenRecording: true, geminiKey: true)
        #expect(midway.menuLine == "Finish setting up Worklens (2 of 3)")
        #expect(midway.remaining == [.welcome])
    }
}

/// The six pages, as the window steps through them.
@Suite("The six welcome pages (#232, #352, #357)")
struct SetupPageOrderTests {
    @Test("light or dark, what Worklens does, a sample week, Screen Recording, your keys, ready")
    func order() {
        #expect(SetupPage.allCases == [.appearance, .privacy, .tour, .screenRecording, .keys, .ready])
        #expect(SetupPage.count == 6)
        for page in SetupPage.allCases {
            #expect(!page.title.isEmpty)
            #expect(!page.summary.isEmpty)
            #expect(page.stepLine.contains("of 6"))
        }
    }

    /// #357 second pass: the appearance page is first, and is not one of the three things setup
    /// is waiting on. A page stored before it existed still resumes where it was left.
    @Test("light or dark comes first, is not a setup step, and older stored pages still resume")
    func appearancePage() {
        #expect(SetupPage.appearance.index == 1)
        #expect(SetupPage.appearance.previous == nil)
        #expect(SetupPage.appearance.next == .privacy)
        #expect(SetupPage.appearance.title == "Light or dark")
        #expect(SetupStep.allCases == [.screenRecording, .geminiKey, .welcome])
        for raw in ["privacy", "tour", "screenRecording", "keys", "ready", "appearance"] {
            #expect(SetupPage.stored(raw)?.rawValue == raw)
        }
        #expect(SetupPage.stored("optionalPermissions") == nil)
    }

    /// #352: the sample week comes before the first thing macOS is asked for, and is not one of
    /// the three things setup is waiting on.
    @Test("the sample week is before Screen Recording and is not a setup step")
    func tourPage() {
        #expect(SetupPage.privacy.next == .tour)
        #expect(SetupPage.tour.next == .screenRecording)
        #expect(SetupPage.screenRecording.previous == .tour)
        #expect(SetupPage.tour.title == "See a sample week")
        #expect(SetupStep.allCases == [.screenRecording, .geminiKey, .welcome])
        let started = SetupProgress(screenRecording: false, geminiKey: false)
        #expect(started.menuLine == "Finish setting up Worklens (0 of 3)")
    }

    /// Walking forwards from the first page reaches the last, and no further.
    @Test("the pages are a path, not a graph")
    func walk() {
        var page = SetupPage.appearance
        var seen = [page]
        while let next = page.next {
            page = next
            seen.append(page)
        }
        #expect(seen == SetupPage.allCases)
        #expect(page == .ready)
        #expect(SetupPage.appearance.previous == nil)
    }
}
