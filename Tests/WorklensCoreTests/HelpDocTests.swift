import Foundation
import Testing

@testable import WorklensCore

/// `HelpDoc` is a promise about files in this repository and about what `scripts/bundle.sh`
/// copies into the app (#153): every case names a document that exists, every Settings pane
/// names one, and resolution prefers the bundled copy — which is the whole reason the type
/// exists, because the repository is private and a `github.com` link opens for nobody else.
///
/// Offline, like `HelpLinkTests`: the only thing read is this checkout.
@Suite("Help documents")
struct HelpDocTests {
    /// `Tests/WorklensCoreTests/<this file>` → the checkout.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test("every document exists in this checkout")
    func documentsExist() {
        for doc in HelpDoc.allCases {
            let file = Self.repoRoot.appendingPathComponent(doc.repoRelativePath)
            #expect(
                FileManager.default.fileExists(atPath: file.path),
                "\(doc.repoRelativePath) is not in the repository"
            )
        }
    }

    @Test("every document is one bundle.sh copies into Contents/Resources")
    func bundleShipsEveryDocument() throws {
        let script = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("scripts/bundle.sh"), encoding: .utf8
        )
        for doc in HelpDoc.allCases {
            // The top-level files are named; the pages under `docs/user/` arrive as a directory
            // copy, so the prefix is what the script has to mention.
            let needle = doc.repoRelativePath.hasPrefix("docs/") ? "docs/user" : doc.repoRelativePath
            #expect(
                script.contains(needle),
                "scripts/bundle.sh copies nothing that would carry \(doc.repoRelativePath)"
            )
        }
    }

    @Test("the bundled copy wins, then the checkout, then GitHub")
    func resolutionOrder() {
        let resources = URL(fileURLWithPath: "/Applications/Worklens.app/Contents/Resources")
        let checkout = URL(fileURLWithPath: "/tmp/worklens-checkout")

        let bundled = HelpDoc.privacy.url(
            bundledIn: resources, inCheckout: checkout, fileExists: { _ in true }
        )
        #expect(bundled.path == resources.appendingPathComponent("PRIVACY.md").path)

        let fromCheckout = HelpDoc.privacy.url(
            bundledIn: resources,
            inCheckout: checkout,
            fileExists: { $0.path.hasPrefix(checkout.path) }
        )
        #expect(fromCheckout.path == checkout.appendingPathComponent("PRIVACY.md").path)

        #expect(
            HelpDoc.privacy.url(bundledIn: resources, inCheckout: checkout, fileExists: { _ in false })
                == HelpDoc.privacy.webURL
        )
        #expect(
            HelpDoc.privacy.url(bundledIn: nil, inCheckout: nil, fileExists: { _ in true })
                == HelpDoc.privacy.webURL
        )
    }

    @Test("the web fallback is a blob URL on this repository")
    func webURLPointsAtTheRepository() {
        let url = HelpDoc.troubleshooting.webURL
        #expect(url.absoluteString == HelpLink.repositoryURL + "/blob/main/docs/user/troubleshooting.md")
    }

    @Test("the troubleshooting page is the same path HelpLink anchors into")
    func troubleshootingAgreesWithHelpLink() {
        #expect(HelpDoc.troubleshooting.repoRelativePath == HelpLink.page)
    }

    @Test("a bundled troubleshooting page wins over the checkout and the web")
    func helpLinkPrefersTheBundle() {
        let resources = URL(fileURLWithPath: "/Applications/Worklens.app/Contents/Resources")
        let bundled = HelpLink.redIcon.url(
            bundledIn: resources, inCheckout: nil, fileExists: { _ in true }
        )
        #expect(bundled.path == resources.appendingPathComponent(HelpLink.page).path)
        #expect(
            HelpLink.pageURL(bundledIn: resources, inCheckout: nil, fileExists: { _ in true }).path
                == bundled.path
        )
        // Nothing in the bundle: the existing two answers, unchanged.
        #expect(
            HelpLink.redIcon.url(bundledIn: nil, inCheckout: nil, fileExists: { _ in true })
                == HelpLink.redIcon.webURL
        )
    }

    @Test("every settings section names a page, and every page named exists")
    func sectionsNameADocument() {
        for section in SettingsSection.allCases {
            let file = Self.repoRoot.appendingPathComponent(section.helpDoc.repoRelativePath)
            #expect(
                FileManager.default.fileExists(atPath: file.path),
                "\(section.title)'s Learn more points at \(section.helpDoc.repoRelativePath), which is not there"
            )
        }
        // The sections whose page is unmistakable, named so a re-mapping is a deliberate act.
        #expect(SettingsSection.privacy.helpDoc == .privacy)
        #expect(SettingsSection.usage.helpDoc == .cost)
        #expect(SettingsSection.capture.helpDoc == .permissions)
        #expect(SettingsSection.connections.helpDoc == .integrations)
    }

    @Test("every document has a title, and no two share one")
    func titlesAreDistinct() {
        #expect(HelpDoc.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(Set(HelpDoc.allCases.map(\.title)).count == HelpDoc.allCases.count)
    }
}
