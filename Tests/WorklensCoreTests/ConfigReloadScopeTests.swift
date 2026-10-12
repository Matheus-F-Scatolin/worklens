import Foundation
import Testing
@testable import WorklensCore

/// A value for this key that is definitely not the one it has now.
private func changedValue(for key: ConfigKey) -> String {
    switch key.kind {
    case .int:
        return String((Int(key.defaultLiteral) ?? 10) + 5)
    case .double, .unitDouble:
        return "0.5"
    case .bool:
        return key.defaultLiteral == "true" ? "false" : "true"
    case let .choice(options):
        return options.first { $0 != key.defaultLiteral } ?? key.defaultLiteral
    default:
        return "changed-\(key.name.lowercased())"
    }
}

private func applying(_ key: ConfigKey, to config: Config) throws -> Config {
    var changed = config
    try key.apply?(&changed, changedValue(for: key), FileManager.default.temporaryDirectory)
    return changed
}

@Suite("A reload confined to the context sources (#135)")
struct ConfigReloadScopeTests {
    @Test("every context key, changed on its own, is recognised as context-only")
    func everyContextKeyIsInScope() throws {
        let base = Config.defaults()
        let contextKeys = Config.keys.filter { $0.section == .context && !$0.retired }
        #expect(!contextKeys.isEmpty)
        #expect(ConfigReload.contextKeyNames.sorted() == contextKeys.map(\.name).sorted())

        for key in contextKeys {
            let changed = try applying(key, to: base)
            #expect(changed != base, "\(key.name) did not actually change")
            #expect(
                ConfigReload.onlyContextChanged(from: base, to: changed),
                "\(key.name) is a context key but a change to it rebuilds the whole stack"
            )
        }
    }

    @Test("a key from any other section is not")
    func otherSectionsAreOutOfScope() throws {
        let base = Config.defaults()
        for key in Config.keys where key.section != nil && key.section != .context && !key.retired {
            let changed = try applying(key, to: base)
            guard changed != base else { continue }
            #expect(
                !ConfigReload.onlyContextChanged(from: base, to: changed),
                "\(key.name) is not a context key, so capture must be rebuilt around it"
            )
        }
    }

    @Test("a context key and a capture key together rebuild everything")
    func mixedChangesAreOutOfScope() {
        var changed = Config.defaults()
        changed.granolaAPIKey = "grn_new"
        changed.captureIntervalSeconds += 5
        #expect(!ConfigReload.onlyContextChanged(from: Config.defaults(), to: changed))
    }

    @Test("a reload that changed nothing is not a context reload either")
    func unchangedIsNotInScope() {
        #expect(!ConfigReload.onlyContextChanged(from: Config.defaults(), to: Config.defaults()))
    }

    @Test("the message says the interval and that capture was left alone")
    func message() {
        var config = Config.defaults()
        config.contextSyncMinutes = 30
        let message = ConfigReload.contextReloadedMessage(config)
        #expect(message.contains("30 min"))
        #expect(message.lowercased().contains("capture kept running"))
    }
}
