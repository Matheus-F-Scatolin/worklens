import Foundation

/// Frames in, contiguous blocks out. A pure function on purpose: rebuilding a whole day is cheap
/// (≤ ~1000 frames), so the writer throws the day away and rebuilds it rather than maintaining
/// incremental state that can drift.
public enum BlockBuilder {
    public static let idleKey = "idle"
    public static let redactedTaskKey = "redacted"
    /// Meeting time on the screen side. `StatsAggregator` counts a block as a meeting when its
    /// task key is this or its source is a calendar, so the two must not drift apart — see the
    /// contract test in `BlockBuilderTests`. The finer key (`video_call`, `huddle`) stays on the
    /// description row, and the app key still names the app.
    public static let meetingTaskKey = StatsAggregator.meetingTaskKey
    public static let unknownAppKey = "unknown"
    public static let redactedSummary = "Redacted (blocked app)"
    /// Window titles are metadata, not prose; long ones are noise in a heading.
    public static let maxTitleLength = 80
    /// The shortest stretch that can be a block (#63). Two ticks in the same second are one
    /// tick, and the pairs already in the database sit milliseconds apart rather than at the
    /// identical instant — 2026-09-08's wake tick landed 28 ms after the normal one — so "no
    /// duration at all" has to mean "under a second" to catch them.
    public static let minimumBlockDuration: TimeInterval = 1

    /// Consecutive frames of the same app+task within `gapTolerance` seconds become one block.
    /// The default tolerance elsewhere is `max(3 × capture interval, 180 s)`.
    ///
    /// `meetingGapTolerance` (#66) is the same rule at the meeting interval: inside a detected
    /// meeting the scheduler captures every `MEETING_CAPTURE_INTERVAL_SECONDS`, so consecutive
    /// meeting frames are always further apart than the normal tolerance and every one of them
    /// would start its own one-minute block. It applies only when *both* frames being joined
    /// carry `isMeeting`, so a meeting frame never reaches across into ordinary work. Nil means
    /// "the same as `gapTolerance`", which reproduces the pre-#66 output exactly.
    ///
    /// A frame that recorded its own interval (`TimelineFrame.intervalSeconds`) is measured by
    /// it rather than by the configured one: on battery the scheduler captures every five
    /// minutes (#145), and a morning of those frames used to fall apart into one-minute blocks
    /// five minutes apart. It widens the tolerance to three of those ticks (never narrower than
    /// `gapTolerance`) and makes the last frame of a block stand for one of its own ticks. Frames
    /// without it — every row written before the column — build exactly as they did.
    ///
    /// `now`, when given, stops the final block from running into the future — a day still being
    /// recorded should not claim a minute that has not happened.
    ///
    /// `sessions` (#51) are the day's `foreground_sessions`. They carry the switch instant to the
    /// second, so a block can begin when the user actually switched rather than at the next
    /// frame. Passing none reproduces the old output exactly, byte for byte. Still pure: the
    /// sessions are just another value in.
    public static func build(
        frames: [TimelineFrame],
        gapTolerance: TimeInterval,
        meetingGapTolerance: TimeInterval? = nil,
        tickInterval: TimeInterval,
        timeZone: TimeZone = .current,
        now: Date? = nil,
        sessions: [ForegroundSession] = []
    ) -> [ActivityBlock] {
        let meetingTolerance = max(meetingGapTolerance ?? gapTolerance, gapTolerance)
        var runs = absorbFlicker(
            group(
                frames.sorted { $0.at < $1.at },
                gapTolerance: gapTolerance,
                meetingGapTolerance: meetingTolerance
            ),
            tickInterval: tickInterval,
            gapTolerance: gapTolerance,
            meetingGapTolerance: meetingTolerance
        )
        guard !runs.isEmpty else { return [] }

        // Two passes, because a run's end depends on the *snapped* start of the one after it:
        // the whole point is that the previous block now ends where the next one begins.
        var snapped = snapAll(runs, tickInterval: tickInterval, sessions: sessions)

        // #63: when two ticks land in the same second — a wake tick on top of a normal one — the
        // first run's end clamps to the second's start and the block has no duration left. It is
        // not a stretch of the day, so it is not a block: fold its frames into the run that
        // follows, where they are still counted and can still be read once.
        while let index = (0..<max(runs.count - 1, 0)).first(where: {
            end(at: $0, runs: runs, snapped: snapped, tickInterval: tickInterval, now: now)
                .timeIntervalSince(snapped[$0].start) < minimumBlockDuration
        }) {
            runs[index + 1].frames = runs[index].frames + runs[index + 1].frames
            runs.remove(at: index)
            snapped = snapAll(runs, tickInterval: tickInterval, sessions: sessions)
        }

        var blocks: [ActivityBlock] = []
        for (index, run) in runs.enumerated() {
            guard let first = run.frames.first else { continue }
            let end = end(
                at: index, runs: runs, snapped: snapped, tickInterval: tickInterval, now: now
            )

            blocks.append(ActivityBlock(
                day: DayBoundaries.dayString(first.at, timeZone: timeZone),
                startAt: snapped[index].start,
                endAt: end,
                appKey: run.appKey,
                taskKey: run.taskKey,
                title: dominantTitle(run.frames),
                summaryMd: summary(for: run),
                captureCount: run.frames.count,
                source: .screen
            ))
        }
        return blocks
    }

    /// Where each run's block would end, given the snapped bounds: the session's end or a tick
    /// past the last frame, never past the next block's start, and never past `now`.
    private static func end(
        at index: Int, runs: [Run], snapped: [SnappedBounds], tickInterval: TimeInterval,
        now: Date?
    ) -> Date {
        guard let last = runs[index].frames.last else { return snapped[index].start }
        var end = snapped[index].end ?? last.at.addingTimeInterval(tick(last, tickInterval))
        if let next = snapped[safe: index + 1]?.start { end = min(end, next) }
        if let now, index == runs.count - 1 { end = min(end, max(now, last.at)) }
        return end
    }

    // MARK: - Snapping to session edges (#51)

    private static func snapAll(
        _ runs: [Run], tickInterval: TimeInterval, sessions: [ForegroundSession]
    ) -> [SnappedBounds] {
        runs.enumerated().map { index, run in
            snap(
                run: run,
                previous: runs[safe: index - 1],
                tickInterval: tickInterval,
                sessions: sessions
            )
        }
    }

    /// Where a run's block begins and, when a session says so, where it ends. `end` is nil when
    /// nothing was snapped, leaving the caller on the old `last frame + tickInterval` rule.
    struct SnappedBounds {
        var start: Date
        var end: Date?
    }

    /// Frames say *what* happened; sessions only say *when*. So a run is moved only by a session
    /// for the bundle its own first frame was in — a frame that fell inside some other app's
    /// session is a tick that had not fired yet, not evidence about this block.
    ///
    /// Meeting blocks are untouched by construction: `build` only ever emits `source == .screen`,
    /// and the calendar/Granola blocks come from `ContextBlocks`, which never sees this function.
    static func snap(
        run: Run,
        previous: Run?,
        tickInterval: TimeInterval,
        sessions: [ForegroundSession]
    ) -> SnappedBounds {
        guard let first = run.frames.first, let last = run.frames.last else {
            return SnappedBounds(start: .distantPast, end: nil)
        }
        var bounds = SnappedBounds(start: first.at, end: nil)
        guard let bundle = first.bundleID, !sessions.isEmpty else { return bounds }

        // The latest session start still within a tick of the frame: the closest evidence wins.
        let session = sessions
            .filter {
                $0.appBundleId == bundle
                    && $0.startAt <= first.at
                    && first.at.timeIntervalSince($0.startAt) <= tick(first, tickInterval)
            }
            .max { $0.startAt < $1.startAt }
        guard let session else { return bounds }

        // A block may never start before the previous run's last frame — that frame is evidence
        // the previous app really was in front then, and a start behind it would invert the
        // block the `min(end, next.start)` rule is about to close.
        bounds.start = max(session.startAt, previous?.frames.last?.at ?? session.startAt)

        // An interval still open on a day being recorded has no end to snap to; the last block
        // keeps ending at `now`, as it does today.
        if let sessionEnd = session.endAt,
           sessionEnd >= last.at,
           sessionEnd.timeIntervalSince(last.at) <= tick(last, tickInterval) {
            bounds.end = sessionEnd
        }
        return bounds
    }

    // MARK: - Runs

    struct Run {
        var appKey: String
        var taskKey: String
        var frames: [TimelineFrame]

        var span: TimeInterval {
            guard let first = frames.first, let last = frames.last else { return 0 }
            return last.at.timeIntervalSince(first.at)
        }
    }

    /// How far apart two frames may sit and still belong to the same run. A pair of meeting
    /// frames gets the meeting interval's tolerance; every other pair, including a meeting frame
    /// beside an ordinary one, gets the normal one.
    ///
    /// When both frames recorded their interval, three of those ticks, if that is wider. Two of
    /// a kind take the longer of the two, which covers the gap either side of a switch to or
    /// from battery; a meeting frame beside an ordinary one takes the shorter, so a call still
    /// never reaches across into ordinary work.
    private static func tolerance(
        joining earlier: TimelineFrame,
        to later: TimelineFrame,
        gapTolerance: TimeInterval,
        meetingGapTolerance: TimeInterval
    ) -> TimeInterval {
        let configured = earlier.isMeeting && later.isMeeting ? meetingGapTolerance : gapTolerance
        guard let a = earlier.intervalSeconds, let b = later.intervalSeconds else { return configured }
        let interval = earlier.isMeeting == later.isMeeting ? max(a, b) : min(a, b)
        return max(configured, interval * 3)
    }

    /// How long one frame stands for: its own interval when its row recorded one, else the
    /// configured interval the build was handed.
    static func tick(_ frame: TimelineFrame, _ tickInterval: TimeInterval) -> TimeInterval {
        frame.intervalSeconds ?? tickInterval
    }

    private static func group(
        _ frames: [TimelineFrame], gapTolerance: TimeInterval, meetingGapTolerance: TimeInterval
    ) -> [Run] {
        var runs: [Run] = []
        for frame in frames {
            guard let key = frame.blockKey else { continue }
            if var current = runs.last,
               current.appKey == key.appKey,
               current.taskKey == key.taskKey,
               let previous = current.frames.last,
               frame.at.timeIntervalSince(previous.at) <= tolerance(
                   joining: previous, to: frame,
                   gapTolerance: gapTolerance, meetingGapTolerance: meetingGapTolerance
               ) {
                current.frames.append(frame)
                runs[runs.count - 1] = current
            } else {
                runs.append(Run(appKey: key.appKey, taskKey: key.taskKey, frames: [frame]))
            }
        }
        return runs
    }

    /// A one-frame detour into another app between two stretches of the same work is app
    /// switching, not a third activity. Absorb it so the day does not read as fragmented when
    /// it was not.
    ///
    /// Two kinds of single frame are never a detour. An idle or redacted row is written once per
    /// period (#6), so one frame stands for the whole stretch away from the keyboard or inside a
    /// blocked app — absorbing it would hand that stretch to the neighbouring app. And a frame
    /// with a gap wider than the tolerance on either side sits between two runs `group` kept
    /// apart on purpose; stitching them through it would swallow a pause or a quit as work.
    private static func absorbFlicker(
        _ runs: [Run], tickInterval: TimeInterval, gapTolerance: TimeInterval,
        meetingGapTolerance: TimeInterval
    ) -> [Run] {
        guard runs.count >= 3 else { return runs }
        var result = runs
        var index = 1
        while index < result.count - 1 {
            let previous = result[index - 1]
            let current = result[index]
            let next = result[index + 1]
            let sameNeighbours = previous.appKey == next.appKey && previous.taskKey == next.taskKey
            let isDetour = current.appKey != idleKey && current.taskKey != redactedTaskKey
            let contiguous = contiguous(
                previous, current,
                gapTolerance: gapTolerance, meetingGapTolerance: meetingGapTolerance
            ) && contiguous(
                current, next,
                gapTolerance: gapTolerance, meetingGapTolerance: meetingGapTolerance
            )
            if sameNeighbours, isDetour, contiguous, current.span < tickInterval {
                var merged = previous
                merged.frames += current.frames + next.frames
                result.replaceSubrange((index - 1)...(index + 1), with: [merged])
                index = max(1, index - 1)
            } else {
                index += 1
            }
        }
        return result
    }

    private static func contiguous(
        _ earlier: Run, _ later: Run, gapTolerance: TimeInterval, meetingGapTolerance: TimeInterval
    ) -> Bool {
        guard let end = earlier.frames.last, let start = later.frames.first else { return false }
        return start.at.timeIntervalSince(end.at) <= tolerance(
            joining: end, to: start,
            gapTolerance: gapTolerance, meetingGapTolerance: meetingGapTolerance
        )
    }

    // MARK: - Block fields

    /// The title the block spent most of its frames under, so a heading names the document the
    /// person actually worked on rather than whatever was on screen last.
    static func dominantTitle(_ frames: [TimelineFrame]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for title in frames.compactMap({ $0.title?.nonEmpty }) {
            if counts[title] == nil { order.append(title) }
            counts[title, default: 0] += 1
        }
        guard let best = order.max(by: { (counts[$0] ?? 0) < (counts[$1] ?? 0) }) else { return nil }
        return String(best.prefix(maxTitleLength))
    }

    private static func summary(for run: Run) -> String? {
        if run.taskKey == redactedTaskKey { return redactedSummary }
        if run.appKey == idleKey { return nil }
        return run.frames.last { !$0.isInherited && $0.summary?.nonEmpty != nil }?.summary
            ?? run.frames.last { $0.summary?.nonEmpty != nil }?.summary
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
