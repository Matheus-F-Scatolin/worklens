import Foundation
import WorklensCore

/// The spotlight tour (#351) as `AppModel` sees it: start it over the reader, take the reader to
/// each stop, and remember how it ended.
///
/// Its own file rather than more of `AppModel.swift`, which is past 148 k. The controller is a
/// static here for the same reason: an extension cannot add a stored property, and the tour has
/// exactly one of everything `AppModel.shared` does.
@MainActor
extension AppModel {
    private static let tourController: TourController = {
        let tour = TourController()
        // The tour points at the sample week (#349), so every stop has something to show: a
        // Today with bars to open, a Week with every day filled in.
        tour.onWillStart = { AppModel.shared.sampleWeekForTour() }
        tour.onDidEnd = { _ in AppModel.shared.sampleWeekAfterTour() }
        return tour
    }()

    /// Whether this tour put the sample week up, rather than finding it already shown.
    private static var tourShowedSample = false

    /// `app_state` key: a tour from the welcome window is running. A Worklens that quits in the
    /// middle of it resumes on Screen Recording without saying the grant is still off, since
    /// nothing was asked for.
    static let welcomeTourKey = "setup_tour_running"

    /// The one tour. Views observe it directly.
    var tour: TourController { AppModel.tourController }

    /// Opens the reader and runs the tour over it: Settings → Advanced's **Take the tour again**,
    /// and the welcome window's **Take the tour** through `takeTourFromWelcome()`.
    ///
    /// - Parameters:
    ///   - run: `.again` from Settings, which can be skipped; `.welcome` from the welcome window,
    ///     which cannot (#357).
    ///   - then: called once when the tour ends, however it ends.
    func startTour(run: TourRun = .again, then: ((TourOutcome) -> Void)? = nil) {
        closeSettings()
        frontHomeWindow()
        tour.start(
            run: run,
            keys: tourKeys,
            navigate: { [weak self] stop in self?.showTourStop(stop) },
            remember: { [weak self] outcome in self?.rememberTour(outcome) },
            then: then
        )
    }

    /// The welcome window's **Take the tour** (#352): the tour, and then the welcome window
    /// again on the Screen Recording page. Part of setting up since #357, so it has no Skip;
    /// closing the reader window under it is the one other way it ends.
    ///
    /// The page is written before the tour starts rather than after it ends, so a Worklens that
    /// quits halfway through the tour still comes back to Screen Recording.
    func takeTourFromWelcome() {
        guard let next = SetupPage.tour.next else { return }
        setupMove(to: next)
        if let db { try? AppStateStore(db).setDate(AppModel.welcomeTourKey, Date()) }
        startTour(run: .welcome) { [weak self] _ in
            guard let self else { return }
            if let db = self.db { try? AppStateStore(db).delete(AppModel.welcomeTourKey) }
            self.openWindow(id: AppModel.setupWindowID)
        }
    }

    /// True once after a launch that quit in the middle of a welcome-window tour, and clears it.
    /// The launch gate asks before it puts the resumed page's line up.
    func takeInterruptedWelcomeTour() -> Bool {
        guard let db else { return false }
        let store = AppStateStore(db)
        guard ((try? store.getDate(AppModel.welcomeTourKey)) ?? nil) != nil else { return false }
        try? store.delete(AppModel.welcomeTourKey)
        return true
    }

    /// Before the first stop: the sample week, landed on Today.
    private func sampleWeekForTour() {
        AppModel.tourShowedSample = !isShowingSampleWeek
        showSampleWeek()
    }

    /// After the last one. During the welcome flow the sample stays: there is nothing of yours
    /// yet, and your first real moment takes it away (#350). Once your own days have started, a
    /// tour that put the sample up takes it down again; one you opened yourself stays.
    private func sampleWeekAfterTour() {
        defer { AppModel.tourShowedSample = false }
        guard AppModel.tourShowedSample, sampleWeekHandedOff else { return }
        exitSampleWeek()
    }

    /// The shortcuts as they are registered right now, so the card never names a key that is not
    /// the one that works. Nil for a shortcut another app owns.
    private var tourKeys: TourKeys {
        TourKeys(pause: pauseHotkey?.display, open: openHotkey?.display)
    }

    /// The reader page a stop is on. Stops that are not about a page leave it where it is.
    ///
    /// A step that waits for you to open a page never opens it (#357); if that page is somehow
    /// showing already, the step goes on by itself, after this run of the loop so the controller
    /// has finished arriving.
    private func showTourStop(_ stop: TourStop) {
        if let wanted = stop.waitsFor {
            guard wanted == readerPlace, settingsSection == nil else { return }
            DispatchQueue.main.async { [weak self] in self?.tour.placeShown(wanted) }
            return
        }
        guard let place = stop.readerPlace, place != readerPlace || settingsSection != nil else {
            return
        }
        closeSettings()
        show(place)
    }

    /// The reader just showed `place`, from the rail or from the tour. A step waiting for it goes
    /// on. Called by `show(_:)` in `AppModel+Reader.swift`.
    func tourSawPlace(_ place: ReaderPlace) {
        guard tour.isRunning else { return }
        tour.placeShown(place)
    }

    /// The week the Weeks page opens on while a tour is up over the sample: last week until
    /// this one has `SampleWeek.tourWeekWholeDays` whole days (#357), so the stop never lands on
    /// one morning and six empty columns. Nil outside a tour, or over your own days.
    var tourWeekMonday: String? {
        guard tour.isRunning, isShowingSampleWeek else { return nil }
        return SampleWeek.tourWeek(now: Date())?.start
    }

    private func rememberTour(_ outcome: TourOutcome) {
        guard let db else { return }
        try? TourMemory.record(outcome, in: AppStateStore(db))
    }
}
