import Foundation

@testable import WorklensCore

/// One invented work day of undescribed frames (#121), for the fake pipeline tests.
///
/// The frames are pending, so the describe stage actually runs over them, and they need no files
/// on disk. Per the no-SPM-resources rule this is Swift constants, and per the size rule it is one
/// day written as ten runs rather than a week of JSON.
///
/// Nothing here came off anybody's screen. The company, the people and the documents are invented,
/// and the window outlines are three or four lines each — enough for the describe prompt to have
/// something to read, not a transcript.
enum SampleData {
    /// Pending captures and the window outline each was taken with. A pending frame with neither
    /// text nor an image on disk can never be described, so the outlines are not optional.
    struct Bundle {
        var captures: [Capture]
        var snapshots: [AXSnapshotRecord]

        /// Every day the bundle touches.
        var days: [String] {
            Array(Set(captures.map { DayBoundaries.dayString($0.capturedAt) })).sorted()
        }
    }

    struct BadDay: Error {
        let day: String
    }

    /// Writes the bundle into `db`. A frame that is already there keeps what it has, so a second
    /// seed of the same bundle inserts nothing.
    static func seed(_ bundle: Bundle, into db: Database) throws {
        let captureStore = CaptureStore(db)
        for capture in bundle.captures where (try captureStore.fetch(id: capture.id)) == nil {
            try captureStore.insert(capture)
        }
        // After the captures: the snapshot's foreign key is the capture it belongs to.
        let snapshotStore = AXSnapshotStore(db)
        for snapshot in bundle.snapshots
        where (try snapshotStore.fetch(captureId: snapshot.captureId)) == nil {
            try snapshotStore.insert(snapshot)
        }
    }

    /// The interval the day was written for. Runs are five minutes apart, so the tests pin
    /// `CAPTURE_INTERVAL_SECONDS` to this and the timeline's gap tolerance (three intervals)
    /// keeps each run in one block.
    static let embeddedIntervalSeconds = 300

    /// A stretch of the day spent in one window: the same app, title and outline, sampled
    /// `frames` times at `embeddedIntervalSeconds`.
    struct EmbeddedRun: Sendable {
        let clock: String
        let frames: Int
        let bundleID: String
        let appName: String
        let title: String
        let url: String?
        let text: String
    }

    /// Ten runs, 48 frames, roughly four hours of screen across a working day.
    ///
    /// The apps are all in the seeded taxonomy, so the describe schema offers a real task list for
    /// each one and the day's "where the time went" table has more than one row in it.
    static let embeddedDay: [EmbeddedRun] = [
        EmbeddedRun(
            clock: "09:05", frames: 5,
            bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
            title: "#northwind-launch — Sample Workspace", url: nil,
            text: """
                #northwind-launch
                Avery Lin: the sample pricing page is still pointing at the old copy
                Devon Marsh: I can take that after standup
                Avery Lin: thanks — no rush, it is not in the launch checklist
                """
        ),
        EmbeddedRun(
            clock: "09:40", frames: 7,
            bundleID: "com.google.Chrome", appName: "Google Chrome",
            title: "Northwind launch plan — Google Docs",
            url: "https://docs.google.com/document/d/sample-northwind-plan/edit",
            text: """
                Northwind launch plan
                Week 1 — finish the sample pricing page and the onboarding email
                Week 2 — invite the first ten sample accounts
                Open question: who owns the migration note?
                """
        ),
        EmbeddedRun(
            clock: "10:25", frames: 4,
            bundleID: "com.google.Chrome", appName: "Google Chrome",
            title: "Pull requests · sample-org/northwind",
            url: "https://github.com/sample-org/northwind/pulls",
            text: """
                sample-org/northwind — 3 open pull requests
                #412 Rename the sample pricing strings
                #411 Add a migration note to the sample README
                #409 Drop the unused sample fixture
                """
        ),
        EmbeddedRun(
            clock: "10:55", frames: 6,
            bundleID: "com.microsoft.VSCode", appName: "Code",
            title: "pricing.ts — northwind-sample", url: nil,
            text: """
                pricing.ts
                export const samplePlans = [ { key: "starter" }, { key: "team" } ]
                TODO: the starter copy still says "beta"
                48 problems, 0 errors
                """
        ),
        EmbeddedRun(
            clock: "11:35", frames: 3,
            bundleID: "com.apple.Terminal", appName: "Terminal",
            title: "northwind-sample — make test", url: nil,
            text: """
                $ make test
                Test run with 214 tests in 31 suites passed
                $ git status
                On branch sample/pricing-copy
                """
        ),
        EmbeddedRun(
            clock: "13:10", frames: 4,
            bundleID: "com.google.Chrome", appName: "Google Chrome",
            title: "Inbox (12) — sample@example.com — Gmail",
            url: "https://mail.google.com/mail/u/0/#inbox",
            text: """
                Inbox — 12 unread
                Avery Lin — Re: Northwind launch plan
                Sample Billing — your invoice is ready
                Devon Marsh — notes from the sample sync
                """
        ),
        EmbeddedRun(
            clock: "13:40", frames: 7,
            bundleID: "com.google.Chrome", appName: "Google Chrome",
            title: "Northwind pricing model — Google Sheets",
            url: "https://docs.google.com/spreadsheets/d/sample-northwind-model/edit",
            text: """
                Northwind pricing model
                A1 Plan  B1 Seats  C1 Monthly
                Starter  5  120
                Team  25  480
                """
        ),
        EmbeddedRun(
            clock: "14:50", frames: 4,
            bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
            title: "#northwind-launch — Sample Workspace", url: nil,
            text: """
                #northwind-launch
                Devon Marsh: pricing copy is up in #412
                Avery Lin: looks right to me
                Devon Marsh: merging after the sample checks pass
                """
        ),
        EmbeddedRun(
            clock: "15:20", frames: 5,
            bundleID: "com.google.Chrome", appName: "Google Chrome",
            title: "Northwind launch plan — Google Docs",
            url: "https://docs.google.com/document/d/sample-northwind-plan/edit",
            text: """
                Northwind launch plan
                Week 1 — pricing page done, onboarding email drafted
                Open question: who owns the migration note? (still open)
                Comment from Avery Lin: can we decide this today?
                """
        ),
        EmbeddedRun(
            clock: "16:15", frames: 3,
            bundleID: "md.obsidian", appName: "Obsidian",
            title: "Sample daily note — northwind", url: nil,
            text: """
                Sample daily note
                - pricing copy shipped
                - migration note still unowned
                - ask Avery tomorrow
                """
        ),
    ]

    /// The embedded day as a bundle of **pending** captures and their window outlines, dated
    /// `day`. No blocks and no timeline: those are what `describe-pending` and the timeline
    /// writer produce, and a sample that shipped them would prove nothing.
    static func embedded(day: String, timeZone: TimeZone = .current) throws -> Bundle {
        guard let midnight = DayBoundaries.range(day: day, timeZone: timeZone)?.start else {
            throw BadDay(day: day)
        }
        var captures: [Capture] = []
        var snapshots: [AXSnapshotRecord] = []

        for run in embeddedDay {
            guard let start = minutesAfterMidnight(run.clock) else { continue }
            for frame in 0..<run.frames {
                let at = midnight.addingTimeInterval(
                    Double(start * 60 + frame * embeddedIntervalSeconds)
                )
                let id = embeddedID(day: day, index: captures.count)
                captures.append(
                    Capture(
                        id: id,
                        capturedAt: at,
                        appBundleId: run.bundleID,
                        appName: run.appName,
                        windowTitle: run.title,
                        browserUrl: run.url,
                        urlHost: run.url.flatMap { URL(string: $0)?.host },
                        // Text only: there is no JPEG to embed and none is needed — #54's
                        // accessibility path is the one the app prefers anyway.
                        captureSource: .accessibility,
                        titleSource: .ax,
                        urlSource: run.url == nil ? ForegroundContext.Source.none : .ax,
                        describeStatus: .pending,
                        createdAt: at
                    ))
                snapshots.append(
                    AXSnapshotRecord(
                        captureId: id,
                        coverage: .full,
                        nodeCount: run.text.split(separator: "\n").count,
                        textChars: run.text.count,
                        elapsedMs: 0,
                        textHash: AXOutline.hash(run.text),
                        text: run.text,
                        createdAt: at
                    ))
            }
        }
        return Bundle(captures: captures, snapshots: snapshots)
    }

    /// `demo0000-2026-0911-0000-000000000007` — UUID-shaped, like every other id in the schema,
    /// and the same every time so a second seed inserts nothing instead of doubling the day.
    static func embeddedID(day: String, index: Int) -> String {
        let digits = day.filter(\.isNumber)
        let year = String(digits.prefix(4))
        let monthDay = String(digits.dropFirst(4).prefix(4))
        return "demo0000-\(year)-\(monthDay)-0000-\(String(format: "%012d", index))"
    }

    /// `"09:05"` → 545. Nil for anything else.
    private static func minutesAfterMidnight(_ clock: String) -> Int? {
        let parts = clock.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }
        return hour * 60 + minute
    }
}
