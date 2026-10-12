import Foundation

/// One stretch of the day on one project, or on none, and the rule that decided it (#322).
///
/// Spans never overlap and cover exactly the day accounting's screen and meeting seconds. A span
/// names its rule, never the URL, document, repo path or title behind it.
public struct ProjectSpan: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case screen
        case meeting
    }

    /// What decided a stretch, strongest first. `assignment` is a stretch you claimed, applied
    /// after smoothing; the next eight are evidence tiers; `detour` and `gapFill` are the
    /// smoothing that joined a stretch to its neighbours.
    public enum Rule: String, Codable, Sendable, CaseIterable {
        /// A stretch you assigned with `worklens projects assign` (#324).
        case assignment
        /// A URL prefix you wrote on a project, the longest that matched (#324).
        case ruleUrlPrefix = "rule_url_prefix"
        /// A repo you wrote on a project (#324): a GitHub page on screen or an agent session.
        case ruleRepo = "rule_repo"
        /// A domain on a project (#318, #324): a URL host on screen or a meeting's attendee
        /// domain, the most specific that matched.
        case ruleDomain = "rule_domain"
        /// The company a meeting's attendee domains named (#318).
        case meetingCompany = "meeting_company"
        /// A prompt you typed to a coding agent in a repo the catalog claims (#321).
        case agentRepo = "agent_repo"
        /// A document or PR on screen that a catalog entry claims (#319).
        case resourceKey = "resource_key"
        /// The catalog key the describer picked (#315).
        case projectKey = "project_key"
        /// The describer's free-text hint, folded onto the catalog (#70, #90).
        case projectHint = "project_hint"
        /// One frame between two frames of one project took that project.
        case detour
        /// A short stretch with no frame between two stretches of one project took that project.
        case gapFill = "gap_fill"

        /// The evidence tiers, strongest first.
        public static let tiers: [Rule] = [
            .ruleUrlPrefix, .ruleRepo, .ruleDomain, .meetingCompany, .agentRepo, .resourceKey, .projectKey, .projectHint,
        ]

        var rank: Int { Rule.allCases.firstIndex(of: self) ?? Rule.allCases.count }
    }

    /// Why a stretch has no project.
    public enum Reason: String, Codable, Sendable, CaseIterable {
        /// Nothing on record named a project.
        case noEvidence = "no_evidence"
        /// The frame has no description yet.
        case undescribed
        /// The frame was redacted, so its words name nothing.
        case redacted
        /// A meeting no company was named for.
        case meetingWithoutCompany = "meeting_without_company"
        /// Two pieces of evidence of the same strength named different projects.
        case conflict
    }

    public var start: Date
    public var end: Date
    public var kind: Kind
    /// The project key, or nil when the stretch is unattributed.
    public var project: String?
    public var name: String?
    /// The rule behind most of the span's seconds. Nil on an unattributed span.
    public var rule: Rule?
    /// Seconds per `Rule` raw value; empty on an unattributed span.
    public var secondsByRule: [String: Double]
    /// How many one-frame detours the span absorbed.
    public var absorbed: Int
    /// Why the span has no project. Nil when it has one.
    public var unattributed: Reason?
    /// Keys weaker evidence named inside the span. Counted nowhere.
    public var overridden: [String]?

    public init(
        start: Date, end: Date, kind: Kind, project: String? = nil, name: String? = nil, rule: Rule? = nil,
        secondsByRule: [String: Double] = [:], absorbed: Int = 0, unattributed: Reason? = nil,
        overridden: [String]? = nil
    ) {
        self.start = start
        self.end = end
        self.kind = kind
        self.project = project
        self.name = name
        self.rule = rule
        self.secondsByRule = secondsByRule
        self.absorbed = absorbed
        self.unattributed = unattributed
        self.overridden = overridden
    }

    public var seconds: Double { max(0, end.timeIntervalSince(start)) }

    // A busy day has a couple of hundred spans, so the JSON leaves out what it can: no `name`
    // (`byProject` maps each key to its name), no `secondsByRule` when one rule, the span's
    // `rule`, decided all of it or none did, no `absorbed` when nothing was.
    enum CodingKeys: String, CodingKey {
        case start, end, kind, project, name, rule, secondsByRule, absorbed, unattributed, overridden
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(Date.self, forKey: .start)
        let end = try container.decode(Date.self, forKey: .end)
        let rule = try container.decodeIfPresent(Rule.self, forKey: .rule)
        let project = try container.decodeIfPresent(String.self, forKey: .project)
        let whole = project != nil ? rule.map { [$0.rawValue: max(0, end.timeIntervalSince(start))] } : nil
        self.init(
            start: start,
            end: end,
            kind: try container.decode(Kind.self, forKey: .kind),
            project: project,
            name: try container.decodeIfPresent(String.self, forKey: .name),
            rule: rule,
            secondsByRule: try container.decodeIfPresent([String: Double].self, forKey: .secondsByRule) ?? whole ?? [:],
            absorbed: try container.decodeIfPresent(Int.self, forKey: .absorbed) ?? 0,
            unattributed: try container.decodeIfPresent(Reason.self, forKey: .unattributed),
            overridden: try container.decodeIfPresent([String].self, forKey: .overridden)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(project, forKey: .project)
        try container.encodeIfPresent(rule, forKey: .rule)
        let oneRule = project != nil && secondsByRule.count == 1
            && rule.flatMap { secondsByRule[$0.rawValue] }.map { abs($0 - seconds) < 0.001 } == true
        if !secondsByRule.isEmpty, !oneRule { try container.encode(secondsByRule, forKey: .secondsByRule) }
        if absorbed > 0 { try container.encode(absorbed, forKey: .absorbed) }
        try container.encodeIfPresent(unattributed, forKey: .unattributed)
        try container.encodeIfPresent(overridden, forKey: .overridden)
    }
}

/// Counts over a set of spans: what `worklens projects coverage` prints. Seconds and counts only,
/// never a project key or a name.
public struct SpanCoverage: Codable, Sendable, Equatable {
    public var screenSeconds: Double = 0
    public var screenAttributedSeconds: Double = 0
    /// Unattributed screen seconds by `ProjectSpan.Reason` raw value.
    public var screenUnattributed: [String: Double] = [:]
    public var meetingSeconds: Double = 0
    public var meetingAttributedSeconds: Double = 0
    public var meetingUnattributed: [String: Double] = [:]
    /// Attributed seconds, screen and meeting, by `ProjectSpan.Rule` raw value.
    public var byRule: [String: Double] = [:]
    public var spans = 0
    public var absorbed = 0

    public init() {}

    public static func + (lhs: SpanCoverage, rhs: SpanCoverage) -> SpanCoverage {
        var sum = lhs
        sum.screenSeconds += rhs.screenSeconds
        sum.screenAttributedSeconds += rhs.screenAttributedSeconds
        sum.screenUnattributed.merge(rhs.screenUnattributed, uniquingKeysWith: +)
        sum.meetingSeconds += rhs.meetingSeconds
        sum.meetingAttributedSeconds += rhs.meetingAttributedSeconds
        sum.meetingUnattributed.merge(rhs.meetingUnattributed, uniquingKeysWith: +)
        sum.byRule.merge(rhs.byRule, uniquingKeysWith: +)
        sum.spans += rhs.spans
        sum.absorbed += rhs.absorbed
        return sum
    }
}

/// Turns a day's evidence into project spans (#322). Pure and deterministic: no clock, no
/// database, ties broken by key, and the same input in any order gives the same spans.
///
/// 1. The day accounting's meeting, screen and battery-sparse stretches are the only time spans
///    cover; every other bucket (idle, locked, away, asleep, not running, paused, unexplained) is a
///    hard break nothing joins across.
/// 2. A frame stands for its tick, cut at the next frame. Frame evidence covers that piece;
///    stretch evidence covers its own start and end.
/// 3. Each moment takes its strongest tier. Two projects at that tier are a `conflict`; weaker
///    projects that disagree go to `overridden`. Your rules (#324) are the strongest tiers. In a
///    meeting only a domain rule on its attendees and the meeting's company count, so screen
///    under a meeting counts once, as the meeting.
/// 4. Smoothing: one frame decided by `project_key`, a hint or nothing between two stretches of
///    one project takes it (`detour`); a stretch with no frame of up to `maximumGap` between two
///    stretches of one project takes it (`gap_fill`). A redacted or idle frame is never absorbed.
/// 5. Assignments (#324) claim the screen and meeting seconds under them after smoothing, the
///    newest winning an overlap. Idle and redacted frames keep their reason.
public enum ProjectSpans {
    /// The longest stretch with no frame that smoothing fills: `TimelineWriter.minimumGapTolerance`.
    public static let maximumGap: TimeInterval = TimelineWriter.minimumGapTolerance

    public struct Frame: Sendable, Equatable {
        public var id: String
        public var at: Date
        /// The frame's own interval; nil falls back to `Input.tick`.
        public var interval: TimeInterval?
        public var isDescribed: Bool
        public var isIdle: Bool
        public var isRedacted: Bool

        public init(
            id: String, at: Date, interval: TimeInterval? = nil, isDescribed: Bool = true,
            isIdle: Bool = false, isRedacted: Bool = false
        ) {
            self.id = id
            self.at = at
            self.interval = interval
            self.isDescribed = isDescribed
            self.isIdle = isIdle
            self.isRedacted = isRedacted
        }
    }

    /// One piece of evidence: a project (or, for a meeting, possibly none) over a frame's piece or
    /// over a stretch. New sources append rows; nothing here knows where a row came from.
    public struct Evidence: Sendable, Equatable {
        public enum Scope: Sendable, Equatable {
            case frame(String)
            case stretch(start: Date, end: Date)
        }

        public var scope: Scope
        public var project: String?
        public var name: String?
        public var rule: ProjectSpan.Rule

        public init(scope: Scope, project: String?, name: String? = nil, rule: ProjectSpan.Rule) {
            self.scope = scope
            self.project = project
            self.name = name
            self.rule = rule
        }
    }

    /// A stretch you claimed for one project (#324). It overrides whatever decided the screen
    /// and meeting seconds under it, after smoothing; idle and redacted frames keep their reason.
    public struct Assignment: Sendable, Equatable {
        public var start: Date
        public var end: Date
        public var project: String
        public var name: String?
        /// Higher wins an overlap: the newest assignment.
        public var order: Int

        public init(start: Date, end: Date, project: String, name: String? = nil, order: Int = 0) {
            self.start = start
            self.end = end
            self.project = project
            self.name = name
            self.order = order
        }
    }

    public struct Input: Sendable, Equatable {
        /// The day accounting's spans: covered and hard-break stretches alike.
        public var accounting: [DayAccounting.Span]
        public var frames: [Frame]
        public var evidence: [Evidence]
        /// A frame's tick when it recorded none: `BlockBuilder.tick`'s fallback.
        public var tick: TimeInterval
        public var assignments: [Assignment]

        public init(
            accounting: [DayAccounting.Span], frames: [Frame], evidence: [Evidence], tick: TimeInterval = 60,
            assignments: [Assignment] = []
        ) {
            self.accounting = accounting
            self.frames = frames
            self.evidence = evidence
            self.tick = tick
            self.assignments = assignments
        }
    }

    public struct Policy: Sendable, Equatable {
        public var absorbsDetours: Bool
        public var maximumGap: TimeInterval

        public init(absorbsDetours: Bool, maximumGap: TimeInterval) {
            self.absorbsDetours = absorbsDetours
            self.maximumGap = maximumGap
        }

        public static let `default` = Policy(absorbsDetours: true, maximumGap: ProjectSpans.maximumGap)
        /// Each frame alone, no smoothing: what `byProject` did before #322.
        public static let perFrame = Policy(absorbsDetours: false, maximumGap: 0)
    }

    // MARK: Build

    /// What one elementary stretch was decided as, before smoothing.
    private struct Decision: Equatable {
        var project: String?
        var name: String?
        var rule: ProjectSpan.Rule?
        var reason: ProjectSpan.Reason?
        /// Weaker keys that disagreed.
        var overridden: Set<String> = []
        /// A stretch no frame stands for.
        var frameless = false
        /// Idle or redacted: never absorbed, never walked through.
        var barrier = false
    }

    /// Adjacent stretches with one decision.
    private struct Segment {
        var start: Date
        var end: Date
        var kind: ProjectSpan.Kind
        var decision: Decision
        var secondsByRule: [String: Double]
        var frames: Set<String>
        /// A one-frame detour smoothing gave its neighbours' project.
        var isDetour = false
        var seconds: Double { end.timeIntervalSince(start) }

        var isGap: Bool {
            kind == .screen && decision.project == nil && decision.reason == .noEvidence
                && decision.frameless && !decision.barrier
        }

        /// One frame decided by `project_key`, a hint or nothing.
        var isWeakSingleFrame: Bool {
            guard kind == .screen, frames.count == 1, !decision.barrier, !decision.frameless else { return false }
            if decision.project == nil {
                return decision.reason == .noEvidence || decision.reason == .undescribed
            }
            let weak: Set<String> = [ProjectSpan.Rule.projectKey.rawValue, ProjectSpan.Rule.projectHint.rawValue]
            return secondsByRule.keys.allSatisfy(weak.contains)
        }
    }

    public static func build(_ input: Input, policy: Policy = .default) -> [ProjectSpan] {
        let covered = coveredStretches(input.accounting)
        guard !covered.isEmpty else { return [] }

        let frames = input.frames.sorted { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }
        var pieces: [(start: Date, end: Date, frame: Frame)] = []
        for (index, frame) in frames.enumerated() {
            var end = frame.at.addingTimeInterval(frame.interval ?? input.tick)
            if index + 1 < frames.count { end = min(end, frames[index + 1].at) }
            if end > frame.at { pieces.append((frame.at, end, frame)) }
        }

        var frameEvidence: [String: [Evidence]] = [:]
        var stretchEvidence: [(start: Date, end: Date, evidence: Evidence)] = []
        for row in input.evidence {
            switch row.scope {
            case let .frame(id): frameEvidence[id, default: []].append(row)
            case let .stretch(start, end) where end > start: stretchEvidence.append((start, end, row))
            case .stretch: continue
            }
        }

        var points = Set<Date>()
        for stretch in covered { points.insert(stretch.start); points.insert(stretch.end) }
        for piece in pieces { points.insert(piece.start); points.insert(piece.end) }
        for row in stretchEvidence { points.insert(row.start); points.insert(row.end) }
        let cuts = points.sorted()

        var segments: [Segment] = []
        var coveredIndex = 0
        var pieceIndex = 0
        for index in 0..<max(0, cuts.count - 1) {
            let start = cuts[index], end = cuts[index + 1]
            let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            while coveredIndex < covered.count, covered[coveredIndex].end <= middle { coveredIndex += 1 }
            guard coveredIndex < covered.count, covered[coveredIndex].start <= middle else { continue }
            let kind = covered[coveredIndex].kind
            while pieceIndex < pieces.count, pieces[pieceIndex].end <= middle { pieceIndex += 1 }
            let frame = pieceIndex < pieces.count && pieces[pieceIndex].start <= middle ? pieces[pieceIndex].frame : nil
            var rows = frame.map { frameEvidence[$0.id] ?? [] } ?? []
            rows += stretchEvidence.filter { $0.start <= middle && middle < $0.end }.map(\.evidence)
            let decision = decide(kind: kind, frame: frame, evidence: rows)
            let seconds = end.timeIntervalSince(start)
            if var last = segments.last, last.end == start, last.kind == kind, sameRun(last.decision, decision) {
                last.end = end
                last.decision.overridden.formUnion(decision.overridden)
                if let rule = decision.rule { last.secondsByRule[rule.rawValue, default: 0] += seconds }
                if let frame { last.frames.insert(frame.id) }
                segments[segments.count - 1] = last
            } else {
                segments.append(Segment(
                    start: start, end: end, kind: kind, decision: decision,
                    secondsByRule: decision.rule.map { [$0.rawValue: seconds] } ?? [:],
                    frames: frame.map { [$0.id] } ?? []
                ))
            }
        }

        return merged(assigned(smoothed(segments, policy: policy), input.assignments))
    }

    /// Assignments cut the smoothed segments at their edges and claim the pieces under them, the
    /// highest `order` winning an overlap. Idle and redacted pieces are never claimed.
    private static func assigned(_ segments: [Segment], _ assignments: [Assignment]) -> [Segment] {
        let usable = assignments.filter { $0.end > $0.start }
        guard !usable.isEmpty else { return segments }
        var out: [Segment] = []
        for segment in segments {
            let touching = usable.filter { $0.start < segment.end && $0.end > segment.start }
            guard !segment.decision.barrier, !touching.isEmpty, segment.seconds > 0 else {
                out.append(segment)
                continue
            }
            var cuts: Set<Date> = [segment.start, segment.end]
            for assignment in touching {
                if assignment.start > segment.start { cuts.insert(assignment.start) }
                if assignment.end < segment.end { cuts.insert(assignment.end) }
            }
            let edges = cuts.sorted()
            var detourKept = !segment.isDetour
            for index in 0..<(edges.count - 1) {
                var piece = segment
                piece.start = edges[index]
                piece.end = edges[index + 1]
                let middle = piece.start.addingTimeInterval(piece.seconds / 2)
                let winner = touching
                    .filter { $0.start <= middle && middle < $0.end }
                    .max { $0.order < $1.order }
                if let winner {
                    if let project = piece.decision.project, project != winner.project {
                        piece.decision.overridden.insert(project)
                    }
                    piece.decision.project = winner.project
                    piece.decision.name = winner.name ?? winner.project
                    piece.decision.rule = .assignment
                    piece.decision.reason = nil
                    piece.secondsByRule = [ProjectSpan.Rule.assignment.rawValue: piece.seconds]
                    piece.isDetour = false
                } else {
                    let share = piece.seconds / segment.seconds
                    piece.secondsByRule = segment.secondsByRule.mapValues { $0 * share }
                    piece.isDetour = !detourKept
                    detourKept = true
                }
                out.append(piece)
            }
        }
        return out
    }

    /// The accounting's meeting and screen stretches, sorted, equal neighbours joined.
    private static func coveredStretches(
        _ accounting: [DayAccounting.Span]
    ) -> [(start: Date, end: Date, kind: ProjectSpan.Kind)] {
        var out: [(start: Date, end: Date, kind: ProjectSpan.Kind)] = []
        let sorted = accounting.sorted {
            ($0.start, $0.end, $0.bucket.rawValue) < ($1.start, $1.end, $1.bucket.rawValue)
        }
        for span in sorted where span.end > span.start {
            let kind: ProjectSpan.Kind
            switch span.bucket {
            case .meeting: kind = .meeting
            case .screen, .batterySparse: kind = .screen
            default: continue
            }
            if let last = out.last, last.kind == kind, last.end == span.start {
                out[out.count - 1].end = span.end
            } else if let last = out.last, span.start < last.end {
                // Overlapping input is clipped, so spans never overlap.
                guard span.end > last.end else { continue }
                out.append((last.end, span.end, kind))
            } else {
                out.append((span.start, span.end, kind))
            }
        }
        return out
    }

    /// Two elementary decisions that belong to one segment.
    private static func sameRun(_ a: Decision, _ b: Decision) -> Bool {
        a.project == b.project && a.reason == b.reason && a.frameless == b.frameless && a.barrier == b.barrier
    }

    /// One moment's decision: the strongest tier present wins.
    private static func decide(kind: ProjectSpan.Kind, frame: Frame?, evidence: [Evidence]) -> Decision {
        if kind == .screen, let frame, frame.isRedacted {
            return Decision(reason: .redacted, barrier: true)
        }
        if kind == .screen, let frame, frame.isIdle {
            return Decision(reason: .noEvidence, barrier: true)
        }
        // In a meeting, only a domain rule on the meeting itself and the meeting's company
        // decide. On screen, a domain rule counts only from the frame's own URL.
        let usable = evidence.filter { kind == .meeting || $0.rule != .meetingCompany }
        func decides(_ row: Evidence) -> Bool {
            let onStretch: Bool
            if case .stretch = row.scope { onStretch = true } else { onStretch = false }
            switch (kind, row.rule) {
            case (.meeting, .meetingCompany): return true
            case (.meeting, .ruleDomain): return onStretch
            case (.meeting, _): return false
            case (.screen, .ruleDomain): return !onStretch
            case (.screen, _): return true
            }
        }

        func keys(_ rows: [Evidence]) -> Set<String> { Set(rows.compactMap(\.project)) }
        func weaker(than rule: ProjectSpan.Rule) -> Set<String> {
            keys(usable.filter { $0.rule.rank > rule.rank })
        }

        for tier in ProjectSpan.Rule.tiers {
            let rows = usable.filter { $0.rule == tier && decides($0) }
            let named = keys(rows)
            if named.count > 1 {
                return Decision(reason: .conflict, overridden: weaker(than: tier))
            }
            if let key = named.first {
                let name = rows.filter { $0.project == key }.compactMap(\.name).min() ?? key
                var overridden = weaker(than: tier)
                overridden.remove(key)
                return Decision(project: key, name: name, rule: tier, overridden: overridden)
            }
        }
        if kind == .meeting {
            return Decision(reason: .meetingWithoutCompany, overridden: keys(usable))
        }
        guard let frame else { return Decision(reason: .noEvidence, frameless: true) }
        return Decision(reason: frame.isDescribed ? .noEvidence : .undescribed)
    }

    /// Detours and short gaps between two stretches of one project take that project. Segments
    /// are visited in time order and the left neighbour is read as already smoothed, so in
    /// `a b a b a` both `b`s are detours and the middle `a` never becomes one.
    private static func smoothed(_ segments: [Segment], policy: Policy) -> [Segment] {
        var result = segments

        func absorb(_ index: Int, into neighbour: Segment, rule: ProjectSpan.Rule) {
            var segment = result[index]
            if let project = segment.decision.project { segment.decision.overridden.insert(project) }
            segment.decision.project = neighbour.decision.project
            segment.decision.name = neighbour.decision.name
            segment.decision.rule = rule
            segment.decision.reason = nil
            segment.secondsByRule = [rule.rawValue: segment.seconds]
            result[index] = segment
        }

        /// The first segment past a chain of short gaps, walking from `index` by `step`, with the
        /// gaps walked through. Nil when the chain breaks or the gaps run past `maximumGap`.
        func neighbour(of index: Int, step: Int) -> (index: Int, gaps: [Int])? {
            var edge = step > 0 ? segments[index].end : segments[index].start
            var gaps: [Int] = []
            var gapSeconds = 0.0
            var cursor = index + step
            while cursor >= 0, cursor < segments.count {
                let segment = segments[cursor]
                let touches = step > 0 ? segment.start == edge : segment.end == edge
                guard touches, segment.kind == .screen else { return nil }
                guard segment.isGap else { return (cursor, gaps) }
                gapSeconds += segment.seconds
                guard gapSeconds <= policy.maximumGap else { return nil }
                gaps.append(cursor)
                edge = step > 0 ? segment.end : segment.start
                cursor += step
            }
            return nil
        }

        if policy.absorbsDetours {
            for index in segments.indices where segments[index].isWeakSingleFrame {
                guard let left = neighbour(of: index, step: -1), let right = neighbour(of: index, step: 1)
                else { continue }
                let before = result[left.index], after = segments[right.index]
                guard let project = before.decision.project, after.decision.project == project,
                      result[index].decision.project != project
                else { continue }
                absorb(index, into: before, rule: .detour)
                result[index].isDetour = true
                for gap in left.gaps + right.gaps where result[gap].decision.project == nil {
                    absorb(gap, into: before, rule: .gapFill)
                }
            }
        }
        for index in result.indices where segments[index].isGap && result[index].decision.project == nil {
            guard result[index].seconds <= policy.maximumGap, index > 0, index + 1 < result.count else { continue }
            let before = result[index - 1], after = result[index + 1]
            guard before.end == result[index].start, after.start == result[index].end,
                  let project = before.decision.project, after.decision.project == project
            else { continue }
            absorb(index, into: before, rule: .gapFill)
        }
        return result
    }

    /// Adjacent segments of one kind and one project (or one reason) joined into spans.
    private static func merged(_ segments: [Segment]) -> [ProjectSpan] {
        var spans: [ProjectSpan] = []
        var overridden: [Set<String>] = []
        for segment in segments {
            let detours = segment.isDetour ? 1 : 0
            if var last = spans.last, last.end == segment.start, last.kind == segment.kind,
               last.project == segment.decision.project,
               segment.decision.project != nil || last.unattributed == segment.decision.reason {
                last.end = segment.end
                last.secondsByRule.merge(segment.secondsByRule, uniquingKeysWith: +)
                last.absorbed += detours
                spans[spans.count - 1] = last
                overridden[overridden.count - 1].formUnion(segment.decision.overridden)
            } else {
                spans.append(ProjectSpan(
                    start: segment.start, end: segment.end, kind: segment.kind,
                    project: segment.decision.project, name: segment.decision.name,
                    secondsByRule: segment.decision.project == nil ? [:] : segment.secondsByRule,
                    absorbed: detours,
                    unattributed: segment.decision.project == nil ? (segment.decision.reason ?? .noEvidence) : nil
                ))
                overridden.append(segment.decision.overridden)
            }
        }
        for index in spans.indices {
            var others = overridden[index]
            if let project = spans[index].project { others.remove(project) }
            spans[index].overridden = others.isEmpty ? nil : others.sorted()
            spans[index].rule = dominantRule(spans[index].secondsByRule)
        }
        return spans
    }

    /// The rule behind the most seconds, the stronger one on a tie.
    private static func dominantRule(_ secondsByRule: [String: Double]) -> ProjectSpan.Rule? {
        var best: (rule: ProjectSpan.Rule, seconds: Double)?
        for rule in ProjectSpan.Rule.allCases {
            guard let seconds = secondsByRule[rule.rawValue] else { continue }
            if seconds > (best?.seconds ?? -1) { best = (rule, seconds) }
        }
        return best?.rule
    }

    // MARK: Reading

    /// The project covering most of `[start, end)`, ties broken by key. Nil when unattributed
    /// time covers most of it, or no span touches it. Stats threads and timeline headings both
    /// read a block's project through this, so the two always agree.
    public static func project(
        from start: Date, to end: Date, in spans: [ProjectSpan]
    ) -> (key: String, name: String)? {
        var seconds: [String: Double] = [:]
        var names: [String: String] = [:]
        var unattributed = 0.0
        for span in spans where span.end > start && span.start < end {
            let overlap = min(span.end, end).timeIntervalSince(max(span.start, start))
            guard overlap > 0 else { continue }
            if let key = span.project {
                seconds[key, default: 0] += overlap
                names[key] = min(names[key] ?? span.name ?? key, span.name ?? key)
            } else {
                unattributed += overlap
            }
        }
        guard let best = seconds.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }),
              best.value > unattributed
        else { return nil }
        return (best.key, names[best.key] ?? best.key)
    }

    /// Seconds by kind, by rule and by reason. Counts only.
    public static func coverage(_ spans: [ProjectSpan]) -> SpanCoverage {
        var coverage = SpanCoverage()
        for span in spans {
            coverage.spans += 1
            coverage.absorbed += span.absorbed
            let attributed = span.project != nil
            switch span.kind {
            case .screen:
                coverage.screenSeconds += span.seconds
                if attributed {
                    coverage.screenAttributedSeconds += span.seconds
                } else {
                    coverage.screenUnattributed[(span.unattributed ?? .noEvidence).rawValue, default: 0] += span.seconds
                }
            case .meeting:
                coverage.meetingSeconds += span.seconds
                if attributed {
                    coverage.meetingAttributedSeconds += span.seconds
                } else {
                    coverage.meetingUnattributed[(span.unattributed ?? .noEvidence).rawValue, default: 0] += span.seconds
                }
            }
            if attributed { coverage.byRule.merge(span.secondsByRule, uniquingKeysWith: +) }
        }
        return coverage
    }
}
