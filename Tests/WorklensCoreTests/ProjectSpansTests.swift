import Foundation
import Testing
@testable import WorklensCore

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func at(_ minute: Double) -> Date { t0.addingTimeInterval(minute * 60) }

private func covered(_ from: Double, _ to: Double, _ bucket: DayAccounting.Bucket = .screen) -> DayAccounting.Span {
    DayAccounting.Span(start: at(from), end: at(to), bucket: bucket)
}

/// Frames one minute apart from `from`, ids `f<minute>`.
private func frames(_ from: Int, count: Int) -> [ProjectSpans.Frame] {
    (0..<count).map { ProjectSpans.Frame(id: "f\(from + $0)", at: at(Double(from + $0)), interval: 60) }
}

private func hint(_ frame: Int, _ project: String) -> ProjectSpans.Evidence {
    ProjectSpans.Evidence(scope: .frame("f\(frame)"), project: project, name: project, rule: .projectHint)
}

private func stretch(
    _ from: Double, _ to: Double, _ project: String?, _ rule: ProjectSpan.Rule
) -> ProjectSpans.Evidence {
    ProjectSpans.Evidence(scope: .stretch(start: at(from), end: at(to)), project: project, name: project, rule: rule)
}

/// Five screen minutes with one frame each, hinted with `pattern` (nil for no hint).
private func row(_ pattern: [String?], accounting: [DayAccounting.Span]? = nil) -> ProjectSpans.Input {
    ProjectSpans.Input(
        accounting: accounting ?? [covered(0, Double(pattern.count))],
        frames: frames(0, count: pattern.count),
        evidence: pattern.enumerated().compactMap { index, project in project.map { hint(index, $0) } }
    )
}

@Suite("Project spans (#322)")
struct ProjectSpansTests {
    @Test func aDetourBetweenTwoStretchesOfOneProjectIsAbsorbed() {
        let spans = ProjectSpans.build(row(["a", "a", "b", "a", "a"]))
        #expect(spans.count == 1)
        #expect(spans[0].project == "a")
        #expect(spans[0].absorbed == 1)
        #expect(spans[0].overridden == ["b"])
        #expect(spans[0].secondsByRule["detour"] == 60)
        #expect(spans[0].rule == .projectHint)
    }

    @Test func alternatingDetoursAllGoToTheProjectTheyInterrupt() {
        let five = ProjectSpans.build(row(["a", "b", "a", "b", "a"]))
        #expect(five.map(\.project) == ["a"])
        #expect(five.first?.absorbed == 2)
        let four = ProjectSpans.build(row(["a", "b", "a", "b"]))
        #expect(four.map(\.project) == ["a", "b"])
        #expect(four.first?.absorbed == 1)
        #expect(four.first?.seconds == 180)
    }

    @Test func aFrameWithNothingBetweenTwoFramesOfOneProjectIsAbsorbed() {
        let spans = ProjectSpans.build(row(["a", nil, "a"]))
        #expect(spans.count == 1)
        #expect(spans[0].project == "a")
        #expect(spans[0].absorbed == 1)
    }

    @Test func aFrameDecidedByAResourceKeyStays() {
        var input = row(["a", "a", nil, "a", "a"])
        input.evidence.append(ProjectSpans.Evidence(scope: .frame("f2"), project: "b", rule: .resourceKey))
        let spans = ProjectSpans.build(input)
        #expect(spans.map(\.project) == ["a", "b", "a"])
        #expect(spans[1].rule == .resourceKey)
        #expect(spans.allSatisfy { $0.absorbed == 0 })
    }

    @Test func twoFramesOfAnotherProjectAreNotADetour() {
        let spans = ProjectSpans.build(row(["a", "b", "b", "a"]))
        #expect(spans.map(\.project) == ["a", "b", "a"])
    }

    @Test(arguments: [DayAccounting.Bucket.idle, .locked, .asleep, .notRunning, .away, .paused, .unexplained])
    func aHardBreakBetweenTwoFramesOfOneProjectSplitsThem(bucket: DayAccounting.Bucket) {
        let input = ProjectSpans.Input(
            accounting: [covered(0, 2), covered(2, 3, bucket), covered(3, 5)],
            frames: frames(0, count: 2) + frames(3, count: 2),
            evidence: [hint(0, "a"), hint(1, "a"), hint(3, "a"), hint(4, "a")]
        )
        let spans = ProjectSpans.build(input)
        #expect(spans.count == 2)
        #expect(spans.allSatisfy { $0.project == "a" && $0.absorbed == 0 })
        #expect(spans[0].end == at(2))
        #expect(spans[1].start == at(3))
    }

    @Test func aRedactedOrIdleFrameBetweenTwoFramesOfOneProjectSplitsThem() {
        for flag in ["redacted", "idle"] {
            var input = row(["a", "a", nil, "a", "a"])
            input.frames[2] = ProjectSpans.Frame(
                id: "f2", at: at(2), interval: 60, isIdle: flag == "idle", isRedacted: flag == "redacted"
            )
            let spans = ProjectSpans.build(input)
            #expect(spans.map(\.project) == ["a", nil, "a"], "\(flag)")
            #expect(spans[1].unattributed == (flag == "redacted" ? .redacted : .noEvidence))
        }
    }

    @Test func aShortGapBetweenTwoFramesOfOneProjectIsFilledAndALongOneIsNot() throws {
        // Frames at 0, 2, 3 and 8, each standing for a minute: a 60 s gap and a 240 s one.
        let input = ProjectSpans.Input(
            accounting: [covered(0, 9)],
            frames: [0, 2, 3, 8].map { ProjectSpans.Frame(id: "f\($0)", at: at(Double($0)), interval: 60) },
            evidence: [hint(0, "a"), hint(2, "a"), hint(3, "a"), hint(8, "a")]
        )
        let spans = ProjectSpans.build(input)
        try #require(spans.map(\.project) == ["a", nil, "a"])
        #expect(spans[0].secondsByRule["gap_fill"] == 60)
        #expect(spans[1].unattributed == .noEvidence)
        #expect(spans[1].seconds == 240)
    }

    @Test func aMeetingOfOneCompanyOverFramesOfAnotherCountsOnceAsTheMeeting() {
        let input = ProjectSpans.Input(
            accounting: [covered(0, 2), covered(2, 5, .meeting)],
            frames: frames(0, count: 5),
            evidence: (0..<5).map { hint($0, "y") } + [stretch(2, 5, "x", .meetingCompany)]
        )
        let spans = ProjectSpans.build(input)
        #expect(spans.count == 2)
        #expect(spans[1].kind == .meeting)
        #expect(spans[1].project == "x")
        #expect(spans[1].rule == .meetingCompany)
        #expect(spans[1].overridden == ["y"])
        #expect(spans[1].seconds == 180)
        let total = spans.reduce(0) { $0 + $1.seconds }
        #expect(total == 300)
    }

    @Test func aMeetingWithoutACompanyOrWithTwoIsUnattributed() {
        let none = ProjectSpans.build(ProjectSpans.Input(
            accounting: [covered(0, 30, .meeting)], frames: [],
            evidence: [stretch(0, 30, nil, .meetingCompany)]
        ))
        #expect(none.count == 1)
        #expect(none[0].unattributed == .meetingWithoutCompany)

        let two = ProjectSpans.build(ProjectSpans.Input(
            accounting: [covered(0, 30, .meeting)], frames: [],
            evidence: [stretch(0, 30, "x", .meetingCompany), stretch(10, 20, "z", .meetingCompany)]
        ))
        #expect(two.map(\.project) == ["x", nil, "x"])
        #expect(two[1].unattributed == .conflict)
    }

    @Test func anAssignmentBeatsEveryOtherTier() {
        let input = ProjectSpans.Input(
            accounting: [covered(0, 2), covered(2, 4, .meeting)],
            frames: frames(0, count: 4),
            evidence: [
                hint(0, "h"), ProjectSpans.Evidence(scope: .frame("f1"), project: "k", rule: .projectKey),
                ProjectSpans.Evidence(scope: .frame("f0"), project: "r", rule: .resourceKey),
                stretch(0, 4, "agent", .agentRepo), stretch(2, 4, "x", .meetingCompany),
                ProjectSpans.Evidence(scope: .frame("f0"), project: "u", rule: .ruleUrlPrefix),
                stretch(2, 4, "d", .ruleDomain),
            ],
            assignments: [ProjectSpans.Assignment(start: at(0), end: at(4), project: "mine")]
        )
        let spans = ProjectSpans.build(input)
        #expect(spans.allSatisfy { $0.project == "mine" && $0.rule == .assignment })
        #expect(spans.count == 2)
        #expect(spans[0].overridden == ["agent", "h", "k", "r", "u"])
        #expect(spans[1].overridden == ["agent", "d", "x"])
    }

    @Test func rulesBeatWhatWorklensWorkedOutUrlPrefixFirst() {
        var input = row(["a", "a", "a"])
        input.evidence += [
            ProjectSpans.Evidence(scope: .frame("f0"), project: "dom", rule: .ruleDomain),
            ProjectSpans.Evidence(scope: .frame("f1"), project: "dom", rule: .ruleDomain),
            ProjectSpans.Evidence(scope: .frame("f1"), project: "repo", rule: .ruleRepo),
            ProjectSpans.Evidence(scope: .frame("f2"), project: "repo", rule: .ruleRepo),
            ProjectSpans.Evidence(scope: .frame("f2"), project: "url", rule: .ruleUrlPrefix),
            ProjectSpans.Evidence(scope: .frame("f0"), project: "res", rule: .resourceKey),
        ]
        let spans = ProjectSpans.build(input)
        #expect(spans.map(\.project) == ["dom", "repo", "url"])
        #expect(spans.map(\.rule) == [.ruleDomain, .ruleRepo, .ruleUrlPrefix])
    }

    @Test func aDomainRuleDecidesAMeetingOnlyFromItsAttendees() {
        let input = ProjectSpans.Input(
            accounting: [covered(0, 4, .meeting)],
            frames: frames(0, count: 4),
            evidence: [
                stretch(0, 4, "company", .meetingCompany),
                // A host on screen during the call names nothing about the call.
                ProjectSpans.Evidence(scope: .frame("f0"), project: "site", rule: .ruleDomain),
                stretch(2, 4, "rule", .ruleDomain),
            ]
        )
        let spans = ProjectSpans.build(input)
        #expect(spans.map(\.project) == ["company", "rule"])
        #expect(spans.map(\.rule) == [.meetingCompany, .ruleDomain])
    }

    @Test func aStretchDomainRuleDoesNotDecideScreen() {
        var input = row([nil, nil])
        input.evidence.append(stretch(0, 2, "rule", .ruleDomain))
        #expect(ProjectSpans.build(input).allSatisfy { $0.project == nil })
    }

    @Test func theNewerOverlappingAssignmentWins() {
        var input = row(["a", "a", "a", "a", "a", "a"])
        input.assignments = [
            ProjectSpans.Assignment(start: at(1), end: at(4), project: "new", order: 2),
            ProjectSpans.Assignment(start: at(0), end: at(5), project: "old", order: 1),
        ]
        let spans = ProjectSpans.build(input)
        #expect(spans.map(\.project) == ["old", "new", "old", "a"])
        #expect(spans.map(\.seconds) == [60, 180, 60, 60])
        #expect(spans[0].rule == .assignment)
        #expect(spans[3].rule == .projectHint)
    }

    @Test func anAssignmentNeverClaimsIdleOrRedactedFramesOrUncoveredTime() {
        var input = ProjectSpans.Input(
            accounting: [covered(0, 3), covered(3, 4, .idle), covered(4, 5, .locked), covered(5, 6)],
            frames: [
                ProjectSpans.Frame(id: "f0", at: at(0), interval: 60),
                ProjectSpans.Frame(id: "f1", at: at(1), interval: 60, isIdle: true),
                ProjectSpans.Frame(id: "f2", at: at(2), interval: 60, isRedacted: true),
                ProjectSpans.Frame(id: "f5", at: at(5), interval: 60),
            ],
            evidence: []
        )
        input.assignments = [ProjectSpans.Assignment(start: at(0), end: at(6), project: "mine")]
        let spans = ProjectSpans.build(input)
        #expect(spans.map(\.project) == ["mine", nil, nil, "mine"])
        #expect(spans.map(\.unattributed) == [nil, .noEvidence, .redacted, nil])
        #expect(spans.reduce(0) { $0 + $1.seconds } == 240)
    }

    @Test func anAssignmentCutsAStretchAndKeepsTheRestOfItsRules() {
        var input = row(["a", "a", "a", "a"])
        input.assignments = [ProjectSpans.Assignment(start: at(1.5), end: at(2.5), project: "mine")]
        let spans = ProjectSpans.build(input)
        #expect(spans.map(\.project) == ["a", "mine", "a"])
        #expect(spans.map(\.seconds) == [90, 60, 90])
        #expect(spans[0].secondsByRule == ["project_hint": 90])
    }

    @Test func eachTierBeatsTheOnesBelowIt() {
        let order: [ProjectSpan.Rule] = [.agentRepo, .resourceKey, .projectKey, .projectHint]
        for (index, strong) in order.enumerated() {
            for weak in order.dropFirst(index + 1) {
                func row(_ rule: ProjectSpan.Rule, _ key: String) -> ProjectSpans.Evidence {
                    rule == .agentRepo
                        ? stretch(0, 1, key, rule)
                        : ProjectSpans.Evidence(scope: .frame("f0"), project: key, rule: rule)
                }
                let spans = ProjectSpans.build(ProjectSpans.Input(
                    accounting: [covered(0, 1)], frames: frames(0, count: 1),
                    evidence: [row(weak, "weak"), row(strong, "strong")]
                ))
                #expect(spans.map(\.project) == ["strong"], "\(strong) over \(weak)")
            }
        }
    }

    @Test func noFramesAndNoEvidenceIsOneUnattributedSpan() {
        let spans = ProjectSpans.build(ProjectSpans.Input(accounting: [covered(0, 10)], frames: [], evidence: []))
        #expect(spans == [ProjectSpan(start: at(0), end: at(10), kind: .screen, unattributed: .noEvidence)])
        let undescribed = ProjectSpans.build(ProjectSpans.Input(
            accounting: [covered(0, 1)],
            frames: [ProjectSpans.Frame(id: "f0", at: at(0), interval: 60, isDescribed: false)],
            evidence: []
        ))
        #expect(undescribed.map(\.unattributed) == [.undescribed])
    }

    @Test func projectOfABlockIsTheOneCoveringMostOfIt() {
        let spans = [
            ProjectSpan(start: at(0), end: at(3), kind: .screen, project: "a", name: "A"),
            ProjectSpan(start: at(3), end: at(5), kind: .screen, unattributed: .noEvidence),
            ProjectSpan(start: at(5), end: at(6), kind: .screen, project: "b", name: "B"),
        ]
        #expect(ProjectSpans.project(from: at(0), to: at(6), in: spans)?.key == "a")
        #expect(ProjectSpans.project(from: at(3), to: at(6), in: spans) == nil)
        #expect(ProjectSpans.project(from: at(4.5), to: at(6), in: spans)?.name == "B")
    }

    @Test func coverageCountsByKindRuleAndReason() {
        let spans = ProjectSpans.build(row(["a", "a", "b", "a", "a", nil, nil]))
        let coverage = ProjectSpans.coverage(spans)
        #expect(coverage.screenSeconds == 420)
        #expect(coverage.screenAttributedSeconds == 300)
        #expect(coverage.screenUnattributed == ["no_evidence": 120])
        #expect(coverage.byRule == ["project_hint": 240, "detour": 60])
        #expect(coverage.absorbed == 1)
    }

    @Test func jsonLeavesOutWhatIsEmptyAndReadsBackTheSame() throws {
        let spans = ProjectSpans.build(row(["a", "a", "b", "a", "a", nil, nil]))
        let data = try JSONEncoder().encode(spans)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.components(separatedBy: "secondsByRule").count == 2)
        #expect(json.components(separatedBy: "absorbed").count == 2)
        #expect(!json.contains("name"))
        let unnamed = spans.map { span -> ProjectSpan in
            var span = span
            span.name = nil
            return span
        }
        #expect(try JSONDecoder().decode([ProjectSpan].self, from: data) == unnamed)

        let whole = ProjectSpans.build(row(["a", "a"]))
        let wholeJSON = String(decoding: try JSONEncoder().encode(whole), as: UTF8.self)
        #expect(!wholeJSON.contains("secondsByRule"))
        #expect(try JSONDecoder().decode([ProjectSpan].self, from: Data(wholeJSON.utf8)).first?.secondsByRule
            == ["project_hint": 120])
    }

    @Test func perFramePolicyAbsorbsNothing() {
        let spans = ProjectSpans.build(row(["a", "b", "a"]), policy: .perFrame)
        #expect(spans.map(\.project) == ["a", "b", "a"])
    }

    /// A seeded generator, so a failure reproduces.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    @Test(arguments: 1...40)
    func spansAreSortedDisjointSumToCoveredAndIgnoreInputOrder(seed: Int) {
        var random = Seeded(state: UInt64(seed))
        let buckets: [DayAccounting.Bucket] = [.screen, .screen, .screen, .meeting, .batterySparse, .idle, .locked]
        var accounting: [DayAccounting.Span] = []
        var cursor = 0.0
        while cursor < 240 {
            let length = Double(Int.random(in: 1...30, using: &random))
            accounting.append(covered(cursor, cursor + length, buckets.randomElement(using: &random)!))
            cursor += length
        }
        var frames: [ProjectSpans.Frame] = []
        var evidence: [ProjectSpans.Evidence] = []
        var minute = 0.0
        while minute < 240 {
            let id = "f\(frames.count)"
            let roll = Int.random(in: 0..<10, using: &random)
            frames.append(ProjectSpans.Frame(
                id: id, at: at(minute), interval: [60, 60, 300].randomElement(using: &random),
                isDescribed: roll != 0, isIdle: roll == 1, isRedacted: roll == 2
            ))
            if roll > 3 {
                let rule: ProjectSpan.Rule = [.projectHint, .projectKey, .resourceKey].randomElement(using: &random)!
                evidence.append(ProjectSpans.Evidence(
                    scope: .frame(id), project: ["a", "b", "c"].randomElement(using: &random)!, rule: rule
                ))
            }
            minute += Double(Int.random(in: 1...4, using: &random)) * Double.random(in: 0.9...1.1, using: &random)
        }
        for _ in 0..<6 {
            let start = Double(Int.random(in: 0..<240, using: &random))
            let rule: ProjectSpan.Rule = [.meetingCompany, .agentRepo, .ruleRepo].randomElement(using: &random)!
            evidence.append(stretch(
                start, start + Double(Int.random(in: 1...40, using: &random)),
                ["a", "b", "x", nil].randomElement(using: &random)!, rule
            ))
        }
        let input = ProjectSpans.Input(accounting: accounting, frames: frames, evidence: evidence)
        let spans = ProjectSpans.build(input)

        for (left, right) in zip(spans, spans.dropFirst()) { #expect(left.end <= right.start) }
        #expect(spans.allSatisfy { $0.end > $0.start })
        #expect(spans.allSatisfy { ($0.project == nil) == ($0.unattributed != nil) })
        let coveredSeconds = accounting
            .filter { [.screen, .meeting, .batterySparse].contains($0.bucket) }
            .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let spanSeconds = spans.reduce(0) { $0 + $1.seconds }
        #expect(abs(spanSeconds - coveredSeconds) < 0.001)
        for span in spans where span.project != nil {
            #expect(abs(span.secondsByRule.values.reduce(0, +) - span.seconds) < 0.001)
        }

        let shuffled = ProjectSpans.Input(
            accounting: accounting.shuffled(using: &random),
            frames: frames.shuffled(using: &random),
            evidence: evidence.shuffled(using: &random)
        )
        #expect(ProjectSpans.build(shuffled) == spans)
    }
}
