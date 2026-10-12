import Foundation

/// Turns the describer's free-text `project_hint` into a handful of project names.
///
/// The model answers "which company, deal or project is this about" once per frame and spells the
/// answer the way the screen spelled it, so one project arrives under several labels: on
/// 2026-09-08 seven projects came in under fifteen (`worklens` 43 and `Worklens` 3, `KPL
/// trivia night` 13 beside a bare `KPL` and a bare `Trivia Night`). This is the clean-up, and it is
/// deliberately a pure function with no model call in it, so the same day always groups the same
/// way:
///
/// 1. trim, collapse runs of whitespace, case-fold for every comparison;
/// 2. drop a hint that only echoes the frame back — one equal to its own app name or window title,
///    since "Youka" on a Youka tab names the tool, not the project — and drop the empty ones;
/// 3. merge a label into another when its words appear in the other's, in order and whole:
///    `solara` into `dd solara`, `kpl` and `trivia night` into `kpl trivia night`, `pinecrest
///    machines` into `pinecrest machines & riverbend`. Merging is transitive, so `solara trading`
///    joins `dd solara` through the `solara` they both contain;
/// 4. a group's display name is its most frequent original spelling, ties broken alphabetically so
///    the answer never depends on dictionary order.
///
/// What it deliberately does not do is guess: two labels that share no words stay two projects,
/// however obviously related they look. That is what the canonical list in `taxonomy.json` is
/// for (#90): pass `projects:` and a cluster that any of its spellings claims takes that
/// project's key and name instead of the day's most frequent spelling, so two days spell a
/// project the same way even when they share no wording.
public enum ProjectNames {
    /// One frame's hint, with the two strings it is not allowed to be a copy of, and the catalog
    /// key the describer picked when it picked one (#315).
    public struct Observation: Sendable, Equatable {
        public var hint: String?
        public var appName: String?
        public var windowTitle: String?
        /// A d5 `project_key`. Nil on every older row, which then resolves exactly as before.
        public var projectKey: String?

        public init(
            hint: String?, appName: String? = nil, windowTitle: String? = nil, projectKey: String? = nil
        ) {
            self.hint = hint
            self.appName = appName
            self.windowTitle = windowTitle
            self.projectKey = projectKey
        }
    }

    /// One project, as a breakdown row needs it.
    public struct Project: Sendable, Equatable, Hashable {
        /// The display name, case-folded — what a week groups two days' rows by, so `worklens` on
        /// Monday and `Worklens` on Tuesday are one project rather than two. Two days that
        /// disagree on more than casing still land on two keys; teaching the describer to reuse
        /// the day's spellings is #65's job, not this one's.
        public var key: String
        /// The spelling to show: the group's most frequent original.
        public var name: String

        public init(key: String, name: String) {
            self.key = key
            self.name = name
        }
    }

    /// The project each observation resolves to, under the same keys it came in with.
    ///
    /// A key is absent when its hint was not a project — empty, or only the frame's own app or
    /// window name. The caller counts those as unattributed rather than as a project called "".
    ///
    /// A frame whose `projectKey` the catalog knows (#315) goes straight to that entry, ahead of
    /// the echo filter and the clustering: the describer already chose from the list, so a null
    /// hint or one that only repeats the app name does not undo the choice. A key the catalog
    /// no longer has is ignored and the frame falls back to its hint; a key that was merged away
    /// still resolves, because the merge kept it as an alias of the target.
    public static func resolve<ID: Hashable>(
        _ observations: [ID: Observation], projects canonical: [ProjectEntry] = []
    ) -> [ID: Project] {
        var keyed: [ID: Project] = [:]
        var foldedByID: [ID: String] = [:]
        /// folded label → original spelling → how many frames used that spelling.
        var spellings: [String: [String: Int]] = [:]
        for (id, observation) in observations {
            if let key = observation.projectKey, let entry = ProjectEntry.lookup(key: key, in: canonical) {
                keyed[id] = Project(key: entry.key, name: entry.name)
                continue
            }
            guard let label = usableLabel(observation) else { continue }
            foldedByID[id] = label.folded
            spellings[label.folded, default: [:]][label.cleaned, default: 0] += 1
        }
        guard !spellings.isEmpty else { return keyed }
        let projects = fold(groups(spellings), spellings: spellings, into: canonical)
        return foldedByID.compactMapValues { projects[$0] }.merging(keyed) { _, key in key }
    }

    /// The day's clusters, renamed to the canonical list wherever it claims one of their
    /// spellings (#90).
    ///
    /// A cluster is claimed as a whole, not spelling by spelling: today's `Riverbend Capital` sits in
    /// the same cluster as `Riverbend Capital Group`, so the whole cluster becomes the canonical
    /// project even on the day the canonical spelling itself never appeared. When two projects
    /// each claim part of one cluster the one with more frames behind it wins, ties by key, so a
    /// list the user edited by hand never makes the grouping depend on file order. Clusters no
    /// project claims keep the name their most frequent spelling gave them.
    static func fold(
        _ byLabel: [String: Project], spellings: [String: [String: Int]], into canonical: [ProjectEntry]
    ) -> [String: Project] {
        guard !canonical.isEmpty else { return byLabel }
        var clusters: [Project: [String]] = [:]
        for (label, project) in byLabel { clusters[project, default: []].append(label) }

        var result = byLabel
        for (_, labels) in clusters {
            guard let entry = claimant(of: labels, spellings: spellings, in: canonical) else { continue }
            for label in labels { result[label] = Project(key: entry.key, name: entry.name) }
        }
        // A spelling the list claims by itself keeps that project whatever its cluster resolved
        // to: the list is the answer, and the clustering is only the guess for what it does not
        // mention yet.
        for (label, byName) in spellings {
            let claims = byName.keys.compactMap { spelling in
                canonical.first { $0.matches(spelling) }
            }
            guard let entry = claims.first, claims.allSatisfy({ $0.key == entry.key }) else { continue }
            result[label] = Project(key: entry.key, name: entry.name)
        }
        return result
    }

    /// The canonical project a cluster belongs to: the one whose name or aliases the cluster's
    /// spellings match on the most frames, ties broken by key. Nil when the list claims none of
    /// them — a new project, as far as the list is concerned.
    static func claimant(
        of labels: [String], spellings: [String: [String: Int]], in canonical: [ProjectEntry]
    ) -> ProjectEntry? {
        var claimed: [String: Int] = [:]
        var entries: [String: ProjectEntry] = [:]
        for label in labels {
            for (spelling, count) in spellings[label] ?? [:] {
                guard let entry = canonical.first(where: { $0.matches(spelling) }) else { continue }
                claimed[entry.key, default: 0] += count
                entries[entry.key] = entry
            }
        }
        let winner = claimed
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .first
        return winner.flatMap { entries[$0.key] }
    }

    /// The hint as it should be counted, or nil when it is not a project name at all.
    static func usableLabel(_ observation: Observation) -> (cleaned: String, folded: String)? {
        let cleaned = collapsed(observation.hint)
        guard !cleaned.isEmpty else { return nil }
        let folded = cleaned.lowercased()
        for own in [observation.appName, observation.windowTitle] where collapsed(own).lowercased() == folded {
            return nil
        }
        return (cleaned, folded)
    }

    /// Trimmed, with every run of whitespace collapsed to one space.
    static func collapsed(_ text: String?) -> String {
        (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Folded label → the project it belongs to.
    static func groups(_ spellings: [String: [String: Int]]) -> [String: Project] {
        let labels = spellings.keys.sorted()
        var parent: [String: String] = Dictionary(uniqueKeysWithValues: labels.map { ($0, $0) })

        func root(of label: String) -> String {
            var current = label
            while let next = parent[current], next != current { current = next }
            return current
        }
        func merge(_ one: String, _ other: String) {
            let (a, b) = (root(of: one), root(of: other))
            guard a != b else { return }
            // The smaller root keeps the group, so the grouping never depends on the order the
            // pairs happened to be visited in.
            if a < b { parent[b] = a } else { parent[a] = b }
        }

        let bridges = bridgeLabels(labels, spellings: spellings)
        for (index, needle) in labels.enumerated() where !bridges.contains(needle) {
            for haystack in labels[labels.index(after: index)...]
            where !bridges.contains(haystack)
                && (containsAsWords(haystack, needle) || containsAsWords(needle, haystack)) {
                merge(needle, haystack)
            }
        }

        // A bridge joins the heaviest of the projects it names rather than joining them to each
        // other: two frames of "Riverbend Capital Group - Meridian" are two frames about
        // Riverbend, not a reason for 57 Meridian frames to become Riverbend ones.
        for bridge in bridges.sorted() {
            var weights: [String: Int] = [:]
            for label in labels where label != bridge && containsAsWords(bridge, label) {
                weights[root(of: label), default: 0] += (spellings[label] ?? [:]).values.reduce(0, +)
            }
            let winner = weights
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .first
            if let winner { parent[bridge] = winner.key }
        }

        var members: [String: [String]] = [:]
        for label in labels { members[root(of: label), default: []].append(label) }
        // `group` below is only the union-find root; the row's key comes from the display name, so
        // it survives a day where the shortest spelling happened not to appear.

        var result: [String: Project] = [:]
        for (group, labels) in members {
            var counts: [String: Int] = [:]
            for label in labels {
                for (spelling, count) in spellings[label] ?? [:] { counts[spelling, default: 0] += count }
            }
            let name = counts
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .first?.key ?? group
            for label in labels { result[label] = Project(key: name.lowercased(), name: name) }
        }
        return result
    }

    /// The labels that name two projects at once, and are too rare to be either.
    ///
    /// Containment is transitive, which is what lets `solara trading` reach `dd solara`
    /// through the `solara` they share (#70). The same transitivity is a trap when one label
    /// mentions two projects: on 2026-09-09 two frames of `riverbend capital group - meridian`
    /// contained both `riverbend capital group` (59 frames) and `meridian` (41), and merging on it
    /// made every Meridian frame a Riverbend one.
    ///
    /// Frequency is what tells the two cases apart, because the words cannot: `kpl trivia night`
    /// also contains two unrelated labels — `kpl` and `trivia night` — but it is the *common*
    /// spelling and they are the stray ones, so it is the name of the project rather than a
    /// mention of two. A label only stops merging when it is rarer than both of the unrelated
    /// things it names; it is then attached afterwards to the heavier of them.
    static func bridgeLabels(_ labels: [String], spellings: [String: [String: Int]]) -> Set<String> {
        func frames(_ label: String) -> Int { (spellings[label] ?? [:]).values.reduce(0, +) }
        var result: Set<String> = []
        for haystack in labels {
            let inside = labels.filter { $0 != haystack && containsAsWords(haystack, $0) }
            guard inside.count > 1 else { continue }
            let unrelated = inside.filter { one in
                inside.contains { other in
                    one != other && !containsAsWords(one, other) && !containsAsWords(other, one)
                }
            }
            guard let rarest = unrelated.map(frames).min() else { continue }
            if frames(haystack) < rarest { result.insert(haystack) }
        }
        return result
    }

    /// True when `needle`'s words appear inside `haystack`'s, in order and as whole words. Words
    /// rather than characters, so `kpl` merges into `kpl trivia night` but not into `kplx`.
    static func containsAsWords(_ haystack: String, _ needle: String) -> Bool {
        let outer = haystack.split(separator: " ")
        let inner = needle.split(separator: " ")
        guard !inner.isEmpty, inner.count < outer.count else { return false }
        for start in 0...(outer.count - inner.count) {
            if Array(outer[start..<(start + inner.count)]) == Array(inner) { return true }
        }
        return false
    }
}
