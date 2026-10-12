import Foundation
import Testing

@testable import WorklensCore

/// #130: the version comes from the bundle, which gets it from the git tag. These tests are over
/// the injected dictionary rather than over `WorklensVersion.short`, because under `make test`
/// there is no app bundle to read and the answer would be the fallback either way.
@Suite("Version")
struct VersionTests {
    @Test("a bundle's version keys win over the fallback")
    func readsTheBundle() {
        let numbers = WorklensVersion.numbers(from: [
            "CFBundleShortVersionString": "0.4.2",
            "CFBundleVersion": "421",
        ])
        #expect(numbers == WorklensVersion.Numbers(short: "0.4.2", build: "421"))
    }

    @Test("no dictionary at all is the unbundled build, which reports the fallback")
    func unbundled() {
        #expect(WorklensVersion.numbers(from: nil) == WorklensVersion.fallback)
        #expect(WorklensVersion.numbers(from: [:]) == WorklensVersion.fallback)
    }

    @Test("the two keys fall back one at a time, not together")
    func perKeyFallback() {
        let noBuild = WorklensVersion.numbers(from: ["CFBundleShortVersionString": "1.2.3"])
        #expect(noBuild.short == "1.2.3")
        #expect(noBuild.build == WorklensVersion.fallback.build)

        let noShort = WorklensVersion.numbers(from: ["CFBundleVersion": "97"])
        #expect(noShort.short == WorklensVersion.fallback.short)
        #expect(noShort.build == "97")
    }

    @Test("an empty or whitespace value is not a version")
    func emptyValues() {
        let numbers = WorklensVersion.numbers(from: [
            "CFBundleShortVersionString": "",
            "CFBundleVersion": "   ",
        ])
        #expect(numbers == WorklensVersion.fallback)
    }

    @Test("a value of the wrong type is ignored rather than crashing the app")
    func wrongTypes() {
        let numbers = WorklensVersion.numbers(from: [
            "CFBundleShortVersionString": 3 as Int,
            "CFBundleVersion": ["1"] as [String],
        ])
        #expect(numbers == WorklensVersion.fallback)
    }

    @Test("surrounding whitespace is trimmed, so a stray newline is not part of the version")
    func trimsWhitespace() {
        let numbers = WorklensVersion.numbers(from: ["CFBundleShortVersionString": " 2.0 "])
        #expect(numbers.short == "2.0")
    }

    /// The rule `scripts/bundle.sh` enforces, asserted here so a change to that script has
    /// something to fail against: `CFBundleShortVersionString` has to
    /// be one to three dot-separated integers or Finder and every installer misread it. This is
    /// why `bundle.sh` uses `git describe --abbrev=0` and not `--always --dirty`.
    @Test("the fallback obeys CFBundleShortVersionString's own format rule")
    func fallbackIsAValidMarketingVersion() {
        func isAllDigits(_ text: some StringProtocol) -> Bool {
            !text.isEmpty && text.allSatisfy { $0.isNumber }
        }
        let parts = WorklensVersion.fallback.short
            .split(separator: ".", omittingEmptySubsequences: false)
        #expect((1...3).contains(parts.count))
        #expect(parts.allSatisfy { isAllDigits($0) })
        #expect(isAllDigits(WorklensVersion.fallback.build))
    }

    /// `Tests/WorklensCoreTests/<this file>` → the checkout, the same walk `AppIconTests` does.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Both are only ever fallbacks — `bundle.sh` overwrites the plist's pair from the git tag
    /// before signing — but they answer the same question in two places, and two copies of an
    /// answer drift. This is the assertion that keeps them one answer.
    @Test("the checked-in Info.plist and the fallback are the same pair")
    func plistMatchesFallback() throws {
        let url = Self.repoRoot.appendingPathComponent("Resources/Info.plist")
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil) as? [String: Any]
        let numbers = WorklensVersion.numbers(from: plist)
        #expect(
            numbers == WorklensVersion.fallback,
            """
            Resources/Info.plist says \(numbers) but WorklensVersion.fallback says \
            \(WorklensVersion.fallback) — make the two agree.
            """)
    }

    @Test("the live version is a real version string, whether or not this build is bundled")
    func liveVersion() {
        #expect(!WorklensVersion.short.isEmpty)
        // Under `make test` there is no .app around the runner, so the fallback is the answer —
        // and specifically *not* Swift Testing's own CFBundleShortVersionString.
        #expect(WorklensVersion.short == WorklensVersion.fallback.short)
    }
}
