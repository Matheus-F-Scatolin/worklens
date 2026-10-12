import Foundation
import Testing
@testable import WorklensCore

/// Every case is a path judged against an injected home, with `Probe.none` so nothing here
/// touches the disk, the network or a real cloud folder — which is also the only way to cover
/// Dropbox and Google Drive on a machine that has neither.
@Suite("DataDirLocation")
struct DataDirLocationTests {
    private let home = URL(fileURLWithPath: "/Users/you")

    private func check(_ path: String, probe: DataDirLocation.Probe = .none) -> DataDirLocation? {
        DataDirLocation.check(URL(fileURLWithPath: path), home: home, probe: probe)
    }

    @Test("an ordinary folder on this Mac is fine")
    func localIsFine() {
        #expect(check("/Users/you/worklens/data") == nil)
        #expect(check("/Users/you/Documents/data") == nil)
        #expect(check("/opt/worklens/data") == nil)
        // The word alone is not the signal: a folder you named after the thing is still local.
        #expect(check("/Users/you/projects/dropbox-clone/data") == nil)
    }

    @Test("each provider's folder is named by product, not by folder")
    func providers() {
        #expect(check("/Users/you/Library/Mobile Documents/com~apple~CloudDocs/data")?.provider
            == "iCloud Drive")
        #expect(check("/Users/you/Dropbox/data")?.provider == "Dropbox")
        #expect(check("/Users/you/Dropbox (Personal)/data")?.provider == "Dropbox")
        #expect(check("/Users/you/Google Drive/My Drive/data")?.provider == "Google Drive")
        #expect(check("/Users/you/OneDrive - Contoso/data")?.provider == "OneDrive")
        #expect(check("/Users/you/Library/CloudStorage/GoogleDrive-you@example.com/data")?.provider
            == "Google Drive")
        #expect(check("/Users/you/Library/CloudStorage/OneDrive-Personal/data")?.provider == "OneDrive")
        #expect(check("/Users/you/Library/CloudStorage/Dropbox/data")?.provider == "Dropbox")
        // An account folder from a provider nobody has mapped still reads as its own name.
        #expect(check("/Users/you/Library/CloudStorage/Nextcloud-you/data")?.provider == "Nextcloud")
    }

    @Test("the path is the primary signal, and it is reported as one")
    func signalIsPathPrefix() {
        #expect(check("/Users/you/Dropbox/data")?.signal == .pathPrefix)
        // Under another account's home, and so not home-relative at all.
        #expect(check("/Users/someone/Library/Mobile Documents/data")?.signal == .pathPrefix)
    }

    @Test("a ubiquitous folder outside the known paths is still iCloud")
    func ubiquitous() {
        var probe = DataDirLocation.Probe.none
        probe.isUbiquitous = { _ in true }
        let found = check("/Users/you/elsewhere/data", probe: probe)
        #expect(found?.provider == "iCloud Drive")
        #expect(found?.signal == .ubiquitous)
    }

    @Test("volumeIsLocal only ever catches a network volume")
    func networkVolume() {
        var probe = DataDirLocation.Probe.none
        probe.isOnLocalVolume = { _ in false }
        #expect(check("/Volumes/team/worklens", probe: probe)?.signal == .networkVolume)

        // The three headline providers all sit on the local boot volume and answer true, which
        // is exactly why this signal cannot be the primary test.
        var local = DataDirLocation.Probe.none
        local.isOnLocalVolume = { _ in true }
        #expect(check("/Users/you/worklens/data", probe: local) == nil)
        #expect(check("/Users/you/Dropbox/data", probe: local)?.signal == .pathPrefix)
    }

    @Test("a volume that cannot be read yet is not called remote")
    func unknownVolume() {
        // `Probe.none` answers nil, which is what a folder that does not exist yet looks like.
        #expect(check("/Users/you/not-created-yet/data") == nil)
    }

    @Test(".icloud placeholders are a last resort, never the first test")
    func placeholders() {
        var probe = DataDirLocation.Probe.none
        probe.hasICloudPlaceholders = { _ in true }
        #expect(check("/Users/you/somewhere/data", probe: probe)?.signal == .placeholders)

        // Ordering: a path that already matched is reported as a path match, not as placeholders.
        #expect(check("/Users/you/Dropbox/data", probe: probe)?.signal == .pathPrefix)
    }

    @Test("symlinks are resolved before the path is judged")
    func symlinks() throws {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-datadir-\(UUID().uuidString)")
        let fake = temporary.appendingPathComponent("Users/you/Dropbox/data")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let link = temporary.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fake)

        let realHome = temporary.appendingPathComponent("Users/you").resolvingSymlinksInPath()
        #expect(DataDirLocation.check(link, home: realHome, probe: .none)?.provider == "Dropbox")
    }

    @Test("what the user reads names the folder, the risk and both ways out")
    func wording() throws {
        let found = try #require(check("/Users/you/Library/Mobile Documents/com~apple~CloudDocs/data"))

        // The path is abbreviated: a menu row is narrow, and a home folder is often a person.
        #expect(found.path.hasPrefix("~/Library/Mobile Documents/"))
        #expect(!found.path.contains("/Users/you"))

        #expect(found.menuMessage.contains("iCloud Drive"))
        #expect(found.menuMessage.contains(found.path))
        #expect(found.menuMessage.contains("capture is off"))
        #expect(found.menuMessage.contains(DataDirLocation.overrideKey))

        #expect(found.explanation.contains(found.path))
        #expect(found.explanation.contains(InstanceLock.fileName))
        #expect(found.explanation.contains("make install-env"))
        #expect(found.explanation.contains(DataDirLocation.overrideKey))
        // Second person throughout, and no judgement about the choice.
        #expect(found.explanation.contains("this Mac"))
    }

    @Test("a refused run exits 3, never as a success")
    func exitCodes() {
        #expect(DataDirLocation.refusedExitCode == 3)
    }
}
