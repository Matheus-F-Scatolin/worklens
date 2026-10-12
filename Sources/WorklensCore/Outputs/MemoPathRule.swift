import Foundation

/// One company memo a merged PR touched (#317).
public struct MemoEvent: Sendable, Equatable {
    /// The company folder: `acme-corp` in `corpus/companies/acme-corp/memo.md`.
    public var slug: String
    public var kind: OutputKind
    /// The memo file the event came from.
    public var path: String

    public init(slug: String, kind: OutputKind, path: String) {
        self.slug = slug
        self.kind = kind
        self.path = path
    }
}

/// Which files of a merged PR are a company memo, and what happened to it (#317). Pure.
///
/// Only `corpus/companies/<slug>/<file>.md` counts, `<file>` not starting with `_`: the
/// `_history/` snapshots and `_updates/` logs a memo update also writes sit a folder deeper, and
/// the rendered `.html` beside the memo is a copy of it. ADDED is a publish; MODIFIED, RENAMED and
/// CHANGED are an update; DELETED and anything else is nothing. One event per company folder, and
/// a publish wins over an update in the same PR.
public enum MemoPathRule {
    /// What `provenance` says on every memo row.
    public static let provenance = "memo-path-rule v1"

    /// One changed file, as `gh pr view --json files` lists it.
    public struct File: Decodable, Sendable, Equatable {
        public var path: String
        public var changeType: String?

        public init(path: String, changeType: String?) {
            self.path = path
            self.changeType = changeType
        }
    }

    /// `gh pr view <n> --repo <owner/name> --json files`.
    public static func filesArguments(repo: String, number: Int) -> [String] {
        ["pr", "view", String(number), "--repo", repo, "--json", "files"]
    }

    public static func decodeFiles(_ data: Data) throws -> [File] {
        struct Answer: Decodable { let files: [File]? }
        return try JSONDecoder().decode(Answer.self, from: data).files ?? []
    }

    /// The memo events in one PR's file list, in the order their folders first appear.
    public static func events(files: [File]) -> [MemoEvent] {
        var order: [String] = []
        var bySlug: [String: MemoEvent] = [:]
        for file in files {
            guard let slug = slug(of: file.path), let kind = kind(of: file.changeType) else { continue }
            if let existing = bySlug[slug] {
                if existing.kind != .memoPublished, kind == .memoPublished {
                    bySlug[slug] = MemoEvent(slug: slug, kind: kind, path: file.path)
                }
            } else {
                order.append(slug)
                bySlug[slug] = MemoEvent(slug: slug, kind: kind, path: file.path)
            }
        }
        return order.compactMap { bySlug[$0] }
    }

    /// `events(files:)` over `(path, changeType)` pairs, for tests and callers without `File`s.
    public static func events(files: [(String, String)]) -> [MemoEvent] {
        events(files: files.map { File(path: $0.0, changeType: $0.1) })
    }

    /// The company folder of an exact `corpus/companies/<slug>/<file>.md`, or nil.
    public static func slug(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "corpus", parts[1] == "companies" else { return nil }
        let slug = parts[2]
        let file = parts[3]
        guard !slug.isEmpty, !slug.hasPrefix("_"), !slug.hasPrefix("."),
              !file.hasPrefix("_"), file.lowercased().hasSuffix(".md"), file.count > 3
        else { return nil }
        return slug
    }

    static func kind(of changeType: String?) -> OutputKind? {
        switch changeType?.uppercased() {
        case "ADDED": .memoPublished
        case "MODIFIED", "RENAMED", "CHANGED": .memoUpdated
        default: nil
        }
    }
}

/// Which catalog entry a memo's company folder names (#317). Pure.
///
/// Three tries, each stopping at the first that answers: the slug as written; the slug with `-`
/// and `_` read as spaces (`ProjectEntry.matches` folds case and accents, not hyphens); and the
/// slug without separators against every spelling with a domain suffix taken off, so
/// `acme-corp` finds an entry that answers to `acmecorp.com`. Two entries answering the same try
/// is ambiguous: nothing is linked and nothing is created. The house entry is never a memo's
/// company.
public enum MemoCompanyMatcher {
    public enum Match: Sendable, Equatable {
        case one(ProjectEntry)
        case none
        case ambiguous
    }

    public static func match(slug: String, in projects: [ProjectEntry]) -> Match {
        let candidates = projects.filter { $0.kind != .house }
        let spaced = spacedSlug(slug)
        let tries: [(ProjectEntry) -> Bool] = [
            { $0.matches(slug) },
            { $0.matches(spaced) },
            { entry in
                let wanted = compact(slug)
                guard !wanted.isEmpty else { return false }
                let key = entry.key.hasPrefix("company:") ? String(entry.key.dropFirst(8)) : entry.key
                return ([key] + entry.spellings).contains { compact(withoutDomainSuffix($0)) == wanted }
            },
        ]
        for test in tries {
            let found = candidates.filter(test)
            if found.count == 1 { return .one(found[0]) }
            if found.count > 1 { return .ambiguous }
        }
        return .none
    }

    /// `acme-corp` → `acme corp`.
    static func spacedSlug(_ slug: String) -> String {
        String(slug.map { $0 == "-" || $0 == "_" ? " " : $0 })
    }

    /// The name a created entry is given: `acme-corp` → `Acme Corp`.
    public static func displayName(slug: String) -> String {
        spacedSlug(slug)
            .split(whereSeparator: \.isWhitespace)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Folded, with every space, `-`, `_` and `.` taken out.
    static func compact(_ text: String) -> String {
        ProjectEntry.fold(text).filter { !" -_.".contains($0) }
    }

    /// `acmecorp.com` → `acmecorp`; anything that is not a bare domain comes back unchanged.
    static func withoutDomainSuffix(_ text: String) -> String {
        let folded = ProjectEntry.fold(text)
        let labels = folded.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }),
              let last = labels.last, last.allSatisfy(\.isLetter)
        else { return text }
        return String(labels[0])
    }
}
