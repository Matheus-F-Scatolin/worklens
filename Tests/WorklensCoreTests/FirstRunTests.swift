import Foundation
import Testing
@testable import WorklensCore

// MARK: - The bundled app's data directory (#116)

@Suite("Bundled defaults")
struct BundledDefaultsTests {
    private let cwd = URL(fileURLWithPath: "/tmp/worklens-test-cwd", isDirectory: true)
    private var appSupportData: URL { Config.appSupportDataDir() }

    @Test("a bundled app defaults to Application Support, a checkout to ./data")
    func dataDirDependsOnTheBundle() {
        #expect(Config.defaults(cwd: cwd, isBundledApp: false).dataDir.path == "/tmp/worklens-test-cwd/data")
        #expect(Config.defaults(cwd: cwd, isBundledApp: true).dataDir == appSupportData)
        #expect(appSupportData.path.hasSuffix("Library/Application Support/Worklens/data"))
    }

    @Test("the test runner is not a bundled app, so every other test keeps ./data")
    func testsAreNotBundled() {
        // The whole point of matching the app's own identifier rather than "has an identifier
        // at all": the test host has one, and it is not Worklens's.
        #expect(!Config.isBundledApp)
        #expect(Config.defaults(cwd: cwd).dataDir.path == "/tmp/worklens-test-cwd/data")
    }

    @Test("any layer that sets DATA_DIR still outranks the bundled default")
    func layersWin() throws {
        let pinned = try Config.load(layers: [["DATA_DIR": "/tmp/pinned"]], cwd: cwd, isBundledApp: true)
        #expect(pinned.dataDir.path == "/tmp/pinned")
        let unset = try Config.load(layers: [[:]], cwd: cwd, isBundledApp: true)
        #expect(unset.dataDir == appSupportData)
    }
}

// MARK: - The starter .env (#116)

@Suite("Env template")
struct EnvTemplateTests {
    @Test("every live key appears, set or commented, and no retired one does")
    func coversTheRegistry() {
        let lines = EnvTemplate.text.components(separatedBy: "\n")
        for key in Config.liveKeys {
            let assigned = lines.contains { $0 == "\(key.name)=" || $0.hasPrefix("\(key.name)=") }
            let commented = lines.contains { $0.hasPrefix("# \(key.name)=") }
            #expect(assigned || commented, "\(key.name) is not in the template")
        }
        for key in Config.retiredKeys {
            #expect(!lines.contains { $0.contains(key) }, "\(key) is retired and should not be offered")
        }
        // Its own help text comes along: this is the only documentation an installed app has.
        #expect(EnvTemplate.text.contains("# Vision model id."))
        for section in ConfigSection.allCases {
            #expect(EnvTemplate.text.contains("# --- \(section.rawValue) "))
        }
    }

    @Test("the keys are live and blank, everything else is commented out")
    func onlySecretsAreLive() {
        let values = DotEnv.parse(EnvTemplate.text)
        // A freshly written file sets nothing: the binary's defaults stay the source of every
        // value, including DATA_DIR, until the user types something.
        #expect(values.allSatisfy { $0.value.isEmpty })
        for key in Config.liveKeys where key.kind == .secret {
            #expect(values[key.name] == "", "\(key.name) should be waiting for a value")
        }
        #expect(values["DATA_DIR"] == nil)
        #expect(EnvTemplate.text.contains("# DATA_DIR=./data"))
        #expect(EnvTemplate.text.hasSuffix("\n"))
    }
}

@Suite("First-run .env")
struct FirstRunEnvTests {
    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-firstrun-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("writes the template at 0600 into a directory it creates at 0700")
    func createsTheFile() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".env")

        #expect(try FirstRunEnv.createIfMissing(at: url) == url)
        #expect(try String(contentsOf: url, encoding: .utf8) == EnvTemplate.text)
        #expect(try mode(of: url) == 0o600)
        #expect(try mode(of: dir) == 0o700)
    }

    @Test("an existing file is never touched")
    func leavesAnExistingFileAlone() throws {
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".env")
        try "GEMINI_API_KEY=mine\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(try FirstRunEnv.createIfMissing(at: url) == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "GEMINI_API_KEY=mine\n")
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }
}

// MARK: - "nothing was found" is a fact of its own

@Suite("Provenance: no files")
struct NoFilesFoundTests {
    private func file(_ layer: ConfigLayer, _ exists: Bool) -> ConfigProvenance.File {
        ConfigProvenance.File(layer: layer, url: URL(fileURLWithPath: "/tmp/.env"), exists: exists)
    }

    @Test("true only when every consulted file is missing")
    func detectsAFirstRun() {
        #expect(ConfigProvenance(files: [file(.appSupport, false), file(.cwd, false)]).noFilesFound)
        #expect(!ConfigProvenance(files: [file(.appSupport, false), file(.cwd, true)]).noFilesFound)
        // A load that failed leaves an empty provenance behind; "we never looked" is not
        // "there was nothing", and writing a starter file over a broken .env would be wrong.
        #expect(!ConfigProvenance().noFilesFound)
    }
}
