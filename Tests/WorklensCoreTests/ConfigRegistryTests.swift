import Foundation
import Testing
@testable import WorklensCore

// MARK: - The registry (#108)

@Suite("Config key registry")
struct ConfigRegistryTests {
    @Test("every key the dump prints has a registry entry, and every live entry is dumped")
    func registryIsTheDump() {
        #expect(Config.liveKeys.map(\.name) == Config.knownKeys)
        #expect(Set(Config.keys.map(\.name)).count == Config.keys.count)   // no duplicates
        #expect(Config.liveKeys.allSatisfy { $0.apply != nil && $0.read != nil && $0.section != nil })
        #expect(Config.keys.filter(\.retired).allSatisfy { $0.apply == nil && $0.section == nil })
    }

    @Test("the retired list is the registry's retired entries, in order")
    func retiredIsDerived() {
        #expect(Config.retiredKeys == Config.keys.filter(\.retired).map(\.name))
        #expect(Config.retiredKeys.first == "DESCRIBE_PROVIDER")
        #expect(Set(Config.retiredKeys).isDisjoint(with: Config.knownKeys))
    }

    @Test("every key has help, a section that is not empty, and a default that parses")
    func entriesAreWellFormed() throws {
        for section in ConfigSection.allCases {
            #expect(!Config.keys.filter { $0.section == section }.isEmpty, "\(section) has no keys")
        }
        for key in Config.liveKeys {
            #expect(!key.help.isEmpty, "\(key.name) has no help")
            guard !key.defaultLiteral.isEmpty else { continue }
            // A default that does not parse is a default nobody could type back in.
            try Config.validate(key: key.name, value: key.defaultLiteral)
        }
    }

    @Test("#242: every numeric capture key is bounded, so no Settings control invents its own")
    func captureKeysAreBounded() {
        for key in Config.liveKeys where key.section == .capture {
            switch key.kind {
            case .int:
                // Both ends, and in that order: a stepper reads `range` and cannot offer a
                // number `worklens config set` would refuse.
                #expect(key.range != nil, "\(key.name) has no range")
            case .double:
                // None today, but a capture double without a bound is the same bug as an int
                // without a range.
                #expect(key.minimum != nil || key.maximum != nil, "\(key.name) has no bound")
            case .unitDouble:
                // Bounded by its kind: `CHANGE_THRESHOLD` is a fraction, checked against 0...1.
                break
            case .secret, .string, .bool, .choice, .list, .regexList, .model, .path:
                // Not a number, so there is nothing to bound. Listed rather than defaulted: a
                // new numeric `Kind` has to stop here and be decided on, which is the silent
                // pass #242 asked this test to close.
                break
            }
        }
    }

    @Test("validate accepts what load accepts and refuses what it does not")
    func validation() throws {
        try Config.validate(key: "DAILY_BUDGET_USD", value: "2.5")
        #expect(throws: ConfigError.invalidDouble(key: "DAILY_BUDGET_USD", value: "free")) {
            try Config.validate(key: "DAILY_BUDGET_USD", value: "free")
        }
        #expect(throws: ConfigError.outOfRange(key: "CHANGE_THRESHOLD", value: "4", range: "0...1")) {
            try Config.validate(key: "CHANGE_THRESHOLD", value: "4")
        }
        #expect(throws: ConfigError.unknownKey(key: "NOPE")) { try Config.validate(key: "NOPE", value: "1") }
        // A retired key is not silently accepted either.
        #expect(throws: ConfigError.unknownKey(key: "AX_MAX_NODES")) {
            try Config.validate(key: "AX_MAX_NODES", value: "10")
        }
        #expect(throws: ConfigError.emptyValue(key: "LOG_LEVEL")) { try Config.validate(key: "LOG_LEVEL", value: " ") }
    }
}

// MARK: - .env.example is generated (#108)

@Suite(".env.example")
struct EnvExampleTests {
    private var checkedIn: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WorklensCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(".env.example")
    }

    @Test("the checked-in file is what the registry renders, byte for byte")
    func matchesTheRegistry() throws {
        let expected = EnvExample.render()
        // Same escape hatch the timeline goldens use, for when a key's prose legitimately
        // changes: `WORKLENS_UPDATE_FIXTURES=1 make test` rewrites the file.
        if ProcessInfo.processInfo.environment["WORKLENS_UPDATE_FIXTURES"] == "1" {
            try expected.write(to: checkedIn, atomically: true, encoding: .utf8)
        }
        let actual = try String(contentsOf: checkedIn, encoding: .utf8)
        #expect(
            actual == expected,
            "`.env.example` is out of date: regenerate it with `swift run Worklens config-example > .env.example`"
        )
    }

    @Test("no section header is left without keys under it")
    func noOrphanSections() {
        // #87 retired every AX_* key and left an "--- Accessibility ---" header with prose and
        // nothing to set. A header comes from a section that has keys, so that cannot recur.
        let rendered = EnvExample.render()
        for section in ConfigSection.allCases {
            let keys = Config.keys.filter { $0.section == section }
            #expect(!keys.isEmpty)
            #expect(rendered.contains("# --- \(section.rawValue) "))
            for key in keys { #expect(rendered.contains("\n\(key.name)=")) }
        }
        let headers = rendered.components(separatedBy: "\n").filter { $0.hasPrefix("# --- ") }
        #expect(headers.count == ConfigSection.allCases.count)
    }
}
