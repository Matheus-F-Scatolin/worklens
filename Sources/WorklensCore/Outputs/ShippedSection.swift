import Foundation

/// How the shipped ledger reads (#314): grouped by project, counted per kind, one line per row.
/// Pure; the timeline's `## Shipped`, the `shipped` MCP tool and `worklens shipped` all print
/// through it.
///
/// Counts are per kind and never summed: a merged PR, an opened issue and a review are different
/// things, and a single number across them would read as a score.
public enum ShippedSection {
    public struct Group: Sendable, Equatable {
        public var name: String
        public var outputs: [Output]
    }

    /// The project a row belongs to: its `project_key` when something attributed it (resolved
    /// through `ProjectEntry.lookup`, so a key merged into another names the target), else the
    /// project a repo rule names for its repo (#324; the order `span` and the timesheet's agent
    /// column use), else the project whose name or alias is the repo's name (with `-`, `_` and
    /// `.` read as spaces), else the repo itself.
    public static func groupName(for output: Output, projects: [ProjectEntry]) -> String {
        groupName(for: output, projects: projects, matcher: ProjectRuleMatcher(catalog: projects))
    }

    static func groupName(for output: Output, projects: [ProjectEntry], matcher: ProjectRuleMatcher) -> String {
        if let key = output.projectKey, !key.isEmpty {
            return ProjectEntry.lookup(key: key, in: projects)?.name ?? key
        }
        guard let repo = output.repo, !repo.isEmpty else { return output.source }
        if let entry = matcher.project(forRepo: repo) { return entry.name }
        let short = repo.split(separator: "/").last.map(String.init) ?? repo
        // `my-app`, `my_app` and `my.app` all read as the project "My App".
        let spaced = String(short.map { "-_.".contains($0) ? " " : $0 })
        return projects.first { $0.matches(short) || $0.matches(repo) || $0.matches(spaced) }?.name ?? repo
    }

    /// Groups in the order their first row happened, rows oldest first inside each.
    public static func groups(_ outputs: [Output], projects: [ProjectEntry]) -> [Group] {
        var order: [String] = []
        var byName: [String: [Output]] = [:]
        let matcher = ProjectRuleMatcher(catalog: projects)
        for output in outputs.sorted(by: { $0.at < $1.at }) {
            let name = groupName(for: output, projects: projects, matcher: matcher)
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(output)
        }
        return order.map { Group(name: $0, outputs: byName[$0] ?? []) }
    }

    /// Whether `filter` names this row's project (a repo rule's project included), its repo
    /// (`owner/name` or `name`) or its key.
    public static func matches(_ output: Output, filter: String, projects: [ProjectEntry]) -> Bool {
        let wanted = ProjectEntry.fold(filter)
        guard !wanted.isEmpty else { return true }
        let matcher = ProjectRuleMatcher(catalog: projects)
        var names = [groupName(for: output, projects: projects, matcher: matcher)]
        if let key = output.projectKey, !key.isEmpty {
            names.append(key)
            if let entry = ProjectEntry.lookup(key: key, in: projects) { names.append(entry.key) }
        } else if let entry = matcher.project(forRepo: output.repo) {
            names.append(entry.key)
        }
        if let repo = output.repo {
            names.append(repo)
            if let short = repo.split(separator: "/").last { names.append(String(short)) }
        }
        return names.contains { ProjectEntry.fold($0) == wanted }
    }

    /// Per-kind counts, known kinds in their fixed order and unknown ones after, by name.
    public static func counts(_ outputs: [Output]) -> [(kind: OutputKind, count: Int)] {
        var tally: [OutputKind: Int] = [:]
        for output in outputs { tally[output.kind, default: 0] += 1 }
        let unknown = tally.keys.filter { !OutputKind.known.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        return (OutputKind.known + unknown).compactMap { kind in
            tally[kind].map { (kind: kind, count: $0) }
        }
    }

    /// `3 PRs merged · 1 issue opened`.
    public static func countsLine(_ outputs: [Output]) -> String {
        counts(outputs).map { $0.kind.count($0.count) }.joined(separator: " · ")
    }

    /// `merged owner/repo#12: Title`, after a clock in `format`; a memo row reads
    /// `You published the memo for <name> in owner/repo#12`.
    public static func line(
        _ output: Output, timeZone: TimeZone, format: String = "HH:mm", withURL: Bool = false
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Format.fixed
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        // #317: `You updated the memo for Acme Corp in owner/memos#12`.
        if output.kind.isMemo {
            let name = output.title.flatMap { $0.isEmpty ? nil : $0 } ?? "a company"
            var text = "\(formatter.string(from: output.at)) You \(output.kind.verb) \(name) in \(output.reference)"
            if withURL, let url = output.url { text += " " + url }
            return text
        }
        var text = "\(formatter.string(from: output.at)) \(output.kind.verb) \(output.reference)"
        if let title = output.title, !title.isEmpty {
            text += ": " + title.split(whereSeparator: \.isNewline).joined(separator: " ")
        }
        if withURL, let url = output.url { text += " " + url }
        return text
    }

    /// The timeline's `## Shipped`, or nothing on a day without rows.
    static func timelineLines(
        _ outputs: [Output], projects: [ProjectEntry], timeZone: TimeZone
    ) -> [String] {
        guard !outputs.isEmpty else { return [] }
        var lines = ["", "## Shipped"]
        for group in groups(outputs, projects: projects) {
            lines += ["", "\(group.name): \(countsLine(group.outputs))"]
            lines += group.outputs.map { "- " + line($0, timeZone: timeZone) }
        }
        return lines
    }
}
