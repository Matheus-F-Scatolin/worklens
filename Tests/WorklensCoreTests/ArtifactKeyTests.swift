import Foundation
import Testing
@testable import WorklensCore

@Suite("ArtifactKey (#319)")
struct ArtifactKeyTests {
    private func key(_ url: String) -> ArtifactKey? { ArtifactKey.parse(url) }

    @Test("Docs, Sheets and Slides resolve, with /present and /u/1/d/")
    func google() {
        #expect(key("https://docs.google.com/document/d/abc123/edit") == .google(kind: .document, id: "abc123"))
        #expect(key("https://docs.google.com/spreadsheets/d/s1/edit") == .google(kind: .spreadsheets, id: "s1"))
        #expect(key("https://docs.google.com/presentation/d/p1/present") == .google(kind: .presentation, id: "p1"))
        #expect(key("https://docs.google.com/document/u/1/d/abc123/edit") == .google(kind: .document, id: "abc123"))
        #expect(key("https://docs.google.com/presentation/d/p1")?.canonical == "docs.google.com/presentation/d/p1")
    }

    @Test("a published file is keyed by its own id, not by `e`")
    func googlePublished() {
        #expect(key("https://docs.google.com/document/d/e/2PACX-a/pub") == .google(kind: .document, id: "2PACX-a"))
        #expect(key("https://docs.google.com/presentation/d/e/2PACX-b/pub?start=false")
            == .google(kind: .presentation, id: "2PACX-b"))
        #expect(key("https://docs.google.com/document/d/e/2PACX-a/pub") != key("https://docs.google.com/document/d/e/2PACX-c/pub"))
        #expect(key("https://docs.google.com/document/d/e") == nil)
    }

    @Test("a query and a fragment never change the key")
    func queryIgnored() {
        #expect(key("https://docs.google.com/document/d/abc/edit?usp=x#h") == key("https://docs.google.com/document/d/abc/edit"))
        #expect(key("https://github.com/o/r/pull/3?w=1#diff") == key("https://github.com/o/r/pull/3"))
    }

    @Test("a PR with a subpath, an issue and a mixed-case owner resolve")
    func github() {
        #expect(key("https://github.com/Owner/Repo/pull/12/files") == .github(owner: "owner", repo: "repo", kind: .pull, number: 12))
        #expect(key("https://github.com/o/r/issues/7") == .github(owner: "o", repo: "r", kind: .issues, number: 7))
        #expect(key("https://github.com/Matheus-F-Scatolin/worklens/pull/319")?.canonical
            == "github.com/matheus-f-scatolin/worklens/pull/319")
        #expect(key("https://github.com/Owner/Repo/pull/12")?.shortName == "owner/repo#12")
    }

    @Test("a PR list, blob/, a gist, Forms and chrome:// give nil")
    func notDocuments() {
        #expect(key("https://github.com/o/r/pulls") == nil)
        #expect(key("https://github.com/o/r/pull/") == nil)
        #expect(key("https://github.com/o/r/blob/main/README.md") == nil)
        #expect(key("https://gist.github.com/o/abc123") == nil)
        #expect(key("https://docs.google.com/forms/d/f1/viewform") == nil)
        #expect(key("chrome://settings") == nil)
        #expect(key("https://example.com/document/d/x") == nil)
        #expect(key("not a url") == nil)
        #expect(key("") == nil)
    }

    @Test("a file: path is percent-decoded")
    func local() {
        #expect(key("file:///Users/me/notes/a%20b.md") == .local(path: "/Users/me/notes/a b.md"))
        #expect(key("file:///Users/me/notes/a%20b.md")?.shortName == "a b.md")
        #expect(key("file:///Users/me/x.md")?.canonical == "file:/Users/me/x.md")
        #expect(key("file:///Users/me/code/worklens/") == key("file:///Users/me/code/worklens"))
        #expect(key("file:///") == .local(path: "/"))
    }

    @Test("your home folder reads as ~")
    func home() {
        #expect(ArtifactKey.local(path: "/Users/me/x.md").displayKey(home: "/Users/me") == "file:~/x.md")
        #expect(ArtifactKey.local(path: "/Users/mel/x.md").displayKey(home: "/Users/me") == "file:/Users/mel/x.md")
        #expect(ArtifactKey.github(owner: "o", repo: "r", kind: .pull, number: 1).displayKey(home: "/Users/me")
            == "github.com/o/r/pull/1")
    }

    @Test("url wins over documentURL, which fills in when url names nothing")
    func urlWins() {
        let pr = "https://github.com/o/r/pull/1"
        let doc = "https://docs.google.com/document/d/abc/edit"
        #expect(ArtifactKey.resolve(url: pr, documentURL: doc) == .github(owner: "o", repo: "r", kind: .pull, number: 1))
        #expect(ArtifactKey.resolve(url: "https://example.com", documentURL: doc) == .google(kind: .document, id: "abc"))
        #expect(ArtifactKey.resolve(url: nil, documentURL: "file:///tmp/a.md") == .local(path: "/tmp/a.md"))
        #expect(ArtifactKey.resolve(url: nil, documentURL: nil) == nil)
    }
}
