import Foundation
import Testing

@testable import WorklensCore

/// The handshake `scripts/launch.sh` reads so a relaunch keeps the configuration the running
/// app had (#129).
@Suite("Launch environment handshake")
struct LaunchEnvTests {
    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-launchenv-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("writes the path, under a comment saying what the file is for")
    func writesThePath() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let handshake = dir.appendingPathComponent(".launch-env")
        let env = dir.appendingPathComponent(".env")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "GEMINI_API_KEY=g\n".write(to: env, atomically: true, encoding: .utf8)

        #expect(try LaunchEnv.write(envFile: env, to: handshake) == handshake)
        let text = try String(contentsOf: handshake, encoding: .utf8)
        #expect(text.hasPrefix("#"))
        #expect(LaunchEnv.parse(text) == env.path)
        #expect(LaunchEnv.resolved(at: handshake) == URL(fileURLWithPath: env.path))
    }

    @Test("no override to record removes a record left by an earlier launch")
    func removesAStaleRecord() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let handshake = dir.appendingPathComponent(".launch-env")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "/gone/.env\n".write(to: handshake, atomically: true, encoding: .utf8)

        #expect(try LaunchEnv.write(envFile: nil, to: handshake) == nil)
        #expect(!FileManager.default.fileExists(atPath: handshake.path))
        // Removing a file that is not there is not an error either.
        #expect(try LaunchEnv.write(envFile: nil, to: handshake) == nil)
    }

    @Test("a record naming a file that no longer exists resolves to nothing")
    func staleRecordDoesNotResolve() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let handshake = dir.appendingPathComponent(".launch-env")
        let gone = dir.appendingPathComponent("deleted-worktree/.env")
        try LaunchEnv.write(envFile: gone, to: handshake)

        #expect(LaunchEnv.parse(try String(contentsOf: handshake, encoding: .utf8)) == gone.path)
        #expect(LaunchEnv.resolved(at: handshake) == nil)
    }

    @Test("a missing handshake resolves to nothing rather than throwing")
    func missingFile() {
        let dir = temporaryDirectory()
        #expect(LaunchEnv.resolved(at: dir.appendingPathComponent(".launch-env")) == nil)
    }

    @Test("parse skips comments and blank lines, and tolerates an empty file")
    func parsing() {
        #expect(LaunchEnv.parse("# a comment\n\n  /Users/dev/.env  \n") == "/Users/dev/.env")
        #expect(LaunchEnv.parse("# only comments\n") == nil)
        #expect(LaunchEnv.parse("") == nil)
    }

    @Test("it lives beside the .env, not inside DATA_DIR — the value in dispute")
    func fixedLocation() {
        #expect(
            LaunchEnv.defaultURL.deletingLastPathComponent().path
                == Config.appSupportEnvURL().deletingLastPathComponent().path
        )
        #expect(LaunchEnv.defaultURL.lastPathComponent == ".launch-env")
    }
}

/// The "Dev override" line the menu and Settings show while `WORKLENS_ENV_FILE` is in play
/// (#129).
@Suite("Dev override")
struct DevOverrideTests {
    private func provenance(explicit: URL?, exists: Bool, supplied: Bool = true) -> ConfigProvenance {
        var files: [ConfigProvenance.File] = []
        var sources: [String: ConfigLayer] = ["DATA_DIR": .appSupport]
        if let explicit {
            files.append(ConfigProvenance.File(layer: .explicitFile, url: explicit, exists: exists))
            if supplied { sources["GEMINI_API_KEY"] = .explicitFile }
        }
        files.append(
            ConfigProvenance.File(layer: .appSupport, url: Config.appSupportEnvURL(), exists: true)
        )
        return ConfigProvenance(sources: sources, files: files)
    }

    @Test("no WORKLENS_ENV_FILE, no line — the ordinary installed launch")
    func quietWithoutAnOverride() {
        let plain = provenance(explicit: nil, exists: false)

        #expect(plain.devOverrideFile == nil)
        #expect(!plain.devOverrideActive)
        #expect(plain.devOverrideLine == nil)
    }

    @Test("names the file being read, and nothing in it")
    func namesTheFile() {
        let url = URL(fileURLWithPath: "/Users/dev/worklens/.env")
        let overridden = provenance(explicit: url, exists: true)

        #expect(overridden.devOverrideActive)
        #expect(overridden.devOverrideLine == "Dev override: reading /Users/dev/worklens/.env")
        #expect(overridden.devOverrideFile?.url == url)
    }

    @Test("a WORKLENS_ENV_FILE pointing at nothing says so instead of staying silent")
    func missingOverrideFile() {
        let url = URL(fileURLWithPath: "/Users/dev/deleted/.env")
        let overridden = provenance(explicit: url, exists: false, supplied: false)

        #expect(!overridden.devOverrideActive)
        #expect(
            overridden.devOverrideLine
                == "Dev override: WORKLENS_ENV_FILE names /Users/dev/deleted/.env, which does not exist"
        )
    }
}
