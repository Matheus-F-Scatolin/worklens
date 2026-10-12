import Foundation

/// The rules you wrote on a project (#324): "this repo, this URL prefix, is that project". Domains
/// live on `ProjectEntry.domains`, which #318 already reads for meetings, so a domain rule is a
/// row there and nothing here duplicates it. Both lists are optional so every older
/// `taxonomy.json` decodes.
public struct ProjectRules: Codable, Sendable, Equatable {
    /// `owner/repo`, lowercased.
    public var repos: [String]?
    /// `host/path`, lowercased, with no scheme, no `www.`, no query and no fragment.
    public var urlPrefixes: [String]?

    public init(repos: [String]? = nil, urlPrefixes: [String]? = nil) {
        self.repos = repos
        self.urlPrefixes = urlPrefixes
    }

    public var isEmpty: Bool { (repos ?? []).isEmpty && (urlPrefixes ?? []).isEmpty }
}

/// The three sorts of rule, as `worklens projects rule add` spells them.
public enum ProjectRuleKind: String, Codable, Sendable, CaseIterable {
    case domain
    case repo
    case urlPrefix = "url_prefix"

    /// The CLI flag that names this kind.
    public var flag: String {
        switch self {
        case .domain: "--domain"
        case .repo: "--repo"
        case .urlPrefix: "--url-prefix"
        }
    }

    /// The value as stored, or nil when it cannot be a rule of this kind.
    public func normalized(_ value: String) -> String? {
        switch self {
        case .domain: ProjectRuleMatcher.normalizedDomain(value)
        case .repo: ProjectRuleMatcher.normalizedRepo(value)
        case .urlPrefix: ProjectRuleMatcher.normalizedURLPrefix(value)
        }
    }

    /// The values `entry` holds of this kind, as stored.
    public func values(on entry: ProjectEntry) -> [String] {
        switch self {
        case .domain: entry.domains ?? []
        case .repo: entry.rules?.repos ?? []
        case .urlPrefix: entry.rules?.urlPrefixes ?? []
        }
    }

    /// `entry` with `values` as its list of this kind; an empty list is stored as nil.
    public func setting(_ values: [String], on entry: ProjectEntry) -> ProjectEntry {
        var entry = entry
        let list = values.isEmpty ? nil : values
        switch self {
        case .domain:
            entry.domains = list
        case .repo:
            var rules = entry.rules ?? ProjectRules()
            rules.repos = list
            entry.rules = rules.isEmpty ? nil : rules
        case .urlPrefix:
            var rules = entry.rules ?? ProjectRules()
            rules.urlPrefixes = list
            entry.rules = rules.isEmpty ? nil : rules
        }
        return entry
    }
}

/// Pure matching of what a frame, a meeting or an agent session carries against the catalog's
/// rules (#324). Never logs: a rule value is a URL, a host or a repo.
public struct ProjectRuleMatcher: Sendable {
    private let prefixes: [(prefix: String, entry: ProjectEntry)]
    private let repos: [String: ProjectEntry]
    private let domains: [(domain: String, entry: ProjectEntry)]

    /// The house entry's domains are your own (#318) and never name a project.
    public init(catalog: [ProjectEntry]) {
        var prefixes: [(String, ProjectEntry)] = []
        var repos: [String: ProjectEntry] = [:]
        var domains: [(String, ProjectEntry)] = []
        for entry in catalog.sorted(by: { $0.key < $1.key }) {
            for raw in entry.rules?.urlPrefixes ?? [] {
                if let value = Self.normalizedURLPrefix(raw) { prefixes.append((value, entry)) }
            }
            for raw in entry.rules?.repos ?? [] {
                if let value = Self.normalizedRepo(raw), repos[value] == nil { repos[value] = entry }
            }
            guard entry.kind != .house else { continue }
            for raw in entry.domains ?? [] {
                if let value = Self.normalizedDomain(raw) { domains.append((value, entry)) }
            }
        }
        // Longest first, so the first hit is the most specific one.
        self.prefixes = prefixes.sorted { $0.0.count == $1.0.count ? $0.1.key < $1.1.key : $0.0.count > $1.0.count }
        self.repos = repos
        self.domains = domains.sorted { $0.0.count == $1.0.count ? $0.1.key < $1.1.key : $0.0.count > $1.0.count }
    }

    public var isEmpty: Bool { prefixes.isEmpty && repos.isEmpty && domains.isEmpty }

    /// The entry whose URL prefix is the longest one any of `urls` starts with.
    public func project(forURLs urls: [String?]) -> ProjectEntry? {
        guard !prefixes.isEmpty else { return nil }
        let stripped = urls.compactMap { $0.flatMap(Self.strippedURL) }
        guard !stripped.isEmpty else { return nil }
        return prefixes.first { rule in stripped.contains { Self.url($0, startsWith: rule.prefix) } }?.entry
    }

    /// The entry a repo rule names for `repo` (`owner/repo`, any case).
    public func project(forRepo repo: String?) -> ProjectEntry? {
        guard let repo, let value = Self.normalizedRepo(repo) else { return nil }
        return repos[value]
    }

    /// The entry whose domain is the most specific one any of `hosts` equals or sits under.
    public func project(forHosts hosts: [String]) -> ProjectEntry? {
        guard !domains.isEmpty else { return nil }
        let cleaned = hosts.compactMap(Self.normalizedDomain)
        return domains.first { rule in cleaned.contains { Self.host($0, isUnder: rule.domain) } }?.entry
    }

    /// The entries the domains on a meeting name, each attendee domain by its most specific
    /// rule. More than one entry means the rule cannot say which.
    public func projects(forDomains attendeeDomains: [String]) -> [ProjectEntry] {
        var seen: Set<String> = []
        return attendeeDomains.compactMap { project(forHosts: [$0]) }.filter { seen.insert($0.key).inserted }
    }

    // MARK: Normalization

    /// Lowercased, with any `user@`, scheme, `www.`, path and surrounding dots dropped. Nil when
    /// what is left has no dot or holds a space.
    public static func normalizedDomain(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let slash = text.firstIndex(where: { "/?#:".contains($0) }) { text = String(text[..<slash]) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        guard text.contains("."), !text.contains(where: \.isWhitespace) else { return nil }
        return text
    }

    /// `owner/repo`, lowercased, from `owner/repo`, `github.com/owner/repo` or a GitHub URL.
    public static func normalizedRepo(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        if text.hasPrefix("github.com/") { text = String(text.dropFirst("github.com/".count)) }
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        let parts = text.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, !parts.joined().contains(where: \.isWhitespace) else { return nil }
        return parts.joined(separator: "/")
    }

    /// The stored form of a URL prefix: `strippedURL`, with no trailing slash. Nil when there is
    /// no host.
    public static func normalizedURLPrefix(_ value: String) -> String? {
        guard var text = strippedURL(value) else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        return text.isEmpty ? nil : text
    }

    /// `host/path`, lowercased, with no scheme, no `www.`, no query and no fragment: the only
    /// form of a URL a rule is ever compared with or stored as.
    public static func strippedURL(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<cut]) }
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        guard host.contains("."), !text.contains(where: \.isWhitespace) else { return nil }
        return text
    }

    /// The host of a URL, lowercased, or nil.
    public static func host(of url: String?) -> String? {
        guard let stripped = url.flatMap(strippedURL) else { return nil }
        let host = stripped.split(separator: "/", maxSplits: 1).first.map(String.init) ?? stripped
        return host.split(separator: ":").first.map(String.init)
    }

    /// `a.example.com` is under `example.com`; `notexample.com` is not.
    public static func host(_ host: String, isUnder domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    /// A prefix matches only up to a boundary: the URL is the prefix, or the prefix is followed
    /// by `/` (or by `:` when the prefix is a bare host and the URL carries a port).
    /// `notion.so/acme` covers `notion.so/acme/plan`, never `notion.so/acme-plan` or
    /// `notion.so/acm`; `acme.com` never covers `acme.com.br`.
    static func url(_ url: String, startsWith prefix: String) -> Bool {
        guard url.hasPrefix(prefix) else { return false }
        guard let next = url.dropFirst(prefix.count).first else { return true }
        return next == "/" || (next == ":" && !prefix.contains("/"))
    }
}
