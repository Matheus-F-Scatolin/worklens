import Foundation
import Testing
@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!
private let t0 = Date(timeIntervalSince1970: 1_757_246_400)   // 2025-09-07T12:00:00Z
private let tick: TimeInterval = 60
private let tolerance: TimeInterval = 180

private func frame(
    _ minute: Double,
    _ app: String? = "slack",
    _ task: String? = "reading_messages",
    title: String? = "#general",
    summary: String? = "Reading #general.",
    idle: Bool = false,
    redacted: Bool = false,
    inherited: Bool = false,
    meeting: Bool = false,
    sensitive: Bool = false,
    interval: TimeInterval? = nil
) -> TimelineFrame {
    TimelineFrame(
        captureId: Identifiers.new(),
        at: t0.addingTimeInterval(minute * 60),
        appKey: app,
        taskKey: task,
        title: title,
        summary: summary,
        isIdle: idle,
        isRedacted: redacted,
        isMeeting: meeting,
        isInherited: inherited,
        isSensitive: sensitive,
        intervalSeconds: interval
    )
}

private func build(_ frames: [TimelineFrame], now: Date? = nil) -> [ActivityBlock] {
    BlockBuilder.build(
        frames: frames, gapTolerance: tolerance, tickInterval: tick, timeZone: utc, now: now
    )
}

@Suite("BlockBuilder")
struct BlockBuilderTests {
    @Test("no frames, no blocks")
    func empty() {
        #expect(build([]).isEmpty)
    }

    @Test("consecutive frames of the same app and task are one block")
    func joinsSameTask() {
        let blocks = build([frame(0), frame(1), frame(2)])
        #expect(blocks.count == 1)
        #expect(blocks[0].captureCount == 3)
        #expect(blocks[0].startAt == t0)
        #expect(blocks[0].appKey == "slack")
        #expect(blocks[0].day == "2025-09-07")
    }

    @Test("a different task starts a new block")
    func splitsOnTaskChange() {
        let blocks = build([frame(0), frame(1, "slack", "writing_messages")])
        #expect(blocks.count == 2)
        #expect(blocks.map(\.taskKey) == ["reading_messages", "writing_messages"])
    }

    @Test("frames out of order are sorted before grouping")
    func sortsInput() {
        let blocks = build([frame(2), frame(0), frame(1)])
        #expect(blocks.count == 1)
        #expect(blocks[0].startAt == t0)
    }

    @Test("a gap larger than the tolerance splits the block")
    func splitsOnGap() {
        let blocks = build([frame(0), frame(1), frame(10), frame(11)])
        #expect(blocks.count == 2)
        #expect(blocks[0].endAt == t0.addingTimeInterval(2 * 60))
        #expect(blocks[1].startAt == t0.addingTimeInterval(10 * 60))
    }

    @Test("a gap exactly at the tolerance still joins")
    func toleranceIsInclusive() {
        #expect(build([frame(0), frame(3)]).count == 1)
        #expect(build([frame(0), frame(3.5)]).count == 2)
    }

    @Test("end_at is the last frame plus one tick, and never runs into the next block")
    func endAtRule() {
        let blocks = build([frame(0), frame(1), frame(1.5, "slack", "searching")])
        #expect(blocks.count == 2)
        // The first block would end at 12:02 but the next frame starts at 12:01:30.
        #expect(blocks[0].endAt == t0.addingTimeInterval(90))
        #expect(blocks[1].endAt == t0.addingTimeInterval(90 + 60))
    }

    @Test("the last block does not run past now")
    func clampsToNow() {
        let now = t0.addingTimeInterval(90)
        let blocks = build([frame(0), frame(1)], now: now)
        #expect(blocks[0].endAt == now)
    }

    @Test("an idle frame becomes its own idle block and splits the surrounding work")
    func idleSplits() {
        let blocks = build([
            frame(0), frame(1),
            frame(2, nil, nil, title: nil, summary: nil, idle: true),
            frame(3, nil, nil, title: nil, summary: nil, idle: true),
            frame(4),
        ])
        #expect(blocks.count == 3)
        #expect(blocks[1].appKey == "idle")
        #expect(blocks[1].taskKey == "idle")
        #expect(blocks[1].captureCount == 2)
        #expect(blocks[1].summaryMd == nil)
        #expect(blocks[2].appKey == "slack")
    }

    @Test("a redacted frame keeps its app but loses its content")
    func redactedHandling() {
        let blocks = build([
            frame(0, "onepassword", nil, title: "Vault", summary: nil, redacted: true),
            frame(1, "onepassword", nil, title: "Vault", summary: nil, redacted: true),
        ])
        #expect(blocks.count == 1)
        #expect(blocks[0].appKey == "onepassword")
        #expect(blocks[0].taskKey == "redacted")
        #expect(blocks[0].summaryMd == "Redacted (blocked app)")
    }

    @Test("frames with no description yet are not drawn")
    func undescribedFramesAreSkipped() {
        let blocks = build([frame(0), frame(1, nil, nil, title: "?", summary: nil), frame(2)])
        #expect(blocks.count == 1)
        #expect(blocks[0].captureCount == 2)
    }

    @Test("a single-frame detour between two stretches of the same work is absorbed")
    func absorbsFlicker() {
        let blocks = build([
            frame(0), frame(1),
            frame(2, "finder", "browsing_files", title: "Downloads", summary: "Looking in Downloads."),
            frame(3), frame(4),
        ])
        #expect(blocks.count == 1)
        #expect(blocks[0].captureCount == 5)
        #expect(blocks[0].appKey == "slack")
    }

    @Test("a detour longer than one tick is real work and survives")
    func keepsRealSwitches() {
        let blocks = build([
            frame(0),
            frame(1, "finder", "browsing_files", title: "Downloads", summary: "Looking in Downloads."),
            frame(2, "finder", "browsing_files", title: "Downloads", summary: "Still in Downloads."),
            frame(3),
        ])
        #expect(blocks.count == 3)
    }

    @Test("one idle row between two stretches of the same app is a break, not a flicker")
    func idleRowIsNeverAbsorbed() {
        // #6 writes exactly one idle row per idle period, so this single frame stands for the
        // whole half hour: it must stay an idle block, and Slack must not claim the time.
        let blocks = build([
            frame(0), frame(1),
            frame(2, nil, nil, title: nil, summary: nil, idle: true),
            frame(32), frame(33),
        ])
        #expect(blocks.count == 3)
        #expect(blocks[1].appKey == "idle")
        #expect(blocks[1].startAt == t0.addingTimeInterval(2 * 60))
        #expect(blocks[1].endAt == t0.addingTimeInterval(3 * 60))
        #expect(blocks[0].endAt == t0.addingTimeInterval(2 * 60))
        #expect(blocks[2].startAt == t0.addingTimeInterval(32 * 60))
    }

    @Test("one redacted row between two stretches of the same app stays redacted")
    func redactedRowIsNeverAbsorbed() {
        let blocks = build([
            frame(0), frame(1),
            frame(2, "onepassword", nil, title: nil, summary: nil, redacted: true),
            frame(3), frame(4),
        ])
        #expect(blocks.count == 3)
        #expect(blocks[1].appKey == "onepassword")
        #expect(blocks[1].taskKey == "redacted")
        #expect(blocks[1].summaryMd == "Redacted (blocked app)")
    }

    @Test("a single frame across a gap wider than the tolerance does not stitch two runs together")
    func flickerAcrossGapIsNotAbsorbed() {
        // Slack, a Finder frame, then nothing for half an hour (a pause, a quit) and Slack again.
        // Absorbing the Finder frame would turn the silent half hour into one long Slack block.
        let blocks = build([
            frame(0), frame(1),
            frame(2, "finder", "browsing_files", title: "Downloads", summary: "Looking in Downloads."),
            frame(32), frame(33),
        ])
        #expect(blocks.count == 3)
        #expect(blocks[0].endAt == t0.addingTimeInterval(2 * 60))
        #expect(blocks[1].appKey == "finder")
        #expect(blocks[2].startAt == t0.addingTimeInterval(32 * 60))
    }

    @Test("a flicker between two different activities is left alone")
    func flickerNeedsMatchingNeighbours() {
        let blocks = build([
            frame(0),
            frame(1, "finder", "browsing_files", title: nil, summary: "Downloads."),
            frame(2, "vscode", "coding", title: nil, summary: "Editing."),
        ])
        #expect(blocks.count == 3)
    }

    @Test("the block's title is the one most frames were under, capped at 80 characters")
    func dominantTitle() {
        let long = String(repeating: "a", count: 120)
        let blocks = build([
            frame(0, title: "#random"),
            frame(1, title: "#general"),
            frame(2, title: "#general"),
        ])
        #expect(blocks[0].title == "#general")

        let capped = build([frame(0, title: long)])
        #expect(capped[0].title?.count == 80)
    }

    @Test("the block summary is the last summary that was not inherited")
    func summaryPrefersFreshFrames() {
        let blocks = build([
            frame(0, summary: "Reading the first thread."),
            frame(1, summary: "Reading the second thread."),
            frame(2, summary: "Reading the second thread.", inherited: true),
        ])
        #expect(blocks[0].summaryMd == "Reading the second thread.")
        #expect(blocks[0].captureCount == 3)
    }

    @Test("meeting frames become their own block under the key stats counts")
    func meetingFramesGetTheMeetingKey() {
        let blocks = build([
            frame(0),
            frame(1, "gmeet", "video_call", title: "Portfolio review",
                  summary: "In a video call.", meeting: true),
            frame(2, "gmeet", "video_call", title: "Portfolio review",
                  summary: "Still in the call.", meeting: true),
            frame(3),
        ])
        #expect(blocks.count == 3)
        #expect(blocks[1].appKey == "gmeet")
        #expect(blocks[1].taskKey == "meeting")
        #expect(StatsAggregator.isMeeting(blocks[1]))
        #expect(!StatsAggregator.isMeeting(blocks[0]))
    }

    @Test("idle and redacted outrank meeting, and idle stays inactive for stats")
    func flagPrecedence() {
        let idleInMeeting = build([
            frame(0, nil, nil, title: nil, summary: nil, idle: true, meeting: true),
        ])
        #expect(idleInMeeting[0].taskKey == "idle")
        #expect(StatsAggregator.isInactive(idleInMeeting[0]))

        let redactedInMeeting = build([
            frame(0, "onepassword", nil, title: nil, summary: nil, redacted: true, meeting: true),
        ])
        #expect(redactedInMeeting[0].taskKey == "redacted")
    }

    @Test("two frames in the same second never leave a zero-length block behind")
    func wakeTickDoesNotLeaveAZeroLengthBlock() {
        // #63: a wake tick landing on a normal one wrote two rows in the same second, and the
        // first block's end clamped to the second's start. The frames stay — folded into the run
        // that follows, so the summary is still there to read — and the empty block goes.
        let blocks = build([
            frame(0, "chrome", "video", title: "Youka", summary: "Syncing lyrics."),
            frame(0, "chrome", "other", title: "Youka", summary: "Syncing timestamps."),
            frame(3, "chrome", "other", title: "Youka", summary: "Still syncing."),
        ])
        #expect(blocks.allSatisfy { $0.endAt > $0.startAt })
        #expect(blocks.count == 1)
        #expect(blocks[0].captureCount == 3)
        #expect(blocks[0].taskKey == "other")
        #expect(blocks[0].startAt == t0)
    }

    @Test("two frames milliseconds apart are folded too — that is what the database holds")
    func millisecondsApartIsStillTheSameTick() {
        // 2026-09-08's wake tick landed 28 ms after the normal one, not on the same instant.
        let blocks = build([
            frame(0, "chrome", "video", title: "Youka", summary: "Syncing lyrics."),
            frame(0.028 / 60, "chrome", "other", title: "Youka", summary: "Syncing timestamps."),
        ])
        #expect(blocks.count == 1)
        #expect(blocks[0].captureCount == 2)
        #expect(blocks[0].taskKey == "other")
    }

    @Test("a block a second long is a real block and is kept")
    func aSecondApartIsNotFolded() {
        let blocks = build([
            frame(0, "chrome", "video", title: "Youka", summary: "Syncing lyrics."),
            frame(1.0 / 60, "chrome", "other", title: "Youka", summary: "Syncing timestamps."),
        ])
        #expect(blocks.map(\.captureCount) == [1, 1])
        #expect(blocks[0].endAt.timeIntervalSince(blocks[0].startAt) == 1)
    }

    @Test("every block is marked as coming from the screen")
    func sourceIsScreen() {
        #expect(build([frame(0)]).allSatisfy { $0.source == .screen })
    }
}

// MARK: - Snapping to foreground session edges (#51)

private let slackBundle = "com.tinyspeck.slackmacgap"
private let xcodeBundle = "com.apple.dt.Xcode"

/// `seconds` past `t0`, so a fixture can say "the switch happened at :00:40".
private func second(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

private func bundledFrame(
    _ minute: Double,
    app: String,
    bundle: String,
    task: String = "working"
) -> TimelineFrame {
    TimelineFrame(
        captureId: Identifiers.new(),
        at: t0.addingTimeInterval(minute * 60),
        appKey: app,
        taskKey: task,
        title: app,
        summary: "Working in \(app).",
        bundleID: bundle
    )
}

private func foregroundSession(
    from: Double,
    to: Double?,
    bundle: String?
) -> ForegroundSession {
    ForegroundSession(
        startAt: second(from),
        endAt: to.map(second),
        appBundleId: bundle,
        appName: bundle,
        isBlocked: bundle == nil
    )
}

/// Slack at :00, Xcode at :01 and :02 — the day the acceptance criterion describes.
private let switchFrames = [
    bundledFrame(0, app: "slack", bundle: slackBundle),
    bundledFrame(1, app: "xcode", bundle: xcodeBundle),
    bundledFrame(2, app: "xcode", bundle: xcodeBundle),
]

private func build(
    _ frames: [TimelineFrame],
    sessions: [ForegroundSession],
    now: Date? = nil
) -> [ActivityBlock] {
    BlockBuilder.build(
        frames: frames, gapTolerance: tolerance, tickInterval: tick, timeZone: utc,
        now: now, sessions: sessions
    )
}

@Suite("BlockBuilder with foreground sessions")
struct BlockBuilderSessionTests {
    @Test("a block starts when the user actually switched, and the one before it ends there")
    func blockStartsAtTheSwitch() {
        let blocks = build(
            switchFrames,
            sessions: [foregroundSession(from: 40, to: nil, bundle: xcodeBundle)]
        )
        #expect(blocks.count == 2)
        #expect(blocks[0].appKey == "slack")
        #expect(blocks[0].startAt == t0)
        #expect(blocks[0].endAt == second(40))
        #expect(blocks[1].appKey == "xcode")
        #expect(blocks[1].startAt == second(40))
        // No gap and no overlap at the switch — the point of the whole exercise.
        #expect(blocks[0].endAt == blocks[1].startAt)
    }

    @Test("a session for another bundle around a frame does not move the block")
    func otherBundleSessionIsIgnored() {
        let withoutSessions = build(switchFrames, sessions: [])
        let blocks = build(
            switchFrames,
            sessions: [foregroundSession(from: 40, to: 200, bundle: "com.google.Chrome")]
        )
        #expect(blocks.map(\.startAt) == withoutSessions.map(\.startAt))
        #expect(blocks.map(\.endAt) == withoutSessions.map(\.endAt))
    }

    @Test("no sessions renders exactly as it did before #51")
    func noSessionsChangesNothing() {
        let before = BlockBuilder.build(
            frames: switchFrames, gapTolerance: tolerance, tickInterval: tick, timeZone: utc
        )
        let after = build(switchFrames, sessions: [])
        // Ids and `createdAt` are fresh on every build; everything a reader sees must match.
        #expect(before.map(\.startAt) == after.map(\.startAt))
        #expect(before.map(\.endAt) == after.map(\.endAt))
        #expect(before.map(\.appKey) == after.map(\.appKey))
        #expect(before.map(\.taskKey) == after.map(\.taskKey))
        #expect(before.map(\.captureCount) == after.map(\.captureCount))
        #expect(before.map(\.summaryMd) == after.map(\.summaryMd))
    }

    @Test("a session that started more than a tick before the frame does not move the block")
    func staleSessionStartIsIgnored() {
        // The switch is claimed at :00:00 but the first Xcode frame is at :02:00 — two ticks
        // later. Believing it would hand Slack's second minute to Xcode.
        let blocks = build(
            [
                bundledFrame(0, app: "slack", bundle: slackBundle),
                bundledFrame(2, app: "xcode", bundle: xcodeBundle),
            ],
            sessions: [foregroundSession(from: 0, to: nil, bundle: xcodeBundle)]
        )
        #expect(blocks[1].startAt == t0.addingTimeInterval(120))
    }

    @Test("a block ends at its session's end when that lands within a tick of the last frame")
    func blockEndsAtTheSessionEnd() {
        let blocks = build(
            [
                bundledFrame(0, app: "xcode", bundle: xcodeBundle),
                bundledFrame(1, app: "xcode", bundle: xcodeBundle),
            ],
            sessions: [foregroundSession(from: 0, to: 95, bundle: xcodeBundle)]
        )
        #expect(blocks.count == 1)
        // 95 s, not the 120 s that "last frame plus one tick" would have claimed.
        #expect(blocks[0].endAt == second(95))
    }

    @Test("a session still open leaves the last block ending at now, as it does today")
    func openSessionLeavesTheEndAlone() {
        let now = second(90)
        let blocks = build(
            [
                bundledFrame(0, app: "xcode", bundle: xcodeBundle),
                bundledFrame(1, app: "xcode", bundle: xcodeBundle),
            ],
            sessions: [foregroundSession(from: 0, to: nil, bundle: xcodeBundle)],
            now: now
        )
        #expect(blocks[0].endAt == now)
    }

    @Test("a snapped start never reaches back past the previous run's last frame")
    func snappedStartIsFlooredAtTheLastFrame() {
        // A session claiming the switch happened at :00:20 cannot be right: there is a Slack
        // frame at :00:30, which is evidence Slack really was in front then. Floored there, the
        // Slack run has nothing left to span, so #63 folds it into the block that follows
        // instead of emitting a zero-minute one — an unfloored :00:20 start would show here as
        // a block beginning ten seconds earlier.
        let blocks = build(
            [
                bundledFrame(0.5, app: "slack", bundle: slackBundle),
                bundledFrame(1, app: "xcode", bundle: xcodeBundle),
            ],
            sessions: [foregroundSession(from: 20, to: nil, bundle: xcodeBundle)]
        )
        #expect(blocks.count == 1)
        #expect(blocks[0].startAt == second(30))
        #expect(blocks[0].appKey == "xcode")
        #expect(blocks[0].captureCount == 2)
    }

    @Test("the latest matching session start wins when several are in range")
    func closestSessionWins() {
        let blocks = build(
            switchFrames,
            sessions: [
                foregroundSession(from: 5, to: 20, bundle: xcodeBundle),
                foregroundSession(from: 40, to: nil, bundle: xcodeBundle),
            ]
        )
        #expect(blocks[1].startAt == second(40))
    }

    @Test("a blocked interval carries no bundle, so it snaps nothing")
    func blockedSessionSnapsNothing() {
        let withoutSessions = build(switchFrames, sessions: [])
        let blocks = build(
            switchFrames,
            sessions: [foregroundSession(from: 40, to: nil, bundle: nil)]
        )
        #expect(blocks.map(\.startAt) == withoutSessions.map(\.startAt))
    }

    @Test("a frame with no bundle id cannot be snapped")
    func frameWithoutBundleIsUntouched() {
        let frames = [
            bundledFrame(0, app: "slack", bundle: slackBundle),
            frame(1, "xcode", "working"),
        ]
        let blocks = build(
            frames,
            sessions: [foregroundSession(from: 40, to: nil, bundle: xcodeBundle)]
        )
        #expect(blocks[1].startAt == t0.addingTimeInterval(60))
    }
}

// MARK: - Meeting gap tolerance (#66)

private let meetingInterval: TimeInterval = 300
private let meetingTolerance: TimeInterval = 900   // max(3 × 300, 180)

private func meetingBuild(_ frames: [TimelineFrame]) -> [ActivityBlock] {
    BlockBuilder.build(
        frames: frames,
        gapTolerance: tolerance,
        meetingGapTolerance: meetingTolerance,
        tickInterval: tick,
        timeZone: utc
    )
}

/// `minute` is in whole capture intervals of the meeting throttle, i.e. 300 s apart.
private func callFrame(
    _ step: Double, _ app: String = "gmeet", meeting: Bool = true
) -> TimelineFrame {
    TimelineFrame(
        captureId: Identifiers.new(),
        at: t0.addingTimeInterval(step * meetingInterval),
        appKey: app,
        taskKey: meeting ? nil : BlockBuilder.meetingTaskKey,
        title: "Pinecrest Machines & Riverbend",
        summary: "In the call.",
        isIdle: false,
        isRedacted: false,
        isMeeting: meeting,
        isInherited: false,
        isSensitive: false
    )
}

@Suite("BlockBuilder meeting gap tolerance")
struct BlockBuilderMeetingToleranceTests {
    @Test("five meeting frames one meeting interval apart are one block")
    func meetingFramesJoinAcrossTheMeetingInterval() {
        let blocks = meetingBuild((0..<5).map { callFrame(Double($0)) })
        #expect(blocks.count == 1)
        #expect(blocks[0].captureCount == 5)
        #expect(blocks[0].startAt == t0)
        #expect(blocks[0].taskKey == BlockBuilder.meetingTaskKey)
    }

    @Test("five non-meeting frames one meeting interval apart are still five blocks")
    func ordinaryFramesKeepTheNormalTolerance() {
        let blocks = meetingBuild((0..<5).map { frame(Double($0) * meetingInterval / 60) })
        #expect(blocks.count == 5)
        #expect(blocks.allSatisfy { $0.captureCount == 1 })
    }

    @Test("a meeting frame does not join the ordinary frame after it")
    func meetingDoesNotReachIntoOrdinaryWork() {
        let blocks = meetingBuild([
            callFrame(0),
            frame(meetingInterval / 60, "gmeet", "browsing", title: "Pinecrest Machines & Riverbend"),
        ])
        #expect(blocks.count == 2)
        #expect(blocks[0].taskKey == BlockBuilder.meetingTaskKey)
        #expect(blocks[1].taskKey == "browsing")
    }

    @Test("a frame keyed as a meeting but not captured in one keeps the normal tolerance")
    func sameKeyButNotFlaggedDoesNotJoin() {
        // Both frames carry (gmeet, meeting), so only the tolerance can decide — the wider one
        // is for frames the scheduler actually throttled, which this second one was not (#64).
        let blocks = meetingBuild([callFrame(0), callFrame(1, meeting: false)])
        #expect(blocks.count == 2)
    }

    @Test("a one-frame detour inside a meeting is absorbed at the meeting tolerance")
    func flickerInsideAMeetingIsAbsorbed() {
        let blocks = meetingBuild([
            callFrame(0), callFrame(1),
            callFrame(2, "chrome"),
            callFrame(3), callFrame(4),
        ])
        #expect(blocks.count == 1)
        #expect(blocks[0].appKey == "gmeet")
        #expect(blocks[0].captureCount == 5)
    }

    @Test("no meeting tolerance given reproduces the pre-#66 output")
    func defaultsToTheNormalTolerance() {
        let frames = (0..<5).map { callFrame(Double($0)) }
        #expect(build(frames).count == 5)
    }

    // MARK: - Each frame's own interval (battery capture)

    @Test("five-minute battery frames of one task are one block, the last standing for its tick")
    func batteryFramesJoin() {
        let frames = [0.0, 5, 10, 15].map { frame($0, interval: 300) }
        let blocks = build(frames)
        #expect(blocks.count == 1)
        #expect(blocks[0].captureCount == 4)
        #expect(blocks[0].startAt == t0)
        #expect(blocks[0].endAt == t0.addingTimeInterval(20 * 60))
    }

    @Test("the same frames without a recorded interval still split, as they always did")
    func legacyFramesKeepTheConfiguredRule() {
        let blocks = build([0.0, 5, 10].map { frame($0) })
        #expect(blocks.count == 3)
        #expect(blocks.allSatisfy { $0.endAt.timeIntervalSince($0.startAt) == tick })
    }

    @Test("a real break on battery still splits: more than three ticks apart")
    func batteryBreakSplits() {
        let blocks = build([frame(0, interval: 300), frame(5, interval: 300), frame(25, interval: 300)])
        #expect(blocks.count == 2)
    }

    @Test("plugging in: the gap after the last battery frame joins, and the next frames tick a minute")
    func switchToMains() {
        let frames = [frame(0, interval: 300), frame(5, interval: 60), frame(6, interval: 60)]
        let blocks = build(frames)
        #expect(blocks.count == 1)
        #expect(blocks[0].endAt == t0.addingTimeInterval(7 * 60))
    }

    @Test("a battery meeting frame beside ordinary work is held to the ordinary tick")
    func meetingNeverReachesIntoWork() {
        // Meeting frames every 25 minutes on battery; ordinary work every 5. A 20-minute gap
        // between the two kinds is wider than three ordinary ticks, so they stay apart.
        let frames = [
            frame(0, "zoom", "meeting", meeting: true, interval: 1500),
            frame(20, "zoom", "meeting", interval: 300),
        ]
        #expect(build(frames).count == 2)
    }
}
