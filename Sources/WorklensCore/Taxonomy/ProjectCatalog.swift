import Foundation

/// The canonical project list as a thing you can read and edit (#90).
///
/// One place for both halves of the list's life: `learn` grows it from the days the describer has
/// already named, and `rename` / `merge` / `addAlias` / `forget` are the hand edits the CLI
/// (`worklens projects …`) and the Projects settings tab both go through, so an edit means the
/// same thing wherever it was made. Every write goes through `TaxonomyStore.save`, which
/// validates, bumps the version and writes atomically.
public struct ProjectCatalog: Sendable {
    /// How many days back `learn` looks. A week: long enough for a project to reappear, short
    /// enough that a thing you stopped working on stops adding aliases.
    public static let learningWindow = 7

    private let db: Database
    private let taxonomy: TaxonomyStore
    private let timeZone: TimeZone

    public init(db: Database, taxonomy: TaxonomyStore, timeZone: TimeZone = .current) {
        self.db = db
        self.taxonomy = taxonomy
        self.timeZone = timeZone
    }

    public var projects: [ProjectEntry] { taxonomy.projects }

    // MARK: Learning

    /// Folds the last `learningWindow` days of hints into the list, saving only when something
    /// changed. Returns the days it read and what it added, for the CLI to print.
    @discardableResult
    public func learn(upTo day: String, days: Int = ProjectCatalog.learningWindow) throws -> Change {
        let change = try preview(upTo: day, days: days)
        if !change.isEmpty { try write(change.after) }
        return change
    }

    /// The `app_state` key holding the last local day `learnIfDue` ran.
    public static let lastLearnedKey = "projects_learned_day"

    /// `learn(upTo: yesterday)` at most once per local day: the app's housekeeping pass calls it,
    /// now that no daily report runs it first (2026-10-05). Yesterday rather than today, so the
    /// window is seven complete days however early the pass runs. The day is stored only after a
    /// pass that did not throw, so a failure is tried again on the next pass. Nil when today has
    /// already run.
    @discardableResult
    public func learnIfDue(now: Date = Date()) throws -> Change? {
        let state = AppStateStore(db)
        let today = DayBoundaries.dayString(now, timeZone: timeZone)
        if try state.get(Self.lastLearnedKey) == today { return nil }
        let yesterday = DayBoundaries.shift(day: today, by: -1, timeZone: timeZone) ?? today
        let change = try learn(upTo: yesterday)
        try state.set(Self.lastLearnedKey, today)
        return change
    }

    /// What `learn` would do, without touching the file. `worklens projects learn --dry-run`.
    public func preview(upTo day: String, days: Int = ProjectCatalog.learningWindow) throws -> Change {
        let window = Self.window(endingAt: day, days: days, timeZone: timeZone)
        var byDay: [String: [ProjectNames.Observation]] = [:]
        let store = DescriptionStore(db)
        for day in window {
            let observations = try store.projectObservations(day: day, timeZone: timeZone)
            guard !observations.isEmpty else { continue }
            byDay[day] = Array(observations.values)
        }
        let before = taxonomy.projects
        let learned = ProjectLearning.learned(projects: before, byDay: byDay) ?? before
        let companies = try meetingCompanies(window: window, projects: learned)
        return Change(
            daysRead: byDay.count, before: before, after: learned + companies.added,
            suggestedMerges: companies.suggested
        )
    }

    /// #318: a `company:<domain>` entry (kind `company`) for every company domain that alone
    /// settled a meeting in the window and that the catalog does not have yet. A meeting with
    /// several company domains never creates one. The name is the domain's first label; when an
    /// entry already answers to it (`existingOwner`), nothing is added and the merge that would make the domain
    /// that entry's is suggested instead, so the same company is never spelled twice.
    func meetingCompanies(
        window: [String], projects: [ProjectEntry]
    ) throws -> (added: [ProjectEntry], suggested: [SuggestedMerge]) {
        guard let first = window.first, let last = window.last,
              let start = DayBoundaries.range(day: first, timeZone: timeZone)?.start,
              let end = DayBoundaries.range(day: last, timeZone: timeZone)?.end
        else { return ([], []) }
        let events = try ContextEventStore(db).fetch(from: start, to: end)
        let answers = MeetingAttribution.resolve(
            events, catalog: projects, ignoredDomains: taxonomy.current.ignoredDomains ?? []
        )
        let keys = Set(answers.values.filter { $0.rule == .domain }.compactMap(\.key))
        var added: [ProjectEntry] = []
        var suggested: [SuggestedMerge] = []
        for key in keys.sorted() {
            guard let domain = MeetingAttribution.companyDomain(ofKey: key),
                  ProjectEntry.lookup(key: key, in: projects + added) == nil
            else { continue }
            let name = MeetingAttribution.companyName(domain: domain)
            if let owner = Self.existingOwner(name: name, in: projects + added) {
                suggested.append(SuggestedMerge(key: key, into: owner.key))
                continue
            }
            added.append(ProjectEntry(key: key, name: name, kind: .company))
        }
        return (added, suggested)
    }

    /// The entry a domain's company name already belongs to: one that answers to the name, or
    /// else the one entry the memo matcher (#317) finds for it with spaces, `-` and domain
    /// suffixes ignored, so `acmecorp.com` meets the memo-created `Acme Corp` instead of making a
    /// second entry for the same company.
    static func existingOwner(name: String, in projects: [ProjectEntry]) -> ProjectEntry? {
        if let owner = projects.first(where: { $0.matches(name) }) { return owner }
        if case .one(let owner) = MemoCompanyMatcher.match(slug: name, in: projects) { return owner }
        return nil
    }

    /// A `projects merge <key> <into>` that `learn` prints instead of adding a company entry
    /// whose name an existing entry already answers to (#318).
    public struct SuggestedMerge: Sendable, Equatable {
        public let key: String
        public let into: String

        public init(key: String, into: String) {
            self.key = key
            self.into = into
        }
    }

    /// What one `learn` pass did.
    public struct Change: Sendable, Equatable {
        public let daysRead: Int
        public let before: [ProjectEntry]
        public let after: [ProjectEntry]
        /// Merges to run by hand; never written by `learn`, and not part of `isEmpty`.
        public var suggestedMerges: [SuggestedMerge] = []

        public var addedProjects: [ProjectEntry] {
            let known = Set(before.map(\.key))
            return after.filter { !known.contains($0.key) }
        }

        /// Project key → the aliases this pass added to it.
        public var addedAliases: [String: [String]] {
            var result: [String: [String]] = [:]
            for project in after {
                guard let old = before.first(where: { $0.key == project.key }) else { continue }
                let known = Set(old.aliases ?? [])
                let added = (project.aliases ?? []).filter { !known.contains($0) }
                if !added.isEmpty { result[project.key] = added }
            }
            return result
        }

        public var isEmpty: Bool { addedProjects.isEmpty && addedAliases.isEmpty }
    }

    /// `day` and the `days - 1` local days before it, oldest first.
    static func window(endingAt day: String, days: Int, timeZone: TimeZone) -> [String] {
        guard days > 0, let end = DayBoundaries.range(day: day, timeZone: timeZone)?.start
        else { return [day] }
        return (0..<days)
            .map {
                DayBoundaries.dayString(
                    end.addingTimeInterval(Double(-$0) * 86_400), timeZone: timeZone
                )
            }
            .reversed()
            .map { $0 }
    }

    // MARK: Hand edits

    /// Renames a project, keeping the old spelling as an alias so the days already described
    /// under it still fold onto the same row.
    public func rename(key: String, to name: String) throws {
        var projects = self.projects
        guard let index = projects.firstIndex(where: { $0.key == key }) else {
            throw ProjectCatalogError.unknownProject(key)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectCatalogError.emptyName }
        if let owner = projects.first(where: { $0.key != key && $0.matches(trimmed) }) {
            throw ProjectCatalogError.spellingTaken(trimmed, owner.key)
        }
        let old = projects[index].name
        projects[index].name = trimmed
        if ProjectEntry.fold(old) != ProjectEntry.fold(trimmed) {
            projects[index].aliases = (projects[index].aliases ?? []) + [old]
        }
        try write(projects)
    }

    /// Folds `key` into `into`: every spelling the source answered to becomes an alias of the
    /// target, and the source is removed.
    public func merge(key: String, into target: String) throws {
        guard key != target else { throw ProjectCatalogError.cannotMergeIntoItself(key) }
        var projects = self.projects
        guard let targetIndex = projects.firstIndex(where: { $0.key == target }) else {
            throw ProjectCatalogError.unknownProject(target)
        }
        guard let sourceIndex = projects.firstIndex(where: { $0.key == key }) else {
            // #318: `company:<domain>` that `learn` suggested rather than wrote: the domain
            // becomes the target's, as it would had the entry existed.
            guard let domain = MeetingAttribution.companyDomain(ofKey: key) else {
                throw ProjectCatalogError.unknownProject(key)
            }
            projects[targetIndex].domains = Self.uniquedDomains((projects[targetIndex].domains ?? []) + [domain])
            try write(projects)
            return
        }
        // #315: the source's kind moves to a target that has none; the house mark is never lost
        // to a target that is already something else.
        if projects[sourceIndex].kind == .house, let kind = projects[targetIndex].kind, kind != .house {
            throw ProjectCatalogError.mergeWouldDropHouse(key, target)
        }
        let source = projects.remove(at: sourceIndex)
        let index = projects.firstIndex { $0.key == target } ?? targetIndex
        let additions = ([source.key] + source.spellings).filter { spelling in
            !projects[index].matches(spelling)
        }
        projects[index].aliases = (projects[index].aliases ?? []) + Self.uniqued(additions)
        if projects[index].kind == nil { projects[index].kind = source.kind }
        // #318: the source's domains, and the one a `company:<domain>` key is named after, are
        // the target's from now on, so its meetings count toward it by the `yours` rule.
        let domains = (projects[index].domains ?? []) + (source.domains ?? [])
            + (MeetingAttribution.companyDomain(ofKey: source.key).map { [$0] } ?? [])
        let merged = Self.uniquedDomains(domains)
        projects[index].domains = merged.isEmpty ? nil : merged
        // #324: the source's repo and URL-prefix rules, and the stretches assigned to it, are
        // the target's from now on.
        for kind in [ProjectRuleKind.repo, .urlPrefix] {
            let values = Self.uniqued(kind.values(on: projects[index]) + kind.values(on: source))
            projects[index] = kind.setting(values, on: projects[index])
        }
        // Assignments first: reassigning is idempotent, so a failed write can be retried, while
        // the other order could leave rows naming a key that no longer exists.
        try ProjectAssignmentStore(db).reassign(projectKey: key, to: target)
        try write(projects)
    }

    public func addAlias(_ alias: String, to key: String) throws {
        var projects = self.projects
        guard let index = projects.firstIndex(where: { $0.key == key }) else {
            throw ProjectCatalogError.unknownProject(key)
        }
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectCatalogError.emptyName }
        if let owner = projects.first(where: { $0.matches(trimmed) }) {
            throw ProjectCatalogError.spellingTaken(trimmed, owner.key)
        }
        projects[index].aliases = (projects[index].aliases ?? []) + [trimmed]
        try write(projects)
    }

    public func removeAlias(_ alias: String, from key: String) throws {
        var projects = self.projects
        guard let index = projects.firstIndex(where: { $0.key == key }) else {
            throw ProjectCatalogError.unknownProject(key)
        }
        let remaining = (projects[index].aliases ?? [])
            .filter { ProjectEntry.fold($0) != ProjectEntry.fold(alias) }
        guard remaining.count != (projects[index].aliases ?? []).count else {
            throw ProjectCatalogError.unknownAlias(alias, key)
        }
        projects[index].aliases = remaining.isEmpty ? nil : remaining
        try write(projects)
    }

    /// Marks what sort of project `key` is (#315), or clears the mark with nil. Only one entry may
    /// be `house`; marking a second one is refused rather than silently moving the mark.
    public func setKind(_ kind: ProjectKind?, for key: String) throws {
        var projects = self.projects
        guard let index = projects.firstIndex(where: { $0.key == key }) else {
            throw ProjectCatalogError.unknownProject(key)
        }
        if kind == .house, let other = projects.first(where: { $0.kind == .house && $0.key != key }) {
            throw ProjectCatalogError.houseTaken(other.key)
        }
        projects[index].kind = kind
        try write(projects)
    }

    /// Drops a project the learner should not have created. Its hints go back to being clustered
    /// day by day, and it can be learned again — `forget` is a correction, not a block list.
    /// The one exception is a `company:<domain>` entry (#318): its domain joins
    /// `ignored_domains`, so its meetings stop counting and the next `learn` does not bring it back.
    public func forget(key: String) throws {
        let projects = self.projects
        guard projects.contains(where: { $0.key == key }) else {
            throw ProjectCatalogError.unknownProject(key)
        }
        // #324: an assignment names its project by key; forgetting the key would orphan it.
        let assigned = try ProjectAssignmentStore(db).count(projectKey: key)
        guard assigned == 0 else { throw ProjectCatalogError.assignmentsPointAt(key, assigned) }
        var ignored = taxonomy.current.ignoredDomains
        if let domain = MeetingAttribution.companyDomain(ofKey: key) {
            ignored = Self.uniquedDomains((ignored ?? []) + [domain])
        }
        try write(projects.filter { $0.key != key }, ignoredDomains: ignored)
    }

    // MARK: Rules (#324)

    /// Adds `value` as a `kind` rule on the project `project` names (its key or any spelling) and
    /// saves. Returns the entry and the value as stored.
    @discardableResult
    public func addRule(
        _ kind: ProjectRuleKind, _ value: String, to project: String
    ) throws -> (entry: ProjectEntry, value: String) {
        let change = try Self.adding(kind, value, to: project, in: projects)
        try write(change.projects)
        return (change.entry, change.value)
    }

    /// Removes the `kind` rule `value` from whichever project holds it and saves. Returns the
    /// entry it came off and the value as stored.
    @discardableResult
    public func removeRule(_ kind: ProjectRuleKind, _ value: String) throws -> (entry: ProjectEntry, value: String) {
        let change = try Self.removing(kind, value, in: projects)
        try write(change.projects)
        return (change.entry, change.value)
    }

    /// The catalog with the rule added, unsaved: what a dry run previews. Refuses a value another
    /// project owns, naming it. Adding a rule the project already has changes nothing.
    public static func adding(
        _ kind: ProjectRuleKind, _ value: String, to project: String, in projects: [ProjectEntry]
    ) throws -> (projects: [ProjectEntry], entry: ProjectEntry, value: String) {
        guard let normalized = kind.normalized(value) else { throw ProjectCatalogError.invalidRule(kind, value) }
        guard let index = projects.firstIndex(where: { $0.key == project })
            ?? projects.firstIndex(where: { $0.matches(project) })
        else { throw ProjectCatalogError.unknownProject(project) }
        if let owner = projects.first(where: { holds(kind, normalized, $0) }) {
            guard owner.key == projects[index].key else {
                throw ProjectCatalogError.ruleTaken(normalized, owner.key)
            }
            return (projects, owner, normalized)
        }
        var next = projects
        next[index] = kind.setting(kind.values(on: next[index]) + [normalized], on: next[index])
        return (next, next[index], normalized)
    }

    /// The catalog with the rule removed, unsaved.
    public static func removing(
        _ kind: ProjectRuleKind, _ value: String, in projects: [ProjectEntry]
    ) throws -> (projects: [ProjectEntry], entry: ProjectEntry, value: String) {
        guard let normalized = kind.normalized(value) else { throw ProjectCatalogError.invalidRule(kind, value) }
        guard let index = projects.firstIndex(where: { holds(kind, normalized, $0) }) else {
            throw ProjectCatalogError.unknownRule(kind, normalized)
        }
        var next = projects
        let kept = kind.values(on: next[index]).filter { kind.normalized($0) != normalized }
        next[index] = kind.setting(kept, on: next[index])
        return (next, next[index], normalized)
    }

    private static func holds(_ kind: ProjectRuleKind, _ normalized: String, _ entry: ProjectEntry) -> Bool {
        kind.values(on: entry).contains { kind.normalized($0) == normalized }
    }

    private func write(_ projects: [ProjectEntry]) throws {
        try write(projects, ignoredDomains: taxonomy.current.ignoredDomains)
    }

    private func write(_ projects: [ProjectEntry], ignoredDomains: [String]?) throws {
        var next = taxonomy.current
        next.projects = projects
        next.ignoredDomains = ignoredDomains
        try taxonomy.save(next)
    }

    private static func uniquedDomains(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.map(MeetingAttribution.normalized).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert(ProjectEntry.fold($0)).inserted }
    }
}

public enum ProjectCatalogError: Error, Equatable, CustomStringConvertible {
    case unknownProject(String)
    case unknownAlias(String, String)
    case spellingTaken(String, String)
    case cannotMergeIntoItself(String)
    case emptyName
    case houseTaken(String)
    case mergeWouldDropHouse(String, String)
    case invalidRule(ProjectRuleKind, String)
    case ruleTaken(String, String)
    case unknownRule(ProjectRuleKind, String)
    case assignmentsPointAt(String, Int)

    public var description: String {
        switch self {
        case .unknownProject(let key): "no project with key \"\(key)\""
        case .unknownAlias(let alias, let key): "\"\(key)\" has no alias \"\(alias)\""
        case .spellingTaken(let spelling, let owner): "\"\(spelling)\" already names \"\(owner)\""
        case .cannotMergeIntoItself(let key): "cannot merge \"\(key)\" into itself"
        case .emptyName: "a project name cannot be empty"
        case .houseTaken(let owner): "\"\(owner)\" is already the house project; mark it as something else first"
        case .mergeWouldDropHouse(let house, let target):
            "\"\(house)\" is your house project and \"\(target)\" has another kind; run `worklens projects kind \(target) none` first"
        case .invalidRule(let kind, let value): "\"\(value)\" is not a usable \(kind.flag) value"
        case .ruleTaken(let value, let owner): "\"\(value)\" is already a rule on \"\(owner)\"; remove it there first"
        case .unknownRule(let kind, let value): "no project has the \(kind.flag) rule \"\(value)\""
        case .assignmentsPointAt(let key, let count):
            "\(count) \(count == 1 ? "assignment points" : "assignments point") at \"\(key)\"; remove \(count == 1 ? "it" : "them") with `worklens projects rule remove --assignment <id>` first"
        }
    }
}
