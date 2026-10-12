import Foundation
import Testing
@testable import WorklensCore

@Suite("RepoMap")
struct RepoMapTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("a worktree folds to the checkout it belongs to")
    func worktreeFold() {
        #expect(RepoMap.root(of: "/Users/me/code/app/.claude/worktrees/fix-x") == "/Users/me/code/app")
        #expect(RepoMap.root(of: "/Users/me/code/app/.claude/worktrees/fix-x/Sources") == "/Users/me/code/app")
        #expect(RepoMap.root(of: "/Users/me/code/app/") == "/Users/me/code/app")
        #expect(RepoMap.worktree(of: "/Users/me/code/app/.claude/worktrees/fix-x/Sources") == "/Users/me/code/app/.claude/worktrees/fix-x")
        #expect(RepoMap.worktree(of: "/Users/me/code/app") == nil)
    }

    @Test("own PR, then git remote, then the learned root, then the folder")
    func order() {
        let sessions = [
            RepoMap.Session(id: "pr", tool: "claude_code", cwd: "/c/app/.claude/worktrees/a", prRepos: ["me/app", "me/app", "me/lib"]),
            RepoMap.Session(id: "remote", tool: "codex", cwd: "/c/tool", vcsRepo: "me/tool"),
            RepoMap.Session(id: "learned", tool: "claude_code", cwd: "/c/app/.claude/worktrees/b"),
            RepoMap.Session(id: "folder", tool: "claude_code", cwd: "/c/notes"),
            RepoMap.Session(id: "nowhere", tool: "claude_code", cwd: nil),
        ]
        let map = RepoMap.resolve(sessions)
        #expect(map["pr"] == RepoMap.Resolution(repo: "me/app", rule: RepoMap.ruleOwnPR))
        #expect(map["remote"] == RepoMap.Resolution(repo: "me/tool", rule: RepoMap.ruleRemote))
        #expect(map["learned"] == RepoMap.Resolution(repo: "me/app", rule: RepoMap.ruleLearned))
        #expect(map["folder"] == RepoMap.Resolution(repo: "notes", rule: RepoMap.ruleFolder))
        #expect(map["nowhere"] == RepoMap.Resolution(repo: nil, rule: nil))
    }

    @Test("a root two repos were learned from stays unassigned")
    func ambiguous() {
        let map = RepoMap.resolve([
            RepoMap.Session(id: "a", tool: "claude_code", cwd: "/c/mono", prRepos: ["me/one"]),
            RepoMap.Session(id: "b", tool: "claude_code", cwd: "/c/mono/.claude/worktrees/x", prRepos: ["me/two"]),
            RepoMap.Session(id: "c", tool: "claude_code", cwd: "/c/mono/.claude/worktrees/y"),
        ])
        #expect(map["c"] == RepoMap.Resolution(repo: nil, rule: RepoMap.ruleAmbiguous))
        #expect(map["a"]?.repo == "me/one")
    }

    @Test("a Codex run in a Claude worktree takes the overlapping Claude session as its parent")
    func codexParent() {
        let tree = "/c/app/.claude/worktrees/fix"
        let map = RepoMap.resolve([
            RepoMap.Session(id: "short", tool: "claude_code", cwd: tree, start: t0, end: t0 + 300),
            RepoMap.Session(id: "long", tool: "claude_code", cwd: tree + "/Sources", start: t0, end: t0 + 3_600),
            RepoMap.Session(id: "elsewhere", tool: "claude_code", cwd: "/c/app/.claude/worktrees/other", start: t0, end: t0 + 7_200),
            RepoMap.Session(id: "consult", tool: "codex", cwd: tree, start: t0 + 600, end: t0 + 1_200, vcsRepo: "me/app"),
            RepoMap.Session(id: "late", tool: "codex", cwd: tree, start: t0 + 9_000, end: t0 + 9_100),
            RepoMap.Session(id: "plain", tool: "codex", cwd: "/c/app", start: t0, end: t0 + 100),
        ])
        #expect(map["consult"]?.parentId == "long")
        #expect(map["late"]?.parentId == nil)
        #expect(map["plain"]?.parentId == nil)
        #expect(map["long"]?.parentId == nil)
    }
}
