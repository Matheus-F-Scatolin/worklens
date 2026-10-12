import Foundation
import Testing
@testable import WorklensCore

@Suite("SettingsStore (#108)")
struct SettingsStoreTests {
    private func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a value survives a round trip, and the file is 0600")
    func roundTrip() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))

        #expect(store.get("DAILY_BUDGET_USD") == nil)
        try store.set("DAILY_BUDGET_USD", "2.25")
        #expect(store.get("DAILY_BUDGET_USD") == "2.25")

        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)

        try store.set("LOG_LEVEL", "debug")
        #expect(store.values() == ["DAILY_BUDGET_USD": "2.25", "LOG_LEVEL": "debug"])

        try store.remove("LOG_LEVEL")
        #expect(store.get("LOG_LEVEL") == nil)
        #expect(store.get("DAILY_BUDGET_USD") == "2.25")
        // Removing what is not there is not an error: the end state is what was asked for.
        try store.remove("LOG_LEVEL")
    }

    @Test("a value that does not parse never reaches the file")
    func validatesBeforeWriting() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))

        #expect(throws: ConfigError.invalidDouble(key: "DAILY_BUDGET_USD", value: "lots")) {
            try store.set("DAILY_BUDGET_USD", "lots")
        }
        #expect(throws: ConfigError.unknownKey(key: "MADE_UP")) { try store.set("MADE_UP", "1") }
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test("DATA_DIR is refused, and ignored even if somebody hand-edits it in")
    func dataDirIsNotTheAppsToWrite() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        let store = SettingsStore(url: url)

        #expect(throws: SettingsStoreError.notEditable(key: "DATA_DIR")) {
            try store.set("DATA_DIR", "/tmp/elsewhere")
        }
        // Hand-edited in, it is still not read: `WORKLENS_ENV_FILE` is how a worktree or a test
        // pins the data directory, and this file must not be able to take that away (#34).
        try #"{"DATA_DIR": "/tmp/elsewhere", "LOG_LEVEL": "warn"}"#
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(store.layerValues() == ["LOG_LEVEL": "warn"])
    }

    @Test("a corrupt settings file is ignored, not fatal")
    func corruptFileIsIgnored() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(SettingsStore(url: url).values().isEmpty)
        #expect(SettingsStore(url: url).layerValues().isEmpty)
    }
}

// MARK: - Where the layer sits

@Suite("the settings layer's precedence (#108)")
struct SettingsLayerTests {
    private func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-layer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("settings.json beats both .env files and loses to WORKLENS_ENV_FILE and the environment")
    func precedence() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json")
        let appSupport = dir.appendingPathComponent("app-support.env")
        let explicit = dir.appendingPathComponent("pinned.env")

        try SettingsStore(url: settings).set("CAPTURE_INTERVAL_SECONDS", "45")
        try SettingsStore(url: settings).set("LOG_LEVEL", "warn")
        try "CAPTURE_INTERVAL_SECONDS=90\nLOG_LEVEL=error\n"
            .write(to: appSupport, atomically: true, encoding: .utf8)
        try "CAPTURE_INTERVAL_SECONDS=120\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        // Nothing above it: the settings file wins both .env files.
        var loaded = try Config.loadWithProvenance(
            environment: [:], cwd: dir, appSupportEnv: appSupport, settingsFile: settings
        )
        #expect(loaded.config.captureIntervalSeconds == 45)
        #expect(loaded.provenance.source(of: "CAPTURE_INTERVAL_SECONDS") == .appSettings)
        #expect(loaded.provenance.source(of: "CAPTURE_INTERVAL_SECONDS").label == "settings")

        // `WORKLENS_ENV_FILE` still wins — that is what worktrees, tests and scripts pin with.
        try "CAPTURE_INTERVAL_SECONDS=15\n".write(to: explicit, atomically: true, encoding: .utf8)
        loaded = try Config.loadWithProvenance(
            environment: ["WORKLENS_ENV_FILE": explicit.path], cwd: dir,
            appSupportEnv: appSupport, settingsFile: settings
        )
        #expect(loaded.config.captureIntervalSeconds == 15)
        #expect(loaded.provenance.source(of: "CAPTURE_INTERVAL_SECONDS") == .explicitFile)
        // A key that file does not set still comes from the settings layer.
        #expect(loaded.config.logLevel == .warn)

        // And so does the process environment.
        loaded = try Config.loadWithProvenance(
            environment: ["CAPTURE_INTERVAL_SECONDS": "5"], cwd: dir,
            appSupportEnv: appSupport, settingsFile: settings
        )
        #expect(loaded.config.captureIntervalSeconds == 5)
        #expect(loaded.provenance.source(of: "CAPTURE_INTERVAL_SECONDS") == .process)
    }

    @Test("config-dump lists the settings file among the layers it consulted")
    func provenanceNamesTheFile() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json")
        let loaded = try Config.loadWithProvenance(
            environment: [:], cwd: dir,
            appSupportEnv: dir.appendingPathComponent("absent.env"), settingsFile: settings
        )
        let file = loaded.provenance.files.first { $0.layer == .appSettings }
        #expect(file?.url == settings)
        #expect(file?.exists == false)
        // Highest precedence first, and it sits above both .env files.
        #expect(loaded.provenance.files.map(\.layer) == [.appSettings, .appSupport, .cwd])
    }
}
