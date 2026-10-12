import AppKit
import SwiftUI
import WorklensCore

/// Runs the spotlight tour (#351): which stop is up, the keys that move it, the panel under the
/// menu-bar ring, and what happens when it ends.
///
/// The order and the words are `TourState` and `TourStop` in `WorklensCore`; this holds one
/// `TourState` and tells the reader where to go. It knows nothing about `AppModel`:
/// `AppModel+Tour.swift` hands it the navigation and the memory as closures.
@MainActor
final class TourController: ObservableObject {
    /// The tour on screen, or nil when there is none.
    @Published private(set) var state: TourState?
    /// Whether the menu-bar ring was found for the last stop. False draws the card that says
    /// how to get back in.
    @Published private(set) var menuBarFound = false
    /// Whether the current stop's view is on screen, as the overlay last measured it. On a step
    /// that waits for a click it decides whether Next is there (#357).
    @Published private(set) var anchorFound = false
    /// The shortcuts as they are bound on this Mac, read when the tour starts.
    private(set) var keys = TourKeys()

    /// Called once before the first stop, so whatever the tour is shown over can be put in
    /// place first — the sample week (#349). `AppModel+Tour.swift` is where it is wired.
    var onWillStart: (() -> Void)?
    /// Called once after the tour has ended, however it ended.
    var onDidEnd: ((TourOutcome) -> Void)?

    private var navigate: ((TourStop) -> Void)?
    private var remember: ((TourOutcome) -> Void)?
    private var completion: ((TourOutcome) -> Void)?
    private var keyMonitor: Any?
    private let panel = TourMenuBarPanel()

    var isRunning: Bool { state?.isRunning ?? false }

    /// Starts from the first stop. A tour already running keeps running, and the new caller's
    /// `then` replaces the old one's: the last person to ask is the one waiting for the end.
    func start(
        run: TourRun,
        keys: TourKeys,
        navigate: @escaping (TourStop) -> Void,
        remember: @escaping (TourOutcome) -> Void,
        then completion: ((TourOutcome) -> Void)? = nil
    ) {
        self.completion = completion
        guard !isRunning else { return }
        self.keys = keys
        self.navigate = navigate
        self.remember = remember
        onWillStart?()
        anchorFound = false
        state = TourState(run: run)
        installKeyMonitor()
        arrive()
        Log.ui.info("tour started")
    }

    func next() { perform(.next) }
    func back() { perform(.back) }
    func skip() { perform(.skip) }

    /// The window the tour is drawn over went away under it, which ends any tour, a first run
    /// included, and is remembered as a skip.
    func hostWentAway() {
        guard var moved = state, moved.isRunning else { return }
        moved.abandon()
        if let outcome = moved.outcome { finish(outcome) }
    }

    /// The overlay measured the current stop's view: there, or not on screen.
    func anchorMeasured(_ found: Bool) {
        if anchorFound != found { anchorFound = found }
    }

    /// The reader is showing `place`. On a step waiting for that page, the tour goes on (#357):
    /// you clicked the rail button the step cut out.
    func placeShown(_ place: ReaderPlace) {
        guard var moved = state, moved.isRunning, moved.placeShown(place) else { return }
        state = moved
        arrive()
    }

    private func perform(_ command: TourCommand) {
        guard var moved = state, moved.isRunning else { return }
        let before = moved.index
        moved.apply(command, anchorFound: anchorFound)
        if let outcome = moved.outcome {
            finish(outcome)
        } else if moved.index != before {
            state = moved
            arrive()
        }
    }

    /// Takes the reader to the stop, puts the panel up or down, and tells VoiceOver.
    private func arrive() {
        guard let stop = state?.stop else { return }
        // Measured again for the new stop; until then a waiting step keeps its Next.
        anchorFound = false
        navigate?(stop)
        if stop.isInsideWindow {
            panel.hide()
        } else {
            // Published before the panel measures its card: the card reads it, and a panel sized
            // for the longer "cannot see its ring" card puts its arrow below the ring.
            menuBarFound = panel.ringIsOnScreen
            menuBarFound = panel.show(tour: self)
        }
        announce()
    }

    private func finish(_ outcome: TourOutcome) {
        panel.hide()
        anchorFound = false
        removeKeyMonitor()
        state = nil
        Log.ui.info("tour \(outcome.rawValue)")
        remember?(outcome)
        onDidEnd?(outcome)
        let then = completion
        completion = nil
        navigate = nil
        remember = nil
        then?(outcome)
    }

    // MARK: Keyboard

    /// → or Return next, ← back, Esc skip, from whichever Worklens window is key. A local
    /// monitor rather than a focused view, because the panel under the ring never becomes key
    /// and the reader's own controls may hold focus.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let held = !event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            guard let command = TourCommand.forKey(code: event.keyCode, withModifiers: held)
            else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isRunning else { return false }
                // A first-run tour has no Skip, and its Esc does nothing at all rather than
                // reaching the reader underneath.
                self.perform(command)
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: VoiceOver

    /// Each stop is announced as it arrives; the card also takes the accessibility focus.
    private func announce() {
        guard let state else { return }
        let text = state.announcement(keys: keys, menuBarFound: menuBarFound)
        // After the run loop turns, so the card the sentence describes is the one on screen.
        DispatchQueue.main.async {
            NSAccessibility.post(
                element: NSApp.keyWindow ?? NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: text,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    }
}
