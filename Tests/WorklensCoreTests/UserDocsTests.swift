import Foundation
import Testing

@testable import WorklensCore

/// The guard behind #127's README rewrite.
///
/// The README was cut from 3 849 words to about 1 600 by *moving* the developer-machine material
/// into `docs/user/` and `docs/contributing/` rather than deleting it, so the README and those
/// pages are now a web of relative links — and a moved or renamed file breaks them silently. The
/// same rewrite made two in-app messages name `docs/user/setup.md#keys`, which is a promise the
/// app makes about this repository and is worth checking the same way.
///
/// Source-scanning through `#filePath` follows `NetworkDestinationsDocTests` (#120). It stays
/// offline: the only thing read is this checkout.
@Suite("User documentation")
struct UserDocsTests {
    /// `Tests/WorklensCoreTests/<this file>` → the checkout.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Every Markdown file the rewrite owns: the two new directories, plus the three root
    /// documents that point into them. `PRIVACY.md` and `CONTRIBUTING.md` are here because the
    /// move is what can break their cross-references, not because #127 rewrote them.
    static func documents() -> [(path: String, url: URL)] {
        var found: [(String, URL)] = ["README.md", "PRIVACY.md", "CONTRIBUTING.md"].map {
            ($0, repoRoot.appendingPathComponent($0))
        }
        for dir in ["docs/user", "docs/user/integrations", "docs/contributing"] {
            let base = repoRoot.appendingPathComponent(dir)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".md") {
                found.append(("\(dir)/\(name)", base.appendingPathComponent(name)))
            }
        }
        return found
    }

    /// `[text](target)`, target captured — enough for the links these documents use, which are
    /// all inline. Reference-style links and bare autolinks (`<https://…>`) are not link targets
    /// this has to resolve.
    static let linkPattern = try! NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#)

    /// `<img src="…">`, source captured. #152 embeds the screenshots as HTML rather than as
    /// `![](…)` so they can be centred and sized, which puts them outside `linkPattern`
    /// altogether — a renamed or deleted PNG would break every one of them silently.
    static let imagePattern = try! NSRegularExpression(pattern: #"<img[^>]+src="([^"]+)""#)

    static func links(in text: String) -> [String] {
        matches(of: linkPattern, in: text) + matches(of: imagePattern, in: text)
    }

    static func matches(of pattern: NSRegularExpression, in text: String) -> [String] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    /// GitHub's heading slug: lowercased, punctuation dropped, spaces hyphenated.
    static func slug(_ heading: String) -> String {
        let text = heading.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        let kept = text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
        return kept.replacingOccurrences(of: " ", with: "-")
    }

    static func anchors(in text: String) -> Set<String> {
        Set(
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.hasPrefix("#") }
                .map { slug(String($0)) }
        )
    }

    /// A section the move relocated must not still be attributed to the README. These are prose
    /// pointers rather than Markdown links, so `linksResolve` cannot see them.
    @Test("no root document still names a README section that moved")
    func movedSectionsAreNotStillCreditedToTheReadme() throws {
        let readme = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("README.md"), encoding: .utf8)
        for heading in ["The Keychain dialog after every rebuild", "Two Macs"] {
            #expect(!readme.contains(heading), "\(heading) moved out of the README")
            for name in ["PRIVACY.md", "CONTRIBUTING.md"] {
                let text = try String(
                    contentsOf: Self.repoRoot.appendingPathComponent(name), encoding: .utf8)
                for line in text.split(separator: "\n") where line.contains(heading) {
                    #expect(
                        !line.contains("README"),
                        "\(name) credits the README with \"\(heading)\", which now lives elsewhere"
                    )
                }
            }
        }
    }

    @Test("every relative link and embedded image in the README and the user docs resolves")
    func linksResolve() throws {
        for (path, url) in Self.documents() {
            let text = try String(contentsOf: url, encoding: .utf8)
            let dir = url.deletingLastPathComponent()
            for link in Self.links(in: text) {
                if link.hasPrefix("http://") || link.hasPrefix("https://") { continue }
                if link.hasPrefix("#") { continue }
                let target = String(link.split(separator: "#", maxSplits: 1)[0])
                if target.isEmpty { continue }
                let resolved = dir.appendingPathComponent(target).standardizedFileURL
                #expect(
                    FileManager.default.fileExists(atPath: resolved.path),
                    "\(path) links to \(link), which is not in the checkout"
                )
            }
        }
    }

    @Test("every anchor those links name is a heading in the file they point at")
    func anchorsResolve() throws {
        for (path, url) in Self.documents() {
            let text = try String(contentsOf: url, encoding: .utf8)
            let dir = url.deletingLastPathComponent()
            for link in Self.links(in: text) where link.contains("#") {
                if link.hasPrefix("http://") || link.hasPrefix("https://") { continue }
                let parts = link.split(separator: "#", maxSplits: 1)
                let fragment = String(parts.count == 2 ? parts[1] : parts[0])
                let targetURL: URL =
                    link.hasPrefix("#")
                    ? url
                    : dir.appendingPathComponent(String(parts[0])).standardizedFileURL
                guard let targetText = try? String(contentsOf: targetURL, encoding: .utf8) else {
                    continue  // `linksResolve` is what reports a missing file.
                }
                #expect(
                    Self.anchors(in: targetText).contains(fragment),
                    "\(path) links to #\(fragment), which is not a heading in \(targetURL.lastPathComponent)"
                )
            }
        }
    }

    /// The menu line a Mac with no Gemini key shows, and the two CLI errors beside it, now name
    /// the page that says where a key comes from. A renamed page would leave the app telling the
    /// user to read something that is not there.
    @Test("the missing-key notice points at a page that exists, at a heading that exists")
    func missingKeyNoticeNamesTheSetupPage() throws {
        let message = SetupIssue.noGeminiKey.message
        #expect(message.contains("docs/user/setup.md#keys"))

        let setup = Self.repoRoot.appendingPathComponent("docs/user/setup.md")
        let text = try String(contentsOf: setup, encoding: .utf8)
        #expect(Self.anchors(in: text).contains("keys"))
        // The key URL lives on that page; the issue asked for it by name.
        #expect(text.contains("aistudio.google.com/apikey"))
    }

    /// #127's deliverable was a README aimed at someone who wants to *use* Worklens. The word
    /// count is the crudest possible proxy for that, and it is the one the issue names: the
    /// developer-machine material was ~2 340 of the original 3 849 words.
    ///
    /// #152 raised the ceiling from 2 000 to 2 250, and that is a measurement, not a budget: the
    /// README was 1 997 words the day before the first image landed, one word under the old cap.
    /// The four figures and the quoted sample report cost about 290 "words" to this splitter —
    /// an `<img>` tag with a real alt text is twenty on its own, and the splitter cannot tell
    /// those from prose — against which the prose the pictures replaced came to about 70: the
    /// menu's example status line (the hero shows it), the sentence that narrated the pipeline
    /// the data-flow diagram draws, the budget paragraph that "Cost" and the new Models & budget
    /// shot both already carried, and the CLI cost line beside that shot. Cutting the
    /// remaining 220 would have meant cutting the pictures. The number to watch is still prose
    /// creeping back in, so this stays snug.
    ///
    /// #144 raised it again, from 2 250 to 2 350, for the two paragraphs a reader asks for before
    /// installing and could not get anywhere else: how many megabytes a day of this costs, and the
    /// setting that makes the history age out. Both are the shortest form that says the number —
    /// the method and the full behaviour are in `docs/user/data.md`, which is where the detail
    /// belongs. The rule has not changed: a paragraph that could live in `docs/user/` does.
    @Test("the README stays a user-facing page rather than a lab notebook")
    func readmeStaysShort() throws {
        let readme = Self.repoRoot.appendingPathComponent("README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        #expect(words < 2_350, "README is \(words) words; it was rewritten at about 1 600")

        // The things a first-time user has to be told, none of which the old README said.
        #expect(text.contains("$2 a month"))
        #expect(text.contains("aistudio.google.com/apikey"))
        #expect(text.contains("billing-enabled"))
    }
}
