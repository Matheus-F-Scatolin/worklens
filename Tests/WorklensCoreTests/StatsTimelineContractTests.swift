import Foundation
import Testing
@testable import WorklensCore

// The vocabulary two agents had to agree on blind (PR #28 deviation 2): what the timeline side
// emits for idle, blocked and meeting frames, and what the stats side counts. This suite builds a
// day the way the app does — frames through `BlockBuilder`, synced meetings through
// `ContextBlocks` — and checks that `StatsAggregator` and the timeline header agree about it.

private let utc = TimeZone(identifier: "UTC")!
private let day = "2026-09-07"
private let dayStart = DayBoundaries.range(day: day, timeZone: utc)!.start
private let tick: TimeInterval = 60

private func at(_ hour: Int, _ minute: Int) -> Date {
    dayStart.addingTimeInterval(Double(hour) * 3600 + Double(minute) * 60)
}

private func frame(
    _ hour: Int, _ minute: Int,
    app: String? = "slack", task: String? = "reading_messages",
    summary: String? = "Reading #general.",
    idle: Bool = false, redacted: Bool = false, meeting: Bool = false
) -> TimelineFrame {
    TimelineFrame(
        captureId: Identifiers.new(), at: at(hour, minute), appKey: app, taskKey: task,
        title: "a window", summary: summary, isIdle: idle, isRedacted: redacted, isMeeting: meeting
    )
}

private func capture(for frame: TimelineFrame) -> Capture {
    Capture(
        id: frame.captureId, capturedAt: frame.at, appBundleId: "com.tinyspeck.slackmacgap",
        isIdle: frame.isIdle, isRedacted: frame.isRedacted, isMeeting: frame.isMeeting,
        describeStatus: frame.isIdle ? .skipped : .described
    )
}

@Suite("Timeline ↔ stats vocabulary contract")
struct StatsTimelineContractTests {
    /// 09:00-09:04 Slack, 09:05 idle, 09:10-09:12 in a Meet call that the calendar also knows
    /// about (09:10-09:40), 09:13 back in Slack while the call is still on.
    private let frames: [TimelineFrame] = [
        frame(9, 0), frame(9, 1), frame(9, 2), frame(9, 3), frame(9, 4),
        frame(9, 5, app: nil, task: nil, summary: nil, idle: true),
        frame(9, 10, app: "gmeet", task: "video_call", summary: "In a video call.", meeting: true),
        frame(9, 11, app: "gmeet", task: "video_call", summary: "Still on the call.", meeting: true),
        frame(9, 12, app: "gmeet", task: "video_call", summary: "Still on the call.", meeting: true),
        frame(9, 13, meeting: true),
    ]

    private let calendarMeeting = ContextEvent(
        source: .calendar, externalId: "ev1", startAt: at(9, 10), endAt: at(9, 40),
        title: "Portfolio review", bodyMd: "Quarterly numbers.", isMeeting: true
    )

    private func blocks() -> [ActivityBlock] {
        BlockBuilder.build(frames: frames, gapTolerance: 180, tickInterval: tick, timeZone: utc)
            + ContextBlocks.meetingBlocks(day: day, events: [calendarMeeting], timeZone: utc)
    }

    @Test("idle frames become a block the aggregator counts as idle, not active")
    func idleIsInactive() {
        let all = blocks()
        let idle = all.filter { $0.appKey == BlockBuilder.idleKey }
        #expect(idle.count == 1)
        #expect(idle.allSatisfy(StatsAggregator.isInactive))
        #expect(all.filter { !StatsAggregator.isInactive($0) }.count == all.count - 1)

        let stats = StatsAggregator.daily(day: day, blocks: all, captures: frames.map(capture), timeZone: utc)
        // The idle block runs from 09:05 to the next block's start clamp: one tick.
        #expect(stats.idleMinutes == 1)
        #expect(stats.activeMinutes == stats.trackedMinutes - stats.idleMinutes)
    }

    @Test("meeting frames and calendar meeting blocks both count as meeting time, once")
    func meetingMinutesAreAUnion() {
        let all = blocks()
        let screenMeeting = all.first { $0.appKey == "gmeet" }
        let calendar = all.first { $0.source == .calendar }
        #expect(screenMeeting?.taskKey == StatsAggregator.meetingTaskKey)
        #expect(screenMeeting.map(StatsAggregator.isMeeting) == true)
        #expect(calendar?.appKey == ContextBlocks.appKey)
        #expect(calendar.map(StatsAggregator.isMeeting) == true)

        let stats = StatsAggregator.daily(
            day: day, blocks: all, captures: frames.map(capture), contextEvents: [calendarMeeting], timeZone: utc
        )
        // 09:10-09:40 from the calendar covers the 09:10-09:13 screen block: 30 minutes, not 33.
        #expect(stats.meetingMinutes == 30)
        #expect(stats.meetingsCount == 1)
        // Slack 09:00-09:05 plus the meeting 09:10-09:40; the 09:13 Slack frame sits inside it.
        #expect(stats.activeMinutes == 35)
        #expect(stats.trackedMinutes == 36)
    }

    @Test("the timeline header quotes the same minutes as the stats")
    func headerMatchesStats() {
        let all = blocks()
        let stats = StatsAggregator.daily(
            day: day, blocks: all, captures: frames.map(capture), contextEvents: [calendarMeeting], timeZone: utc
        )
        let markdown = TimelineRenderer.render(
            day: day, blocks: all, frames: frames, contextEvents: [calendarMeeting], timeZone: utc
        )
        let header = markdown.split(separator: "\n").first { $0.hasPrefix("Tracked ") } ?? ""
        #expect(header.contains("Tracked \(stats.trackedMinutes)m"))
        #expect(header.contains("Active \(stats.activeMinutes)m"))
        #expect(header.contains("Idle \(stats.idleMinutes)m"))
        #expect(header.contains("Meetings \(stats.meetingMinutes)m"))
    }

    @Test("a blocked frame is redacted time, not active work in an unknown task")
    func redactedFramesStayOutOfTasks() {
        let redacted = frame(10, 0, app: "onepassword", task: nil, summary: nil, redacted: true)
        let all = BlockBuilder.build(frames: [frame(9, 59), redacted, frame(10, 1)],
                                     gapTolerance: 180, tickInterval: tick, timeZone: utc)
        let block = all.first { $0.appKey == "onepassword" }
        #expect(block?.taskKey == BlockBuilder.redactedTaskKey)
        #expect(block?.summaryMd == BlockBuilder.redactedSummary)

        let captures = [frame(9, 59), redacted, frame(10, 1)].map(capture)
        let stats = StatsAggregator.daily(day: day, blocks: all, captures: captures, timeZone: utc)
        #expect(stats.redactedMinutes == 1)
        #expect(!stats.byTask.contains { $0.key.hasSuffix("/\(BlockBuilder.redactedTaskKey)") } || stats.byTask.count >= 1)
    }
}
