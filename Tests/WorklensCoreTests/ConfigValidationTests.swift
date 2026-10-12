import Foundation
import Testing
@testable import WorklensCore

/// #126: validation, multi-error reporting with provenance, and the lenient load.
@Suite("Config validation")
struct ConfigValidationTests {
    private let cwd = URL(fileURLWithPath: "/tmp/worklens-test-cwd", isDirectory: true)
    private static let noAppSupportEnv = URL(fileURLWithPath: "/nonexistent/worklens/app-support/.env")
    private static let noSettings = URL(fileURLWithPath: "/nonexistent/worklens/settings.json")

    private func scratchDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-config-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Bounds

    @Test("the interval keys and the budget have floors, and below one is an error")
    func minimums() throws {
        let belowFloor: [String: (String, String)] = [
            "CAPTURE_INTERVAL_SECONDS": ("0", "5 to 600"),
            "MEETING_CAPTURE_INTERVAL_SECONDS": ("4", "5 to 900"),
            "CAPTURE_IDLE_SECONDS": ("-1", "5 to 1800"),
            "CAPTURE_HEARTBEAT_SECONDS": ("0", "5 to 3600"),
            "CAPTURE_MAX_EDGE_PX": ("32", "64 to 4096"),
            "AUTO_UPDATE_POLL_MINUTES": ("1", "5 or more"),
        ]
        for (key, (value, range)) in belowFloor {
            #expect(throws: ConfigError.outOfRange(key: key, value: value, range: range)) {
                _ = try Config.load(layers: [[key: value]], cwd: cwd)
            }
        }
        #expect(throws: ConfigError.outOfRange(key: "DAILY_BUDGET_USD", value: "-0.5", range: "0 or more")) {
            _ = try Config.load(layers: [["DAILY_BUDGET_USD": "-0.5"]], cwd: cwd)
        }
        // The floor itself is legal, and so is a zero budget — "describe nothing" is a choice.
        #expect(try Config.load(layers: [["CAPTURE_INTERVAL_SECONDS": "5"]], cwd: cwd).captureIntervalSeconds == 5)
        #expect(try Config.load(layers: [["DAILY_BUDGET_USD": "0"]], cwd: cwd).dailyBudgetUSD == 0)
    }

    @Test("#242: a ceiling is refused the same way a floor is, wherever the value was typed")
    func maximums() throws {
        let aboveCeiling: [String: (String, String)] = [
            "CAPTURE_INTERVAL_SECONDS": ("601", "5 to 600"),
            "MEETING_CAPTURE_INTERVAL_SECONDS": ("901", "5 to 900"),
            "CAPTURE_IDLE_SECONDS": ("1801", "5 to 1800"),
            "CAPTURE_HEARTBEAT_SECONDS": ("3601", "5 to 3600"),
            "CAPTURE_MAX_EDGE_PX": ("8192", "64 to 4096"),
        ]
        for (key, (value, range)) in aboveCeiling {
            let expected = ConfigError.outOfRange(key: key, value: value, range: range)
            // The loader refuses it...
            #expect(throws: expected) { _ = try Config.load(layers: [[key: value]], cwd: cwd) }
            // ...and so does `worklens config set`, with the same sentence, which is the one the
            // Settings pane shows when a write fails.
            #expect(throws: expected) { try Config.validate(key: key, value: value) }
        }
        // The ceiling itself is legal.
        #expect(try Config.load(layers: [["CAPTURE_INTERVAL_SECONDS": "600"]], cwd: cwd).captureIntervalSeconds == 600)
    }

    @Test("`.env.example`'s stated bounds are the registry's, so the doc cannot drift")
    func minimumsComeFromTheRegistry() {
        let bounds: [String: (Double, Double?)] = [
            "CAPTURE_INTERVAL_SECONDS": (5, 600),
            "MEETING_CAPTURE_INTERVAL_SECONDS": (5, 900),
            "CAPTURE_IDLE_SECONDS": (5, 1800),
            "CAPTURE_HEARTBEAT_SECONDS": (5, 3600),
            "CAPTURE_MAX_EDGE_PX": (64, 4096),
            "AUTO_UPDATE_POLL_MINUTES": (5, nil),
        ]
        for (name, (minimum, maximum)) in bounds {
            #expect(Config.key(named: name)?.minimum == minimum, "\(name)")
            #expect(Config.key(named: name)?.maximum == maximum, "\(name)")
        }
        #expect(Config.key(named: "DAILY_BUDGET_USD")?.minimum == 0)
        // A key with both ends is what a Settings stepper is built from.
        #expect(Config.key(named: "CAPTURE_INTERVAL_SECONDS")?.range == 5...600)
        #expect(Config.key(named: "AUTO_UPDATE_POLL_MINUTES")?.range == nil)
    }

    // MARK: Models — warning, never fatal

    @Test("an unpriced model id is a warning, not a refusal: a new id must still launch")
    func unknownModelIsAWarning() throws {
        let loaded = try Config.load(
            sources: [ConfigSource(layer: .cwd, url: nil, values: ["DESCRIBE_MODEL": "gemini-9-flash"])],
            cwd: cwd
        )
        #expect(loaded.config.describeModel == "gemini-9-flash")
        #expect(loaded.warnings == [.unknownModel(key: "DESCRIBE_MODEL", model: "gemini-9-flash")])
        #expect(loaded.warnings.first?.description.contains("costed at $0") == true)
    }

    @Test("a model that is in the price table warns about nothing")
    func knownModelIsSilent() throws {
        let loaded = try Config.load(
            sources: [ConfigSource(layer: .cwd, url: nil, values: ["DESCRIBE_MODEL": "gemini-2.5-flash-lite"])],
            cwd: cwd
        )
        #expect(loaded.warnings.isEmpty)
    }

    // MARK: Lists

    @Test("bundle ids and URL hosts take either separator")
    func listSeparators() throws {
        let semicolons = try Config.load(
            layers: [["BLOCKED_BUNDLE_IDS": "com.a.one;com.b.two", "BLOCKED_URL_HOSTS": "bank.example;clinic.example"]],
            cwd: cwd
        )
        #expect(semicolons.blockedBundleIDs == ["com.a.one", "com.b.two"])
        #expect(semicolons.blockedURLHosts == ["bank.example", "clinic.example"])

        let commas = try Config.load(
            layers: [["BLOCKED_BUNDLE_IDS": "com.a.one,com.b.two", "BLOCKED_URL_HOSTS": "bank.example,clinic.example"]],
            cwd: cwd
        )
        #expect(commas.blockedBundleIDs == ["com.a.one", "com.b.two"])
        #expect(commas.blockedURLHosts == ["bank.example", "clinic.example"])
    }

    @Test("a regex list is never split on a comma: `{2,3}` is one pattern, not two")
    func regexListsKeepTheirCommas() throws {
        let loaded = try Config.load(
            sources: [
                ConfigSource(
                    layer: .cwd, url: nil,
                    values: ["BLOCKED_TITLE_PATTERNS": "Acct \\d{2,3};Private"]
                )
            ],
            cwd: cwd
        )
        #expect(loaded.config.blockedTitlePatterns == ["Acct \\d{2,3}", "Private"])
        // A semicolon is present, so this is a list that meant what it said: no warning.
        #expect(loaded.warnings.isEmpty)
    }

    @Test("a regex list with a comma and no semicolon is named rather than split")
    func regexListSeparatorWarning() throws {
        let loaded = try Config.load(
            sources: [
                ConfigSource(layer: .cwd, url: nil, values: ["REDACT_EXTRA_PATTERNS": "alpha,beta"])
            ],
            cwd: cwd
        )
        #expect(loaded.config.redactExtraPatterns == ["alpha,beta"])
        #expect(loaded.warnings == [.listSeparator(key: "REDACT_EXTRA_PATTERNS")])
    }

    // MARK: Multiple errors, with provenance

    @Test("every error is collected, each naming the file it came from")
    func multipleErrorsCarryTheirFile() throws {
        let file = URL(fileURLWithPath: "/tmp/worklens/.env")
        let source = ConfigSource(
            layer: .cwd, url: file,
            values: [
                "CAPTURE_INTERVAL_SECONDS": "soon",
                "AUTO_UPDATE_ENABLED": "maybe",
                "LOG_LEVEL": "shouty",
            ]
        )
        var thrown: ConfigError?
        do {
            _ = try Config.load(sources: [source], cwd: cwd)
        } catch let error as ConfigError {
            thrown = error
        }
        let error = try #require(thrown)
        #expect(error.errors.count == 3)
        #expect(error.keys.sorted() == ["AUTO_UPDATE_ENABLED", "CAPTURE_INTERVAL_SECONDS", "LOG_LEVEL"])
        #expect(error.file == file)
        #expect(error.layer == .cwd)
        // One sentence per error, and each of them says where.
        #expect(error.sentences.count == 3)
        #expect(error.sentences.allSatisfy { $0.contains("/tmp/worklens/.env") })
        #expect(error.summary.contains("3 settings need fixing"))
    }

    @Test("one error is thrown on its own, so an existing catch still matches it")
    func singleErrorIsNotWrapped() throws {
        #expect(throws: ConfigError.invalidInt(key: "CAPTURE_INTERVAL_SECONDS", value: "soon")) {
            _ = try Config.load(layers: [["CAPTURE_INTERVAL_SECONDS": "soon"]], cwd: cwd)
        }
    }

    @Test("the file named is the layer that actually supplied the bad value")
    func errorNamesTheWinningLayer() throws {
        let appSupport = URL(fileURLWithPath: "/tmp/worklens-app-support/.env")
        let checkout = URL(fileURLWithPath: "/tmp/worklens-checkout/.env")
        var thrown: ConfigError?
        do {
            _ = try Config.load(
                sources: [
                    ConfigSource(layer: .appSupport, url: appSupport, values: ["AUTO_UPDATE_ENABLED": "maybe"]),
                    ConfigSource(layer: .cwd, url: checkout, values: ["AUTO_UPDATE_ENABLED": "false"]),
                ],
                cwd: cwd
            )
        } catch let error as ConfigError {
            thrown = error
        }
        #expect(try #require(thrown).file == appSupport)
    }

    // MARK: Lenient load

    @Test("lenient drops only the offending keys and keeps every other value")
    func lenientLoad() throws {
        let loaded = try Config.load(
            sources: [
                ConfigSource(
                    layer: .cwd, url: URL(fileURLWithPath: "/tmp/worklens/.env"),
                    values: [
                        "CAPTURE_INTERVAL_SECONDS": "soon",
                        "AUTO_UPDATE_ENABLED": "maybe",
                        "CAPTURE_IDLE_SECONDS": "45",
                        "LOG_LEVEL": "debug",
                    ]
                )
            ],
            cwd: cwd,
            lenient: true
        )
        #expect(loaded.droppedKeys.sorted() == ["AUTO_UPDATE_ENABLED", "CAPTURE_INTERVAL_SECONDS"])
        // The two that parsed are still the user's.
        #expect(loaded.config.captureIdleSeconds == 45)
        #expect(loaded.config.logLevel == .debug)
        // The two that did not are the built-in defaults, and each is named.
        #expect(loaded.config.captureIntervalSeconds == 60)
        #expect(loaded.config.autoUpdateEnabled == false)
        #expect(loaded.warnings.contains(.usingDefault(key: "AUTO_UPDATE_ENABLED")))
    }

    @Test("a lenient load writes nothing: .env stays the source of truth")
    func lenientWritesNothing() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = dir.appendingPathComponent(".env")
        let text = "AUTO_UPDATE_ENABLED=maybe\nCAPTURE_IDLE_SECONDS=45\n"
        try text.write(to: env, atomically: true, encoding: .utf8)

        let loaded = try Config.loadWithProvenance(
            environment: [:], cwd: dir, appSupportEnv: Self.noAppSupportEnv,
            settingsFile: Self.noSettings, lenient: true
        )
        #expect(loaded.config.autoUpdateEnabled == false)
        #expect(loaded.config.captureIdleSeconds == 45)
        #expect(try String(contentsOf: env, encoding: .utf8) == text)
    }

    // MARK: Unknown keys

    @Test("an unknown key in a file is named with a suggestion, and never blocks the load")
    func unknownKeys() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "CAPTURE_INTERVAL_SECS=30\nMY_OWN_THING=1\nCAPTURE_IDLE_SECONDS=45\n"
            .write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let loaded = try Config.loadWithProvenance(
            environment: [:], cwd: dir, appSupportEnv: Self.noAppSupportEnv, settingsFile: Self.noSettings
        )
        // Non-fatal: the rest of the file applied.
        #expect(loaded.config.captureIdleSeconds == 45)
        let names = loaded.provenance.unknownKeys.map(\.name)
        #expect(names.contains("CAPTURE_INTERVAL_SECS"))
        #expect(names.contains("MY_OWN_THING"))
        let typo = try #require(loaded.provenance.unknownKeys.first { $0.name == "CAPTURE_INTERVAL_SECS" })
        #expect(typo.suggestion == "CAPTURE_INTERVAL_SECONDS")
        #expect(typo.url?.lastPathComponent == ".env")
        // Nothing is close to this one, so no suggestion is invented.
        #expect(loaded.provenance.unknownKeys.first { $0.name == "MY_OWN_THING" }?.suggestion == nil)
    }

    @Test("the process environment is never searched for unknown keys")
    func unknownKeysIgnoreTheProcessEnvironment() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let loaded = try Config.loadWithProvenance(
            environment: ["PATH": "/usr/bin", "HOMEBREW_PREFIX": "/opt/homebrew"],
            cwd: dir, appSupportEnv: Self.noAppSupportEnv, settingsFile: Self.noSettings
        )
        #expect(loaded.provenance.unknownKeys.isEmpty)
    }

    @Test("a retired key keeps its own #87 sentence rather than being called unknown")
    func retiredKeysAreNotUnknown() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let retired = try #require(Config.retiredKeys.first)
        try "\(retired)=whatever\n"
            .write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let loaded = try Config.loadWithProvenance(
            environment: [:], cwd: dir, appSupportEnv: Self.noAppSupportEnv, settingsFile: Self.noSettings
        )
        #expect(loaded.provenance.retiredKeys == [retired])
        #expect(loaded.provenance.unknownKeys.isEmpty)
    }

    @Test("a warning line names keys, never values, one could be a mistyped API key")
    func warningsNameKeysOnly() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "GEMINI_API_KEYY=AIza-secret-value\n"
            .write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let loaded = try Config.loadWithProvenance(
            environment: [:], cwd: dir, appSupportEnv: Self.noAppSupportEnv, settingsFile: Self.noSettings
        )
        #expect(loaded.provenance.warningLines.contains { $0.contains("GEMINI_API_KEYY") })
        #expect(!loaded.provenance.warningLines.contains { $0.contains("AIza-secret-value") })
    }

    @Test("the nearest known key is only suggested when it really is near")
    func suggestions() {
        #expect(Config.nearestKnownKey("CAPTURE_INTERVAL_SECS") == "CAPTURE_INTERVAL_SECONDS")
        #expect(Config.nearestKnownKey("REPORT_LANGUAG") == "REPORT_LANGUAGE")
        #expect(Config.nearestKnownKey("GEMINI_APIKEY") == "GEMINI_API_KEY")
        #expect(Config.nearestKnownKey("TOTALLY_UNRELATED_NAME") == nil)
    }

    // MARK: SettingsStore agrees with the loader

    @Test("a value Settings would write is checked by the same rules the loader uses")
    func validateRunsTheSameRules() {
        #expect(throws: ConfigError.invalidBool(key: "AUTO_UPDATE_ENABLED", value: "maybe")) {
            try Config.validate(key: "AUTO_UPDATE_ENABLED", value: "maybe")
        }
        #expect(throws: ConfigError.outOfRange(key: "CAPTURE_INTERVAL_SECONDS", value: "2", range: "5 to 600")) {
            try Config.validate(key: "CAPTURE_INTERVAL_SECONDS", value: "2")
        }
        #expect(throws: Never.self) { try Config.validate(key: "AUTO_UPDATE_ENABLED", value: "false") }
        // An unpriced model is advisory, so writing one is allowed.
        #expect(throws: Never.self) { try Config.validate(key: "DESCRIBE_MODEL", value: "gemini-9-flash") }
    }
}

/// #126: the reload decision — parse first, and only then tear anything down.
@Suite("Config reload")
struct ConfigReloadTests {
    private let cwd = URL(fileURLWithPath: "/tmp/worklens-test-cwd", isDirectory: true)

    @Test("a reload that cannot parse keeps the running stack: nothing is rebuilt")
    func failedReloadChangesNothing() throws {
        let file = URL(fileURLWithPath: "/tmp/worklens/.env")
        let outcome = ConfigReload.outcome {
            try Config.load(
                sources: [ConfigSource(layer: .cwd, url: file, values: ["AUTO_UPDATE_ENABLED": "maybe"])],
                cwd: self.cwd
            ).config.asLoaded
        }
        #expect(outcome.keepsRunning)
        guard case let .keepRunning(message, badFile) = outcome else {
            Issue.record("expected the running stack to be kept")
            return
        }
        #expect(message.hasPrefix("Configuration not reloaded: "))
        #expect(message.contains("AUTO_UPDATE_ENABLED"))
        #expect(badFile == file)
    }

    @Test("a reload that parses asks for a rebuild, with the config it parsed")
    func goodReloadRebuilds() throws {
        let outcome = ConfigReload.outcome {
            (try Config.load(layers: [["CAPTURE_INTERVAL_SECONDS": "30"]], cwd: self.cwd), ConfigProvenance())
        }
        #expect(!outcome.keepsRunning)
        guard case let .rebuild(config, _) = outcome else {
            Issue.record("expected a rebuild")
            return
        }
        #expect(config.captureIntervalSeconds == 30)
        #expect(ConfigReload.reloadedMessage(config) == "Configuration reloaded: capturing every 30 s")
    }

    @Test("three bad settings say how many there are before naming the first")
    func failureMessageCountsThem() {
        let file = URL(fileURLWithPath: "/tmp/worklens/.env")
        let error = ConfigError.multiple([
            .located(.invalidEnum(key: "LOG_LEVEL", value: "shouty", allowed: ["debug", "info"]), layer: .cwd, file: file),
            .located(.invalidInt(key: "CAPTURE_INTERVAL_SECONDS", value: "soon"), layer: .cwd, file: file),
            .located(.invalidBool(key: "AUTO_UPDATE_ENABLED", value: "maybe"), layer: .cwd, file: file),
        ])
        let message = ConfigReload.failureMessage(error)
        #expect(message.contains("3 settings need fixing"))
        #expect(message.contains("/tmp/worklens/.env"))
    }

    @Test("the confirmation names the keys it dropped and says the file is unchanged")
    func defaultsMessage() {
        let message = ConfigReload.startedOnDefaultsMessage(droppedKeys: ["LOG_LEVEL", "CAPTURE_IDLE_SECONDS"])
        #expect(message.contains("LOG_LEVEL, CAPTURE_IDLE_SECONDS"))
        #expect(message.contains("this session only"))
        #expect(message.contains("unchanged"))
        #expect(ConfigReload.startedOnDefaultsMessage(droppedKeys: []) == "Started with the configuration as it is.")
    }

    @Test("a rebuild only re-stops a stack that existed and was deliberately stopped")
    func stopsAfterRebuild() {
        // A reload of a running app: it keeps running.
        #expect(!ConfigReload.stopsAfterRebuild(hadStack: true, wasRunning: true))
        // A reload while capture was deliberately stopped: still stopped afterwards.
        #expect(ConfigReload.stopsAfterRebuild(hadStack: true, wasRunning: false))
        // "Use defaults for these keys and start" from a degraded startup: there was no stack at
        // all, so the new one must be left running — this is the whole promise of the button.
        #expect(!ConfigReload.stopsAfterRebuild(hadStack: false, wasRunning: false))
    }

    @Test("keysUsingDefaults is exactly what a lenient load dropped")
    func keysUsingDefaults() throws {
        let loaded = try Config.load(
            sources: [
                ConfigSource(
                    layer: .cwd, url: nil,
                    values: ["AUTO_UPDATE_ENABLED": "maybe", "CAPTURE_INTERVAL_SECONDS": "soon"]
                )
            ],
            cwd: cwd, lenient: true
        )
        let provenance = ConfigProvenance(warnings: loaded.warnings)
        #expect(provenance.keysUsingDefaults.sorted() == ["AUTO_UPDATE_ENABLED", "CAPTURE_INTERVAL_SECONDS"])
    }
}

private extension Config {
    /// Sugar for the reload tests: a `Config` with an empty provenance beside it.
    var asLoaded: (config: Config, provenance: ConfigProvenance) { (self, ConfigProvenance()) }
}
