import Foundation
import Testing

@testable import WorklensCore

/// `HelpLink` is a promise about a file in this repository: every case names a section of
/// `docs/user/troubleshooting.md`, and the menu, the settings panes and the CLI print it. A
/// renamed heading would leave the app pointing at nothing, so the anchors are checked the same
/// way `UserDocsTests` checks the links between the pages — offline, reading only this checkout.
@Suite("Help links")
struct HelpLinkTests {
    /// `Tests/WorklensCoreTests/<this file>` → the checkout.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// GitHub's heading slug: lowercased, punctuation dropped, spaces hyphenated.
    static func slug(_ heading: String) -> String {
        let text = heading.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        let kept = text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
        return kept.replacingOccurrences(of: " ", with: "-")
    }

    static func troubleshootingAnchors() throws -> Set<String> {
        let page = repoRoot.appendingPathComponent(HelpLink.page)
        let text = try String(contentsOf: page, encoding: .utf8)
        return Set(
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.hasPrefix("#") }
                .map { slug(String($0)) }
        )
    }

    @Test("every help link names a heading that exists in the troubleshooting page")
    func anchorsExist() throws {
        let anchors = try Self.troubleshootingAnchors()
        for link in HelpLink.allCases {
            #expect(
                anchors.contains(link.anchor),
                "#\(link.anchor) is not a heading in \(HelpLink.page)"
            )
        }
    }

    @Test("the symptoms the issue named each have a link")
    func theNamedSymptomsAreCovered() {
        // #142 listed these by name; they are the ones the app can point at from an error.
        // Named by anchor rather than by case, so dropping a case fails this test rather than
        // only failing to compile it.
        let required = [
            "the-menu-bar-icon-is-red",
            "frames-pile-up-as-pending-or-over-budget",
            "todays-counts-reset-after-a-make-run",
            "the-timeline-says-chrome-but-never-which-page",
            "macos-asks-for-a-permission-again-after-a-rebuild",
            "a-keychain-dialog-on-every-new-build",
            "there-is-no-update-and-restart-item",
            "the-update-failed",
        ]
        let anchors = Set(HelpLink.allCases.map(\.anchor))
        for anchor in required {
            #expect(anchors.contains(anchor), "no HelpLink case answers #\(anchor)")
        }
    }

    @Test("no two cases share an anchor")
    func anchorsAreUnique() {
        #expect(Set(HelpLink.allCases.map(\.anchor)).count == HelpLink.allCases.count)
    }

    @Test("the printed path is the page plus the anchor")
    func repoRelativePathIsThePageAndAnchor() {
        #expect(
            HelpLink.screenRecordingOff.repoRelativePath
                == "docs/user/troubleshooting.md#nothing-is-being-captured"
        )
    }

    @Test("the web fallback is a blob URL on this repository")
    func webURLPointsAtTheRepository() {
        let url = HelpLink.updateFailed.webURL
        #expect(url.absoluteString.hasPrefix(HelpLink.repositoryURL + "/blob/main/"))
        #expect(url.absoluteString.hasSuffix("#the-update-failed"))
    }

    @Test("a checkout that has the page wins over the web URL")
    func localFileIsPreferred() {
        let checkout = URL(fileURLWithPath: "/tmp/worklens-checkout")
        let resolved = HelpLink.redIcon.url(inCheckout: checkout, fileExists: { _ in true })
        #expect(resolved.isFileURL)
        #expect(resolved.path == "/tmp/worklens-checkout/" + HelpLink.page)
    }

    @Test("no checkout, or a checkout missing the page, falls back to GitHub")
    func webURLIsTheFallback() {
        #expect(
            HelpLink.redIcon.url(inCheckout: nil, fileExists: { _ in true })
                == HelpLink.redIcon.webURL
        )
        let checkout = URL(fileURLWithPath: "/tmp/worklens-checkout")
        #expect(
            HelpLink.redIcon.url(inCheckout: checkout, fileExists: { _ in false })
                == HelpLink.redIcon.webURL
        )
    }

    /// The real checkout this test runs in: the page is there, so resolution must find it.
    @Test("resolution finds the page in this checkout")
    func resolvesInThisCheckout() {
        let resolved = HelpLink.redIcon.url(inCheckout: Self.repoRoot)
        #expect(resolved.isFileURL)
        #expect(FileManager.default.fileExists(atPath: resolved.path))
    }
}
