import Foundation
import Testing
@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!
private let day = "2026-09-07"
private let dayRange = DayBoundaries.range(day: day, timeZone: utc)!
private func at(_ hour: Int, _ minute: Int) -> Date {
    dayRange.start.addingTimeInterval(Double(hour) * 3600 + Double(minute) * 60)
}

// MARK: - The row model (pure)

@Suite("Last frame (#151)")
struct LastFrameTests {
    @Test("each stored ending maps to one outcome")
    func outcomes() {
        func outcome(
            _ status: DescribeStatus,
            skip: SkipReason? = nil,
            redacted: Bool = false,
            sensitive: Bool = false
        ) -> LastFrame.Outcome {
            LastFrame.outcome(
                describeStatus: status, skipReason: skip, isRedacted: redacted,
                isSensitive: sensitive
            )
        }
        #expect(outcome(.described) == .described)
        // Inherited cost nothing, which is a fact about the bill and not about the frame.
        #expect(outcome(.inherited) == .described)
        #expect(outcome(.pending) == .pending)
        #expect(outcome(.failed) == .failed)
        #expect(outcome(.skipped, skip: .idle) == .idle)
        #expect(outcome(.skipped, skip: .locked) == .locked)
        // #313: sleep has its own row now, and the menu still says what it said before.
        #expect(outcome(.skipped, skip: .asleep) == .locked)
        #expect(outcome(.skipped, skip: .unchanged) == .unchanged)
        #expect(outcome(.skipped, skip: .budget) == .overBudget)
        #expect(outcome(.skipped, skip: .noText) == .noText)
        #expect(outcome(.skipped, skip: nil) == .unchanged)
    }

    @Test("blocked outranks everything, and sensitive outranks described")
    func privacyOutcomesWin() {
        // A blocked frame never reached the model, so its describe_status says nothing.
        for skip in [SkipReason.blocked, .blockedBundle, .blockedTitle, .blockedHost] {
            #expect(
                LastFrame.outcome(
                    describeStatus: .skipped, skipReason: skip, isRedacted: true,
                    isSensitive: false
                ) == .blocked
            )
        }
        // Rows written before #16 carry the flag without a refined reason.
        #expect(
            LastFrame.outcome(
                describeStatus: .skipped, skipReason: nil, isRedacted: true, isSensitive: false
            ) == .blocked
        )
        // A sensitive frame *was* described — and that is not the half worth saying.
        #expect(
            LastFrame.outcome(
                describeStatus: .described, skipReason: nil, isRedacted: false, isSensitive: true
            ) == .sensitive
        )
    }

    // MARK: Reading it back

    @Test("the store reads the newest row, described or not, with its summary")
    func fromStore() throws {
        let db = try Database.inMemory()
        let captures = CaptureStore(db)
        #expect(try captures.fetchLastFrame(day: day, timeZone: utc) == nil)

        try captures.insert(Capture(
            id: "a", capturedAt: at(9, 0), appName: "Xcode", describeStatus: .described
        ))
        try DescriptionStore(db).insert(Description(
            captureId: "a", provider: "fake", model: "fake", appKey: "code", taskKey: "coding",
            summaryMd: "Reviews a diff."
        ))
        let described = try #require(try captures.fetchLastFrame(day: day, timeZone: utc))
        #expect(described.appName == "Xcode")
        #expect(described.outcome == .described)
        #expect(described.summary == "Reviews a diff.")

        // The newest row is usually not the newest *described* one, which is exactly why
        // `fetchLastDescribed` could not answer this.
        try captures.insert(Capture(
            id: "b", capturedAt: at(9, 1), isRedacted: true, skipReason: .blockedBundle,
            describeStatus: .skipped
        ))
        let blocked = try #require(try captures.fetchLastFrame(day: day, timeZone: utc))
        #expect(blocked.outcome == .blocked)
        #expect(blocked.appName == nil)
        #expect(blocked.summary == nil)
    }

    @Test("a frame the model flagged reads as sensitive, summary and all")
    func sensitiveFromStore() throws {
        let db = try Database.inMemory()
        try CaptureStore(db).insert(Capture(
            id: "a", capturedAt: at(9, 0), appName: "Safari", describeStatus: .described
        ))
        try DescriptionStore(db).insert(Description(
            captureId: "a", provider: "fake", model: "fake", appKey: "browser", taskKey: "other",
            summaryMd: "Reviews a bank statement.", isSensitive: true
        ))
        let frame = try #require(try CaptureStore(db).fetchLastFrame(day: day, timeZone: utc))
        #expect(frame.outcome == .sensitive)
        // The image is what goes; the sentence is what the timeline is built from.
        #expect(frame.summary == "Reviews a bank statement.")
    }

    @Test("yesterday's last frame does not answer for today")
    func boundedByDay() throws {
        let db = try Database.inMemory()
        let captures = CaptureStore(db)
        let yesterday = try #require(DayBoundaries.shift(day: day, by: -1, timeZone: utc))
        try captures.insert(Capture(
            // 23:30 the evening before, which is exactly the row the menu used to draw at 08:00
            // the next morning under a count of zero.
            id: "old", capturedAt: at(0, 0).addingTimeInterval(-1800), appName: "Mail",
            describeStatus: .described
        ))
        // The counts beside this line are today's, so a line drawn from yesterday's newest row
        // would be two different days on two adjacent rows of one menu.
        #expect(try captures.fetchLastFrame(day: day, timeZone: utc) == nil)
        #expect(try captures.fetchLastFrame(day: yesterday, timeZone: utc)?.appName == "Mail")

        try captures.insert(Capture(
            id: "new", capturedAt: at(9, 30), appName: "Xcode", describeStatus: .pending
        ))
        #expect(try captures.fetchLastFrame(day: day, timeZone: utc)?.appName == "Xcode")
    }
}

// MARK: - The privacy counts

@Suite("Menu privacy counts (#151)")
struct MenuPrivacyCountsTests {
    private func seed(_ db: Database) throws {
        let captures = CaptureStore(db)
        let descriptions = DescriptionStore(db)
        // Two ordinary described frames, one of them with a card number taken out of its title.
        try captures.insert(Capture(id: "a", capturedAt: at(9, 0), describeStatus: .described))
        try descriptions.insert(Description(
            captureId: "a", provider: "fake", model: "fake", appKey: "code", taskKey: "coding",
            summaryMd: "Reads a diff.",
            detailsJson: #"{"redactions":{"card":1,"secret":2}}"#
        ))
        try captures.insert(Capture(id: "b", capturedAt: at(9, 1), describeStatus: .described))
        try descriptions.insert(Description(
            captureId: "b", provider: "fake", model: "fake", appKey: "code", taskKey: "coding",
            summaryMd: "Reads the next file."
        ))
        // One flagged sensitive, and one that inherited that flag and the same details_json.
        try captures.insert(Capture(id: "c", capturedAt: at(9, 2), describeStatus: .described))
        try descriptions.insert(Description(
            captureId: "c", provider: "fake", model: "fake", appKey: "browser", taskKey: "other",
            summaryMd: "Reads a statement.",
            detailsJson: #"{"redactions":{"iban":1}}"#, isSensitive: true
        ))
        try captures.insert(Capture(id: "d", capturedAt: at(9, 3), describeStatus: .inherited))
        try descriptions.insert(Description(
            captureId: "d", provider: "fake", model: "fake", appKey: "browser", taskKey: "other",
            summaryMd: "Reads a statement.",
            detailsJson: #"{"redactions":{"iban":1}}"#, isSensitive: true, isInherited: true
        ))
        // Two blocked minutes.
        for (index, id) in ["e", "f"].enumerated() {
            try captures.insert(Capture(
                id: id, capturedAt: at(9, 4 + index), isRedacted: true,
                skipReason: .blockedHost, describeStatus: .skipped
            ))
        }
    }

    @Test("blocked frames, flagged frames and redacted items each get a number")
    func counted() throws {
        let db = try Database.inMemory()
        try seed(db)
        let counts = try MenuCounts.load(db: db, day: day, timeZone: utc, now: at(12, 0))
        #expect(counts.captures == 6)
        #expect(counts.blocked == 2)
        // Frames, inherited included — the same number the timeline footer prints.
        #expect(counts.sensitive == 2)
        // Described rows only: "d" copied "c"'s details_json, and one IBAN was replaced once.
        #expect(counts.redactions == 4)
    }

    @Test("an ordinary day adds no numbers at all")
    func quietDay() throws {
        let db = try Database.inMemory()
        let captures = CaptureStore(db)
        for minute in 0..<5 {
            try captures.insert(Capture(capturedAt: at(9, minute), describeStatus: .pending))
        }
        let counts = try MenuCounts.load(db: db, day: day, timeZone: utc, now: at(12, 0))
        #expect(counts.blocked == 0)
        #expect(counts.sensitive == 0)
        #expect(counts.redactions == 0)
        #expect(MenuModel.countsRow(counts, budget: 1.5, level: .nominal).text
            == "Today: 5 screenshots · 0 summarized · 5 waiting · $0.00 of $1.50")
    }

    @Test("the counts line prints each privacy number only when it happened")
    func countsLine() {
        let counts = MenuCounts(
            captures: 300, described: 280, blocked: 12, sensitive: 3, redactions: 1, spendUSD: 0.2
        )
        let text = MenuModel.countsRow(counts, budget: 1.5, level: .nominal).text
        #expect(text == "Today: 300 screenshots · 280 summarized · 12 blocked · 3 flagged sensitive "
            + "· 1 item redacted · $0.20 of $1.50")
        let many = MenuCounts(captures: 300, described: 280, redactions: 9)
        #expect(MenuModel.countsRow(many, budget: 0, level: .nominal).text
            .contains("9 items redacted"))
    }

    @Test("a details_json with no redactions object counts nothing")
    func noRedactions() {
        #expect(DescriptionStore.redactions(json: nil) == 0)
        #expect(DescriptionStore.redactions(json: "") == 0)
        #expect(DescriptionStore.redactions(json: "not json") == 0)
        #expect(DescriptionStore.redactions(json: #"{"document":"plan.md"}"#) == 0)
        #expect(DescriptionStore.redactions(json: #"{"redactions":{"otp":1,"password":1}}"#) == 2)
    }
}
