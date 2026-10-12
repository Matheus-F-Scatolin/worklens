import Foundation
import Testing

@testable import WorklensCore

/// Settings → General → "Appearance": what `app_state` holds, read back.
@Suite("Appearance choice")
struct AppearanceChoiceTests {
    @Test("absent or unrecognised means follow the system")
    func defaultsToSystem() {
        #expect(AppearanceChoice(stored: nil) == .system)
        #expect(AppearanceChoice(stored: "") == .system)
        #expect(AppearanceChoice(stored: "sepia") == .system)
    }

    @Test("every choice survives the round trip through its raw value")
    func roundTrips() {
        for choice in AppearanceChoice.allCases {
            #expect(AppearanceChoice(stored: choice.rawValue) == choice)
        }
    }

    @Test("the segments read System, Light, Dark in that order")
    func segmentOrder() {
        #expect(AppearanceChoice.allCases.map(\.name) == ["System", "Light", "Dark"])
    }

    /// #357 second pass: the welcome window's first page.
    @Test("the first page offers Light, Dark, System in that order")
    func cardOrder() {
        #expect(AppearanceChoice.cards == [.light, .dark, .system])
        #expect(Set(AppearanceChoice.cards) == Set(AppearanceChoice.allCases))
    }

    @Test("a new install is light before it is asked; an older one that never chose keeps the system")
    func firstRunDefault() {
        #expect(AppearanceChoice.firstRunDefault(stored: nil, welcomeShows: true) == .light)
        #expect(AppearanceChoice.firstRunDefault(stored: "sepia", welcomeShows: true) == .light)
        // Already chosen: left alone, even on a first run that resumes.
        #expect(AppearanceChoice.firstRunDefault(stored: "dark", welcomeShows: true) == nil)
        #expect(AppearanceChoice.firstRunDefault(stored: "system", welcomeShows: true) == nil)
        // Set up before the page existed: nothing is written, so it stays on the system.
        #expect(AppearanceChoice.firstRunDefault(stored: nil, welcomeShows: false) == nil)
        #expect(AppearanceChoice(stored: nil) == .system)
    }

    @Test("a launch whose database did not open writes nothing, even though the welcome shows")
    func firstRunDefaultWithoutDatabase() {
        #expect(AppearanceChoice.firstRunDefault(stored: nil, welcomeShows: true, databaseOpen: false) == nil)
        #expect(AppearanceChoice.firstRunDefault(stored: nil, welcomeShows: true, databaseOpen: true) == .light)
    }

    @Test("the launch gate's show and resume are the launches the welcome opens on")
    func welcomeShows() {
        #expect(SetupGate.Decision.show.showsWelcome)
        #expect(SetupGate.Decision.resume(page: .tour).showsWelcome)
        #expect(!SetupGate.Decision.recordSilently.showsWelcome)
        #expect(!SetupGate.Decision.nothing.showsWelcome)
    }

    @Test("the stored choice is ringed; with none, what is showing — light on a new install")
    func preselected() {
        // A new install: firstRunDefault made it light before the page opened.
        #expect(AppearanceChoice.preselected(stored: nil, showing: .light) == .light)
        #expect(AppearanceChoice.preselected(stored: "nonsense", showing: .light) == .light)
        #expect(AppearanceChoice.preselected(stored: "dark", showing: .light) == .dark)
        #expect(AppearanceChoice.preselected(stored: "system", showing: .dark) == .system)
    }

    @Test("an install past setup that never chose rings System, so Return keeps following the Mac")
    func preselectedPastSetup() {
        // Settings → Show welcome again on an install set up before the page existed: nothing is
        // stored and `AppearanceChoice(stored: nil)` is what it shows.
        let showing = AppearanceChoice(stored: nil)
        #expect(AppearanceChoice.firstRunDefault(stored: nil, welcomeShows: false) == nil)
        #expect(AppearanceChoice.preselected(stored: nil, showing: showing) == .system)
    }

    @Test("the arrow keys move one card along and stop at either end")
    func arrows() {
        #expect(AppearanceChoice.light.moved(by: 1) == .dark)
        #expect(AppearanceChoice.dark.moved(by: 1) == .system)
        #expect(AppearanceChoice.system.moved(by: 1) == .system)
        #expect(AppearanceChoice.system.moved(by: -1) == .dark)
        #expect(AppearanceChoice.light.moved(by: -1) == .light)
    }
}
