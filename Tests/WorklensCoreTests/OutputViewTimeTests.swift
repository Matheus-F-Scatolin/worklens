import Foundation
import Testing
@testable import WorklensCore

/// The join between a shipped GitHub row and the frames that showed its page (#319).
private let zone = TimeZone(identifier: "UTC")!

private func noon(_ day: String) -> Date {
    DayBoundaries.range(day: day, timeZone: zone)!.start.addingTimeInterval(12 * 3600)
}

private func output(
    _ kind: OutputKind, _ day: String, repo: String? = "Owner/Repo", number: Int? = 12,
    source: String = Output.github, id: String = Identifiers.new()
) -> Output {
    Output(
        id: id, source: source, kind: kind, at: noon(day), repo: repo, number: number,
        externalId: id, provenance: "test", syncedAt: noon(day)
    )
}

private let pull12 = ArtifactKey.github(owner: "owner", repo: "repo", kind: .pull, number: 12)
private let issue12 = ArtifactKey.github(owner: "owner", repo: "repo", kind: .issues, number: 12)
private let pull13 = ArtifactKey.github(owner: "owner", repo: "repo", kind: .pull, number: 13)

@Suite("Shipped screen time (#319)")
struct OutputViewTimeTests {
    @Test("frames inside the 30 days count; after the output's day or on another PR they do not")
    func window() {
        let merged = output(.prMerged, "2026-09-30", id: "m")
        let perDay: [String: [ArtifactKey: Double]] = [
            "2026-08-31": [pull12: 600],  // 30 days back, inclusive of the 30th: out.
            "2026-09-01": [pull12: 60],  // the first of the 30 days: in.
            "2026-09-30": [pull12: 120, pull13: 900],
            "2026-10-01": [pull12: 300],  // after the output's day: out.
        ]
        let seconds = OutputViewTime.seconds(outputs: [merged], perDay: perDay, timeZone: zone)
        #expect(seconds["m"] == 180)
    }

    @Test("an issue matches by repo and number")
    func issue() {
        let opened = output(.issueOpened, "2026-09-10", repo: "owner/repo", id: "i")
        let seconds = OutputViewTime.seconds(
            outputs: [opened], perDay: ["2026-09-10": [issue12: 240]], timeZone: zone
        )
        #expect(seconds["i"] == 240)
    }

    @Test("rows sharing a key credit only the latest")
    func latestOnly() {
        let opened = output(.issueOpened, "2026-09-05", id: "first")
        let closed = output(.issueClosed, "2026-09-09", id: "last")
        let seconds = OutputViewTime.seconds(
            outputs: [closed, opened],
            perDay: ["2026-09-05": [issue12: 60], "2026-09-08": [issue12: 60]],
            timeZone: zone
        )
        #expect(seconds["last"] == 120)
        #expect(seconds["first"] == nil)
    }

    @Test("a non-GitHub output gets nothing")
    func nonGitHub() {
        let memo = output(OutputKind(rawValue: "memo_written"), "2026-09-10", repo: nil, number: nil,
                          source: "memo", id: "memo")
        let seconds = OutputViewTime.seconds(
            outputs: [memo], perDay: ["2026-09-10": [pull12: 600]], timeZone: zone
        )
        #expect(seconds.isEmpty)
    }

    @Test("the range reads from 29 days before its first day, and the suffix is in minutes")
    func firstDayAndSuffix() {
        #expect(OutputViewTime.firstDay(from: "2026-09-30", timeZone: zone) == "2026-09-01")
        #expect(OutputViewTime.suffix(seconds: 25 * 60) == " · on your screen 25m")
        #expect(OutputViewTime.suffix(seconds: 0) == "")
        #expect(OutputViewTime.suffix(seconds: 20) == "")
    }
}
