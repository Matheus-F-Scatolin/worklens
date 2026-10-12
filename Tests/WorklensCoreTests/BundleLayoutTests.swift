import Foundation
import Testing

@testable import WorklensCore

/// #119. The CLI tells you when it is the development binary rather than the one inside
/// `Worklens.app`, because macOS gives the two different permissions — so the test that decides
/// it has to be right about the `worklens` symlink `make install` creates.
@Suite("Bundle layout")
struct BundleLayoutTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test("the binary inside an app bundle is bundled")
    func insideABundle() {
        let exe = url("/Applications/Worklens.app/Contents/MacOS/Worklens")
        #expect(BundleLayout.isInsideAppBundle(
            executable: exe,
            fileExists: { $0 == "/Applications/Worklens.app/Contents/Info.plist" }
        ))
    }

    /// The case that made `Bundle.main.bundleIdentifier` the wrong test: through the symlink
    /// `Bundle.main` is `/usr/local/bin`, so only the *resolved* executable path answers.
    @Test("the worklens symlink resolves to the bundled binary and is bundled")
    func throughTheSymlink() {
        // `resolvedExecutableURL()` resolves /usr/local/bin/worklens to this before asking.
        let resolved = url("/Applications/Worklens.app/Contents/MacOS/Worklens")
        #expect(BundleLayout.isInsideAppBundle(executable: resolved, fileExists: { _ in true }))
        // The unresolved symlink path, which is what Bundle.main would have offered, is not.
        #expect(BundleLayout.isInsideAppBundle(
            executable: url("/usr/local/bin/worklens"), fileExists: { _ in true }) == false)
    }

    @Test("the loose development build is not bundled")
    func looseBinary() {
        #expect(BundleLayout.isInsideAppBundle(
            executable: url("/Users/x/worklens/.build/release/Worklens"),
            fileExists: { _ in true }
        ) == false)
    }

    /// A directory someone named `Foo.app` with the right shape but no `Info.plist` is not an
    /// app, and neither is a binary that cannot be located at all.
    @Test("the shape alone is not enough")
    func needsAnInfoPlist() {
        let exe = url("/tmp/Fake.app/Contents/MacOS/Worklens")
        #expect(BundleLayout.isInsideAppBundle(executable: exe, fileExists: { _ in false }) == false)
        #expect(BundleLayout.isInsideAppBundle(executable: nil, fileExists: { _ in true }) == false)
    }

    /// The reason `BuildStamp.current` no longer asks `Bundle.main`: through the symlink the
    /// main bundle is the symlink's directory, and `worklens version` would report an unstamped
    /// build for a bundle that carries the stamp.
    @Test("the stamp is read from the .app the executable lives in, symlink or not")
    func infoDictionaryFromARealBundle() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-bundle-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Worklens.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let binary = macOS.appendingPathComponent("Worklens")
        try Data().write(to: binary)
        try (["WLCommitShort": "0ae882e"] as NSDictionary)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))

        let info = try #require(BundleLayout.infoDictionary(forExecutable: binary))
        #expect(BuildStamp(info: info).shortCommit == "0ae882e")

        // What a symlink on PATH resolves to is exactly the binary above, so the same call
        // answers for `worklens` as for a double-click.
        let link = root.appendingPathComponent("worklens")
        try fm.createSymbolicLink(at: link, withDestinationURL: binary)
        let resolved = link.resolvingSymlinksInPath()
        #expect(BundleLayout.infoDictionary(forExecutable: resolved)?["WLCommitShort"] as? String
            == "0ae882e")

        // A loose binary has no bundle to read, and says so rather than inventing one.
        #expect(BundleLayout.infoDictionary(forExecutable: root.appendingPathComponent("Worklens"))
            == nil)
    }

    /// Not a pure-rule test: the suite itself runs from a loose test binary, so this pins that
    /// the live path works at all and answers the way an unbundled run should.
    @Test("the live lookup finds this process's own executable")
    func liveLookup() throws {
        let exe = try #require(BundleLayout.resolvedExecutableURL())
        #expect(FileManager.default.fileExists(atPath: exe.path))
        #expect(BundleLayout.isBundled == false)
    }
}
