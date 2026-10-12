import ArgumentParser
import Foundation
import WorklensCore

/// `worklens config get|set|unset|path` — the command-line half of the settings layer.
///
/// It writes `~/Library/Application Support/Worklens/settings.json`, the same file the Settings
/// window writes, never `.env`. Whatever it writes is validated first and can still be outranked
/// by the process environment or `WORKLENS_ENV_FILE`, so every verb says which layer actually
/// wins the key afterwards rather than leaving the user to guess.
struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read and write Worklens's own settings file.",
        subcommands: [Get.self, Set.self, Unset.self, Path.self]
    )

    // MARK: get

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print one key's resolved value and the layer that supplied it."
        )

        @Argument(help: "The key, e.g. DAILY_BUDGET_USD.")
        var key: String

        func run() throws {
            let (config, provenance) = try CLIConfig.loadWithProvenance()
            guard let entry = Config.key(named: key), let read = entry.read else {
                throw ValidationError(ConfigError.unknownKey(key: key).description)
            }
            // `read` masks a secret, so nothing here can print an API key in full.
            print("\(key)=\(read(config))  (\(provenance.source(of: key).label))")
            print(entry.help)
        }
    }

    // MARK: set

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write a key to Worklens's settings file."
        )

        @Argument(help: "The key, e.g. DAILY_BUDGET_USD.")
        var key: String
        @Argument(help: "The value. It is validated before anything is written.")
        var value: String

        func run() throws {
            let store = SettingsStore()
            do {
                try store.set(key, value)
            } catch let error as ConfigError {
                throw ValidationError(error.description)
            } catch let error as SettingsStoreError {
                throw ValidationError(error.description)
            }
            print("\(key)=\(Config.key(named: key)?.kind == .secret ? Config.mask(value) : value) → \(store.url.path)")
            try ConfigCommand.reportWinner(key)
        }
    }

    // MARK: unset

    struct Unset: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a key from Worklens's settings file, so the layer below it wins again."
        )

        @Argument(help: "The key to remove.")
        var key: String

        func run() throws {
            let store = SettingsStore()
            let had = store.get(key) != nil
            do {
                try store.remove(key)
            } catch let error as SettingsStoreError {
                throw ValidationError(error.description)
            }
            print(had ? "removed \(key) from \(store.url.path)" : "\(key) was not set in \(store.url.path)")
            try ConfigCommand.reportWinner(key)
        }
    }

    // MARK: path

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the path of Worklens's settings file."
        )

        func run() {
            print(SettingsStore.defaultURL.path)
        }
    }

    /// After a write: which layer the key now resolves from, and the fact that a running app is
    /// still on the old value. Nothing watches the file — the app re-reads it on
    /// "Reload configuration", on its own edits, and at launch.
    private static func reportWinner(_ key: String) throws {
        let (config, provenance) = try CLIConfig.loadWithProvenance()
        let winner = provenance.source(of: key)
        let value = Config.key(named: key)?.read?(config) ?? ""
        if winner != .appSettings, winner != .fallback {
            print("note: \(winner.label) also sets \(key) and outranks the settings file, "
                + "\(key)=\(value) is what Worklens will read.")
        } else {
            print("\(key)=\(value) is what Worklens will read.")
        }
        print("A running Worklens still has the old value: use Settings → General → "
            + "Reload configuration, or restart it.")
    }
}
