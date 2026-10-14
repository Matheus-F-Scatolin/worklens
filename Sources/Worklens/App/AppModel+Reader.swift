import Foundation
import WorklensCore

/// How the reader *works*: every method behind the window that shows your days (#134, #138,
/// #233).
///
/// Split out of `AppModel.swift` because that file is 200 k and three consecutive waves of work
/// land here. What could not come along is the stored state — an extension holds no stored
/// properties — so `AppModel.swift` keeps the `@Published` declarations, the `readerSelection`
/// `didSet` that calls back into this file, and this file is the only thing that writes any of
/// them.
@MainActor
extension AppModel {
    /// True once anything at all has been recorded. The plain "nothing recorded" line is for the
    /// other case.
    var readerHasDays: Bool { !readerWeeks.isEmpty }

    /// The menu's "Open Worklens".
    func openReader(_ selection: ReaderSelection? = nil) {
        // #286: Settings shares this window now; a day asked for is a reading page.
        closeSettings()
        openWindow(id: AppModel.readerWindowID)
        Task { [weak self] in
            await self?.refreshReaderIndex()
            guard let self else { return }
            if let selection {
                self.select(selection)
            } else if self.readerSelection == nil {
                self.selectNewest()
            }
        }
    }

    /// A click on the first-summary banner: the reader, on your own Today page. The banner can
    /// be clicked from Notification Center long after, with the sample week re-opened from
    /// Settings, so it leaves the sample (leaving lands on Today by itself). The debounced
    /// timeline rebuild is run first, so a click inside its five seconds does not open on an
    /// empty day.
    func openToday() {
        closeSettings()
        openWindow(id: AppModel.readerWindowID)
        Task { [weak self] in
            await self?.timeline?.flush()
            guard let self else { return }
            if self.isShowingSampleWeek { return self.exitSampleWeek() }
            await self.refreshReaderIndex()
            self.showToday()
        }
    }

    /// Selects, and reloads even when the same row was already selected.
    func select(_ selection: ReaderSelection) {
        if readerSelection == selection {
            loadReaderDocument()
        } else {
            readerSelection = selection
        }
    }

    func selectNewest() {
        if let day = readerWeeks.first?.days.first {
            select(.day(day.day))
        } else {
            readerSelection = nil
            readerDocument = nil
        }
    }

    /// `ReaderView` appeared or went away. The window is the only thing that knows.
    func readerWindow(isVisible: Bool) {
        readerIsVisible = isVisible
    }

    /// The day before / after the selected one, in sidebar order. Bound to ⌘← and ⌘→.
    ///
    /// #244: stepping off the oldest *loaded* day loads the page behind it and lands on the next
    /// day, rather than returning silently with history still to reach. At the oldest day there
    /// is, it stops, and the line under the list says why.
    func stepReader(by offset: Int) {
        let days = readerWeeks.flatMap(\.days).map(\.day)
        guard !days.isEmpty else { return }
        guard case let .day(current)? = readerSelection, let index = days.firstIndex(of: current)
        else { return select(.day(days[0])) }
        let next = index + offset
        if days.indices.contains(next) { return select(.day(days[next])) }
        guard offset > 0, readerPaging.hasEarlier, !readerPaging.isLoadingEarlier else { return }
        Task { [weak self] in
            await self?.loadEarlierDays()
            guard let self else { return }
            let loaded = self.readerWeeks.flatMap(\.days).map(\.day)
            guard loaded.indices.contains(next) else { return }
            self.select(.day(loaded[next]))
        }
    }

    // MARK: The rail (reader redesign)

    /// A rail item was clicked. Today lands back on the day the reader was on; Weeks shows the
    /// week around it.
    func show(_ place: ReaderPlace) {
        readerPlace = place
        // #357: a step of the tour may be waiting for this page, whichever way it arrived.
        defer { tourSawPlace(place) }
        let fallback = readerFocusDay ?? readerWeeks.first?.days.first?.day
        switch place {
        case .weeks:
            if let monday = tourWeekMonday { return select(.week(monday)) }
            let day = fallback ?? DayBoundaries.dayString(Date())
            if let week = ISOWeek.containing(dayString: day) { select(.week(week.start)) }
        case .today:
            if case .day? = readerSelection { return }
            if let fallback { select(.day(fallback)) }
        }
    }

    /// The rail's Today: back to today, or to the newest day there is when today has nothing.
    func showToday() {
        readerPlace = .today
        let today = DayBoundaries.dayString(Date())
        let days = readerWeeks.flatMap(\.days).map(\.day)
        select(.day(days.contains(today) || days.isEmpty ? today : days[0]))
    }

    /// A day header on the Weeks grid: that day's Today page.
    func openDayFromWeek(_ day: String) {
        readerPlace = .today
        select(.day(day))
    }

    /// Weeks' ‹ ›: the week before or after, among the weeks that have days. Positive is older,
    /// the same direction `stepReader` counts in.
    func stepWeek(by offset: Int) {
        let mondays = readerWeeks.map(\.monday)
        guard case let .week(monday)? = readerSelection,
              let index = mondays.firstIndex(of: monday) else { return }
        let next = index + offset
        if mondays.indices.contains(next) { return select(.week(mondays[next])) }
        guard offset > 0, readerPaging.hasEarlier, !readerPaging.isLoadingEarlier else { return }
        Task { [weak self] in
            await self?.loadEarlierDays()
            guard let self else { return }
            let loaded = self.readerWeeks.map(\.monday)
            guard loaded.indices.contains(next) else { return }
            self.select(.week(loaded[next]))
        }
    }

    /// Whether ‹ or › has anywhere to go, for the chevrons' disabled state.
    func canStepReader(by offset: Int) -> Bool {
        switch readerSelection {
        case let .day(day)?:
            let days = readerWeeks.flatMap(\.days).map(\.day)
            guard let index = days.firstIndex(of: day) else { return false }
            return days.indices.contains(index + offset) || (offset > 0 && readerPaging.hasEarlier)
        case let .week(monday)?:
            let mondays = readerWeeks.map(\.monday)
            guard let index = mondays.firstIndex(of: monday) else { return false }
            return mondays.indices.contains(index + offset) || (offset > 0 && readerPaging.hasEarlier)
        default:
            return false
        }
    }

    /// The sidebar's **Earlier days** row: the page behind the loaded window, appended in place
    /// with the selection kept (#244).
    func loadEarlierDays() async {
        guard let page = readerPaging.earlier, !readerPaging.isLoadingEarlier else { return }
        readerPaging.isLoadingEarlier = true
        readerPaging.loadedFrom = page.after
        readerPaging.pagesLoaded += 1
        await refreshReaderIndex()
        readerPaging.isLoadingEarlier = false
    }

    /// Reads the day index off the main actor, for the pages the sidebar has loaded and no more.
    ///
    /// #244: the read is a date window rather than a row limit. A `LIMIT` is applied after the
    /// grouping, so the old unbounded call grouped every capture row ever written to return the
    /// newest 120 days — on every reader tick a window was open — and day 121 was unreachable
    /// from the UI at all. The window is served by `idx_captures_captured_at`; what is behind it
    /// is one more bounded read, so the **Earlier days** row can say how many days it would add.
    func refreshReaderIndex() async {
        guard let db = readerDB else { return }
        // #349: an index read from one database is not drawn over the other's.
        let sample = isShowingSampleWeek
        let loaded = await readReaderIndex(db, paging: readerPaging)
        guard isShowingSampleWeek == sample else { return }
        applyReaderIndex(loaded)
    }

    /// The read half of `refreshReaderIndex`, which changes nothing on screen: the sample week's
    /// way out reads your own days with it before it swaps them in.
    func readReaderIndex(_ db: Database, paging: ReaderPaging) async -> ReaderIndexLoad {
        let today = DayBoundaries.dayString(Date())
        let labels = readerLabels
        return await Task.detached(priority: .userInitiated) { () -> ReaderIndexLoad in
            let index = DayIndex(db)
            var result = ReaderIndexLoad()
            result.oldestRecordedDay = (try? index.oldestDay()) ?? nil
            let newest = ((try? index.newestDay()) ?? nil) ?? today
            // The first page is re-derived from today on every refresh: its window has no upper
            // bound, so a window pinned at the first load would keep growing as days are
            // recorded, and the row limit would start clipping its oldest days out of a list
            // that still claims to cover them. Only a window a person actually paged back is
            // kept where they put it.
            if let from = paging.loadedFrom, paging.pagesLoaded > 1 {
                result.loadedFrom = from
                result.pagesLoaded = paging.pagesLoaded
            } else {
                result.loadedFrom = ReaderPaging.firstWindow(newest: max(newest, today)).after
                result.pagesLoaded = 1
            }
            let from = result.loadedFrom ?? today
            // Sized from the window, never under the pages loaded, so the limit cannot cut a day
            // out of the stretch the sidebar says it is showing.
            let entries = (try? index.entries(
                limit: max(
                    ReaderPaging.pageDays * result.pagesLoaded,
                    ReaderPaging.dayCount(from: from, to: max(newest, today))
                ),
                after: from,
                labels: labels
            )) ?? []
            result.entries = entries
            // What the next page would hold. Empty windows are walked over — a month nobody used
            // the Mac in is not the end of the history — and the walk stops at the first day
            // there is.
            if let oldest = result.oldestRecordedDay, oldest < from {
                var window = ReaderPaging.previousWindow(loadedFrom: from)
                while window.before >= oldest {
                    let days = (try? index.recordedDays(
                        limit: ReaderPaging.pageDays,
                        after: max(window.after, oldest),
                        before: window.before
                    )) ?? []
                    if !days.isEmpty {
                        result.earlier = ReaderPage(
                            after: window.after, before: window.before, days: days.count
                        )
                        break
                    }
                    window = ReaderPaging.previousWindow(loadedFrom: window.after)
                }
            }
            return result
        }.value
    }

    /// The apply half: the loaded pages become the sidebar's, in one go.
    func applyReaderIndex(_ loaded: ReaderIndexLoad) {
        readerEntries = Dictionary(
            loaded.entries.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first }
        )
        readerWeeks = ReaderIndex.weeks(entries: loaded.entries)
        readerPaging.loadedFrom = loaded.loadedFrom
        readerPaging.pagesLoaded = loaded.pagesLoaded
        readerPaging.earlier = loaded.earlier
        readerPaging.oldestRecordedDay = loaded.oldestRecordedDay
        readerIndexLoaded = true
    }

    /// Rebuilds the detail pane for whatever is selected. Cancels the load in flight, so clicking
    /// down a week of days does not queue a week of renders.
    func loadReaderDocument() {
        readerLoad?.cancel()
        guard let selection = readerSelection else {
            readerDocument = nil
            return
        }
        readerLoading = true
        readerLoad = Task { [weak self] in
            guard let self else { return }
            let document = await self.buildReaderDocument(selection)
            guard !Task.isCancelled else { return }
            self.readerDocument = document
            self.readerLoading = false
        }
    }

    private func buildReaderDocument(_ selection: ReaderSelection) async -> ReaderDocument? {
        guard let db = readerDB else { return nil }
        return await buildReaderDocument(selection, db: db, entries: readerEntries)
    }

    /// A document read from `db` with `entries` as its index, whatever the reader is showing.
    func buildReaderDocument(
        _ selection: ReaderSelection, db: Database, entries: [String: DayIndexEntry]
    ) async -> ReaderDocument? {
        switch selection {
        case let .week(monday):
            let week = ISOWeek.parse(monday) ?? ISOWeek.containing(dayString: monday)
            var calendar: WeekCalendar.Week?
            if let week { calendar = await weekViews(week, db: db) }
            return ReaderDocument(
                selection: selection,
                kind: .weekly,
                title: DayTitle.of(
                    kind: .weekly, periodStart: monday, periodEnd: week?.end ?? monday
                ),
                calendar: calendar
            )
        case let .day(day):
            let waterfall = await dayViews(day: day, db: db, entries: entries)
            return ReaderDocument(
                selection: selection,
                kind: .daily,
                title: DayTitle.of(kind: .daily, periodStart: day, periodEnd: day),
                waterfall: waterfall
            )
        }
    }

    /// The Today page's waterfall, off the day's `DailyStats`.
    ///
    /// `StatsService.daily` is six store reads and the whole aggregation pass, so it runs off the
    /// main actor: the reader must not stutter on a click. The two things it needs from this
    /// actor — whether the day has blocks at all, and the taxonomy the labels come from — are
    /// read before the hop.
    private func dayViews(
        day: String, db: Database, entries: [String: DayIndexEntry]
    ) async -> Waterfall? {
        guard entries[day]?.hasTimeline == true else { return nil }
        let labels = readerLabels
        let service = statsService(db)
        // The day's blocks too: each bar's tooltip says what you were doing in that app (#357).
        let read = await Task.detached(priority: .userInitiated) {
            (try? service.daily(day: day), (try? ActivityBlockStore(db).fetch(day: day)) ?? [])
        }.value
        guard let stats = read.0, !stats.isEmpty else { return nil }
        return Waterfall.of(stats, labels: labels, blocks: read.1)
    }

    /// The taxonomy's names, for your own days and the sample's alike: the sample's apps are
    /// named, and so coloured, exactly as a real day's are (#357).
    private var readerLabels: TimelineLabels {
        taxonomy.map { TimelineLabels.from($0.current) } ?? TimelineLabels()
    }

    /// The Weeks grid: the week's stats for its numbers, and each day's blocks for its top apps,
    /// where the colours go and where the meeting chips go. No previous week: the grid compares nothing.
    private func weekViews(_ week: ISOWeek, db: Database) async -> WeekCalendar.Week? {
        let labels = readerLabels
        let service = statsService(db)
        return await Task.detached(priority: .userInitiated) {
            let stats = try? service.weekly(week, includePreviousWeek: false)
            var blocks: [String: [ActivityBlock]] = [:]
            for day in week.days {
                blocks[day] = (try? ActivityBlockStore(db).fetch(day: day)) ?? []
            }
            return WeekCalendar.build(
                week: week, stats: stats, blocksByDay: blocks, labels: labels
            )
        }.value
    }
}

/// One read of the day index: the loaded pages, and what is behind them (#244). Assembled off the
/// main actor and applied in one go, so the sidebar never draws half a page.
struct ReaderIndexLoad: Sendable {
    var entries: [DayIndexEntry] = []
    var loadedFrom: String?
    var pagesLoaded = 0
    var earlier: ReaderPage?
    var oldestRecordedDay: String?
}
