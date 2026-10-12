import Foundation

/// Deterministic numbers about a day, computed rather than asked for.
///
/// Every entry point is a pure function: same blocks and captures in, same stats out. Minutes are
/// accumulated as seconds and rounded once at the end, so the parts always add up to the whole.
public enum StatsAggregator {
    // MARK: Conventions shared with the timeline writer

    /// App or task keys that mean "not working": the time is tracked but not active.
    ///
    /// The timeline writer (#10) emits these for gaps where the machine was idle, locked or
    /// asleep. Matching is case-insensitive and looks at both `appKey` and `taskKey`.
    public static let inactiveKeys: Set<String> = ["idle", "locked", "away", "asleep", "screensaver"]

    /// Task key the timeline writer uses for a meeting on the screen side.
    public static let meetingTaskKey = "meeting"

    /// App key `ContextBlocks.awayBlocks` gives the stretches a calendar event says you were not
    /// at the machine (#94). One of `inactiveKeys`, so away time is tracked and never active.
    public static let awayAppKey = "away"

    /// Sources that are meetings by construction.
    public static let meetingSources: Set<ActivitySource> = [.calendar, .granola]

    public static func isInactive(_ block: ActivityBlock) -> Bool {
        inactiveKeys.contains(block.appKey.lowercased()) || inactiveKeys.contains(block.taskKey.lowercased())
    }

    public static func isMeeting(_ block: ActivityBlock) -> Bool {
        guard !isAway(block) else { return false }
        return meetingSources.contains(block.source) || block.taskKey.lowercased() == meetingTaskKey
    }

    /// #94: an away block comes from the calendar like a meeting block does, and is the one thing
    /// from the calendar that is not a meeting.
    public static func isAway(_ block: ActivityBlock) -> Bool {
        block.appKey.lowercased() == awayAppKey
    }

    /// How many rows each breakdown keeps before folding the tail into "other".
    public static let appLimit = 12
    public static let taskLimit = 15
    public static let hostLimit = 10
    public static let projectLimit = 8
    /// Apps named inside one project's row (#90).
    public static let projectAppLimit = 3
    /// #91: at most this many threads in a day's table. Ten rows is already more re-entry than
    /// a report can act on, and the tail is single-visit noise.
    public static let threadLimit = 10
    public static let switchPairLimit = 8

    /// A block must last this long to count as focus.
    public static let focusMinimumMinutes = 10.0
    public static let longFocusMinutes = 25.0

    // MARK: Daily

    /// Maps an app key to its taxonomy category. Issue #7 supplies the real resolver; until then
    /// callers pass nothing and every app lands in "uncategorized".
    public typealias CategoryResolver = @Sendable (String) -> String?

    public static func daily(
        day: String,
        blocks: [ActivityBlock],
        captures: [Capture] = [],
        contextEvents: [ContextEvent] = [],
        sessions: [ForegroundSession] = [],
        projectHints: [String: String] = [:],
        /// #315: `capture_id` → the catalog `project_key` a d5 frame picked.
        projectKeys: [String: String] = [:],
        /// #91: `capture_id` → the `document` the describer named, for the threads a frame gave
        /// no project. Absent keys simply carry no document.
        frameDocuments: [String: String] = [:],
        /// #319: `capture_id` → `ax_snapshots.document_url`, for `byDocument`.
        frameDocumentURLs: [String: String] = [:],
        projects: [ProjectEntry] = [],
        /// #318: email domains a meeting never counts toward (`Taxonomy.ignoredDomains`).
        ignoredDomains: [String] = [],
        category: CategoryResolver? = nil,
        llmCost: Double = 0,
        timeZone: TimeZone = .current,
        /// The moment the stats are read at. Calendar blocks are cut off here (see
        /// `clippedToNow`); `nil` counts every block whole, which only a past day can afford.
        now: Date? = nil,
        /// #322: the day's project spans. When given, `byProject` and the threads' projects read
        /// them instead of each frame's hint, and the day carries them as `projectSpans`.
        projectSpans: [ProjectSpan]? = nil
    ) -> DailyStats {
        let blocks = clippedToNow(blocks, now: now)
            .filter { $0.endAt > $0.startAt }
            .sorted { $0.startAt < $1.startAt }
        let meetings = meetingsCount(contextEvents)
        guard !blocks.isEmpty else {
            return DailyStats(
                day: day, hourly: emptyHourly(), llmCostUSD: llmCost,
                meetingsCount: meetings
            )
        }

        let active = blocks.filter { !isInactive($0) }
        let inactive = blocks.filter { isInactive($0) }
        // A meeting block from the calendar sits *on top of* the screen blocks it contains
        // (#19 keeps both, so the day can say what you had open during the call). Totals are
        // therefore the union of the intervals, never the sum, or a day would report more
        // minutes than it has. Breakdowns stay screen-only: the meeting's minutes are already
        // attributed to whatever app the frames were in.
        let screenActive = active.filter { $0.source == .screen }

        let trackedSeconds = unionSeconds(blocks)
        let activeSeconds = unionSeconds(active)
        let idleSeconds = unionSeconds(inactive)
        let screenActiveSeconds = screenActive.reduce(0.0) { $0 + seconds($1) }

        // Captures inherit the minutes of the block they fall in, split evenly, so capture-derived
        // breakdowns (hosts, redaction, meetings) share one denominator with the block ones.
        let weights = captureWeights(blocks: blocks, captures: captures)

        // #46: exact per-app seconds where `foreground_sessions` covers the day, block seconds
        // everywhere else. `byApp` and `byCategory` are the only breakdowns that move — they are
        // the ones a sampled tick interval was distorting.
        let exact = exactAppSeconds(
            screenActive: screenActive, weights: weights, sessions: sessions, activeBlocks: active
        )
        let appSecondsTotal = exact.perKey.values.reduce(0, +)
        let appEntries: [Entry] = exact.perKey.map { Entry(key: $0.key, name: $0.key, seconds: $0.value) }
        let categoryEntries: [Entry] = exact.perKey.map { key, value in
            let category = category?(key) ?? "uncategorized"
            return Entry(key: category, name: category, seconds: value)
        }
        let taskEntries: [Entry] = screenActive.map { block in
            let key = "\(block.appKey)/\(block.taskKey)"
            return Entry(key: key, name: key, seconds: seconds(block))
        }
        let hostEntries: [Entry] = weights.compactMap { weight in
            guard let host = weight.capture.urlHost, !host.isEmpty else { return nil }
            return Entry(key: host, name: host, seconds: weight.seconds)
        }
        let redactedSeconds: Double = weights.filter(\.capture.isRedacted).reduce(0.0) { $0 + $1.seconds }
        let onScreenWeights = weights.filter { $0.block.source == .screen && !isInactive($0.block) }
        // #322: with spans, a frame's own hint no longer names a project anywhere; the spans do.
        let named = projectSpans != nil ? [:] : namedProjects(
            weights: onScreenWeights, hints: projectHints, keys: projectKeys, projects: projects
        )
        let shares = meetingShares(
            contextEvents, projects: projects, ignoredDomains: ignoredDomains,
            day: day, timeZone: timeZone, now: now
        )
        let projectRows = projectSpans.map { spanSlices($0, screenBlocks: screenActive, meetings: shares) }
            ?? projectSlices(weights: onScreenWeights, named: named, total: screenActiveSeconds, meetings: shares)

        let stats = DailyStats(
            day: day,
            firstActivity: active.map(\.startAt).min(),
            lastActivity: active.map(\.endAt).max(),
            trackedMinutes: minutes(trackedSeconds),
            activeMinutes: minutes(activeSeconds),
            idleMinutes: minutes(idleSeconds),
            meetingMinutes: minutes(meetingSeconds(blocks: blocks, weights: weights)),
            awayMinutes: minutes(unionSeconds(blocks.filter(isAway))),
            redactedMinutes: minutes(redactedSeconds),
            framesDescribed: captures.filter { $0.describeStatus == .described }.count,
            framesInherited: captures.filter { $0.describeStatus == .inherited }.count,
            byApp: slices(appEntries, limit: appLimit, total: appSecondsTotal),
            byCategory: slices(categoryEntries, limit: appLimit, total: appSecondsTotal),
            byTask: slices(taskEntries, limit: taskLimit, total: screenActiveSeconds),
            byHost: slices(hostEntries, limit: hostLimit, total: screenActiveSeconds),
            byProject: projectRows,
            // Idle blocks are part of the sequence on purpose (see `threads`): a return after
            // one is a re-entry, which is the whole point of the table.
            threads: threads(
                blocks.filter { $0.source == .screen }, weights: onScreenWeights,
                named: named, documents: frameDocuments,
                spanProjects: projectSpans.map { spanProjects(blocks.filter { $0.source == .screen }, spans: $0) }
            ),
            hourly: hourly(screenActive, timeZone: timeZone),
            contextSwitches: switchPairs(screenActive).reduce(0) { $0 + $1.count },
            switchesPerActiveHour: 0,
            longestFocusBlock: longestFocus(screenActive),
            focusBlocksOver25Min: screenActive.filter { seconds($0) >= longFocusMinutes * 60 }.count,
            medianBlockMinutes: median(screenActive.map { seconds($0) / 60 }),
            topSwitchPairs: Array(switchPairs(screenActive).prefix(switchPairLimit)),
            distinctApps: Set(screenActive.map(\.appKey)).count,
            sessionMinutes: minutes(exact.coveredSeconds),
            sessionCoverage: share(exact.coveredSeconds, of: activeSeconds),
            llmCostUSD: llmCost,
            meetingsCount: meetings
        )
        var result = stats
        result.switchesPerActiveHour = activeSeconds > 0
            ? round(Double(stats.contextSwitches) / (activeSeconds / 3600) * 100) / 100
            : 0
        result.byDocument = DocumentTime.slices(
            weights: onScreenWeights, documentURLs: frameDocumentURLs,
            frameDocuments: frameDocuments, total: screenActiveSeconds
        )
        result.projectSpans = projectSpans
        return result
    }

    // MARK: Weekly

    /// `days` must be the daily stats for the week, Monday first; days without tracked time may be
    /// omitted. `previous` is last week's stats, when there is one, and only feeds the deltas.
    public static func weekly(
        days: [DailyStats],
        previous: WeeklyStats? = nil,
        timeZone: TimeZone = .current
    ) -> WeeklyStats {
        let tracked = days.filter { !$0.isEmpty }.sorted { $0.day < $1.day }
        let week = ISOWeek.containing(dayString: tracked.first?.day ?? days.first?.day ?? "", timeZone: timeZone)
            ?? ISOWeek(year: 0, week: 0, start: "", end: "", days: [])

        let activeMinutes = tracked.reduce(0) { $0 + $1.activeMinutes }
        let contextSwitches = tracked.reduce(0) { $0 + $1.contextSwitches }
        let byDay = Dictionary(tracked.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })

        var totals = WeeklyTotals(
            daysTracked: tracked.count,
            trackedMinutes: tracked.reduce(0) { $0 + $1.trackedMinutes },
            activeMinutes: activeMinutes,
            idleMinutes: tracked.reduce(0) { $0 + $1.idleMinutes },
            meetingMinutes: tracked.reduce(0) { $0 + $1.meetingMinutes },
            contextSwitches: contextSwitches,
            switchesPerActiveHour: activeMinutes > 0
                ? round(Double(contextSwitches) / (Double(activeMinutes) / 60) * 100) / 100
                : 0,
            focusBlocksOver25Min: tracked.reduce(0) { $0 + $1.focusBlocksOver25Min },
            averageActiveMinutesPerDay: tracked.isEmpty
                ? 0
                : round(Double(activeMinutes) / Double(tracked.count) * 10) / 10,
            longestFocusBlock: tracked.compactMap(\.longestFocusBlock).max { $0.minutes < $1.minutes },
            byApp: merge(tracked.map(\.byApp), limit: appLimit, total: activeMinutes),
            byCategory: merge(tracked.map(\.byCategory), limit: appLimit, total: activeMinutes),
            byTask: merge(tracked.map(\.byTask), limit: taskLimit, total: activeMinutes),
            byHost: merge(tracked.map(\.byHost), limit: hostLimit, total: activeMinutes),
            byProject: coveredShares(merge(tracked.map(\.byProject), limit: projectLimit, total: activeMinutes)),
            topSwitchPairs: mergePairs(tracked.map(\.topSwitchPairs), limit: switchPairLimit),
            distinctApps: Set(tracked.flatMap { $0.byApp.map(\.key) }.filter { $0 != otherKey }).count,
            llmCostUSD: tracked.reduce(0) { $0 + $1.llmCostUSD },
            meetingsCount: tracked.reduce(0) { $0 + $1.meetingsCount }
        )
        totals.byDocument = merge(tracked.map(\.byDocument), limit: DocumentTime.limit, total: activeMinutes)

        return WeeklyStats(
            weekStart: week.start,
            weekEnd: week.end,
            isoWeek: week.identifier,
            days: tracked,
            totals: totals,
            projectLedger: projectLedger(tracked),
            perDayActiveMinutes: week.days.map { byDay[$0]?.activeMinutes ?? 0 },
            deltaVsPreviousWeek: previous.map { delta(this: totals, last: $0.totals) }
        )
    }

    /// Relative change per metric, `(this - last) / last`, rounded to three decimals. Metrics whose
    /// previous value was zero are omitted rather than reported as an infinite increase.
    static func delta(this: WeeklyTotals, last: WeeklyTotals) -> [String: Double] {
        let pairs: [(String, Double, Double)] = [
            ("activeMinutes", Double(this.activeMinutes), Double(last.activeMinutes)),
            ("trackedMinutes", Double(this.trackedMinutes), Double(last.trackedMinutes)),
            ("meetingMinutes", Double(this.meetingMinutes), Double(last.meetingMinutes)),
            ("idleMinutes", Double(this.idleMinutes), Double(last.idleMinutes)),
            ("contextSwitches", Double(this.contextSwitches), Double(last.contextSwitches)),
            ("switchesPerActiveHour", this.switchesPerActiveHour, last.switchesPerActiveHour),
            ("focusBlocksOver25Min", Double(this.focusBlocksOver25Min), Double(last.focusBlocksOver25Min)),
            ("averageActiveMinutesPerDay", this.averageActiveMinutesPerDay, last.averageActiveMinutesPerDay),
            ("daysTracked", Double(this.daysTracked), Double(last.daysTracked)),
        ]
        var result: [String: Double] = [:]
        for (key, now, before) in pairs where before != 0 {
            result[key] = round((now - before) / before * 1000) / 1000
        }
        return result
    }

    // MARK: Pieces

    /// The bucket every tail row folds into.
    public static let otherKey = "other"

    /// The `byProject` row for frames the describer named no project on (#70). Explicit rather
    /// than dropped, so the table's shares still account for the whole day.
    public static let unattributedProjectKey = "unattributed"

    static func seconds(_ block: ActivityBlock) -> Double {
        max(0, block.endAt.timeIntervalSince(block.startAt))
    }

    /// Calendar blocks with everything from `now` on cut away, and every other block as it was.
    ///
    /// #19 writes the whole day's meetings at sync time, so at 10:00 the afternoon's calls are
    /// already rows. Only the part of a calendar block before `now` has happened: one still
    /// running counts up to `now`, and one that has not started drops out. A past day's blocks
    /// all end before `now`, so this only ever changes today. Screen and Granola blocks are
    /// written after the fact and never reach past `now`.
    public static func clippedToNow(_ blocks: [ActivityBlock], now: Date?) -> [ActivityBlock] {
        guard let now else { return blocks }
        return blocks.compactMap { block in
            guard block.source == .calendar, block.endAt > now else { return block }
            guard block.startAt < now else { return nil }
            var clipped = block
            clipped.endAt = now
            return clipped
        }
    }

    /// Wall-clock seconds these blocks cover between them, counting overlapping stretches once.
    static func unionSeconds(_ blocks: [ActivityBlock]) -> Double {
        totalSeconds(union(blocks.map { Stretch(start: $0.startAt, end: $0.endAt) }))
    }

    // MARK: Exact per-app time (#46)

    /// A half-open stretch of wall clock. `foreground_sessions` and `activity_blocks` have to be
    /// intersected with each other, and only one of them is an `ActivityBlock`.
    struct Stretch: Equatable {
        var start: Date
        var end: Date
        var seconds: Double { max(0, end.timeIntervalSince(start)) }
    }

    /// Overlapping stretches merged into disjoint ones, in order.
    static func union(_ stretches: [Stretch]) -> [Stretch] {
        let sorted = stretches.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [Stretch] = []
        for stretch in sorted {
            if var last = merged.last, stretch.start <= last.end {
                last.end = max(last.end, stretch.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(stretch)
            }
        }
        return merged
    }

    /// The parts both sides cover. Both arguments must already be unions.
    static func intersect(_ left: [Stretch], _ right: [Stretch]) -> [Stretch] {
        var result: [Stretch] = []
        var i = 0, j = 0
        while i < left.count, j < right.count {
            let start = max(left[i].start, right[j].start)
            let end = min(left[i].end, right[j].end)
            if end > start { result.append(Stretch(start: start, end: end)) }
            if left[i].end < right[j].end { i += 1 } else { j += 1 }
        }
        return result
    }

    static func totalSeconds(_ stretches: [Stretch]) -> Double {
        stretches.reduce(0.0) { $0 + $1.seconds }
    }

    /// Per-app-key seconds, exact wherever the day has foreground sessions.
    ///
    /// The problem this solves: an activation event names a *process*, and the app taxonomy is
    /// finer than that. A Chrome session cannot tell `gmail` from `gsheets`; the frames can, but
    /// only to the nearest tick. So each half supplies what it actually knows —
    ///
    /// - **the total per bundle** comes from the sessions: their union, intersected with the
    ///   day's active blocks so idle, lock and meeting handling stay exactly as they were;
    /// - **the split inside a bundle** comes from the blocks: each screen block is attributed to
    ///   the bundle most of its captures were in, and the bundle's exact total is handed to its
    ///   keys in proportion to their block seconds.
    ///
    /// Xcode, one key, simply gets its exact total. Chrome's is divided between `gmail`,
    /// `gsheets` and the rest in the ratio the frames observed. A bundle with no sessions — a day
    /// before the migration, a stretch with the recorder stopped — keeps its block seconds
    /// untouched, so nothing regresses on old data.
    ///
    /// #61: sessions are exact where they exist and silent where they do not — block seconds
    /// outside session coverage are never rescaled. Only the part of a block the recorder actually
    /// saw enters the redistribution, so a day whose sessions cover an hour cannot shrink twelve
    /// hours of blocks to that hour.
    static func exactAppSeconds(
        screenActive: [ActivityBlock],
        weights: [CaptureWeight],
        sessions: [ForegroundSession],
        activeBlocks: [ActivityBlock]
    ) -> (perKey: [String: Double], coveredSeconds: Double) {
        var perKey: [String: Double] = [:]
        for block in screenActive { perKey[block.appKey, default: 0] += seconds(block) }
        guard !sessions.isEmpty else { return (perKey, 0) }

        let activeUnion = union(activeBlocks.map { Stretch(start: $0.startAt, end: $0.endAt) })
        // An open interval has no end yet; the intersection with the day's blocks is what bounds
        // it, so it may not be given an arbitrary one here.
        let asStretch: (ForegroundSession) -> Stretch = {
            Stretch(start: $0.startAt, end: $0.endAt ?? .distantFuture)
        }
        let sessionUnion = union(sessions.map(asStretch))
        let covered = intersect(sessionUnion, activeUnion)

        // Which bundle each block belongs to: the commonest one among the captures the weights
        // assigned to it. Ties break on the bundle id, so the same day always sums the same way.
        var bundleOfBlock: [String: String] = [:]
        var votes: [String: [String: Int]] = [:]
        for weight in weights {
            guard let bundle = weight.capture.appBundleId else { continue }
            votes[weight.block.id, default: [:]][bundle, default: 0] += 1
        }
        for (blockID, tally) in votes {
            bundleOfBlock[blockID] = tally
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .first?.key
        }

        // Only the covered part of a block is redistributable (#61). The rest is time no session
        // has an opinion about, so it keeps the seconds the blocks measured.
        var keySecondsByBundle: [String: [String: Double]] = [:]
        for block in screenActive {
            guard let bundle = bundleOfBlock[block.id] else { continue }
            let inside = coveredSeconds(of: block, within: sessionUnion)
            guard inside > 0 else { continue }
            keySecondsByBundle[bundle, default: [:]][block.appKey, default: 0] += inside
        }

        var sessionsByBundle: [String: [Stretch]] = [:]
        for session in sessions {
            guard let bundle = session.appBundleId else { continue }
            sessionsByBundle[bundle, default: []].append(asStretch(session))
        }

        for (bundle, keySeconds) in keySecondsByBundle {
            guard let stretches = sessionsByBundle[bundle] else { continue }
            let coveredTotal = keySeconds.values.reduce(0, +)
            guard coveredTotal > 0 else { continue }
            let exact = totalSeconds(intersect(union(stretches), activeUnion))
            for (key, blockSeconds) in keySeconds {
                perKey[key, default: 0] -= blockSeconds
                perKey[key, default: 0] += exact * (blockSeconds / coveredTotal)
            }
        }
        return (perKey.filter { $0.value > 0 }, totalSeconds(covered))
    }

    /// How many of a block's seconds the session union covers.
    static func coveredSeconds(of block: ActivityBlock, within sessionUnion: [Stretch]) -> Double {
        totalSeconds(intersect([Stretch(start: block.startAt, end: block.endAt)], sessionUnion))
    }

    /// What the context sources contributed to the day (#19): its meetings, deduplicated the same
    /// way the timeline deduplicates them, so the report and the timeline agree on the count.
    static func meetingsCount(_ events: [ContextEvent]) -> Int {
        ContextBlocks.deduplicate(events.filter(\.isMeeting)).count
    }

    static func minutes(_ seconds: Double) -> Int { Int((seconds / 60).rounded()) }

    struct CaptureWeight {
        let capture: Capture
        /// The share of its block's duration this capture stands for.
        let seconds: Double
        let block: ActivityBlock
    }

    /// Attributes each capture the slice of its block it accounts for. Captures outside every block
    /// carry no minutes, so they cannot inflate a total.
    static func captureWeights(blocks: [ActivityBlock], captures: [Capture]) -> [CaptureWeight] {
        guard !captures.isEmpty else { return [] }
        var perBlock: [String: [Capture]] = [:]
        var blocksByID: [String: ActivityBlock] = [:]
        for block in blocks { blocksByID[block.id] = block }

        for capture in captures {
            // A capture can sit inside a screen block and a meeting block at once; the screen block
            // is the one whose minutes it represents.
            let containing = blocks.filter { $0.startAt <= capture.capturedAt && capture.capturedAt < $0.endAt }
            guard let owner = containing.first(where: { $0.source == .screen }) ?? containing.first else { continue }
            perBlock[owner.id, default: []].append(capture)
        }

        return perBlock.flatMap { blockID, captures -> [CaptureWeight] in
            guard let block = blocksByID[blockID] else { return [] }
            let share = seconds(block) / Double(captures.count)
            return captures.map { CaptureWeight(capture: $0, seconds: share, block: block) }
        }
    }

    /// Time per project (#70), from the `project_hint` the describer answered on each frame.
    ///
    /// The minutes come from the frames the way `byHost`'s do, over screen-active blocks only so
    /// the shares share `byTask`'s denominator. `ProjectNames` decides which hints are projects
    /// and what to call them; everything it rejects — no hint, an empty one, the app's own name —
    /// lands in one explicit `unattributed` row rather than vanishing, so the table cannot imply
    /// the day was more accounted for than it was. A day with no hints at all gets no rows, and
    /// so no table.
    /// The project each on-screen frame was about, cleaned up and folded onto the canonical list.
    ///
    /// Resolved once per day and shared: `byProject` weighs it by frame minutes, `threads` (#91)
    /// reads the same answers a block at a time, and two tables disagreeing about which project
    /// a frame belonged to would be a bug the reader could see.
    static func namedProjects(
        weights onScreen: [CaptureWeight], hints: [String: String], keys: [String: String] = [:],
        projects: [ProjectEntry]
    ) -> [String: ProjectNames.Project] {
        guard !onScreen.isEmpty, !hints.isEmpty || !keys.isEmpty else { return [:] }
        return ProjectNames.resolve(
            Dictionary(
                onScreen.map { weight in
                    (weight.capture.id, ProjectNames.Observation(
                        hint: hints[weight.capture.id],
                        appName: weight.capture.appName,
                        windowTitle: weight.capture.windowTitle,
                        projectKey: keys[weight.capture.id]
                    ))
                },
                uniquingKeysWith: { first, _ in first }
            ),
            projects: projects
        )
    }

    ///
    /// #318: each meeting's share of the day's meeting union lands on its company's row as
    /// `meetingMinutes`, or on `unattributed` under the reason no company was named. A company
    /// with meetings and no frames still gets a row, at `minutes: 0`. Rows rank by screen and
    /// meeting minutes together; `minutes` and `share` stay screen-only.
    static func projectSlices(
        weights onScreen: [CaptureWeight], named: [String: ProjectNames.Project], total: Double,
        meetings: [MeetingShare] = []
    ) -> [Slice] {
        var entries: [Entry] = []
        var unattributedSeconds = 0.0
        /// project key → app key → seconds, for the apps named inside each row.
        var appSeconds: [String: [String: Double]] = [:]
        // A day with meetings counts its unnamed screen time too, so `unattributed` never says 0.
        if !onScreen.isEmpty, !named.isEmpty || !meetings.isEmpty {
            for weight in onScreen {
                if let project = named[weight.capture.id] {
                    entries.append(Entry(key: project.key, name: project.name, seconds: weight.seconds))
                    appSeconds[project.key, default: [:]][weight.block.appKey, default: 0] += weight.seconds
                } else {
                    unattributedSeconds += weight.seconds
                }
            }
        }
        var unattributedMeetings: [String: Double] = [:]
        for meeting in meetings {
            if let key = meeting.company.key {
                entries.append(Entry(
                    key: key, name: meeting.company.name ?? key, seconds: 0,
                    meetingSeconds: [meeting.company.rule.rawValue: meeting.seconds]
                ))
            } else {
                unattributedMeetings[meeting.company.rule.rawValue, default: 0] += meeting.seconds
            }
        }
        guard !entries.isEmpty || unattributedSeconds > 0 || !unattributedMeetings.isEmpty else { return [] }

        var result = slices(entries, limit: projectLimit, total: total).map { slice in
            var slice = slice
            slice.parts = topApps(appSeconds[slice.key] ?? [:])
            return slice
        }
        var unattributed = Slice(
            key: unattributedProjectKey,
            name: unattributedProjectKey,
            minutes: minutes(unattributedSeconds),
            share: share(unattributedSeconds, of: total)
        )
        unattributed.setMeetings(secondsByRule: unattributedMeetings)
        if unattributedSeconds > 0 || unattributed.meetingMinutes != nil {
            // Appended rather than ranked, so it is never the row "other" swallows.
            result.append(unattributed)
        }
        return result
    }

    /// `byProject` from the day's spans (#322). Seconds are summed per project before rounding.
    /// `minutes` is screen time and `meetingMinutes` meeting time, split in `meetingRules` by the
    /// #318 rule that named the company (`owner` for a rule you wrote); `share` is the row's
    /// screen and meeting seconds over the covered seconds, so the rows, `unattributed` included,
    /// add up to the day. `unattributed` splits its screen minutes by reason in `parts` and its
    /// meeting minutes in `meetingRules`: #318's `several_companies` or `no_company_domain` for
    /// the seconds a synced meeting with no company covers, `meeting_without_company` for meeting
    /// time no synced meeting covers, or `conflict`. A day no span names a project on gets no rows.
    static func spanSlices(
        _ spans: [ProjectSpan], screenBlocks: [ActivityBlock], meetings: [MeetingShare] = []
    ) -> [Slice] {
        guard spans.contains(where: { $0.project != nil }) else { return [] }
        let covered = spans.reduce(0.0) { $0 + $1.seconds }
        // #318's rules, per company key (nil: no company), to split a meeting span's seconds by.
        var meetingRules: [String?: [String: Double]] = [:]
        for meeting in meetings {
            meetingRules[meeting.company.key, default: [:]][meeting.company.rule.rawValue, default: 0] += meeting.seconds
        }
        func split(_ seconds: Double, key: String?, fallback: String) -> [String: Double] {
            guard let rules = meetingRules[key], case let total = rules.values.reduce(0, +), total > 0
            else { return [fallback: seconds] }
            return rules.mapValues { seconds * $0 / total }
        }

        var entries: [Entry] = []
        var rowSeconds: [String: Double] = [:]
        var unattributedScreen: [String: Double] = [:]
        var unattributedMeetings: [String: Double] = [:]
        var appSeconds: [String: [String: Double]] = [:]
        let blocks = screenBlocks.sorted { $0.startAt < $1.startAt }
        for span in spans {
            switch (span.kind, span.project) {
            case (.screen, let key?):
                entries.append(Entry(key: key, name: span.name ?? key, seconds: span.seconds))
                rowSeconds[key, default: 0] += span.seconds
                for block in blocks where block.endAt > span.start {
                    if block.startAt >= span.end { break }
                    let overlap = min(block.endAt, span.end).timeIntervalSince(max(block.startAt, span.start))
                    if overlap > 0 { appSeconds[key, default: [:]][block.appKey, default: 0] += overlap }
                }
            case (.meeting, let key?):
                var bySource: [String: Double] = [:]
                for (rule, seconds) in span.secondsByRule {
                    let decided = rule == ProjectSpan.Rule.meetingCompany.rawValue
                        ? split(seconds, key: key, fallback: rule) : [rule: seconds]
                    bySource.merge(decided, uniquingKeysWith: +)
                }
                entries.append(Entry(key: key, name: span.name ?? key, seconds: 0, meetingSeconds: bySource))
                rowSeconds[key, default: 0] += span.seconds
            case (.screen, nil):
                unattributedScreen[(span.unattributed ?? .noEvidence).rawValue, default: 0] += span.seconds
            case (.meeting, nil):
                let reason = span.unattributed ?? .meetingWithoutCompany
                let rules = reason == .meetingWithoutCompany
                    ? splitUnnamed(span, among: meetings) : [reason.rawValue: span.seconds]
                unattributedMeetings.merge(rules, uniquingKeysWith: +)
            }
        }
        let kept = slices(entries, limit: projectLimit, total: covered)
        let keptKeys = Set(kept.map(\.key))
        let otherSeconds = rowSeconds.filter { !keptKeys.contains($0.key) }.values.reduce(0, +)
        var result = kept.map { slice in
            var slice = slice
            slice.parts = topApps(appSeconds[slice.key] ?? [:])
            slice.share = share(slice.key == otherKey ? otherSeconds : rowSeconds[slice.key] ?? 0, of: covered)
            return slice
        }
        let screenSeconds = unattributedScreen.values.reduce(0, +)
        let meetingSeconds = unattributedMeetings.values.reduce(0, +)
        var unattributed = Slice(
            key: unattributedProjectKey, name: unattributedProjectKey,
            minutes: minutes(screenSeconds), share: share(screenSeconds + meetingSeconds, of: covered)
        )
        let reasons = unattributedScreen
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { Slice(key: $0.key, name: $0.key, minutes: minutes($0.value), share: share($0.value, of: screenSeconds)) }
            .filter { $0.minutes > 0 }
        unattributed.parts = reasons.isEmpty ? nil : reasons
        unattributed.setMeetings(secondsByRule: unattributedMeetings)
        // Appended rather than ranked, so it is never the row "other" swallows.
        if unattributed.minutes > 0 || unattributed.meetingMinutes != nil { result.append(unattributed) }
        return result
    }

    /// A company-less meeting span's seconds by why: the part synced meetings with no company
    /// cover goes to their #318 rules, in proportion to how much of the span each covers, and the
    /// rest, meeting time on screen with no synced event, to `meeting_without_company`.
    static func splitUnnamed(_ span: ProjectSpan, among meetings: [MeetingShare]) -> [String: Double] {
        let whole = Stretch(start: span.start, end: span.end)
        let unnamed = meetings.filter { $0.company.key == nil }
        var byRule: [String: Double] = [:]
        for meeting in unnamed {
            guard let stretch = meeting.stretch else { continue }
            let seconds = totalSeconds(intersect([whole], [stretch]))
            if seconds > 0 { byRule[meeting.company.rule.rawValue, default: 0] += seconds }
        }
        let covered = min(span.seconds, totalSeconds(intersect([whole], union(unnamed.compactMap(\.stretch)))))
        let raw = byRule.values.reduce(0, +)
        var result = raw > 0 ? byRule.mapValues { covered * $0 / raw } : [:]
        let rest = span.seconds - (raw > 0 ? covered : 0)
        if rest > 0 { result[ProjectSpan.Reason.meetingWithoutCompany.rawValue, default: 0] += rest }
        return result
    }

    /// Block id → the project the spans put most of the block under (#322), the same answer the
    /// timeline heading reads through `ProjectSpans.project(from:to:in:)`.
    static func spanProjects(_ blocks: [ActivityBlock], spans: [ProjectSpan]) -> [String: ThreadIdentity] {
        var result: [String: ThreadIdentity] = [:]
        for block in blocks where !isInactive(block) {
            if let project = ProjectSpans.project(from: block.startAt, to: block.endAt, in: spans) {
                result[block.id] = ThreadIdentity(key: project.key, label: project.name)
            }
        }
        return result
    }

    /// One meeting's part of the day's meeting time, and the company it counts toward (#318).
    struct MeetingShare: Equatable {
        var company: MeetingCompany
        var seconds: Double
        /// The meeting, cut to the day and to `now`.
        var stretch: Stretch? = nil
    }

    /// The day's meetings, joined the way the timeline joins them, each with the stretch of the
    /// day only it covers: earliest first, a meeting keeps what no earlier one already had, so
    /// a double booking is counted once and the shares add up to the union. Cut to the day and
    /// to `now`, like the calendar blocks.
    static func meetingShares(
        _ events: [ContextEvent], projects: [ProjectEntry], ignoredDomains: [String],
        day: String, timeZone: TimeZone, now: Date?
    ) -> [MeetingShare] {
        let meetings = ContextBlocks.deduplicate(events.filter(\.isMeeting))
        guard !meetings.isEmpty, let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return [] }
        let answers = MeetingAttribution.resolve(events, catalog: projects, ignoredDomains: ignoredDomains)
        var covered: [Stretch] = []
        var shares: [MeetingShare] = []
        for meeting in meetings {
            let start = max(meeting.startAt, range.start)
            let end = min(meeting.effectiveEndAt, range.end, now ?? range.end)
            guard end > start else { continue }
            let stretch = Stretch(start: start, end: end)
            let fresh = stretch.seconds - totalSeconds(intersect([stretch], union(covered)))
            covered.append(stretch)
            guard fresh > 0, let company = answers[meeting.id] else { continue }
            shares.append(MeetingShare(company: company, seconds: fresh, stretch: stretch))
        }
        return shares
    }

    // MARK: Threads (#91)

    /// One block's thread identity, or nil when nothing on screen said what it was about.
    struct ThreadIdentity: Equatable {
        let key: String
        let label: String
    }

    /// What a block was about: the project its frames named, else the app plus the document they
    /// named, else nothing.
    ///
    /// A block gets one identity, the heaviest of its frames', rather than a share of several —
    /// a run of blocks is either on the thread or it is not. That is also why these minutes are
    /// block minutes and can differ by a minute or two from the frame-weighted `byProject` row.
    static func threadIdentity(
        _ block: ActivityBlock,
        weights: [CaptureWeight],
        named: [String: ProjectNames.Project],
        documents: [String: String]
    ) -> ThreadIdentity? {
        var projectSeconds: [ProjectNames.Project: Double] = [:]
        var documentSeconds: [String: Double] = [:]
        /// Folded document key → the spelling to show.
        var documentLabels: [String: String] = [:]
        for weight in weights {
            if let project = named[weight.capture.id] {
                projectSeconds[project, default: 0] += weight.seconds
            } else if let document = documents[weight.capture.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !document.isEmpty {
                let key = document.lowercased()
                documentSeconds[key, default: 0] += weight.seconds
                // Captures reach here in dictionary order, so the spelling is chosen by a rule
                // rather than by whichever frame happened to come first.
                documentLabels[key] = min(documentLabels[key] ?? document, document)
            }
        }
        // A project always beats a document: the document is the fallback for frames no project
        // was named on, not a competitor to one. Ties break on the key, so the same day always
        // resolves the same way whatever order the dictionary happened to enumerate in.
        if let best = projectSeconds.max(by: { left, right in
            left.value == right.value ? left.key.key > right.key.key : left.value < right.value
        }) {
            return ThreadIdentity(key: best.key.key, label: best.key.name)
        }
        guard let best = documentSeconds.max(by: { left, right in
            left.value == right.value ? left.key > right.key : left.value < right.value
        }) else { return nil }
        let app = weights.compactMap(\.capture.appName).min() ?? block.appKey
        return ThreadIdentity(
            key: "\(block.appKey)/\(best.key)",
            label: "\(app): \(documentLabels[best.key] ?? best.key)"
        )
    }

    /// One thread's visits, kept whole: the maximal runs of consecutive blocks that share a
    /// thread identity, in visit order.
    ///
    /// `threads` is a fold over it, keeping only the *median* gap between visits.
    struct ThreadVisits {
        var key: String
        var label: String
        /// The runs of blocks, in visit order. Never empty, and no run inside it is empty.
        var visits: [[ActivityBlock]]

        /// The wall-clock minutes between one visit ending and the next beginning — the numbers
        /// `ThreadStat.medianGapMinutes` is the median of.
        var gapMinutes: [Double] {
            zip(visits, visits.dropFirst()).compactMap { previous, next in
                guard let end = previous.last?.endAt, let start = next.first?.startAt else { return nil }
                return max(0, start.timeIntervalSince(end)) / 60
            }
        }
    }

    /// The day's threads as runs of blocks. `sequence` is what `threads` documents below.
    static func threadVisits(
        _ sequence: [ActivityBlock],
        weights: [CaptureWeight],
        named: [String: ProjectNames.Project],
        documents: [String: String],
        /// #322: block id → the project the spans put most of the block under. A block it does
        /// not name falls back to its document.
        spanProjects: [String: ThreadIdentity]? = nil
    ) -> [ThreadVisits] {
        guard !sequence.isEmpty, !named.isEmpty || !documents.isEmpty || !(spanProjects ?? [:]).isEmpty
        else { return [] }
        var weightsByBlock: [String: [CaptureWeight]] = [:]
        for weight in weights { weightsByBlock[weight.block.id, default: []].append(weight) }

        /// Consecutive blocks on one thread. Runs are collected in time order, so a thread's
        /// runs come out in visit order.
        struct Run {
            var identity: ThreadIdentity
            var blocks: [ActivityBlock]
        }
        var runs: [Run] = []
        var current: Run?
        for block in sequence {
            let identity = isInactive(block)
                ? nil
                : spanProjects?[block.id] ?? threadIdentity(
                    block, weights: weightsByBlock[block.id] ?? [], named: named, documents: documents
                )
            // Idle, or time nothing could be said about: whatever was running stops here, and the
            // next block on that thread is a return to it.
            guard let identity else {
                if let run = current { runs.append(run) }
                current = nil
                continue
            }
            if current?.identity == identity {
                current?.blocks.append(block)
            } else {
                if let run = current { runs.append(run) }
                current = Run(identity: identity, blocks: [block])
            }
        }
        if let run = current { runs.append(run) }

        var byKey: [String: [Run]] = [:]
        var order: [String] = []
        for run in runs {
            if byKey[run.identity.key] == nil { order.append(run.identity.key) }
            byKey[run.identity.key, default: []].append(run)
        }
        return order.compactMap { key in
            // Every run holds at least one block, so a thread always has a first visit.
            guard let runs = byKey[key], let first = runs.first else { return nil }
            return ThreadVisits(
                key: key,
                label: first.identity.label,
                visits: runs.map(\.blocks)
            )
        }
    }

    /// The day's threads, longest first (#91).
    ///
    /// `sequence` must be the day's screen blocks in time order, **idle ones included**: a thread
    /// is the run of consecutive blocks sharing one identity, and anything else — another thread,
    /// an idle stretch, a block nothing could be said about — ends the run and makes the next
    /// block on the thread a re-entry. This is the opposite convention to `switchPairs`, which
    /// drops idle first so that stepping away is not counted as churn; here stepping away and
    /// coming back is exactly the thing being counted. It does mean a two-minute idle blip splits
    /// a run, which is what `medianGapMinutes` is for: six visits three minutes apart is a thread
    /// never really put down, and the prompt says so in as many words.
    ///
    /// Meeting blocks are left out because they sit *on top of* the screen blocks they contain;
    /// counting them would break every thread that ran through a call.
    static func threads(
        _ sequence: [ActivityBlock],
        weights: [CaptureWeight],
        named: [String: ProjectNames.Project],
        documents: [String: String],
        spanProjects: [String: ThreadIdentity]? = nil
    ) -> [ThreadStat] {
        let stats: [ThreadStat] = threadVisits(
            sequence, weights: weights, named: named, documents: documents, spanProjects: spanProjects
        ).compactMap { thread in
            let blocks = thread.visits.flatMap { $0 }
            guard let firstAt = blocks.map(\.startAt).min(), let lastAt = blocks.map(\.endAt).max()
            else { return nil }
            return ThreadStat(
                key: thread.key,
                project: thread.label,
                visits: thread.visits.count,
                reentries: thread.visits.count - 1,
                longestRunMinutes: thread.visits.map { minutes(unionSeconds($0)) }.max() ?? 0,
                totalMinutes: minutes(unionSeconds(blocks)),
                firstAt: firstAt,
                lastAt: lastAt,
                medianGapMinutes: round(median(thread.gapMinutes) * 10) / 10
            )
        }
        return stats
            .sorted { $0.totalMinutes == $1.totalMinutes ? $0.key < $1.key : $0.totalMinutes > $1.totalMinutes }
            .prefix(threadLimit)
            .map { $0 }
    }

    // MARK: Weekly project ledger (#91)

    /// Project → day → minutes, merged from the days' `byProject` rows.
    ///
    /// Every row of every day is kept, `other` and `unattributed` included, so a day's column
    /// adds up to exactly what that day's own table said. Rows are ordered by the week's total.
    static func projectLedger(_ days: [DailyStats]) -> [ProjectLedgerRow] {
        var perDay: [String: [String: Int]] = [:]
        /// key → spelling → minutes behind it, so a week shows the spelling it spent most time on.
        var spellings: [String: [String: Int]] = [:]
        for day in days {
            for slice in day.byProject where slice.minutes > 0 {
                perDay[slice.key, default: [:]][day.day, default: 0] += slice.minutes
                spellings[slice.key, default: [:]][slice.name, default: 0] += slice.minutes
            }
        }
        return perDay.map { key, minutes in
            let name = spellings[key]?
                .max { left, right in left.value == right.value ? left.key > right.key : left.value < right.value }?
                .key ?? key
            return ProjectLedgerRow(
                key: key,
                name: name,
                minutesPerDay: minutes,
                totalMinutes: minutes.values.reduce(0, +),
                daysSeen: minutes.count
            )
        }
        .sorted { $0.totalMinutes == $1.totalMinutes ? $0.key < $1.key : $0.totalMinutes > $1.totalMinutes }
    }

    /// The apps one project's time was spent in, longest first, at most `projectAppLimit` of them.
    /// Shares are of the project rather than of the day: the row already carries the day's share,
    /// and "70 % of this project was Claude Desktop" is the thing the sub-row can say.
    static func topApps(_ seconds: [String: Double]) -> [Slice]? {
        guard !seconds.isEmpty else { return nil }
        let total = seconds.values.reduce(0, +)
        let rows = seconds
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(projectAppLimit)
            .map { Slice(key: $0.key, name: $0.key, minutes: minutes($0.value), share: share($0.value, of: total)) }
            .filter { $0.minutes > 0 }
        return rows.isEmpty ? nil : rows
    }

    /// Meeting time is whole meeting blocks, plus any screen time whose frames were flagged as a
    /// meeting but which the timeline did not label as one.
    static func meetingSeconds(blocks: [ActivityBlock], weights: [CaptureWeight]) -> Double {
        let labelled = blocks.filter { isMeeting($0) && !isInactive($0) }
        let labelledIDs = Set(labelled.map(\.id))
        // Union again: a Granola note and a calendar entry for the same call both become blocks.
        let fromBlocks = unionSeconds(labelled)
        let fromFrames = weights
            .filter { $0.capture.isMeeting && !labelledIDs.contains($0.block.id) && !isInactive($0.block) }
            .reduce(0.0) { $0 + $1.seconds }
        return fromBlocks + fromFrames
    }

    /// One thing that took time, before it is grouped: an app, a category, a task or a host.
    struct Entry {
        var key: String
        var name: String
        var seconds: Double
        /// #318: meeting seconds by rule, on a `byProject` entry only. They rank the entry but
        /// never enter `minutes` or `share`.
        var meetingSeconds: [String: Double] = [:]

        var rankSeconds: Double { seconds + meetingSeconds.values.reduce(0, +) }
    }

    /// Groups, sorts by minutes, keeps `limit` rows and folds the rest into "other".
    static func slices(_ entries: [Entry], limit: Int, total: Double) -> [Slice] {
        guard !entries.isEmpty else { return [] }
        var totals: [String: Entry] = [:]
        for entry in entries {
            if var existing = totals[entry.key] {
                existing.seconds += entry.seconds
                existing.meetingSeconds.merge(entry.meetingSeconds, uniquingKeysWith: +)
                totals[entry.key] = existing
            } else {
                totals[entry.key] = entry
            }
        }
        // Ties are broken by key so the output is stable run to run.
        let sorted: [Entry] = totals.values
            .sorted { $0.rankSeconds == $1.rankSeconds ? $0.key < $1.key : $0.rankSeconds > $1.rankSeconds }

        func slice(_ entry: Entry) -> Slice {
            var slice = Slice(
                key: entry.key, name: entry.name,
                minutes: minutes(entry.seconds), share: share(entry.seconds, of: total)
            )
            if !entry.meetingSeconds.isEmpty { slice.setMeetings(secondsByRule: entry.meetingSeconds) }
            return slice
        }
        var kept: [Slice] = sorted.prefix(limit).map(slice)
        let tail = sorted.dropFirst(limit)
        if !tail.isEmpty {
            var other = Entry(key: otherKey, name: "other (\(tail.count) more)", seconds: 0)
            for entry in tail {
                other.seconds += entry.seconds
                other.meetingSeconds.merge(entry.meetingSeconds, uniquingKeysWith: +)
            }
            kept.append(slice(other))
        }
        return kept.filter { $0.minutes > 0 || $0.share > 0 || $0.meetingMinutes != nil }
    }

    static func share(_ part: Double, of total: Double) -> Double {
        guard total > 0 else { return 0 }
        return round(part / total * 1000) / 1000
    }

    /// `byProject` rows re-shared over the minutes they all cover, screen and meeting (#322), as
    /// a day's rows from its spans are.
    static func coveredShares(_ rows: [Slice]) -> [Slice] {
        let total = rows.reduce(0) { $0 + $1.minutes + ($1.meetingMinutes ?? 0) }
        return rows.map { row in
            var row = row
            row.share = share(Double(row.minutes + (row.meetingMinutes ?? 0)), of: Double(total))
            return row
        }
    }

    /// Re-groups per-day slices into one week-level breakdown. "other" rows stay "other".
    static func merge(_ slicesPerDay: [[Slice]], limit: Int, total: Int) -> [Slice] {
        let entries: [Entry] = slicesPerDay.flatMap { $0 }.map { slice in
            Entry(
                key: slice.key,
                name: slice.key == otherKey ? "other" : slice.name,
                seconds: Double(slice.minutes) * 60,
                meetingSeconds: (slice.meetingRules ?? [:]).mapValues { Double($0) * 60 }
            )
        }
        return slices(entries, limit: limit, total: Double(total) * 60)
    }

    static func mergePairs(_ pairsPerDay: [[SwitchPair]], limit: Int) -> [SwitchPair] {
        var counts: [String: SwitchPair] = [:]
        for pair in pairsPerDay.flatMap({ $0 }) {
            let key = "\(pair.from)→\(pair.to)"
            counts[key] = SwitchPair(from: pair.from, to: pair.to, count: (counts[key]?.count ?? 0) + pair.count)
        }
        return counts.values
            .sorted { $0.count == $1.count ? "\($0.from)\($0.to)" < "\($1.from)\($1.to)" : $0.count > $1.count }
            .prefix(limit)
            .map { $0 }
    }

    /// Adjacent app changes among active blocks. Idle blocks are removed first, so stepping away
    /// and coming back to the same app is not a switch.
    static func switchPairs(_ active: [ActivityBlock]) -> [SwitchPair] {
        guard active.count > 1 else { return [] }
        var counts: [String: SwitchPair] = [:]
        for (previous, next) in zip(active, active.dropFirst()) where previous.appKey != next.appKey {
            let key = "\(previous.appKey)→\(next.appKey)"
            counts[key] = SwitchPair(from: previous.appKey, to: next.appKey, count: (counts[key]?.count ?? 0) + 1)
        }
        return counts.values
            .sorted { $0.count == $1.count ? "\($0.from)\($0.to)" < "\($1.from)\($1.to)" : $0.count > $1.count }
    }

    static func longestFocus(_ active: [ActivityBlock]) -> FocusBlock? {
        guard let longest = active.max(by: { seconds($0) < seconds($1) }),
              seconds(longest) >= focusMinimumMinutes * 60
        else { return nil }
        return FocusBlock(
            start: longest.startAt,
            end: longest.endAt,
            minutes: minutes(seconds(longest)),
            appKey: longest.appKey,
            taskKey: longest.taskKey,
            title: longest.title
        )
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        let value = sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
        return round(value * 10) / 10
    }

    /// Splits every block across the local hours it spans, proportionally to the time in each.
    static func hourly(_ active: [ActivityBlock], timeZone: TimeZone) -> [HourBucket] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var perHour = [[String: Double]](repeating: [:], count: 24)
        for block in active {
            var cursor = block.startAt
            while cursor < block.endAt {
                let hour = calendar.component(.hour, from: cursor)
                let nextHour = calendar.nextDate(
                    after: cursor,
                    matching: DateComponents(minute: 0, second: 0),
                    matchingPolicy: .nextTime
                ) ?? block.endAt
                let sliceEnd = min(nextHour, block.endAt)
                let slice = sliceEnd.timeIntervalSince(cursor)
                guard slice > 0 else { break }
                perHour[hour][block.appKey, default: 0] += slice
                cursor = sliceEnd
            }
        }

        return (0..<24).map { hour in
            let apps = perHour[hour]
            let dominant = apps
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .first?.key
            let total = apps.values.reduce(0, +)
            return HourBucket(hour: hour, activeMinutes: minutes(total), dominantApp: total > 0 ? dominant : nil)
        }
    }

    static func emptyHourly() -> [HourBucket] {
        (0..<24).map { HourBucket(hour: $0, activeMinutes: 0, dominantApp: nil) }
    }
}
