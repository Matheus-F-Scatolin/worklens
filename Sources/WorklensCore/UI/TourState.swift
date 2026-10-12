import Foundation

/// One stop of the spotlight tour (#351), in the order the tour visits them.
///
/// The tour walks somebody through the reader over the sample week: the day, one bar of it, the
/// rail button you click to open the week, the week, the two keys that stop Worklens looking,
/// Claude, and the ring in the menu bar. The
/// order, the words and the question of where each stop points live here, in the target with
/// tests; `Sources/Worklens/Tour` only draws them.
///
/// The raw value doubles as the anchor id a reader view tags itself with, so a view that moves
/// takes its stop with it and nothing is ever pointed at by coordinates.
public enum TourStop: String, Sendable, CaseIterable, Equatable, Hashable, Identifiable {
    /// Today's chart: where the day went.
    case timeline
    /// One bar of that chart, opened up: the tour pins its tooltip open.
    case moment
    /// The rail's Weeks button, which you click yourself (#357): the tour never changes the page
    /// for you going forward. It goes on by itself once Weeks is showing.
    case openWeeks
    /// The Weeks page.
    case week
    /// The pause shortcut and the menu's Delete, drawn as key caps: there is no control for
    /// either inside the window to point at.
    case pauseAndDelete
    /// Asking Claude about your day, over the MCP server. Points at the Settings gear, where
    /// Connections adds Worklens to Claude Desktop.
    case askClaude
    /// The ring in the menu bar, which is outside the window: a small panel under the status
    /// item, or a card that says how to get back in when the item cannot be found.
    case menuBar

    public var id: String { rawValue }

    /// The reader page the stop is on, or nil when the stop is about something that is not a
    /// page and the reader can stay wherever it is.
    public var readerPlace: ReaderPlace? {
        switch self {
        case .timeline, .moment: return .today
        case .week: return .weeks
        case .openWeeks, .pauseAndDelete, .askClaude, .menuBar: return nil
        }
    }

    /// The page this step waits for you to open, or nil for a step that waits for Next.
    ///
    /// A step that waits hides Next while its rail button is cut out, and lets the click through
    /// to it. When the button cannot be found the step keeps Next, so nobody is ever stuck on it.
    public var waitsFor: ReaderPlace? {
        self == .openWeeks ? .weeks : nil
    }

    /// Whether the step draws a ring around the control it waits for you to click (#357 second
    /// pass): a stroke that draws itself, then pulses until the click; still under Reduce Motion.
    public var drawsClickRing: Bool { waitsFor != nil }

    /// Whether a view in the reader carries this stop's anchor. The two that do not are drawn as
    /// a centred card on purpose, which is also what any other stop falls back to when its view
    /// is not on screen.
    public var hasAnchor: Bool {
        switch self {
        case .timeline, .moment, .openWeeks, .week, .askClaude: return true
        case .pauseAndDelete, .menuBar: return false
        }
    }

    /// Whether the stop is explained inside the reader window. The menu-bar ring is the one
    /// that is not, unless its status item cannot be found.
    public var isInsideWindow: Bool { self != .menuBar }

    /// The card's heading.
    public var title: String {
        switch self {
        case .timeline: return L10n.string("Your day")
        case .moment: return L10n.string("One bar, opened up")
        case .openWeeks: return L10n.string("Open your week")
        case .week: return L10n.string("Your week")
        case .pauseAndDelete: return L10n.string("Pause, or delete")
        case .askClaude: return L10n.string("Ask Claude about your day")
        case .menuBar: return L10n.string("The ring in your menu bar")
        }
    }

    /// The card's one or two sentences.
    ///
    /// - Parameters:
    ///   - keys: the shortcuts as they are bound on this Mac, never the defaults by assumption.
    ///   - menuBarFound: whether the status item was found on screen. Only the last stop reads
    ///     it: when it was not, the card says how to get back in instead of pointing at nothing.
    public func body(keys: TourKeys, menuBarFound: Bool = true) -> String {
        switch self {
        case .timeline:
            return L10n.string(
                "Today draws where your active time went, one bar per app, biggest first, with your total at the end.")
        case .moment:
            return L10n.string(
                "Point at a bar and it opens up like this one: how long you spent in that app, and what you were doing there.")
        case .openWeeks:
            return L10n.string(
                "Click the calendar button on the left to open Weeks. The tour goes on once your week is showing.")
        case .week:
            return L10n.string(
                "Weeks lays the whole week out half an hour at a time, so you can see what each stretch went to.")
        case .pauseAndDelete:
            guard let pause = keys.pause else {
                return L10n.string(
                    "The menu-bar ring pauses everything. Its Delete menu deletes the last 10 minutes or the last hour.")
            }
            return L10n.format(
                "%@ pauses everything, from any app. The menu-bar ring's Delete menu deletes the last 10 minutes or the last hour.",
                pause)
        case .askClaude:
            return L10n.string(
                "Settings \u{2192} Connections adds Worklens to Claude Desktop. Then ask Claude what you worked on yesterday; it reads your days and changes nothing.")
        case .menuBar:
            guard !menuBarFound else {
                return L10n.string(
                    "Pause, delete and this window all start from the ring. Click it whenever you want Worklens.")
            }
            guard let open = keys.open else {
                return L10n.string(
                    "Worklens cannot see its ring in your menu bar right now: the notch or a full bar can hide it. Open Worklens again from Finder to bring this window back.")
            }
            return L10n.format(
                "Worklens cannot see its ring in your menu bar right now: the notch or a full bar can hide it. %@ brings this window back from any app.",
                open)
        }
    }

    /// The keys the card draws as caps, one cap per key, or none.
    public func keyCaps(keys: TourKeys, menuBarFound: Bool = true) -> [String] {
        switch self {
        case .pauseAndDelete: return keys.pause.map(TourKeys.caps) ?? []
        case .menuBar where !menuBarFound: return keys.open.map(TourKeys.caps) ?? []
        default: return []
        }
    }

    /// Whether the card links to the troubleshooting section about a missing menu-bar icon.
    public func offersMenuBarHelp(menuBarFound: Bool) -> Bool {
        self == .menuBar && !menuBarFound
    }
}

/// The two shortcuts the tour names, as `HotkeySpec.display` spells them on this Mac — `⌥⇧P`
/// out of the box — or nil when that shortcut is not registered (another app owns it).
public struct TourKeys: Equatable, Sendable {
    public var pause: String?
    public var open: String?

    public init(pause: String? = nil, open: String? = nil) {
        self.pause = pause
        self.open = open
    }

    /// The modifier glyphs `HotkeySpec.display` writes, in its order.
    static let modifierGlyphs: Set<Character> = ["\u{2303}", "\u{2325}", "\u{21E7}", "\u{2318}"]

    /// `⌥⇧P` → `["⌥", "⇧", "P"]`: one cap per modifier, then one for the key, whose name may be
    /// more than one character (`F5`, `Space`).
    public static func caps(_ display: String) -> [String] {
        var caps: [String] = []
        var rest = Substring(display)
        while let first = rest.first, modifierGlyphs.contains(first) {
            caps.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { caps.append(String(rest)) }
        return caps
    }
}

/// How a tour ended, which is what is remembered (#351).
public enum TourOutcome: String, Sendable, Equatable {
    /// Done was pressed on the last stop.
    case finished
    /// Skip, Esc, or the window closing under it.
    case skipped
}

/// Which tour this is (#357), which decides whether it can be skipped.
public enum TourRun: String, Sendable, Equatable {
    /// From the welcome window's **Take the tour**: part of setting up, so it has no Skip and Esc
    /// does nothing. Back works, and Next is there wherever a click cannot be.
    case welcome
    /// From Settings → Advanced's **Take the tour again**: Skip and Esc end it.
    case again

    public var allowsSkip: Bool { self == .again }
}

/// What a key press does while the tour is up: → or Return is next, ← is back, Esc is skip.
public enum TourCommand: Sendable, Equatable {
    case next
    case back
    case skip

    /// The command behind a `kVK_*` virtual key code, or nil for a key the tour leaves alone.
    /// A press with ⌘, ⌥ or ⌃ held is never the tour's: ⌘← and ⌘→ belong to the reader.
    public static func forKey(code: UInt16, withModifiers: Bool = false) -> TourCommand? {
        guard !withModifiers else { return nil }
        switch code {
        case 124, 36, 76: return .next  // →, Return, keypad Enter
        case 123: return .back  // ←
        case 53: return .skip  // Esc
        default: return nil
        }
    }
}

/// Where a tour has got to (#351). A value: `TourController` holds one and the overlay draws it.
public struct TourState: Equatable, Sendable {
    public static let stops = TourStop.allCases

    /// The 0-based position in `stops`.
    public private(set) var index: Int
    /// Nil while the tour is running; how it ended once it has.
    public private(set) var outcome: TourOutcome?
    /// Which tour this is: a first run cannot be skipped, a run from Settings can.
    public let run: TourRun

    public init(index: Int = 0, run: TourRun = .again) {
        self.index = min(max(index, 0), Self.stops.count - 1)
        self.run = run
    }

    /// Whether the card shows Skip and Esc ends the tour.
    public var allowsSkip: Bool { run.allowsSkip }

    public var stop: TourStop { Self.stops[index] }
    public var isRunning: Bool { outcome == nil }
    public var isFirst: Bool { index == 0 }
    public var isLast: Bool { index == Self.stops.count - 1 }

    /// The next stop, or the end of the tour from the last one.
    public mutating func next() {
        guard isRunning else { return }
        if isLast { outcome = .finished } else { index += 1 }
    }

    /// The stop before, and nothing at all from the first.
    ///
    /// A step that waits for a click is passed over going back: its page is already showing, so
    /// it would only go on again by itself. Back from the week lands on the day's last stop,
    /// and the tour takes the reader back to Today for it.
    public mutating func back() {
        guard isRunning, !isFirst else { return }
        index -= 1
        while stop.waitsFor != nil, index > 0 { index -= 1 }
    }

    /// Ends the tour where it is: Skip or Esc, on a tour that can be skipped.
    public mutating func skip() {
        guard isRunning, allowsSkip else { return }
        outcome = .skipped
    }

    /// The window the tour is drawn over went away under it. Every tour ends then, a first run
    /// included, because there is nothing left to point at; it is remembered as skipped.
    public mutating func abandon() {
        guard isRunning else { return }
        outcome = .skipped
    }

    /// Whether Next can be pressed. Everywhere but a step that waits for a click, and there too
    /// when the button to click is not on screen.
    public func canGoNext(anchorFound: Bool) -> Bool {
        stop.waitsFor == nil || !anchorFound
    }

    /// `place` is showing. On a step waiting for it, the tour goes on by itself; anywhere else
    /// nothing happens. True when the tour moved.
    @discardableResult
    public mutating func placeShown(_ place: ReaderPlace) -> Bool {
        guard isRunning, stop.waitsFor == place else { return false }
        next()
        return true
    }

    /// A key press or a card button. `anchorFound` is whether the current stop's view is on
    /// screen: Next does nothing on a step waiting for a click it can see.
    public mutating func apply(_ command: TourCommand, anchorFound: Bool = true) {
        switch command {
        case .next: if canGoNext(anchorFound: anchorFound) { next() }
        case .back: back()
        case .skip: skip()
        }
    }

    /// `3 of 6`.
    public var counter: String {
        L10n.format("%lld of %lld", index + 1, Self.stops.count)
    }

    /// Next, or Done on the last stop.
    public var nextLabel: String { isLast ? TourCopy.done : TourCopy.next }

    /// What VoiceOver is told on arriving at a stop: where, what, and the card's sentences.
    public func announcement(keys: TourKeys, menuBarFound: Bool = true) -> String {
        [counter, stop.title, stop.body(keys: keys, menuBarFound: menuBarFound)]
            .joined(separator: ". ")
    }
}

/// The buttons and links on every card.
public enum TourCopy {
    public static let back = L10n.string("Back")
    public static let next = L10n.string("Next")
    public static let done = L10n.string("Done")
    public static let skip = L10n.string("Skip")
    /// What VoiceOver calls the card.
    public static let cardLabel = L10n.string("Tour")
    /// The link on the last card when the ring cannot be found.
    public static let menuBarHelp = L10n.string("If you cannot find the menu-bar icon\u{2026}")
    /// Settings → Advanced.
    public static let settingsRow = L10n.string("Take the tour again")
    public static let settingsDetail = L10n.string(
        "Walks you through Today, Weeks and the menu-bar ring.")
    public static let settingsButton = L10n.string("Take the tour")
}

/// Remembering that the tour was taken (#351): finished or skipped, in `app_state`.
///
/// A word and nothing else, so nothing about the person is in it. Written every time a tour
/// ends, so a second run from Settings overwrites the first.
public enum TourMemory {
    public static let key = "tour_outcome"

    /// How the last tour ended, or nil when there has never been one (or the row is a word this
    /// build does not know).
    public static func outcome(in store: AppStateStore) -> TourOutcome? {
        guard let raw = (try? store.get(key)) ?? nil else { return nil }
        return TourOutcome(rawValue: raw)
    }

    public static func record(_ outcome: TourOutcome, in store: AppStateStore) throws {
        try store.set(key, outcome.rawValue)
    }
}
