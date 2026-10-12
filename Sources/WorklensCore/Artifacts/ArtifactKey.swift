import Foundation

/// The document a screenshot was of (#319): a Google Docs, Sheets or Slides file, a GitHub PR or
/// issue, or a local file. Computed on read from the URLs a capture already stored, so nothing new
/// is kept and erasing a screenshot erases its key.
///
/// Pure. Only a URL's scheme, host and path are read: a query or fragment never changes the key
/// and is never recovered.
public enum ArtifactKey: Hashable, Sendable {
    public enum GoogleKind: String, Sendable, CaseIterable {
        case document, spreadsheets, presentation
    }

    public enum GitHubKind: String, Sendable {
        case pull, issues
    }

    case google(kind: GoogleKind, id: String)
    /// `owner` and `repo` are lowercased: GitHub treats them case-insensitively.
    case github(owner: String, repo: String, kind: GitHubKind, number: Int)
    case local(path: String)

    /// `docs.google.com/<kind>/d/<id>`, `github.com/<o>/<r>/pull/<n>` or `file:<path>`.
    public var canonical: String {
        switch self {
        case let .google(kind, id): "docs.google.com/\(kind.rawValue)/d/\(id)"
        case let .github(owner, repo, kind, number): "github.com/\(owner)/\(repo)/\(kind.rawValue)/\(number)"
        case let .local(path): "file:\(path)"
        }
    }

    /// The key for a capture: its `browser_url` when that names a document, else its
    /// `ax_snapshots.document_url`. Nil when neither does.
    public static func resolve(url: String?, documentURL: String?) -> ArtifactKey? {
        parse(url) ?? parse(documentURL)
    }

    /// One URL's key, or nil for anything that is not a document this knows.
    public static func parse(_ raw: String?) -> ArtifactKey? {
        guard let raw, let components = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased()
        else { return nil }
        if scheme == "file" {
            // `URLComponents.path` is already percent-decoded: `a%20b.md` reads `a b.md`.
            // A folder reads the same with or without its trailing `/` (a Terminal cwd vs a file URL).
            var path = components.path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path.isEmpty ? nil : .local(path: path)
        }
        guard scheme == "http" || scheme == "https", let host = components.host?.lowercased() else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        switch host {
        case "docs.google.com": return google(parts)
        case "github.com", "www.github.com": return github(parts)
        default: return nil
        }
    }

    /// `/{document|spreadsheets|presentation}/(u/<n>/)?d/<id>`, any subpath after the id. A published
    /// file, `/d/e/<pubId>/pub`, is keyed by its `<pubId>`.
    private static func google(_ parts: [String]) -> ArtifactKey? {
        guard let first = parts.first, let kind = GoogleKind(rawValue: first) else { return nil }
        var rest = parts.dropFirst()
        if rest.first == "u", rest.count >= 2, Int(rest[rest.startIndex + 1]) != nil {
            rest = rest.dropFirst(2)
        }
        guard rest.first == "d", rest.count >= 2 else { return nil }
        var id = rest[rest.startIndex + 1]
        if id == "e" {
            guard rest.count >= 3 else { return nil }
            id = rest[rest.startIndex + 2]
        }
        return id.isEmpty ? nil : .google(kind: kind, id: id)
    }

    /// `/<o>/<r>/{pull|issues}/<digits>`, any subpath after the number.
    private static func github(_ parts: [String]) -> ArtifactKey? {
        guard parts.count >= 4, let kind = GitHubKind(rawValue: parts[2]),
              parts[3].allSatisfy(\.isASCII), parts[3].allSatisfy(\.isNumber), let number = Int(parts[3])
        else { return nil }
        return .github(owner: parts[0].lowercased(), repo: parts[1].lowercased(), kind: kind, number: number)
    }

    /// What a row is called when no frame named it: `owner/repo#12`, `Google Slides`, the file name.
    public var shortName: String {
        switch self {
        case .google(.document, _): "Google Docs"
        case .google(.spreadsheets, _): "Google Sheets"
        case .google(.presentation, _): "Google Slides"
        case let .github(owner, repo, _, number): "\(owner)/\(repo)#\(number)"
        case let .local(path):
            (path.split(separator: "/").last.map(String.init)) ?? path
        }
    }

    /// The key a stats row carries: `canonical`, with your home folder written as `~`.
    public func displayKey(home: String = NSHomeDirectory()) -> String {
        guard case let .local(path) = self else { return canonical }
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return canonical }
        if path == home { return "file:~" }
        if path.hasPrefix(home + "/") { return "file:~" + path.dropFirst(home.count) }
        return canonical
    }

    /// `owner/repo` and the number, for joining against a shipped row (#314's `repo`, `number`).
    var githubReference: (repo: String, number: Int)? {
        guard case let .github(owner, repo, _, number) = self else { return nil }
        return ("\(owner)/\(repo)", number)
    }
}
