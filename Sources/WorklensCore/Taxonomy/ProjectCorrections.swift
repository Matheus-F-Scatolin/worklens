import Foundation

/// What a rule or an assignment would move (#324): the allocator run per affected day without
/// and with the change, diffed. Pure; `ProjectSpanService.comparisons` does the reading.
///
/// Minutes and days, and the projects time leaves and lands on. Never a URL, a title or a host:
/// the one value a change prints is the rule you typed.
public enum ProjectCorrections {
    /// One day's spans as they are and as they would be.
    public struct DayComparison: Sendable, Equatable {
        public var day: String
        public var before: [ProjectSpan]
        public var after: [ProjectSpan]

        public init(day: String, before: [ProjectSpan], after: [ProjectSpan]) {
            self.day = day
            self.before = before
            self.after = after
        }
    }

    /// Minutes on one project, or on none (`project` nil: Unattributed).
    public struct Share: Codable, Sendable, Equatable {
        public var project: String?
        public var name: String
        public var minutes: Int
    }

    public struct Preview: Codable, Sendable, Equatable {
        /// Screen and meeting minutes whose project changes: the sum of `to`.
        public var minutesMoved: Int
        /// The days those minutes are on, oldest first.
        public var days: [String]
        /// How many days were run.
        public var daysChecked: Int
        /// Where the moved minutes were, most first.
        public var from: [Share]
        /// Where they go, most first.
        public var to: [Share]

        enum CodingKeys: String, CodingKey {
            case minutesMoved = "minutes_moved"
            case days
            case daysChecked = "days_checked"
            case from, to
        }
    }

    public static let unattributedName = "Unattributed"

    public static func preview(_ comparisons: [DayComparison]) -> Preview {
        var days: [String] = []
        var from: [String?: Double] = [:]
        var to: [String?: Double] = [:]
        var names: [String: String] = [:]
        for comparison in comparisons {
            var dayMoved = 0.0
            var points = Set<Date>()
            for span in comparison.before + comparison.after {
                points.insert(span.start)
                points.insert(span.end)
                if let key = span.project { names[key] = names[key] ?? span.name }
            }
            let cuts = points.sorted()
            for index in 0..<max(0, cuts.count - 1) {
                let start = cuts[index], end = cuts[index + 1]
                let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
                let old = covering(middle, comparison.before)
                let new = covering(middle, comparison.after)
                guard old != nil || new != nil, old?.project != new?.project else { continue }
                let seconds = end.timeIntervalSince(start)
                dayMoved += seconds
                from[old?.project, default: 0] += seconds
                to[new?.project, default: 0] += seconds
            }
            if dayMoved > 0 {
                days.append(comparison.day)
            }
        }
        func shares(_ seconds: [String?: Double]) -> [Share] {
            seconds.map { key, value in
                Share(
                    project: key, name: key.map { names[$0] ?? $0 } ?? unattributedName,
                    minutes: minutes(value)
                )
            }
            .filter { $0.minutes > 0 }
            .sorted { ($0.minutes, $1.name) > ($1.minutes, $0.name) }
        }
        // The headline is the sum of the rounded `to` shares, so those add up to it exactly;
        // the `from` shares are rounded on their own and may differ from it by a minute or so.
        let toShares = shares(to)
        return Preview(
            minutesMoved: toShares.reduce(0) { $0 + $1.minutes }, days: days.sorted(),
            daysChecked: comparisons.count, from: shares(from), to: toShares
        )
    }

    private static func covering(_ moment: Date, _ spans: [ProjectSpan]) -> ProjectSpan? {
        spans.first { $0.start <= moment && moment < $0.end }
    }

    private static func minutes(_ seconds: Double) -> Int { Int((seconds / 60).rounded()) }

    // MARK: Printing

    /// The change a preview is about, as `--json` prints it.
    public struct Change: Codable, Sendable, Equatable {
        /// `rule add`, `rule remove`, `assign` or `unassign`.
        public var action: String
        public var project: String
        public var kind: ProjectRuleKind?
        public var value: String?
        public var assignment: ProjectAssignment?

        public init(
            action: String, project: String, kind: ProjectRuleKind? = nil, value: String? = nil,
            assignment: ProjectAssignment? = nil
        ) {
            self.action = action
            self.project = project
            self.kind = kind
            self.value = value
            self.assignment = assignment
        }
    }

    /// `{change, preview, saved}`: what `rule add|remove --json` and `assign --json` print.
    public struct Report: Codable, Sendable, Equatable {
        public var change: Change
        public var preview: Preview
        public var saved: Bool

        public init(change: Change, preview: Preview, saved: Bool) {
            self.change = change
            self.preview = preview
            self.saved = saved
        }
    }

    /// The lines the CLI prints, `en_US_POSIX`, in the shape the other `projects` writes print.
    public static func lines(_ report: Report, timeZone: TimeZone = .current) -> [String] {
        let change = report.change
        let preview = report.preview
        var lines: [String] = []
        if let kind = change.kind, let value = change.value {
            lines.append("\(change.action == "rule remove" ? "remove" : "rule")      \(kind.flag) \(value) on \(change.project)")
        } else if let assignment = change.assignment {
            let span = "\(stamp(assignment.from, timeZone)) to \(stamp(assignment.to, timeZone))"
            let id = report.saved || change.action == "unassign" ? " (id \(assignment.id))" : ""
            lines.append("\(change.action == "unassign" ? "unassign" : "assign")    \(span) on \(change.project)\(id)")
        }
        let verb = report.saved ? "moved" : "would move"
        let dayWord = preview.days.count == 1 ? "day" : "days"
        lines.append("minutes   \(verb) \(preview.minutesMoved) min on \(preview.days.count) \(dayWord), of \(preview.daysChecked) checked")
        if change.kind == .repo {
            // The timesheet's agent column follows repo rules too, but the preview diffs only
            // screen and meeting spans, so say so rather than under-report what moves.
            lines.append("agent     agent minutes in this repo move with it too; not counted above")
        }
        func shareLines(_ label: String, _ shares: [Share]) {
            for (index, share) in shares.enumerated() {
                lines.append("\(index == 0 ? label : "          ")\(share.name)  \(share.minutes) min")
            }
        }
        shareLines("from      ", preview.from)
        shareLines("to        ", preview.to)
        lines.append("status    \(report.saved ? "saved" : "dry run, nothing written")")
        return lines
    }

    /// One rule as `rule list --json` prints it.
    public struct RuleRow: Codable, Sendable, Equatable {
        public var project: String
        public var kind: ProjectRuleKind
        public var value: String
    }

    /// `{rules, assignments}`: what `rule list --json` prints.
    public struct RuleList: Codable, Sendable, Equatable {
        public var rules: [RuleRow]
        public var assignments: [ProjectAssignment]
    }

    /// Every rule on the catalog, by project then kind, and every assignment, oldest first.
    public static func ruleList(_ projects: [ProjectEntry], assignments: [ProjectAssignment]) -> RuleList {
        let rows = projects.sorted { $0.key < $1.key }.flatMap { entry in
            ProjectRuleKind.allCases.flatMap { kind in
                kind.values(on: entry).map { RuleRow(project: entry.key, kind: kind, value: $0) }
            }
        }
        return RuleList(rules: rows, assignments: assignments.sorted { ($0.from, $0.id) < ($1.from, $1.id) })
    }

    public static func lines(_ list: RuleList, timeZone: TimeZone = .current) -> [String] {
        var lines = ["Rules"]
        lines += list.rules.isEmpty
            ? ["  none yet: `worklens projects rule add --domain <domain> --project <key> --dry-run`"]
            : list.rules.map { "  \($0.project)  \($0.kind.flag) \($0.value)" }
        lines.append("")
        lines.append("Assignments")
        lines += list.assignments.isEmpty
            ? ["  none yet: `worklens projects assign --from <time> --to <time> --project <key> --dry-run`"]
            : list.assignments.map {
                "  \($0.id)  \(stamp($0.from, timeZone)) to \(stamp($0.to, timeZone))  \($0.projectKey)"
            }
        return lines
    }

    private static func stamp(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

/// The writes behind `worklens projects rule` and `projects assign` (#324): each one previews
/// first, through the allocator, and saves only when `dryRun` is false, so the minutes a dry run
/// prints are the minutes a save moves.
public struct ProjectCorrector: Sendable {
    private let db: Database
    private let taxonomy: TaxonomyStore
    private let service: ProjectSpanService
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date

    public init(
        db: Database, taxonomy: TaxonomyStore, timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        baseIntervals: DayAccounting.BaseIntervals = .shipped
    ) {
        self.db = db
        self.taxonomy = taxonomy
        self.timeZone = timeZone
        self.now = now
        self.service = ProjectSpanService(
            db, timeZone: timeZone,
            projects: { taxonomy.projects },
            ignoredDomains: { taxonomy.current.ignoredDomains ?? [] },
            now: now, baseIntervals: baseIntervals
        )
    }

    private var catalog: ProjectCatalog { ProjectCatalog(db: db, taxonomy: taxonomy, timeZone: timeZone) }

    /// A rule reaches every kept day.
    public func addRule(
        _ kind: ProjectRuleKind, _ value: String, project: String, dryRun: Bool
    ) throws -> ProjectCorrections.Report {
        let change = try ProjectCatalog.adding(kind, value, to: project, in: taxonomy.projects)
        let preview = try previewing(days: try service.keptDays(), catalog: change.projects)
        if !dryRun { try catalog.addRule(kind, value, to: change.entry.key) }
        return ProjectCorrections.Report(
            change: .init(action: "rule add", project: change.entry.key, kind: kind, value: change.value),
            preview: preview, saved: !dryRun
        )
    }

    public func removeRule(_ kind: ProjectRuleKind, _ value: String, dryRun: Bool) throws -> ProjectCorrections.Report {
        let change = try ProjectCatalog.removing(kind, value, in: taxonomy.projects)
        let preview = try previewing(days: try service.keptDays(), catalog: change.projects)
        if !dryRun { try catalog.removeRule(kind, value) }
        return ProjectCorrections.Report(
            change: .init(action: "rule remove", project: change.entry.key, kind: kind, value: change.value),
            preview: preview, saved: !dryRun
        )
    }

    /// An assignment reaches its own days. `to` may not be in the future, and must come after
    /// `from`.
    public func assign(from: Date, to: Date, project: String, dryRun: Bool) throws -> ProjectCorrections.Report {
        guard to > from else { throw ProjectCorrectionError.emptyRange }
        guard to <= now() else { throw ProjectCorrectionError.futureEnd }
        guard let entry = ProjectEntry.lookup(key: project, in: taxonomy.projects) else {
            throw ProjectCatalogError.unknownProject(project)
        }
        let store = ProjectAssignmentStore(db)
        let existing = try store.all()
        let pending = ProjectAssignment(
            id: (existing.map(\.id).max() ?? 0) + 1, from: from, to: to, projectKey: entry.key, createdAt: now()
        )
        let preview = try previewing(
            days: service.days(from: from, to: to), assignments: existing + [pending]
        )
        let saved = dryRun
            ? pending : try store.insert(from: from, to: to, projectKey: entry.key, createdAt: pending.createdAt)
        return ProjectCorrections.Report(
            change: .init(action: "assign", project: entry.key, assignment: saved),
            preview: preview, saved: !dryRun
        )
    }

    public func unassign(id: Int64, dryRun: Bool) throws -> ProjectCorrections.Report {
        let store = ProjectAssignmentStore(db)
        guard let row = try store.assignment(id: id) else { throw ProjectCorrectionError.unknownAssignment(id) }
        let preview = try previewing(
            days: service.days(from: row.from, to: row.to), assignments: try store.all().filter { $0.id != id }
        )
        if !dryRun { try store.delete(id: id) }
        return ProjectCorrections.Report(
            change: .init(action: "unassign", project: row.projectKey, assignment: row),
            preview: preview, saved: !dryRun
        )
    }

    private func previewing(
        days: [String], catalog: [ProjectEntry]? = nil, assignments: [ProjectAssignment]? = nil
    ) throws -> ProjectCorrections.Preview {
        ProjectCorrections.preview(try service.comparisons(
            days: days,
            catalog: catalog ?? taxonomy.projects,
            assignments: assignments ?? ProjectAssignmentStore(db).all()
        ))
    }
}

public enum ProjectCorrectionError: Error, Equatable, CustomStringConvertible {
    case emptyRange
    case futureEnd
    case unknownAssignment(Int64)

    public var description: String {
        switch self {
        case .emptyRange: "--to must come after --from"
        case .futureEnd: "--to is in the future; you can assign only time that has passed"
        case .unknownAssignment(let id): "no assignment with id \(id); `worklens projects rule list` shows them"
        }
    }
}
