import Foundation
import Testing
@testable import WorklensCore

// MARK: - Harness

/// An in-memory database with whatever captures and descriptions a test wants, oldest first.
private struct QueriesHarness {
    let db: Database
    let queries: DescribeQueries

    init() throws {
        db = try Database.inMemory()
        queries = DescribeQueries(db)
    }

    /// One capture, described unless `summary` is nil.
    @discardableResult
    func add(
        at: Date,
        bundleID: String? = claude,
        summary: String? = nil,
        appKey: String = "claude_desktop",
        taskKey: String = "prompting",
        inherited: Bool = false,
        idle: Bool = false,
        redacted: Bool = false
    ) throws -> Capture {
        let capture = Capture(
            capturedAt: at,
            appBundleId: bundleID,
            appName: "Test App",
            isIdle: idle,
            isRedacted: redacted,
            describeStatus: summary == nil ? .pending : (inherited ? .inherited : .described)
        )
        try CaptureStore(db).insert(capture)
        if let summary {
            try DescriptionStore(db).insert(Description(
                captureId: capture.id,
                provider: "gemini",
                model: "gemini-3.5-flash-lite",
                appKey: appKey,
                taskKey: taskKey,
                summaryMd: summary,
                isInherited: inherited
            ))
        }
        return capture
    }
}

/// 2026-09-07T12:00:00Z: the frame every test asks for context about.
private let now = Date(timeIntervalSince1970: 1_788_782_400)
private func minutesAgo(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
private let claude = "com.anthropic.claudefordesktop"
private let slack = "com.tinyspeck.slackmacgap"

// MARK: - Tests

@Suite("DescribeQueries.runContext (#65)")
struct DescribeQueriesRunContextTests {
    /// The frame the context is built for: the newest row, in Claude.
    private func subject(_ harness: QueriesHarness) throws -> Capture {
        try harness.add(at: now, summary: nil)
    }

    @Test("the app before this one, then the run in this one")
    func switchThenRun() throws {
        let harness = try QueriesHarness()
        try harness.add(at: minutesAgo(40), bundleID: slack, summary: "Reads #deal-flow.",
                        appKey: "slack", taskKey: "reading_messages")
        try harness.add(at: minutesAgo(30), summary: "Drafts a migration plan.")
        try harness.add(at: minutesAgo(20), summary: "Reviews the generated SQL.")
        try harness.add(at: minutesAgo(10), summary: "Runs the migration against staging.")

        let context = try harness.queries.runContext(for: subject(harness))
        #expect(context.before?.summary == "Reads #deal-flow.")
        #expect(context.before?.appKey == "slack")
        #expect(context.runStart == minutesAgo(30))
        #expect(context.runFrames == 3)
        #expect(context.tail.map(\.summary) == [
            "Drafts a migration plan.", "Reviews the generated SQL.",
            "Runs the migration against staging.",
        ])
        #expect(context.first == nil)
    }

    @Test("the run stops at a bundle change, which is also what the switch line quotes")
    func bundleChange() throws {
        let harness = try QueriesHarness()
        try harness.add(at: minutesAgo(50), summary: "An older Claude thread.")
        try harness.add(at: minutesAgo(40), bundleID: slack, summary: "Reads #deal-flow.",
                        appKey: "slack", taskKey: "reading_messages")
        try harness.add(at: minutesAgo(20), summary: "Drafts a migration plan.")

        let context = try harness.queries.runContext(for: subject(harness))
        #expect(context.runFrames == 1)
        #expect(context.tail.map(\.summary) == ["Drafts a migration plan."])
        #expect(context.before?.summary == "Reads #deal-flow.")
        // The Claude frame on the far side of the switch is not part of this run.
        #expect(!context.tail.contains { $0.summary == "An older Claude thread." })
    }

    @Test("an idle row and a locked row each end the run")
    func idleAndLocked() throws {
        for breaker in ["idle", "locked"] {
            let harness = try QueriesHarness()
            try harness.add(at: minutesAgo(50), summary: "Before the break.")
            try harness.add(
                at: minutesAgo(40), bundleID: nil,
                idle: breaker == "idle", redacted: breaker == "locked"
            )
            try harness.add(at: minutesAgo(20), summary: "After the break.")

            let context = try harness.queries.runContext(for: subject(harness))
            #expect(context.runFrames == 1, "\(breaker)")
            #expect(context.tail.map(\.summary) == ["After the break."], "\(breaker)")
            #expect(context.runStart == minutesAgo(20), "\(breaker)")
            // The break carries no description, and the frame beyond it is the same app, so
            // there is nothing to say about "before this app".
            #expect(context.before == nil, "\(breaker)")
        }
    }

    @Test("the run stops at the 90-minute window, and so does the switch line")
    func window() throws {
        let harness = try QueriesHarness()
        try harness.add(at: minutesAgo(95), bundleID: slack, summary: "Long ago, elsewhere.",
                        appKey: "slack", taskKey: "reading_messages")
        try harness.add(at: minutesAgo(91), summary: "Just outside the window.")
        try harness.add(at: minutesAgo(89), summary: "Just inside it.")

        let context = try harness.queries.runContext(for: subject(harness))
        #expect(context.runFrames == 1)
        #expect(context.tail.map(\.summary) == ["Just inside it."])
        #expect(context.before == nil)
    }

    @Test("inherited rows are never quoted, and do not end the run either")
    func inheritedRows() throws {
        let harness = try QueriesHarness()
        try harness.add(at: minutesAgo(40), bundleID: slack, summary: "Inherited elsewhere.",
                        appKey: "slack", taskKey: "reading_messages", inherited: true)
        try harness.add(at: minutesAgo(30), summary: "Drafts a migration plan.")
        try harness.add(at: minutesAgo(20), summary: "Drafts a migration plan.", inherited: true)
        try harness.add(at: minutesAgo(10), summary: "Reviews the generated SQL.")

        let context = try harness.queries.runContext(for: subject(harness))
        #expect(context.runFrames == 2)
        #expect(context.tail.map(\.summary) == [
            "Drafts a migration plan.", "Reviews the generated SQL.",
        ])
        // The only frame from another app is inherited, so the switch line has nothing to quote.
        #expect(context.before == nil)
    }

    @Test("a frame with nothing before it gets an empty context")
    func nothingBefore() throws {
        let harness = try QueriesHarness()
        let context = try harness.queries.runContext(for: subject(harness))
        #expect(context.isEmpty)
        #expect(context.runFrames == 0)
        #expect(DescribePrompt.contextBlock(context, timeZone: .current) == nil)
    }

    @Test("a long run is compressed on the way out of the query")
    func longRunIsCompressed() throws {
        let harness = try QueriesHarness()
        for minute in stride(from: 60, through: 2, by: -2) {
            try harness.add(at: minutesAgo(Double(minute)), summary: "Step \(minute).")
        }

        let context = try harness.queries.runContext(for: subject(harness))
        #expect(context.runFrames == 30)
        #expect(context.first?.summary == "Step 60.")
        #expect(context.tail.count == DescribePrompt.runContextTail)
        #expect(context.omitted == 25)
        let block = try #require(DescribePrompt.contextBlock(context, timeZone: .current))
        #expect(block.count <= DescribePrompt.runContextBudget)
    }
}
