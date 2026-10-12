import CoreGraphics
import Foundation
import Testing

@testable import WorklensCore

// MARK: - The stops

@Suite("Tour stops (#351)")
struct TourStopTests {
    @Test("seven stops, in the order the tour walks them, the week behind a click on the rail")
    func order() {
        #expect(
            TourStop.allCases == [
                .timeline, .moment, .openWeeks, .week, .pauseAndDelete, .askClaude, .menuBar,
            ])
        #expect(TourState.stops.count == 7)
    }

    /// #357: the tour never changes the page for you going forward. Every change of page is a
    /// step that cuts out the rail button and waits for it, right before the stop on that page.
    @Test("every page change going forward is a step that waits for you to click the rail")
    func pageChangesWait() {
        let stops = TourStop.allCases
        var place: ReaderPlace = .today
        for (index, stop) in stops.enumerated() {
            if let wanted = stop.waitsFor {
                #expect(stop.readerPlace == nil, "\(stop) waits, so it must not navigate")
                #expect(stop.hasAnchor, "\(stop) cuts out the rail button")
                #expect(wanted != place, "\(stop) waits for the page already showing")
                #expect(stops[index + 1].readerPlace == wanted)
                place = wanted
            } else if let next = stop.readerPlace {
                #expect(next == place, "\(stop) changes the page to \(next) without a click")
            }
        }
        #expect(TourStop.openWeeks.waitsFor == .weeks)
        #expect(TourStop.allCases.filter { $0.waitsFor != nil } == [.openWeeks])
    }

    @Test("the day's two stops are on Today, the week's on Weeks, the rest stay put")
    func places() {
        #expect(TourStop.timeline.readerPlace == .today)
        #expect(TourStop.moment.readerPlace == .today)
        #expect(TourStop.week.readerPlace == .weeks)
        for stop in [TourStop.openWeeks, .pauseAndDelete, .askClaude, .menuBar] {
            #expect(stop.readerPlace == nil)
        }
    }

    @Test("only the menu-bar ring is explained outside the window")
    func outsideTheWindow() {
        for stop in TourStop.allCases {
            #expect(stop.isInsideWindow == (stop != .menuBar))
        }
        #expect(!TourStop.pauseAndDelete.hasAnchor)
        #expect(!TourStop.menuBar.hasAnchor)
    }

    /// The pause stop names the shortcut as it is bound on this Mac, not the default.
    @Test("the pause stop reads the real binding and draws it as caps")
    func pauseBinding() {
        let rebound = TourKeys(pause: "\u{2303}\u{2318}P", open: "\u{2325}\u{21E7}W")
        #expect(TourStop.pauseAndDelete.body(keys: rebound).hasPrefix("\u{2303}\u{2318}P pauses"))
        #expect(TourStop.pauseAndDelete.keyCaps(keys: rebound) == ["\u{2303}", "\u{2318}", "P"])
        let unbound = TourKeys(pause: nil, open: nil)
        #expect(!TourStop.pauseAndDelete.body(keys: unbound).contains("\u{2325}"))
        #expect(TourStop.pauseAndDelete.keyCaps(keys: unbound).isEmpty)
        #expect(TourStop.pauseAndDelete.body(keys: unbound).contains("last hour"))
    }

    @Test("a key name longer than one letter stays one cap")
    func caps() {
        #expect(TourKeys.caps("\u{2325}\u{21E7}P") == ["\u{2325}", "\u{21E7}", "P"])
        #expect(TourKeys.caps("\u{2318}F5") == ["\u{2318}", "F5"])
        #expect(TourKeys.caps("\u{2303}Space") == ["\u{2303}", "Space"])
        #expect(TourKeys.caps("") == [])
    }

    /// When the ring cannot be found the last card says how to get back in, with the open
    /// shortcut as it is bound, and links the troubleshooting section.
    @Test("a ring that cannot be found is a way back in, not an arrow at nothing")
    func menuBarFallback() {
        let keys = TourKeys(pause: "\u{2325}\u{21E7}P", open: "\u{2325}\u{21E7}W")
        let found = TourStop.menuBar.body(keys: keys, menuBarFound: true)
        let lost = TourStop.menuBar.body(keys: keys, menuBarFound: false)
        #expect(found != lost)
        #expect(lost.contains("\u{2325}\u{21E7}W"))
        #expect(TourStop.menuBar.keyCaps(keys: keys, menuBarFound: false) == ["\u{2325}", "\u{21E7}", "W"])
        #expect(TourStop.menuBar.keyCaps(keys: keys, menuBarFound: true).isEmpty)
        #expect(TourStop.menuBar.offersMenuBarHelp(menuBarFound: false))
        #expect(!TourStop.menuBar.offersMenuBarHelp(menuBarFound: true))
        #expect(!TourStop.timeline.offersMenuBarHelp(menuBarFound: false))
        // No open shortcut registered: still a way back in, and no key named.
        let noKey = TourStop.menuBar.body(keys: TourKeys(), menuBarFound: false)
        #expect(noKey.contains("Finder"))
        // The section the link opens is a real heading of the troubleshooting page.
        #expect(HelpLink.menuBarIconMissing.rawValue == "i-cannot-find-the-menu-bar-icon")
    }

    /// `docs/copy.md`: no em or en dashes, no emoji, no score, second person, short.
    @Test("every card follows the copy rules")
    func copy() {
        let keys = TourKeys(pause: "\u{2325}\u{21E7}P", open: "\u{2325}\u{21E7}W")
        var sentences: [String] = [
            TourCopy.back, TourCopy.next, TourCopy.done, TourCopy.skip, TourCopy.cardLabel,
            TourCopy.menuBarHelp, TourCopy.settingsRow, TourCopy.settingsDetail,
            TourCopy.settingsButton,
        ]
        for stop in TourStop.allCases {
            sentences.append(stop.title)
            for found in [true, false] {
                sentences.append(stop.body(keys: keys, menuBarFound: found))
                sentences.append(stop.body(keys: TourKeys(), menuBarFound: found))
            }
        }
        for sentence in sentences {
            #expect(!sentence.isEmpty)
            #expect(!sentence.contains("\u{2014}") && !sentence.contains("\u{2013}"), "\(sentence)")
            #expect(
                sentence.unicodeScalars.allSatisfy { $0.isASCII || !$0.properties.isEmoji },
                "\(sentence)")
            let lowered = sentence.lowercased()
            for word in ["score", "better", "worse", "productive", "the user", " i ", "demo"] {
                #expect(!lowered.contains(word), "\"\(sentence)\" says \(word)")
            }
        }
        for stop in TourStop.allCases {
            // One or two sentences.
            let body = stop.body(keys: keys)
            let stops = body.filter { $0 == "." }.count
            #expect(stops >= 1 && stops <= 2, "\(stop): \(body)")
        }
    }
}

// MARK: - Back, next, skip

@Suite("Tour state (#351)")
struct TourStateTests {
    @Test("next walks every stop and finishes on the last")
    func walk() {
        var state = TourState()
        var seen = [state.stop]
        #expect(state.isFirst)
        #expect(state.counter == "1 of 7")
        while !state.isLast {
            state.next()
            seen.append(state.stop)
        }
        #expect(seen == TourStop.allCases)
        #expect(state.counter == "7 of 7")
        #expect(state.nextLabel == TourCopy.done)
        #expect(state.isRunning)
        state.next()
        #expect(state.outcome == .finished)
        #expect(!state.isRunning)
    }

    @Test("back stops at the first stop, and passes over a step that waits for a click")
    func back() {
        var state = TourState()
        state.back()
        #expect(state.index == 0)
        #expect(state.isRunning)
        state.next()
        state.next()
        #expect(state.stop == .openWeeks)
        state.back()
        #expect(state.stop == .moment)
        // From the week, back is the day's last stop: Weeks is already showing, so the step
        // that waits for it would only go on again by itself.
        var week = TourState(index: TourState.stops.firstIndex(of: .week)!)
        week.back()
        #expect(week.stop == .moment)
        #expect(week.nextLabel == TourCopy.next)
    }

    /// #357: on the step that asks you to click Weeks, Next is gone while the button is cut out,
    /// and back when it cannot be found, so nobody is stuck on it.
    @Test("a waiting step goes on by itself once its page shows, and keeps Next without its anchor")
    func waitsForTheClick() {
        var state = TourState(index: TourState.stops.firstIndex(of: .openWeeks)!)
        #expect(!state.canGoNext(anchorFound: true))
        #expect(state.canGoNext(anchorFound: false))
        state.apply(.next, anchorFound: true)
        #expect(state.stop == .openWeeks, "Next or Return does nothing while the button is there")
        let onToday = state.placeShown(.today)
        #expect(!onToday)
        #expect(state.stop == .openWeeks)
        let onWeeks = state.placeShown(.weeks)
        #expect(onWeeks)
        #expect(state.stop == .week)
        // Once past it, showing Weeks again moves nothing.
        let again = state.placeShown(.weeks)
        #expect(!again)
        #expect(state.stop == .week)

        var lost = TourState(index: TourState.stops.firstIndex(of: .openWeeks)!)
        lost.apply(.next, anchorFound: false)
        #expect(lost.stop == .week, "with the rail button missing, Next is how you go on")

        // Every other stop has Next whether or not its view is on screen.
        for stop in TourStop.allCases where stop.waitsFor == nil {
            let other = TourState(index: TourState.stops.firstIndex(of: stop)!)
            #expect(other.canGoNext(anchorFound: true) && other.canGoNext(anchorFound: false))
        }
    }

    /// #357: the welcome window's tour is part of setting up; Settings' can be skipped.
    @Test("a first-run tour has no Skip and ignores Esc, but Back, Next and closing still work")
    func firstRunCannotBeSkipped() {
        #expect(!TourRun.welcome.allowsSkip)
        #expect(TourRun.again.allowsSkip)
        #expect(TourState().allowsSkip, "a tour from Settings is the default")

        var state = TourState(run: .welcome)
        #expect(!state.allowsSkip)
        state.skip()
        state.apply(.skip)
        #expect(state.isRunning)
        state.apply(.next)
        state.apply(.back)
        #expect(state.stop == .timeline)
        // Walking to the end still finishes it.
        while !state.isLast {
            state.apply(.next, anchorFound: false)
        }
        state.next()
        #expect(state.outcome == .finished)

        // The window going away ends any tour.
        var abandoned = TourState(index: 2, run: .welcome)
        abandoned.abandon()
        #expect(abandoned.outcome == .skipped)

        var again = TourState(index: 2, run: .again)
        again.apply(.skip)
        #expect(again.outcome == .skipped)
    }

    @Test("skip ends the tour where it is, from any stop")
    func skip() {
        for index in TourState.stops.indices {
            var state = TourState(index: index)
            state.skip()
            #expect(state.outcome == .skipped)
            #expect(state.index == index)
        }
    }

    @Test("an ended tour does not move again")
    func ended() {
        var state = TourState(index: 2)
        state.skip()
        state.next()
        state.back()
        state.skip()
        #expect(state.index == 2)
        #expect(state.outcome == .skipped)

        var finished = TourState(index: 6)
        finished.next()
        finished.skip()
        #expect(finished.outcome == .finished)
    }

    @Test("an index out of range is clamped")
    func clamp() {
        #expect(TourState(index: -3).index == 0)
        #expect(TourState(index: 40).index == 6)
    }

    @Test("→ and Return go on, ← goes back, Esc skips, and ⌘ keys are the reader's")
    func keys() {
        #expect(TourCommand.forKey(code: 124) == .next)
        #expect(TourCommand.forKey(code: 36) == .next)
        #expect(TourCommand.forKey(code: 76) == .next)
        #expect(TourCommand.forKey(code: 123) == .back)
        #expect(TourCommand.forKey(code: 53) == .skip)
        #expect(TourCommand.forKey(code: 0) == nil)
        #expect(TourCommand.forKey(code: 123, withModifiers: true) == nil)
        #expect(TourCommand.forKey(code: 124, withModifiers: true) == nil)

        var state = TourState()
        state.apply(.next)
        state.apply(.next)
        state.apply(.back)
        #expect(state.stop == .moment)
        state.apply(.skip)
        #expect(state.outcome == .skipped)
    }

    @Test("each stop is announced with where it is and what it says")
    func announcement() {
        let keys = TourKeys(pause: "\u{2325}\u{21E7}P", open: "\u{2325}\u{21E7}W")
        let state = TourState(index: 4)
        let spoken = state.announcement(keys: keys)
        #expect(spoken.hasPrefix("5 of 7"))
        #expect(spoken.contains(TourStop.pauseAndDelete.title))
        #expect(spoken.contains("\u{2325}\u{21E7}P"))
    }
}

// MARK: - Remembering it

@Suite("Tour memory (#351)")
struct TourMemoryTests {
    @Test("nothing is remembered before a tour, and the last ending wins")
    func persistence() throws {
        let db = try Database.inMemory()
        let store = AppStateStore(db)
        #expect(TourMemory.outcome(in: store) == nil)
        try TourMemory.record(.skipped, in: store)
        #expect(TourMemory.outcome(in: store) == .skipped)
        try TourMemory.record(.finished, in: store)
        #expect(TourMemory.outcome(in: store) == .finished)
        #expect(try store.get(TourMemory.key) == "finished")
    }

    @Test("a word this build does not know reads as no tour")
    func unknownWord() throws {
        let db = try Database.inMemory()
        let store = AppStateStore(db)
        try store.set(TourMemory.key, "halfway")
        #expect(TourMemory.outcome(in: store) == nil)
    }
}

// MARK: - Geometry

@Suite("Tour layout (#351)")
struct TourLayoutTests {
    let window = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let card = CGSize(width: 300, height: 160)

    @Test("a missing, empty or off-screen anchor is a centred card, never a hole")
    func missingAnchor() {
        #expect(TourLayout.hole(for: nil, in: window) == nil)
        #expect(TourLayout.hole(for: .zero, in: window) == nil)
        #expect(TourLayout.hole(for: .null, in: window) == nil)
        #expect(TourLayout.hole(for: CGRect(x: 2000, y: 40, width: 100, height: 100), in: window) == nil)
        #expect(TourLayout.hole(for: CGRect(x: 100, y: -500, width: 200, height: 40), in: window) == nil)
        let centred = TourLayout.cardOrigin(card: card, hole: nil, in: window)
        #expect(centred == CGPoint(x: 350, y: 270))
    }

    @Test("a hole stands off its view and stays inside the window")
    func hole() throws {
        let anchor = CGRect(x: 100, y: 100, width: 200, height: 50)
        let hole = try #require(TourLayout.hole(for: anchor, in: window))
        #expect(hole == anchor.insetBy(dx: -TourLayout.holePadding, dy: -TourLayout.holePadding))

        let tall = CGRect(x: 80, y: 60, width: 800, height: 2000)
        let clipped = try #require(TourLayout.hole(for: tall, in: window))
        #expect(window.contains(clipped))
    }

    /// #357 second pass: the Weeks step rings the rail button in terracotta, from the button's
    /// own bounds, so the ring follows it at any window size.
    @Test("the click ring hugs the button inside its hole, at any window size, and only where it waits")
    func clickRing() throws {
        let button = CGRect(x: 11, y: 96, width: 38, height: 38)
        for size in [CGSize(width: 720, height: 480), CGSize(width: 1000, height: 700), CGSize(width: 2400, height: 1400)] {
            let container = CGRect(origin: .zero, size: size)
            let ring = try #require(TourLayout.clickRing(for: button, in: container))
            #expect(ring == button.insetBy(dx: -TourLayout.ringPadding, dy: -TourLayout.ringPadding))
            #expect(ring.midX == button.midX && ring.midY == button.midY)
            #expect(ring.contains(button))
        }
        // Inside the cut-out wherever the cut-out is not clipped by the window's edge.
        let roomy = CGRect(x: 100, y: 100, width: 38, height: 38)
        let hole = try #require(TourLayout.hole(for: roomy, in: window))
        #expect(hole.contains(try #require(TourLayout.clickRing(for: roomy, in: window))))
        // No hole, no ring.
        #expect(TourLayout.clickRing(for: nil, in: window) == nil)
        #expect(TourLayout.clickRing(for: CGRect(x: 2000, y: 40, width: 38, height: 38), in: window) == nil)
        #expect(TourStop.allCases.filter(\.drawsClickRing) == [.openWeeks])
    }

    @Test("the card sits beside the hole when there is room")
    func beside() throws {
        let hole = CGRect(x: 60, y: 200, width: 200, height: 100)
        let origin = TourLayout.cardOrigin(card: card, hole: hole, in: window)
        #expect(origin.x == hole.maxX + TourLayout.gap)
        let frame = CGRect(origin: origin, size: card)
        #expect(!frame.intersects(hole))
        #expect(window.contains(frame))
    }

    @Test("a hole against the trailing edge puts the card below, then above, then leading")
    func fallbacks() {
        let right = CGRect(x: 760, y: 40, width: 220, height: 120)
        let below = CGRect(origin: TourLayout.cardOrigin(card: card, hole: right, in: window), size: card)
        #expect(below.minY >= right.maxY)
        #expect(window.contains(below))

        let bottomRight = CGRect(x: 760, y: 500, width: 220, height: 190)
        let above = CGRect(
            origin: TourLayout.cardOrigin(card: card, hole: bottomRight, in: window), size: card)
        #expect(above.maxY <= bottomRight.minY)
        #expect(window.contains(above))
    }

    @Test("the moment stop's card goes below its bar, clear of the tooltip to its right")
    func momentPrefersVertical() {
        let bar = CGRect(x: 60, y: 120, width: 80, height: 200)
        let frame = CGRect(
            origin: TourLayout.cardOrigin(card: card, hole: bar, in: window, prefersVertical: true),
            size: card)
        #expect(frame.minY >= bar.maxY)
        #expect(window.contains(frame))
        // The strip to the bar's right, where the tooltip opens, stays uncovered.
        let tooltipStrip = CGRect(x: bar.maxX, y: bar.minY, width: 240, height: bar.height)
        #expect(!frame.intersects(tooltipStrip))
    }

    /// #357: the moment stop's hole is the bar and its pinned tooltip; in a short window there
    /// is no side with room, and the card goes where it covers the least of them.
    @Test("with room on no side, the card covers as little of the hole as it can")
    func leastCovered() {
        let short = CGRect(x: 0, y: 0, width: 900, height: 420)
        let hole = CGRect(x: 300, y: 100, width: 590, height: 310)
        let origin = TourLayout.cardOrigin(card: card, hole: hole, in: short, prefersVertical: true)
        let frame = CGRect(origin: origin, size: card)
        #expect(short.contains(frame))
        // The bottom-trailing corner would sit wholly on the hole; pushed in from the leading
        // side, the card covers a sliver of it.
        let overlap = frame.intersection(hole)
        #expect(overlap.width * overlap.height < card.width * card.height / 10)
    }

    @Test("a hole that fills the window still leaves the card on screen")
    func fullHole() {
        let full = window.insetBy(dx: 10, dy: 10)
        let origin = TourLayout.cardOrigin(card: card, hole: full, in: window)
        #expect(window.contains(CGRect(origin: origin, size: card)))
    }

    // MARK: The ring

    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test("the ring is found only when it is drawn where someone can see it")
    func menuBarItem() {
        let item = CGRect(x: 1200, y: 950, width: 30, height: 32)
        #expect(TourLayout.menuBarItem(frame: item, isVisible: true, screen: screen) == item)
        #expect(TourLayout.menuBarItem(frame: nil, isVisible: true, screen: screen) == nil)
        #expect(TourLayout.menuBarItem(frame: item, isVisible: false, screen: screen) == nil)
        #expect(TourLayout.menuBarItem(frame: item, isVisible: true, screen: nil) == nil)
        #expect(TourLayout.menuBarItem(frame: .zero, isVisible: true, screen: screen) == nil)
        let offScreen = CGRect(x: -400, y: 950, width: 30, height: 32)
        #expect(TourLayout.menuBarItem(frame: offScreen, isVisible: true, screen: screen) == nil)
    }

    @Test("a ring behind the notch counts as not found")
    func notch() {
        let left = CGRect(x: 0, y: 950, width: 660, height: 32)
        let right = CGRect(x: 852, y: 950, width: 660, height: 32)
        let behind = CGRect(x: 700, y: 950, width: 30, height: 32)
        let beside = CGRect(x: 900, y: 950, width: 30, height: 32)
        #expect(
            TourLayout.menuBarItem(
                frame: behind, isVisible: true, screen: screen, leftOfNotch: left, rightOfNotch: right
            ) == nil)
        #expect(
            TourLayout.menuBarItem(
                frame: beside, isVisible: true, screen: screen, leftOfNotch: left, rightOfNotch: right
            ) == beside)
    }

    @Test("the panel hangs under the ring and stays on the screen")
    func panel() {
        let size = CGSize(width: 340, height: 200)
        let item = CGRect(x: 1200, y: 950, width: 30, height: 32)
        let frame = TourLayout.panelFrame(item: item, panel: size, screen: screen)
        #expect(frame.maxY < item.minY)
        #expect(abs(frame.midX - item.midX) < 0.5)
        #expect(frame.size == size)

        let corner = CGRect(x: 1490, y: 950, width: 22, height: 32)
        let clamped = TourLayout.panelFrame(item: corner, panel: size, screen: screen)
        #expect(clamped.maxX <= screen.maxX)
        let arrow = TourLayout.arrowOffset(item: corner, panel: clamped)
        #expect(arrow > size.width / 2)
        #expect(arrow <= size.width - 20)
    }
}
