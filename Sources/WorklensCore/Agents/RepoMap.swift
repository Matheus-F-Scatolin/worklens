import Foundation

/// Which repo an agent session worked in (#321). Pure: the stored sessions in, a repo and the
/// rule that named it out. Never runs `git` and never reads a folder: everything it knows is
/// what the logs already said.
///
/// In order: the session's own PR links name a repo; else a Codex rollout's
/// `git.repository_url`; else the repo every other session in the same root learned, when they
/// agree on one; else the root's folder name, when no session in it ever linked a repo. A root
/// whose sessions learned two repos stays nil.
public enum RepoMap {
    public static let ruleOwnPR = "own_pr"
    public static let ruleRemote = "git_remote"
    public static let ruleLearned = "learned_root"
    public static let ruleFolder = "folder"
    public static let ruleAmbiguous = "ambiguous"

    public struct Session: Sendable, Equatable {
        public var id: String
        public var tool: String
        public var cwd: String?
        public var start: Date?
        public var end: Date?
        /// `owner/name` of every PR the session linked, repeats allowed.
        public var prRepos: [String]
        public var vcsRepo: String?

        public init(
            id: String, tool: String, cwd: String?, start: Date? = nil, end: Date? = nil,
            prRepos: [String] = [], vcsRepo: String? = nil
        ) {
            self.id = id
            self.tool = tool
            self.cwd = cwd
            self.start = start
            self.end = end
            self.prRepos = prRepos
            self.vcsRepo = vcsRepo
        }
    }

    public struct Resolution: Sendable, Equatable {
        public var repo: String?
        public var rule: String?
        public var parentId: String?

        public init(repo: String?, rule: String?, parentId: String? = nil) {
            self.repo = repo
            self.rule = rule
            self.parentId = parentId
        }
    }

    static let worktreeMarker = "/.claude/worktrees/"

    /// `<root>/.claude/worktrees/<name>[/…]` folds to `<root>`; anything else is its own root.
    public static func root(of cwd: String) -> String {
        let trimmed = cwd.hasSuffix("/") && cwd.count > 1 ? String(cwd.dropLast()) : cwd
        guard let range = trimmed.range(of: worktreeMarker) else { return trimmed }
        return String(trimmed[..<range.lowerBound])
    }

    /// The worktree folder itself, `<root>/.claude/worktrees/<name>`, or nil outside one.
    static func worktree(of cwd: String) -> String? {
        guard let range = cwd.range(of: worktreeMarker) else { return nil }
        let name = cwd[range.upperBound...].split(separator: "/").first.map(String.init) ?? ""
        guard !name.isEmpty else { return nil }
        return String(cwd[..<range.upperBound]) + name
    }

    /// `owner/name` from `https://github.com/o/r(.git)`, `git@github.com:o/r.git` or `o/r`.
    public static func repo(remoteURL: String) -> String? {
        var text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        if text.hasSuffix("/") { text = String(text.dropLast()) }
        if let range = text.range(of: "github.com") {
            text = String(text[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
        } else if text.contains("://") || text.contains("@") {
            return nil
        }
        let parts = text.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    public static func resolve(_ sessions: [Session]) -> [String: Resolution] {
        var own: [String: Resolution] = [:]
        // What every root learned from sessions that named their repo themselves.
        var learned: [String: Set<String>] = [:]
        for session in sessions {
            let resolution: Resolution?
            if let repo = mostFrequent(session.prRepos) {
                resolution = Resolution(repo: repo, rule: ruleOwnPR)
            } else if let repo = session.vcsRepo {
                resolution = Resolution(repo: repo, rule: ruleRemote)
            } else {
                resolution = nil
            }
            guard let resolution else { continue }
            own[session.id] = resolution
            if let cwd = session.cwd, let repo = resolution.repo {
                learned[root(of: cwd), default: []].insert(repo)
            }
        }

        var out: [String: Resolution] = [:]
        for session in sessions {
            var resolution: Resolution
            if let mine = own[session.id] {
                resolution = mine
            } else if let cwd = session.cwd {
                let root = root(of: cwd)
                let repos = learned[root] ?? []
                if repos.count == 1, let repo = repos.first {
                    resolution = Resolution(repo: repo, rule: ruleLearned)
                } else if repos.isEmpty {
                    let folder = (root as NSString).lastPathComponent
                    resolution = folder.isEmpty || folder == "/"
                        ? Resolution(repo: nil, rule: nil)
                        : Resolution(repo: folder, rule: ruleFolder)
                } else {
                    resolution = Resolution(repo: nil, rule: ruleAmbiguous)
                }
            } else {
                resolution = Resolution(repo: nil, rule: nil)
            }
            resolution.parentId = parent(of: session, among: sessions)
            out[session.id] = resolution
        }
        return out
    }

    /// A Codex run inside a Claude Code worktree is a consult: its parent is the Claude session
    /// in the same worktree that overlaps it most.
    static func parent(of session: Session, among sessions: [Session]) -> String? {
        guard session.tool == AgentStoreParsers.codex,
              let cwd = session.cwd, let tree = worktree(of: cwd),
              let start = session.start
        else { return nil }
        let end = session.end ?? start
        var best: (id: String, overlap: TimeInterval)?
        for other in sessions where other.tool == AgentStoreParsers.claudeCode {
            guard let otherCwd = other.cwd, worktree(of: otherCwd) == tree,
                  let otherStart = other.start
            else { continue }
            let otherEnd = other.end ?? otherStart
            let overlap = min(end, otherEnd).timeIntervalSince(max(start, otherStart))
            guard overlap >= 0 else { continue }
            if best == nil || overlap > best!.overlap { best = (other.id, overlap) }
        }
        return best?.id
    }

    private static func mostFrequent(_ repos: [String]) -> String? {
        guard !repos.isEmpty else { return nil }
        let counts = Dictionary(repos.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }
}
