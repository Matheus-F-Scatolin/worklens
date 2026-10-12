import Foundation
import Testing

/// The guard behind PRIVACY.md's "What leaves your machine" table (#120).
///
/// That table claims to be the whole list of hosts this repository can reach, and the document's
/// opening promise is that every claim names the file implementing it. Both were false for six
/// hosts until #120: the table said "no update check" while `AutoUpdater` ran `git ls-remote`
/// against `origin` every fifteen minutes, and none of the context sources appeared at all. A
/// document that drifts is worse than no document, so the agreement is checked rather than
/// remembered.
///
/// The scan is deliberately two-pronged. URL literals catch the HTTP clients, and the *subprocess*
/// pass catches the destination that caused the issue: GitHub is reached by handing `git` an
/// argument list, with no `https://` anywhere in `Sources/`.
///
/// Source-scanning through `#filePath` follows `MCPToolsTests.argumentsAreNotLogged`. It stays
/// offline: the only thing read is this checkout.
@Suite("Network destinations match PRIVACY.md")
struct NetworkDestinationsDocTests {
    /// `Tests/WorklensCoreTests/<this file>` → the checkout.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Hosts that never leave the Mac: the OAuth redirect lands on a loopback server this app
    /// opens for a few seconds (`Context/Google/LoopbackReceiver.swift`).
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "0.0.0.0"]

    /// `git` subcommands that talk to a remote. `rev-parse`, `status` and `branch` do not, which
    /// is why the check names the network ones rather than flagging every `git` call.
    static let networkGitSubcommands = ["ls-remote", "fetch", "pull", "push", "clone"]

    /// The rows of the destinations table, which is what both checks are read against.
    static func destinationsTable() throws -> String {
        let privacy = try String(
            contentsOf: repoRoot.appendingPathComponent("PRIVACY.md"), encoding: .utf8
        )
        let lines = privacy.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## What leaves your machine") })
        else {
            Issue.record("PRIVACY.md has no '## What leaves your machine' section")
            return ""
        }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
        return lines[start..<end].joined(separator: "\n")
    }

    static func swiftSources() throws -> [(path: String, text: String)] {
        let sources = repoRoot.appendingPathComponent("Sources")
        guard let walk = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil
        ) else { return [] }
        var out: [(String, String)] = []
        for case let url as URL in walk where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            out.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Every `"http…"` literal in a source file, as (host, file). Only quoted literals count: a
    /// documentation link in a comment (`https://docs.granola.ai/…` in `GranolaSource`) is not a
    /// call, and the leading quote is what separates the two.
    static func hostsInURLLiterals() throws -> [(host: String, file: String)] {
        let pattern = try NSRegularExpression(pattern: "\"(https?://[^\"]*)\"")
        var found: [(String, String)] = []
        for (path, text) in try Self.swiftSources() {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let literal = Range(match.range(at: 1), in: text).map({ String(text[$0]) })
                else { continue }
                // `"https://"` in `Taxonomy` is a scheme test, not an address.
                let rest = literal.drop(while: { $0 != "/" }).dropFirst(2)
                let host = String(rest.prefix { $0 != "/" && $0 != ":" && $0 != "\\" })
                guard !host.isEmpty, !loopbackHosts.contains(host) else { continue }
                found.append((host, path))
            }
        }
        return found
    }

    @Test("every host a URL literal names has a row in the PRIVACY.md table")
    func urlHostsAreDocumented() throws {
        let table = try Self.destinationsTable()
        let hosts = try Self.hostsInURLLiterals()
        #expect(!hosts.isEmpty, "the scan found no URL literals at all — it has stopped working")
        for (host, file) in hosts where !table.contains(host) {
            Issue.record(
                """
                \(file) reaches \(host), which PRIVACY.md's "What leaves your machine" table does \
                not name. Add a row saying what is sent, when, and how to turn it off — or delete \
                the call.
                """
            )
        }
    }

    @Test("a git subcommand that talks to a remote has a row too")
    func subprocessDestinationsAreDocumented() throws {
        // The case #120 was opened for: `git(["ls-remote", "origin", …])` reaches GitHub with no
        // URL anywhere in the file, so the literal scan above cannot see it.
        let table = try Self.destinationsTable()
        var seen: [(String, String)] = []
        for (path, text) in try Self.swiftSources() {
            for subcommand in Self.networkGitSubcommands where text.contains("\"\(subcommand)\"") {
                seen.append((subcommand, path))
            }
        }
        #expect(
            seen.contains { $0.0 == "ls-remote" },
            "the auto-updater's `git ls-remote` is gone — drop its row from PRIVACY.md too"
        )
        for (subcommand, file) in seen where !table.contains(subcommand) {
            Issue.record(
                """
                \(file) runs `git \(subcommand)`, which reaches a remote, and PRIVACY.md's "What \
                leaves your machine" table does not mention it.
                """
            )
        }
    }
}
