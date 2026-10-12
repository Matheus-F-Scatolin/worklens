import Foundation
import Testing
@testable import WorklensCore

@Suite("Config")
struct ConfigTests {
    private let cwd = URL(fileURLWithPath: "/tmp/worklens-test-cwd", isDirectory: true)

    /// A path no App Support `.env` occupies, so a test never reads the developer's real one
    /// — it outranks `<cwd>/.env` and would decide these assertions from outside the repo.
    private static let noAppSupportEnv = URL(fileURLWithPath: "/nonexistent/worklens/app-support/.env")
    /// The app-owned settings layer (#108) sits between `WORKLENS_ENV_FILE` and the App
    /// Support `.env`, so every load in here has to be pointed away from the real one.
    private static let noSettings = URL(fileURLWithPath: "/nonexistent/worklens/settings.json")

    /// A fresh directory the caller's `defer` deletes.
    private func scratchDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("defaults match the spec table")
    func defaults() throws {
        let c = try Config.load(layers: [[:]], cwd: cwd)
        #expect(c.geminiAPIKey == nil)
        #expect(c.describeModel == "gemini-3.5-flash-lite")
        #expect(c.captureIntervalSeconds == 60)
        #expect(c.meetingCaptureIntervalSeconds == 300)
        #expect(c.captureIdleSeconds == 120)
        #expect(c.captureHeartbeatSeconds == 300)
        #expect(c.changeThreshold == 0.03)
        #expect(c.captureMaxEdgePx == 1024)
        #expect(c.deleteScreenshotsAfterDescribe == false)
        #expect(c.deleteSensitiveScreenshots == true)
        #expect(c.collectBrowserURL == true)
        #expect(c.blockedBundleIDs == Config.defaultBlockedBundleIDs)
        #expect(c.blockedTitlePatterns == Config.defaultBlockedTitlePatterns)
        #expect(c.dailyBudgetUSD == 1.50)
        #expect(c.screenshotDiskBudgetGB == 20)
        #expect(c.dataDir.path == "/tmp/worklens-test-cwd/data")
        #expect(c.logLevel == .info)
    }

    @Test("earlier layers win per key")
    func precedence() throws {
        let processEnv = ["DESCRIBE_MODEL": "from-env"]
        let fileEnv = ["DESCRIBE_MODEL": "from-file", "LOG_LEVEL": "debug"]
        let c = try Config.load(layers: [processEnv, fileEnv], cwd: cwd)
        #expect(c.describeModel == "from-env")
        #expect(c.logLevel == .debug)
    }

    @Test("empty values fall through to the next layer")
    func emptyFallsThrough() throws {
        let c = try Config.load(layers: [["DESCRIBE_MODEL": ""], ["DESCRIBE_MODEL": "from-file"]], cwd: cwd)
        #expect(c.describeModel == "from-file")
    }

    @Test("DATA_DIR expands ~ and resolves relative paths")
    func dataDirExpansion() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tilde = try Config.load(layers: [["DATA_DIR": "~/Worklens/data"]], cwd: cwd)
        #expect(tilde.dataDir.path == "\(home)/Worklens/data")

        let relative = try Config.load(layers: [["DATA_DIR": "custom/dir"]], cwd: cwd)
        #expect(relative.dataDir.path == "/tmp/worklens-test-cwd/custom/dir")

        let absolute = try Config.load(layers: [["DATA_DIR": "/var/tmp/worklens"]], cwd: cwd)
        #expect(absolute.dataDir.path == "/private/var/tmp/worklens" || absolute.dataDir.path == "/var/tmp/worklens")
    }

    @Test("derived paths hang off DATA_DIR")
    func derivedPaths() throws {
        let c = try Config.load(layers: [["DATA_DIR": "/tmp/wl"]], cwd: cwd)
        #expect(c.databaseURL.lastPathComponent == "worklens.sqlite")
        #expect(c.screenshotsDir.lastPathComponent == "screenshots")
    }

    @Test("lists split on the right separator")
    func lists() throws {
        let c = try Config.load(layers: [[
            "BLOCKED_BUNDLE_IDS": "com.a.b, com.c.d ",
            "BLOCKED_TITLE_PATTERNS": "Secret; Private Browsing ;",
        ]], cwd: cwd)
        #expect(c.blockedBundleIDs == ["com.a.b", "com.c.d"])
        #expect(c.blockedTitlePatterns == ["Secret", "Private Browsing"])
    }

    @Test("booleans accept the usual spellings")
    func booleans() throws {
        for truthy in ["1", "true", "TRUE", "yes", "on"] {
            let c = try Config.load(layers: [["DELETE_SCREENSHOTS_AFTER_DESCRIBE": truthy]], cwd: cwd)
            #expect(c.deleteScreenshotsAfterDescribe == true, "\(truthy) should be true")
        }
        for falsy in ["0", "false", "No", "off"] {
            let c = try Config.load(layers: [["COLLECT_BROWSER_URL": falsy]], cwd: cwd)
            #expect(c.collectBrowserURL == false, "\(falsy) should be false")
        }
    }

    @Test("an invalid Int throws naming the key")
    func invalidInt() {
        #expect(throws: ConfigError.invalidInt(key: "CAPTURE_INTERVAL_SECONDS", value: "soon")) {
            _ = try Config.load(layers: [["CAPTURE_INTERVAL_SECONDS": "soon"]], cwd: cwd)
        }
    }

    @Test("an invalid Double throws naming the key")
    func invalidDouble() {
        #expect(throws: ConfigError.invalidDouble(key: "DAILY_BUDGET_USD", value: "lots")) {
            _ = try Config.load(layers: [["DAILY_BUDGET_USD": "lots"]], cwd: cwd)
        }
    }

    @Test("an out-of-range unit interval throws")
    func outOfRange() {
        #expect(throws: ConfigError.outOfRange(key: "CHANGE_THRESHOLD", value: "1.5", range: "0...1")) {
            _ = try Config.load(layers: [["CHANGE_THRESHOLD": "1.5"]], cwd: cwd)
        }
    }

    @Test("an invalid Bool throws naming the key")
    func invalidBool() {
        #expect(throws: ConfigError.invalidBool(key: "COLLECT_BROWSER_URL", value: "maybe")) {
            _ = try Config.load(layers: [["COLLECT_BROWSER_URL": "maybe"]], cwd: cwd)
        }
    }

    @Test("an invalid enum throws listing the allowed values")
    func invalidEnum() {
        let error = #expect(throws: ConfigError.self) {
            _ = try Config.load(layers: [["LOG_LEVEL": "extreme"]], cwd: cwd)
        }
        #expect(error?.description.contains("LOG_LEVEL") == true)
        #expect(error?.description.contains("debug") == true)
    }

    @Test("secrets are masked in the dump and full keys never appear")
    func maskedDump() throws {
        let secret = "grn_abc-supersecretvalue"
        let c = try Config.load(layers: [["GRANOLA_API_KEY": secret, "GEMINI_API_KEY": "AIzaSyFAKEKEY"]], cwd: cwd)
        let dump = c.dumpLines
        let rendered = dump.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        #expect(!rendered.contains(secret))
        #expect(!rendered.contains("AIzaSyFAKEKEY"))
        #expect(rendered.contains("grn_abc****"))
        #expect(rendered.contains("GEMINI_API_KEY  ") == false)   // formatting is the caller's job
        #expect(dump.first(where: { $0.key == "GOOGLE_CLIENT_SECRET" })?.value == "(unset)")
    }

    @Test("the dump lists every documented key")
    func dumpCoversEveryKey() throws {
        let expected = [
            "GEMINI_API_KEY", "DESCRIBE_MODEL", "REPORT_LANGUAGE", "CAPTURE_INTERVAL_SECONDS",
            "MEETING_CAPTURE_INTERVAL_SECONDS", "CAPTURE_IDLE_SECONDS", "CAPTURE_HEARTBEAT_SECONDS",
            "CHANGE_THRESHOLD", "CAPTURE_MAX_EDGE_PX", "CAPTURE_SOURCE", "CAPTURE_ON_BATTERY",
            "DELETE_SCREENSHOTS_AFTER_DESCRIBE", "DELETE_SENSITIVE_SCREENSHOTS",
            "RETENTION_DAYS", "RETENTION_KEEP_REPORTS",
            "COLLECT_BROWSER_URL", "BLOCKED_BUNDLE_IDS",
            "BLOCKED_TITLE_PATTERNS", "BLOCKED_URL_HOSTS", "REDACT_EXTRA_PATTERNS",
            "DAILY_BUDGET_USD", "SCREENSHOT_DISK_BUDGET_GB",
            "DATA_DIR", "ALLOW_NONLOCAL_DATA_DIR", "LOG_LEVEL", "CONTEXT_SYNC_MINUTES", "GRANOLA_API_KEY",
            "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET",
            "GOOGLE_TOKEN_STORE", "GITHUB_SHIPPED", "MEMO_REPOS", "AGENT_SESSIONS",
            "AUTO_UPDATE_ENABLED", "AUTO_UPDATE_POLL_MINUTES", "PAUSE_REMINDER_HOURS",
        ]
        let keys = try Config.load(layers: [[:]], cwd: cwd).dumpLines.map(\.key)
        #expect(Set(keys) == Set(expected))
    }

    @Test("a relative DATA_DIR in an env file resolves next to that file, not to the process cwd")
    func relativeDataDirIsFileRelative() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let envFile = dir.appendingPathComponent(".env")
        try "DATA_DIR=./data\n".write(to: envFile, atomically: true, encoding: .utf8)

        // The bundled app's cwd is `/`; the file must still win the argument about where `./data` is.
        let c = try Config.load(
            environment: ["WORKLENS_ENV_FILE": envFile.path],
            cwd: URL(fileURLWithPath: "/", isDirectory: true),
            appSupportEnv: Self.noAppSupportEnv, settingsFile: Self.noSettings
        )
        #expect(c.dataDir.standardizedFileURL == dir.appendingPathComponent("data").standardizedFileURL)

        // An absolute or a ~ path in the file is left alone.
        try "DATA_DIR=/tmp/elsewhere\n".write(to: envFile, atomically: true, encoding: .utf8)
        let absolute = try Config.load(
            environment: ["WORKLENS_ENV_FILE": envFile.path], cwd: dir, appSupportEnv: Self.noAppSupportEnv, settingsFile: Self.noSettings
        )
        #expect(absolute.dataDir.path == "/tmp/elsewhere")

        // The process environment still resolves against the cwd, as before.
        let env = try Config.load(
            environment: ["DATA_DIR": "./data", "WORKLENS_ENV_FILE": ""], cwd: dir,
            appSupportEnv: Self.noAppSupportEnv, settingsFile: Self.noSettings
        )
        #expect(env.dataDir.standardizedFileURL == dir.appendingPathComponent("data").standardizedFileURL)
    }

    @Test("reads a real .env file from the working directory")
    func readsFileFromCwd() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "CAPTURE_IDLE_SECONDS=45\n# comment\nLOG_LEVEL=debug\n"
            .write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let c = try Config.load(environment: [:], cwd: dir, appSupportEnv: Self.noAppSupportEnv, settingsFile: Self.noSettings)
        #expect(c.captureIdleSeconds == 45)
        #expect(c.logLevel == .debug)
    }

    @Test("WORKLENS_ENV_FILE outranks the cwd .env")
    func explicitEnvFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "CAPTURE_IDLE_SECONDS=45\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let explicit = dir.appendingPathComponent("other.env")
        try "CAPTURE_IDLE_SECONDS=90\n".write(to: explicit, atomically: true, encoding: .utf8)

        let c = try Config.load(
            environment: ["WORKLENS_ENV_FILE": explicit.path], cwd: dir, appSupportEnv: Self.noAppSupportEnv, settingsFile: Self.noSettings
        )
        #expect(c.captureIdleSeconds == 90)
    }

    // MARK: Retired keys (#87)

    @Test("a stale .env still loads; the retired keys are named once and change nothing")
    func retiredKeysAreNamedAndIgnored() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "GRANOLA_MODE=local\nAX_MAX_NODES=10\nCAPTURE_IDLE_SECONDS=45\n"
            .write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let (config, provenance) = try Config.loadWithProvenance(
            environment: [:], cwd: dir, appSupportEnv: dir.appendingPathComponent("absent.env"), settingsFile: Self.noSettings
        )

        // One warning, naming both, in the order `Config.retiredKeys` lists them.
        #expect(provenance.retiredKeys == ["AX_MAX_NODES", "GRANOLA_MODE"])
        // The keys around them still work, and the walk still spends the shipped budget.
        #expect(config.captureIdleSeconds == 45)
        #expect(AXWalkLimits().maxNodes == 400)
        // Nothing retired can be asked for any more: `config-dump` prints 36 keys, none of them.
        #expect(Config.knownKeys.count == 36)
        #expect(Set(Config.knownKeys).isDisjoint(with: Config.retiredKeys))
    }

    @Test("a .env that still sets the Claude key or a report schedule loads, naming them as retired (#298)")
    func reportKeysAreRetired() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "ANTHROPIC_API_KEY=sk-ant-stale\nREPORT_TIME=07:00\nCAPTURE_IDLE_SECONDS=45\n"
            .write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let (config, provenance) = try Config.loadWithProvenance(
            environment: [:], cwd: dir, appSupportEnv: dir.appendingPathComponent("absent.env"),
            settingsFile: Self.noSettings
        )
        #expect(provenance.retiredKeys.sorted() == ["ANTHROPIC_API_KEY", "REPORT_TIME"])
        #expect(provenance.unknownKeys.isEmpty)
        #expect(config.captureIdleSeconds == 45, "the keys around them still load")
        for key in ["ANTHROPIC_API_KEY", "REPORT_MODEL", "REPORT_EFFORT", "REPORT_TIME", "REPORT_WEEKLY_DAY"] {
            #expect(Config.retiredKeys.contains(key))
        }

        let dump = ConfigDumpText.render(config: config, provenance: provenance)
        #expect(dump.contains("no longer do anything"))
        #expect(dump.contains("ANTHROPIC_API_KEY"))
        #expect(!dump.contains("sk-ant-stale"), "a retired secret's value is never printed")
    }

    @Test("a .env that still sets SLACK_USER_TOKEN loads, and config-dump names it as retired (#285)")
    func slackTokenIsRetired() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "SLACK_USER_TOKEN=xoxp-stale\nGRANOLA_API_KEY=grn_live\n"
            .write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        // The copy the Slack setup sheet wrote, which stays in settings.json and is read as retired.
        let settings = dir.appendingPathComponent("settings.json")
        try #"{"SLACK_USER_TOKEN": "xoxp-stale"}"#.write(to: settings, atomically: true, encoding: .utf8)

        // Before #285's retirement this was an `unknownKey`, and the app would not launch.
        let (config, provenance) = try Config.loadWithProvenance(
            environment: [:], cwd: dir, appSupportEnv: dir.appendingPathComponent("absent.env"),
            settingsFile: settings
        )
        #expect(Config.retiredKeys.contains("SLACK_USER_TOKEN"))
        #expect(!Config.knownKeys.contains("SLACK_USER_TOKEN"))
        #expect(provenance.retiredKeys == ["SLACK_USER_TOKEN"])
        #expect(provenance.unknownKeys.isEmpty)
        #expect(config.granolaAPIKey == "grn_live", "the keys around it still load")

        let dump = ConfigDumpText.render(config: config, provenance: provenance)
        #expect(dump.contains("no longer do anything"))
        #expect(dump.contains("SLACK_USER_TOKEN"))
        #expect(!dump.contains("xoxp-stale"), "a retired secret's value is never printed")
    }

    // MARK: Provenance (#34)

    @Test("provenance names the layer that supplied each key, and default for the rest")
    func provenanceLabelsEveryLayer() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appSupport = dir.appendingPathComponent("app-support.env")
        let explicit = dir.appendingPathComponent("explicit.env")
        try "LOG_LEVEL=debug\n".write(to: appSupport, atomically: true, encoding: .utf8)
        try "CAPTURE_HEARTBEAT_SECONDS=600\n".write(to: explicit, atomically: true, encoding: .utf8)
        try "CAPTURE_IDLE_SECONDS=45\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let (config, provenance) = try Config.loadWithProvenance(
            environment: ["DESCRIBE_MODEL": "from-env", "WORKLENS_ENV_FILE": explicit.path],
            cwd: dir,
            appSupportEnv: appSupport, settingsFile: Self.noSettings
        )

        #expect(provenance.source(of: "DESCRIBE_MODEL") == .process)
        #expect(provenance.source(of: "CAPTURE_HEARTBEAT_SECONDS") == .explicitFile)
        #expect(provenance.source(of: "LOG_LEVEL") == .appSupport)
        #expect(provenance.source(of: "CAPTURE_IDLE_SECONDS") == .cwd)
        #expect(provenance.source(of: "DAILY_BUDGET_USD") == .fallback)
        // Every layer's value actually landed, so the labels describe the config that was built.
        #expect(config.describeModel == "from-env")
        #expect(config.captureHeartbeatSeconds == 600)
        #expect(config.logLevel == .debug)
        #expect(config.captureIdleSeconds == 45)
        #expect(config.dailyBudgetUSD == 1.50)

        #expect(ConfigLayer.process.label == "env")
        #expect(ConfigLayer.explicitFile.label == "WORKLENS_ENV_FILE")
        #expect(ConfigLayer.appSupport.label == "app-support")
        #expect(ConfigLayer.cwd.label == "cwd")
        #expect(ConfigLayer.fallback.label == "default")
    }

    @Test("provenance lists the files it consulted, and whether they exist")
    func provenanceListsFiles() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appSupport = dir.appendingPathComponent("app-support.env")
        try "LOG_LEVEL=debug\n".write(to: appSupport, atomically: true, encoding: .utf8)

        let (_, provenance) = try Config.loadWithProvenance(
            environment: [:], cwd: dir, appSupportEnv: appSupport, settingsFile: Self.noSettings
        )
        #expect(provenance.files.map(\.layer) == [.appSettings, .appSupport, .cwd])
        #expect(provenance.files.first(where: { $0.layer == .appSupport })?.exists == true)
        // No .env was written in the scratch directory.
        #expect(provenance.files.first(where: { $0.layer == .cwd })?.exists == false)

        let explicit = dir.appendingPathComponent("missing.env")
        let (_, withExplicit) = try Config.loadWithProvenance(
            environment: ["WORKLENS_ENV_FILE": explicit.path], cwd: dir, appSupportEnv: appSupport, settingsFile: Self.noSettings
        )
        #expect(withExplicit.files.map(\.layer) == [.explicitFile, .appSettings, .appSupport, .cwd])
        #expect(withExplicit.files.first?.exists == false)
    }

    @Test("a value that will not parse still leaves the provenance knowable (#129)")
    func provenanceSurvivesABadValue() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let explicit = dir.appendingPathComponent("checkout.env")
        try "CAPTURE_INTERVAL_SECONDS=every-so-often\n".write(
            to: explicit, atomically: true, encoding: .utf8
        )
        let environment = ["WORKLENS_ENV_FILE": explicit.path]

        #expect(throws: (any Error).self) {
            try Config.loadWithProvenance(
                environment: environment, cwd: dir, appSupportEnv: Self.noAppSupportEnv,
                settingsFile: Self.noSettings
            )
        }

        // The degraded start still has to say which file it was reading.
        let provenance = Config.provenance(
            environment: environment, cwd: dir, appSupportEnv: Self.noAppSupportEnv,
            settingsFile: Self.noSettings
        )
        #expect(provenance.files.first?.layer == .explicitFile)
        #expect(provenance.files.first?.exists == true)
        #expect(provenance.devOverrideActive)
        #expect(provenance.devOverrideFile?.url.path == explicit.path)
    }

    @Test("an App Support key the cwd .env also sets is reported as an override")
    func appSupportOverridesAreReported() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appSupport = dir.appendingPathComponent("app-support.env")
        try "DATA_DIR=/tmp/other-worktree/data\nLOG_LEVEL=debug\n"
            .write(to: appSupport, atomically: true, encoding: .utf8)
        try "DATA_DIR=./data\nCAPTURE_IDLE_SECONDS=45\n"
            .write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let (config, provenance) = try Config.loadWithProvenance(
            environment: [:], cwd: dir, appSupportEnv: appSupport, settingsFile: Self.noSettings
        )
        // The bug this issue is about: the checkout's own DATA_DIR loses.
        #expect(provenance.appSupportOverrides == ["DATA_DIR"])
        #expect(provenance.source(of: "DATA_DIR") == .appSupport)
        #expect(config.dataDir.path == "/tmp/other-worktree/data")
        // LOG_LEVEL is App Support's alone, CAPTURE_IDLE_SECONDS the checkout's alone: neither is a fight.
        #expect(provenance.source(of: "LOG_LEVEL") == .appSupport)
        #expect(provenance.source(of: "CAPTURE_IDLE_SECONDS") == .cwd)
    }

    @Test("a key the two files agree on is not reported as an override")
    func agreementIsNotAnOverride() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appSupport = dir.appendingPathComponent("app-support.env")
        // What `make install-env` leaves behind: the same values, one copy read from elsewhere.
        try "LOG_LEVEL=debug\nDATA_DIR=\(dir.path)/data\n"
            .write(to: appSupport, atomically: true, encoding: .utf8)
        try "LOG_LEVEL=debug\nDATA_DIR=./data\n"
            .write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let (_, provenance) = try Config.loadWithProvenance(
            environment: [:], cwd: dir, appSupportEnv: appSupport, settingsFile: Self.noSettings
        )
        #expect(provenance.appSupportOverrides.isEmpty)
        #expect(provenance.source(of: "LOG_LEVEL") == .appSupport)
    }

    @Test("DATA_DIR from the process environment wins over an App Support file, with provenance env")
    func processEnvDataDirWinsOverAppSupport() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appSupport = dir.appendingPathComponent("app-support.env")
        try "DATA_DIR=/tmp/other-worktree/data\n".write(to: appSupport, atomically: true, encoding: .utf8)
        try "DATA_DIR=./data\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        // `DATA_DIR=./data swift run Worklens config-dump` from a worktree, the issue's acceptance.
        let (config, provenance) = try Config.loadWithProvenance(
            environment: ["DATA_DIR": "./data"], cwd: dir, appSupportEnv: appSupport, settingsFile: Self.noSettings
        )
        #expect(provenance.source(of: "DATA_DIR") == .process)
        #expect(config.dataDir.standardizedFileURL == dir.appendingPathComponent("data").standardizedFileURL)
        // Nothing is being taken away from the checkout, so nothing is worth logging.
        #expect(provenance.appSupportOverrides.isEmpty)
    }

    @Test("a relative DATA_DIR in the App Support file still resolves next to that file")
    func appSupportRelativeDataDirStaysFileRelative() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appSupport = dir.appendingPathComponent(".env")
        try "DATA_DIR=./data\n".write(to: appSupport, atomically: true, encoding: .utf8)

        let (config, provenance) = try Config.loadWithProvenance(
            environment: [:],
            cwd: URL(fileURLWithPath: "/", isDirectory: true),
            appSupportEnv: appSupport, settingsFile: Self.noSettings
        )
        #expect(config.dataDir.standardizedFileURL == dir.appendingPathComponent("data").standardizedFileURL)
        #expect(provenance.source(of: "DATA_DIR") == .appSupport)
    }

    @Test("the dump carries a provenance label for every key")
    func dumpLinesCarryProvenance() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appSupport = dir.appendingPathComponent("app-support.env")
        try "GRANOLA_API_KEY=grn_abc-secretvalue\n"
            .write(to: appSupport, atomically: true, encoding: .utf8)

        let (config, provenance) = try Config.loadWithProvenance(
            environment: ["DESCRIBE_MODEL": "from-env"], cwd: dir, appSupportEnv: appSupport, settingsFile: Self.noSettings
        )
        let lines = config.dumpLines(provenance: provenance)
        #expect(lines.map(\.key) == config.dumpLines.map(\.key))
        #expect(Set(lines.map(\.key)) == Set(Config.knownKeys))
        #expect(lines.first { $0.key == "DESCRIBE_MODEL" }?.source == .process)
        #expect(lines.first { $0.key == "GRANOLA_API_KEY" }?.source == .appSupport)
        #expect(lines.first { $0.key == "LOG_LEVEL" }?.source == .fallback)
        // Provenance must not turn a masked secret back into a printable one.
        let rendered = lines.map { "\($0.key)=\($0.value) (\($0.source.label))" }.joined(separator: "\n")
        #expect(!rendered.contains("secretvalue"))
        #expect(rendered.contains("GRANOLA_API_KEY=grn_abc**** (app-support)"))
    }

    @Test("a note drops the leading key and keeps the rest of the sentence")
    func noteDropsTheLeadingKey() {
        let range = ConfigError.outOfRange(key: "CAPTURE_INTERVAL_SEC", value: "2", range: "5...600")
        #expect(ConfigError.note(range) == "2 is outside 5...600")
        let int = ConfigError.invalidInt(key: "CAPTURE_IDLE_SECONDS", value: "soon")
        #expect(ConfigError.note(int) == "expected an integer, got \"soon\"")
    }

    @Test("a note leaves a sentence that does not open with a key alone")
    func noteLeavesProseAlone() {
        // No colon at all, and the key is mid-sentence: nothing to strip.
        let unknown = ConfigError.unknownKey(key: "CAPTURE_NOPE")
        #expect(ConfigError.note(unknown) == unknown.description)
        // A colon, but what precedes it is prose rather than a key.
        struct Sentence: Error, CustomStringConvertible {
            var description: String { "Worklens could not write the file: it is read-only" }
        }
        #expect(ConfigError.note(Sentence()) == "Worklens could not write the file: it is read-only")
    }
}
