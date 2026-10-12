import Foundation

// MARK: - Schema

/// The user-editable list of apps, the web apps that live inside a browser, and the tasks a
/// person does in each. It exists so the describer classifies into a small stable vocabulary
/// instead of inventing a new label for every frame.
public struct Taxonomy: Codable, Sendable, Equatable {
    public var version: Int
    public var apps: [AppEntry]
    public var universalTasks: [TaskEntry]
    /// The canonical projects the describer's `project_hint` is folded onto (#90). Optional so a
    /// taxonomy.json written before #90 still decodes, and empty in the seed: the list is the
    /// user's, learned from what the days actually contained rather than shipped.
    public var projects: [ProjectEntry]?
    /// Email domains a meeting never counts toward (#318): `projects forget company:<domain>`
    /// adds one, and the hand edit is the way to take it back. Nil in every older file.
    public var ignoredDomains: [String]?

    public init(
        version: Int,
        apps: [AppEntry],
        universalTasks: [TaskEntry],
        projects: [ProjectEntry]? = nil,
        ignoredDomains: [String]? = nil
    ) {
        self.version = version
        self.apps = apps
        self.universalTasks = universalTasks
        self.projects = projects
        self.ignoredDomains = ignoredDomains
    }
}

/// One project — a company, a deal, a side thing — under the one name a report should use for it.
///
/// The describer spells the same project several ways because the screen does ("Riverbend Capital
/// Group" on the deck, "Riverbend Capital" in the tab title); `ProjectNames` clusters those, and this
/// entry is where the winning spelling is pinned so tomorrow agrees with today. Aliases grow
/// automatically (`ProjectLearning`) and are edited by hand when the guess was wrong.
public struct ProjectEntry: Codable, Sendable, Equatable {
    /// Stable identifier, folded: what `DailyStats.byProject` is keyed on across days.
    public var key: String
    /// The spelling to print.
    public var name: String
    /// Other spellings that mean this project. Never shown in a report.
    public var aliases: [String]?
    /// What sort of project this is (#315): a label the describer is told, never a score. Nil on
    /// every entry written before it existed, and on any entry nobody has marked.
    public var kind: ProjectKind?
    /// Email domains that are this project's (#318): a meeting with one of them on the invite
    /// counts toward this entry by the `yours` rule. On the house entry they are your own
    /// domains and never count. `projects merge` carries them; nil on every older entry.
    public var domains: [String]?
    /// Repo and URL-prefix rules you wrote (#324); a domain rule is a row in `domains`. Nil on
    /// every older entry.
    public var rules: ProjectRules?

    public init(
        key: String, name: String, aliases: [String]? = nil, kind: ProjectKind? = nil,
        domains: [String]? = nil, rules: ProjectRules? = nil
    ) {
        self.key = key
        self.name = name
        self.aliases = aliases
        self.kind = kind
        self.domains = domains
        self.rules = rules
    }

    /// The entry a describer's `project_key` names: the key itself, then any entry that answers
    /// to it as a spelling. A key merged into another stays resolvable that way, because
    /// `ProjectCatalog.merge` keeps the source key as an alias of the target.
    public static func lookup(key: String, in projects: [ProjectEntry]) -> ProjectEntry? {
        projects.first { $0.key == key } ?? projects.first { $0.matches(key) }
    }

    /// Every spelling this project answers to, the name first.
    public var spellings: [String] { [name] + (aliases ?? []) }

    /// Does `candidate` name this project? Case-, diacritic- and whitespace-insensitive, because
    /// the hint is free text off a screen: "riverbend capital  group" and "Riverbénd Capital Group" are
    /// the same answer.
    public func matches(_ candidate: String) -> Bool {
        let folded = ProjectEntry.fold(candidate)
        guard !folded.isEmpty else { return false }
        return folded == ProjectEntry.fold(key) || spellings.contains { ProjectEntry.fold($0) == folded }
    }

    /// Lowercased, unaccented, with every run of whitespace collapsed to one space.
    public static func fold(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

/// The three sorts of project the catalog tells apart (#315). `house` is the firm you work at,
/// and at most one entry may carry it; `company` is a deal or a portfolio company; `side` is a
/// personal project.
public enum ProjectKind: String, Codable, Sendable, Equatable, CaseIterable {
    case house
    case company
    case side
}

public struct AppEntry: Codable, Sendable, Equatable {
    public var key: String
    public var name: String
    public var category: String
    public var bundleIds: [String]
    public var tasks: [TaskEntry]
    public var webApps: [WebAppEntry]?

    public init(
        key: String,
        name: String,
        category: String,
        bundleIds: [String],
        tasks: [TaskEntry],
        webApps: [WebAppEntry]? = nil
    ) {
        self.key = key
        self.name = name
        self.category = category
        self.bundleIds = bundleIds
        self.tasks = tasks
        self.webApps = webApps
    }
}

/// A site that deserves its own key even though it runs inside a browser (Gmail, GitHub, …).
public struct WebAppEntry: Codable, Sendable, Equatable {
    public var key: String
    public var name: String
    public var category: String
    /// `host` or `host/path-prefix`, e.g. `docs.google.com/spreadsheets`.
    public var urlPatterns: [String]
    public var tasks: [TaskEntry]

    public init(key: String, name: String, category: String, urlPatterns: [String], tasks: [TaskEntry]) {
        self.key = key
        self.name = name
        self.category = category
        self.urlPatterns = urlPatterns
        self.tasks = tasks
    }
}

public struct TaskEntry: Codable, Sendable, Equatable {
    public var key: String
    public var description: String
    /// Other names that mean this task (schema v2, added by #25).
    ///
    /// An alias absorbs a synonym without inventing a new key: a frame labelled
    /// `scheduling_followups` is really `writing_email`, and the alias says so, so the frame
    /// keeps a real task instead of falling to `other`. Aliases are never shown to the model —
    /// the prompt lists keys only, and the vocabulary must stay small.
    public var aliases: [String]?

    public init(key: String, description: String, aliases: [String]? = nil) {
        self.key = key
        self.description = description
        self.aliases = aliases
    }

    /// Does `candidate` name this task, by key or by alias?
    public func matches(_ candidate: String) -> Bool {
        key == candidate || (aliases?.contains(candidate) ?? false)
    }
}

/// What the frame's metadata resolved to: one app (or web app) and the tasks it allows.
public struct ResolvedApp: Sendable, Equatable {
    public let appKey: String
    public let name: String
    public let category: String
    public let tasks: [TaskEntry]
    public let isWebApp: Bool

    public init(appKey: String, name: String, category: String, tasks: [TaskEntry], isWebApp: Bool) {
        self.appKey = appKey
        self.name = name
        self.category = category
        self.tasks = tasks
        self.isWebApp = isWebApp
    }
}

// MARK: - Coding

public extension Taxonomy {
    /// Snake_case in the file, camelCase in Swift — one decoder so every call site agrees.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decode(_ data: Data) throws -> Taxonomy {
        try decoder().decode(Taxonomy.self, from: data)
    }

    /// The compiled-in taxonomy. Force-decoded on purpose: a seed that does not parse is a build
    /// mistake, and every other code path assumes a usable fallback exists.
    static let seed: Taxonomy = {
        // swiftlint:disable:next force_try
        try! decode(Data(TaxonomySeed.json.utf8))
    }()
}

// MARK: - Lookup

public extension Taxonomy {
    var universalTaskKeys: [String] { universalTasks.map(\.key) }

    func app(key: String) -> AppEntry? { apps.first { $0.key == key } }

    func app(bundleID: String) -> AppEntry? {
        apps.first { $0.bundleIds.contains(bundleID) }
    }

    /// Every web app in the taxonomy, regardless of which browser entry declared it.
    var allWebApps: [WebAppEntry] { apps.flatMap { $0.webApps ?? [] } }

    func webApp(key: String) -> WebAppEntry? { allWebApps.first { $0.key == key } }

    /// Every app key plus every web-app key — the full classification vocabulary.
    var allAppKeys: [String] { apps.map(\.key) + allWebApps.map(\.key) }

    /// Tasks for an app key or a web-app key.
    func tasks(forAppKey key: String) -> [TaskEntry]? {
        app(key: key)?.tasks ?? webApp(key: key)?.tasks
    }

    /// The category of an app key or a web-app key (`slack` → `communication`, `gmail` →
    /// `communication`, `gsheets` → `analysis`). Nil for a key the taxonomy has never heard of,
    /// which `StatsAggregator` files under "uncategorized".
    func category(forAppKey key: String) -> String? {
        app(key: key)?.category ?? webApp(key: key)?.category
    }
}

// MARK: - Projects (#90)

public extension Taxonomy {
    /// The canonical list, with `nil` and `[]` meaning the same thing to every caller.
    var projectList: [ProjectEntry] { projects ?? [] }

    func project(key: String) -> ProjectEntry? { projectList.first { $0.key == key } }

    /// The entry a describer's `project_key` names, by key and then by spelling (#315).
    func project(forKey key: String) -> ProjectEntry? { ProjectEntry.lookup(key: key, in: projectList) }

    /// The project a free-text hint names, by name or by alias. Nil when no project claims it —
    /// the caller then falls back to `ProjectNames`' clustering.
    func project(matching hint: String) -> ProjectEntry? {
        projectList.first { $0.matches(hint) }
    }
}

// MARK: - URL matching

/// `host` or `host/path-prefix` from a `url_patterns` entry.
struct URLPattern {
    let host: String
    let pathPrefix: String?

    init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let slash = trimmed.firstIndex(of: "/") {
            host = String(trimmed[trimmed.startIndex..<slash])
            let path = String(trimmed[trimmed.index(after: slash)...])
            pathPrefix = path.isEmpty ? nil : path
        } else {
            host = trimmed
            pathPrefix = nil
        }
    }

    /// How specific a match is, so `docs.google.com/spreadsheets` beats a bare `docs.google.com`.
    var specificity: Int { host.count + (pathPrefix?.count ?? 0) * 100 }

    func matches(host urlHost: String, path urlPath: String) -> Bool {
        guard urlHost == host || urlHost.hasSuffix("." + host) else { return false }
        guard let pathPrefix else { return true }
        return urlPath.hasPrefix("/" + pathPrefix)
    }
}

/// Splits a URL — with or without a scheme — into a lowercase host and a path starting with `/`.
func splitURL(_ url: String) -> (host: String, path: String)? {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
    guard let components = URLComponents(string: withScheme), let host = components.host, !host.isEmpty else {
        return nil
    }
    let path = components.path.isEmpty ? "/" : components.path
    return (host.lowercased(), path)
}

// MARK: - Validation

public extension Taxonomy {
    /// Problems that make a taxonomy unusable or ambiguous. Empty means the file is good.
    func validationProblems() -> [String] {
        var problems: [String] = []

        if version < 1 { problems.append("version must be >= 1, got \(version)") }
        if apps.isEmpty { problems.append("apps is empty") }
        if universalTasks.isEmpty { problems.append("universal_tasks is empty") }

        var seenAppKeys: Set<String> = []
        for app in apps {
            if app.key.isEmpty { problems.append("an app has an empty key") }
            if !seenAppKeys.insert(app.key).inserted {
                problems.append("duplicate app key \"\(app.key)\"")
            }
            if app.tasks.isEmpty { problems.append("app \"\(app.key)\" has no tasks") }
            if app.bundleIds.isEmpty && (app.webApps?.isEmpty ?? true) {
                problems.append("app \"\(app.key)\" has neither bundle_ids nor web_apps")
            }
            problems += duplicateTaskProblems(app.tasks, in: app.key)

            for web in app.webApps ?? [] {
                if !seenAppKeys.insert(web.key).inserted {
                    problems.append("duplicate app key \"\(web.key)\"")
                }
                if web.tasks.isEmpty { problems.append("web app \"\(web.key)\" has no tasks") }
                if web.urlPatterns.isEmpty { problems.append("web app \"\(web.key)\" has no url_patterns") }
                problems += duplicateTaskProblems(web.tasks, in: web.key)
            }
        }

        var seenBundleIDs: [String: String] = [:]
        for app in apps {
            for bundleID in app.bundleIds {
                if let owner = seenBundleIDs[bundleID] {
                    problems.append("bundle id \"\(bundleID)\" is claimed by both \"\(owner)\" and \"\(app.key)\"")
                }
                seenBundleIDs[bundleID] = app.key
            }
        }

        problems += duplicateTaskProblems(universalTasks, in: "universal_tasks")
        problems += projectProblems()
        return problems
    }

    /// A project list is unusable when two entries answer to the same spelling: resolution would
    /// then depend on the order the file happens to list them in (#90).
    private func projectProblems() -> [String] {
        var problems: [String] = []
        var seenKeys: Set<String> = []
        var owners: [String: String] = [:]
        var domainOwners: [String: String] = [:]
        var ruleOwners: [String: String] = [:]
        let houses = projectList.filter { $0.kind == .house }.map(\.key)
        if houses.count > 1 {
            problems.append(
                "more than one house project: " + houses.map { "\"\($0)\"" }.joined(separator: ", ")
            )
        }
        for project in projectList {
            if project.key.isEmpty { problems.append("a project has an empty key") }
            if project.name.isEmpty { problems.append("project \"\(project.key)\" has an empty name") }
            if !seenKeys.insert(project.key).inserted {
                problems.append("duplicate project key \"\(project.key)\"")
            }
            for spelling in project.spellings {
                if spelling.isEmpty {
                    problems.append("project \"\(project.key)\" has an empty alias")
                    continue
                }
                let folded = ProjectEntry.fold(spelling)
                if let owner = owners[folded], owner != project.key {
                    problems.append(
                        "spelling \"\(spelling)\" is claimed by both \"\(owner)\" and \"\(project.key)\""
                    )
                }
                owners[folded] = project.key
            }
            // #318: a domain names one company, or the meeting rule cannot say which.
            for domain in project.domains ?? [] {
                if MeetingAttribution.normalized(domain).isEmpty {
                    problems.append("project \"\(project.key)\" has an empty domain")
                    continue
                }
                // Folded as the rule matcher folds it (#324), so `www.acme.com` and `acme.com` clash.
                guard let folded = ProjectRuleKind.domain.normalized(domain) else {
                    problems.append("project \"\(project.key)\" has an unusable domain \"\(domain)\"")
                    continue
                }
                if let owner = domainOwners[folded], owner != project.key {
                    problems.append(
                        "domain \"\(folded)\" is claimed by both \"\(owner)\" and \"\(project.key)\""
                    )
                }
                domainOwners[folded] = project.key
            }
            // #324: a repo or URL prefix names one project, or a rule could not say which.
            for kind in [ProjectRuleKind.repo, .urlPrefix] {
                for value in kind.values(on: project) {
                    guard let folded = kind.normalized(value) else {
                        problems.append("project \"\(project.key)\" has an unusable \(kind.rawValue) \"\(value)\"")
                        continue
                    }
                    let slot = kind.rawValue + " " + folded
                    if let owner = ruleOwners[slot], owner != project.key {
                        problems.append(
                            "\(kind.rawValue) \"\(folded)\" is claimed by both \"\(owner)\" and \"\(project.key)\""
                        )
                    }
                    ruleOwners[slot] = project.key
                }
            }
        }
        return problems
    }

    private func duplicateTaskProblems(_ tasks: [TaskEntry], in owner: String) -> [String] {
        var seen: Set<String> = []
        var problems: [String] = []
        for task in tasks {
            if task.key.isEmpty { problems.append("\(owner) has a task with an empty key") }
            if !seen.insert(task.key).inserted {
                problems.append("\(owner) has duplicate task \"\(task.key)\"")
            }
        }
        // An alias that is also somebody's key would make classification ambiguous, and an alias
        // claimed by two tasks would make a merge silently pick one.
        for task in tasks {
            for alias in task.aliases ?? [] {
                if alias.isEmpty {
                    problems.append("\(owner) task \"\(task.key)\" has an empty alias")
                } else if !seen.insert(alias).inserted {
                    problems.append("\(owner) alias \"\(alias)\" collides with another task or alias")
                }
            }
        }
        return problems
    }
}
