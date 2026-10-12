import Foundation

/// Keeps `activity_blocks` in step with the descriptions, and renders a day's markdown on demand.
///
/// A day is always rebuilt from scratch rather than patched: at ~1000 frames it costs
/// milliseconds, and it means a crash, a re-describe or a late inherited frame can never leave
/// the blocks disagreeing with the frames. Blocks from context sources (#19: calendar, Granola)
/// are rebuilt the same way, from `context_events` — the screen is only one of the day's
/// witnesses, and the two halves of a day are always redrawn together.
public actor TimelineWriter {
    /// Frames arrive one a minute; a nudge per frame should not mean a rebuild per frame.
    public static let debounce: TimeInterval = 5
    /// Blocks join across at least this much silence, whatever the capture interval.
    public static let minimumGapTolerance: TimeInterval = 180

    private let config: Config
    private let taxonomy: TaxonomyStore
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date

    private let blocks: ActivityBlockStore
    private let queries: TimelineQueries
    /// #19: meetings and messages the context sources synced.
    private let contextEvents: ContextEventStore
    /// #51: the day's exact foreground intervals, so a block can begin at the switch rather than
    /// at the frame after it.
    private let sessions: ForegroundSessionStore
    /// #146: when Worklens was not watching, for the footer.
    private let coverage: CoverageEventStore
    /// #314: what you shipped, for `## Shipped`.
    private let outputs: OutputStore
    /// #322: which project each stretch went to, so a heading names the same one the stats do.
    private let projectSpans: ProjectSpanService

    private var pending: [String: Task<Void, Never>] = [:]

    public init(
        config: Config,
        db: Database,
        taxonomy: TaxonomyStore,
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.taxonomy = taxonomy
        self.timeZone = timeZone
        self.now = now
        blocks = ActivityBlockStore(db)
        queries = TimelineQueries(db)
        contextEvents = ContextEventStore(db)
        sessions = ForegroundSessionStore(db)
        coverage = CoverageEventStore(db)
        outputs = OutputStore(db)
        projectSpans = ProjectSpanService(
            db, timeZone: timeZone,
            projects: { taxonomy.current.projectList },
            ignoredDomains: { taxonomy.current.ignoredDomains ?? [] },
            now: now,
            baseIntervals: DayAccounting.BaseIntervals(config: config)
        )
    }

    public var gapTolerance: TimeInterval {
        max(Double(config.captureIntervalSeconds) * 3, TimelineWriter.minimumGapTolerance)
    }

    /// The tolerance between two frames that were both captured inside a meeting (#66). The
    /// scheduler stretches the interval to `MEETING_CAPTURE_INTERVAL_SECONDS` there, so the
    /// normal tolerance would cut a call into one block per frame.
    public var meetingGapTolerance: TimeInterval {
        max(Double(config.meetingCaptureIntervalSeconds) * 3, gapTolerance)
    }

    // MARK: - Scheduling

    /// Asks for a rebuild of `day` in 5 s. Repeated nudges inside that window collapse into one.
    public func nudge(day: String) {
        pending[day]?.cancel()
        pending[day] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(TimelineWriter.debounce * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.rebuildIgnoringErrors(day: day)
        }
    }

    /// Runs every debounced rebuild now instead of waiting the 5 s out — what a short-lived CLI
    /// process needs before it exits.
    public func flush() async {
        let days = Array(pending.keys)
        for task in pending.values { task.cancel() }
        pending.removeAll()
        for day in days { await rebuildIgnoringErrors(day: day) }
    }

    /// Today and yesterday, on launch: cheap, and it heals a rebuild that a crash cut short.
    public func rebuildRecentDays() async {
        let today = DayBoundaries.dayString(now(), timeZone: timeZone)
        let yesterday = DayBoundaries.dayString(
            now().addingTimeInterval(-24 * 3600), timeZone: timeZone
        )
        for day in Set([today, yesterday]).sorted() {
            await rebuildIgnoringErrors(day: day)
        }
    }

    private func rebuildIgnoringErrors(day: String) async {
        do {
            try rebuild(day: day)
        } catch {
            Log.describe.error("timeline rebuild for \(day) failed: \(error)")
        }
    }

    // MARK: - Rebuild

    /// Frames → blocks → replace the day's screen blocks → the day's markdown, which nothing
    /// writes to disk any more: MCP `timeline` and the CLI render it live.
    @discardableResult
    public func rebuild(day: String) throws -> String {
        let frames = try resolvedFrames(day: day)
        // A day with no sessions — before #46's migration, or with the recorder stopped — builds
        // byte for byte as it did before.
        let built = BlockBuilder.build(
            frames: frames,
            gapTolerance: gapTolerance,
            meetingGapTolerance: meetingGapTolerance,
            tickInterval: Double(config.captureIntervalSeconds),
            timeZone: timeZone,
            now: now(),
            sessions: (try? sessions.fetch(day: day, timeZone: timeZone)) ?? []
        )

        // Everything a block can say comes from a description, so a day with none can only
        // produce idle and redacted stubs. Replacing real blocks with those would destroy work
        // a rebuild cannot bring back — it means the describe stage has not run for this day
        // (or the rows were seeded without it), not that the day was empty.
        let described = frames.contains { $0.summary?.nonEmpty != nil }
        let stored = try blocks.fetch(day: day).filter { $0.source == .screen }
        if described || stored.isEmpty {
            try blocks.deleteScreenBlocks(day: day)
            for block in built { try blocks.upsert(block) }
        } else {
            Log.describe.warn(
                "\(day) has \(frames.count) frames but no descriptions; keeping the \(stored.count) blocks already stored"
            )
        }

        // #19: meetings the context sources know about become their own blocks. Rebuilt from
        // scratch like the screen ones, and only after them, so a meeting always sorts against
        // the current shape of the day.
        let events = (try? contextEvents.events(day: day, timeZone: timeZone)) ?? []
        try rebuildMeetingBlocks(day: day, events: events, frames: frames)

        let markdown = render(
            day: day, blocks: try blocks.fetch(day: day), frames: frames, contextEvents: events
        )
        Log.describe.info("rebuilt timeline for \(day): \(built.count) blocks")
        return markdown
    }

    /// The day's markdown as it would render right now, without writing anything.
    ///
    /// `nonisolated` because it reads only the immutable config and the Sendable stores, never the
    /// debounce table: #89's MCP `timeline` tool needs it from a synchronous context, and a caller
    /// that only wants to see a day should not have to wait behind a rebuild.
    public nonisolated func markdown(day: String) throws -> String {
        let read = try inputs(day: day)
        return render(
            day: day, blocks: read.blocks, frames: read.frames, contextEvents: read.events
        )
    }

    /// Everything the rendering needs, read once.
    private nonisolated func inputs(
        day: String
    ) throws -> (blocks: [ActivityBlock], frames: [TimelineFrame], events: [ContextEvent]) {
        (
            blocks: try blocks.fetch(day: day),
            frames: try resolvedFrames(day: day),
            events: (try? contextEvents.events(day: day, timeZone: timeZone)) ?? []
        )
    }

    /// Replaces the day's calendar/Granola blocks with what `context_events` currently says.
    ///
    /// Fetched by overlap rather than by start time: a call that began at 23:40 yesterday is part
    /// of today too, and a day that drops it would show an unexplained hole at midnight.
    ///
    /// `events` are the day's — #94's away blocks are built from the ones that are *not*
    /// meetings — and `frames` are the day's too: whether a lunch was spent away from the
    /// machine is a question about how quiet the screen was through it.
    private func rebuildMeetingBlocks(
        day: String, events: [ContextEvent], frames: [TimelineFrame]
    ) throws {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return }
        let overlapping = (try? contextEvents.meetings(overlapping: range.start, to: range.end)) ?? []
        let meetings = ContextBlocks.meetingBlocks(
            day: day, events: overlapping, timeZone: timeZone
        )
        let away = ContextBlocks.awayBlocks(
            day: day, events: events, frames: frames, timeZone: timeZone
        )
        try blocks.deleteBlocks(day: day, sources: [.calendar, .granola])
        for block in meetings + away { try blocks.upsert(block) }
    }

    // MARK: - Internals

    /// A redacted frame keeps its metadata but loses its content, so the app it belonged to comes
    /// from the taxonomy rather than from a description that was never requested.
    private nonisolated func resolvedFrames(day: String) throws -> [TimelineFrame] {
        try queries.frames(day: day, timeZone: timeZone).map { frame in
            guard frame.isRedacted, frame.appKey == nil else { return frame }
            let resolved = taxonomy.resolve(bundleID: frame.bundleID, url: frame.url)
            return TimelineFrame(
                captureId: frame.captureId,
                at: frame.at,
                appKey: resolved?.appKey ?? BlockBuilder.unknownAppKey,
                taskKey: BlockBuilder.redactedTaskKey,
                title: frame.title,
                summary: nil,
                document: frame.document,
                projectHint: frame.projectHint, projectKey: frame.projectKey,
                bundleID: frame.bundleID,
                appName: frame.appName,
                url: frame.url,
                isIdle: frame.isIdle,
                isRedacted: true,
                isMeeting: frame.isMeeting,
                isInherited: false,
                isSensitive: frame.isSensitive,
                intervalSeconds: frame.intervalSeconds
            )
        }
    }

    private nonisolated func render(
        day: String, blocks: [ActivityBlock], frames: [TimelineFrame], contextEvents: [ContextEvent]
    ) -> String {
        TimelineRenderer.render(
            day: day,
            blocks: blocks,
            frames: frames,
            contextEvents: contextEvents,
            // #314: a failure here costs the section, never the day.
            outputs: (try? outputs.outputs(day: day, timeZone: timeZone)) ?? [],
            labels: TimelineLabels.from(taxonomy.current),
            projects: taxonomy.current.projectList,
            // #146: a failure here costs the footnote, never the day.
            coverageGaps: (try? coverage.gaps(day: day, timeZone: timeZone, now: now())) ?? [],
            // #322: a failure here falls back to each frame's hint.
            projectSpans: try? projectSpans.spans(day: day),
            timeZone: timeZone
        )
    }
}
