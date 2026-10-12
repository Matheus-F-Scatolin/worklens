import Foundation
import GRDB
import Testing
@testable import WorklensCore

private let catalog = [
    ProjectEntry(key: "firm", name: "Firm", kind: .house),
    ProjectEntry(key: "acme", name: "Acme Corp", kind: .company),
    ProjectEntry(key: "worklens", name: "Worklens", kind: .side),
    ProjectEntry(key: "misc", name: "Misc"),
]

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func candidate(_ id: String, minute: Int, hint: String?, key: String? = nil) -> ProjectKeyCheck.Candidate {
    ProjectKeyCheck.Candidate(
        captureId: id,
        capturedAt: start.addingTimeInterval(Double(minute) * 60),
        observation: ProjectNames.Observation(hint: hint, appName: "Mail", windowTitle: "Inbox", projectKey: key)
    )
}

@Suite("ProjectKeyCheck (#315)")
struct ProjectKeyCheckTests {
    @Test("it picks the newest house frames, by hint or by key, up to the sample")
    func picksNewestHouseFrames() {
        let candidates = [
            candidate("old", minute: 0, hint: "Firm"),
            candidate("keyed", minute: 5, hint: nil, key: "firm"),
            candidate("acme", minute: 6, hint: "Acme Corp"),
            candidate("new", minute: 9, hint: "firm"),
            candidate("none", minute: 10, hint: nil),
        ]
        #expect(ProjectKeyCheck.pick(candidates, projects: catalog, sample: 2) == ["new", "keyed"])
        #expect(ProjectKeyCheck.pick(candidates, projects: catalog) == ["new", "keyed", "old"])
        // No house entry, nothing to check.
        #expect(ProjectKeyCheck.pick(candidates, projects: Array(catalog.dropFirst())).isEmpty)
    }

    @Test("the tally counts where each answer went, and the cost")
    func tallies() {
        let outcomes: [DescribeWorker.ProbeOutcome] = [
            .answered(projectKey: "firm", costUSD: 0.0005),
            .answered(projectKey: "acme", costUSD: 0.0005),
            .answered(projectKey: "acme", costUSD: 0.0005),
            .answered(projectKey: "worklens", costUSD: 0.0005),
            .answered(projectKey: "misc", costUSD: 0.0005),
            .answered(projectKey: nil, costUSD: 0.0005),
            .failed("no window text", costUSD: 0),
            .failed("the answer did not match the schema", costUSD: 0.0005),
            .overBudget,
        ]
        let tally = ProjectKeyCheck.tally(outcomes, projects: catalog)
        // The budget stop asked nothing, so it is neither asked nor failed.
        #expect(tally.sampled == 8)
        #expect(tally.stayedHouse == 1)
        #expect(tally.company == 2)
        #expect(tally.side == 1)
        #expect(tally.unmarked == 1)
        #expect(tally.none == 1)
        #expect(tally.failed == 2)
        // The undecodable answer was paid for, so its cost counts.
        #expect(abs(tally.costUSD - 0.0035) < 1e-9)
    }

    @Test("toAsk, which the dry run prints, reads candidates and writes nothing; sensitive frames are left out")
    func dryRunWritesNothing() throws {
        let db = try Database.inMemory()
        let captures = CaptureStore(db)
        let descriptions = DescriptionStore(db)
        let snapshots = AXSnapshotStore(db)
        for (index, (withText, sensitive)) in [(true, false), (false, false), (true, true)].enumerated() {
            let capture = Capture(
                id: "c\(index)", capturedAt: start.addingTimeInterval(Double(index) * 60),
                appName: "Mail", windowTitle: "Inbox", describeStatus: .described
            )
            try captures.insert(capture)
            try descriptions.insert(Description(
                captureId: capture.id, provider: "gemini", model: "m", appKey: "other",
                taskKey: "other", summaryMd: "Reads mail.",
                detailsJson: #"{"project_hint":"Firm"}"#, isSensitive: sensitive, createdAt: start
            ))
            if withText {
                try snapshots.insert(AXSnapshotRecord(
                    captureId: capture.id, coverage: .full, nodeCount: 1, textChars: 4, elapsedMs: 1,
                    textHash: AXOutline.hash("mail"), text: "mail", redactionsJson: nil, createdAt: start
                ))
            }
        }
        func counts() throws -> [Int] {
            try db.writer.read { db in
                try ["descriptions", "llm_calls", "captures"].map {
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? 0
                }
            }
        }
        let before = try counts()
        let found = try ProjectKeyCheck.candidates(db: db, since: start.addingTimeInterval(-60))
        #expect(found.map(\.captureId) == ["c0"])
        #expect(try ProjectKeyCheck.toAsk(db: db, projects: catalog, now: start.addingTimeInterval(3600)) == ["c0"])
        // Outside the lookback window, nothing.
        let late = start.addingTimeInterval(Double(ProjectKeyCheck.lookbackDays + 1) * 86_400)
        #expect(try ProjectKeyCheck.toAsk(db: db, projects: catalog, now: late).isEmpty)
        #expect(try counts() == before)
    }
}
