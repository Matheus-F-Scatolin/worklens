import Foundation

/// Why a write was refused. Every case is something the person typing can act on.
public enum SettingsStoreError: Error, CustomStringConvertible, Equatable {
    /// The key exists but Worklens will not write it — `DATA_DIR` (see `ConfigKey.editableInApp`).
    case notEditable(key: String)
    /// The settings file could not be read as a flat `{"KEY": "value"}` object.
    case unreadable(path: String)
    case writeFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case let .notEditable(key):
            return "\(key) is not a setting Worklens writes: set it in .env or in the environment"
        case let .unreadable(path):
            return "\(path) is not a flat {\"KEY\": \"value\"} object, fix or delete it"
        case let .writeFailed(path, reason):
            return "could not write \(path): \(reason)"
        }
    }
}

/// The one settings file Worklens owns: `~/Library/Application Support/Worklens/settings.json`,
/// mode 0600, a flat map of the same `KEY` names `.env` uses.
///
/// It exists so the app can change a setting without editing a file the user also edits by hand —
/// the merge conflict that kept the Settings window read-only. `.env` stays readable and keeps
/// winning wherever it has to: the process environment and `WORKLENS_ENV_FILE` both outrank this
/// file, which is what worktrees, tests and `make install-env` rely on for `DATA_DIR` (#34).
///
/// Not an actor: it is a file read at launch and written when somebody clicks something, and
/// `Config.load` needs it synchronously. Every write is atomic, so a concurrent reader sees
/// either the old file or the new one.
public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL = SettingsStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Worklens/settings.json")
    }

    // MARK: Reading

    /// Everything in the file, unfiltered. An absent file is an empty map; an unparseable one
    /// warns and reads as empty, because a broken settings file must not stop Worklens starting.
    public func values() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            Log.config.warn("\(url.path) is not a flat {\"KEY\": \"value\"} object, ignoring it")
            return [:]
        }
        return decoded
    }

    /// What `Config` layers in: the values above, minus anything this store would refuse to
    /// write. A hand-added `DATA_DIR` is dropped rather than honoured, so no edit to this file
    /// can outrank the `WORKLENS_ENV_FILE` a worktree or a test pinned.
    public func layerValues() -> [String: String] {
        var kept: [String: String] = [:]
        var dropped: [String] = []
        for (key, value) in values() where !value.isEmpty {
            if let entry = Config.key(named: key), entry.editableInApp {
                kept[key] = value
            } else {
                dropped.append(key)
            }
        }
        if !dropped.isEmpty {
            Log.config.warn(
                "\(url.path) sets \(dropped.sorted().joined(separator: ", ")): Worklens does not read "
                    + "those from this file; set them in .env or in the environment"
            )
        }
        return kept
    }

    public func get(_ key: String) -> String? {
        let value = values()[key]
        return (value?.isEmpty ?? true) ? nil : value
    }

    // MARK: Writing

    /// Validates, then writes. `Config.validate` runs first every time, so the file can only
    /// ever hold values that parse — an invalid one is refused where it was typed rather than
    /// breaking the next launch.
    public func set(_ key: String, _ value: String) throws {
        guard let entry = Config.key(named: key), entry.apply != nil else {
            throw ConfigError.unknownKey(key: key)
        }
        guard entry.editableInApp else { throw SettingsStoreError.notEditable(key: key) }
        try Config.validate(key: key, value: value)
        var current = values()
        current[key] = value
        try write(current)
    }

    /// Removes a key, so the layer below it wins again. Removing one that is not there is not
    /// an error — the end state is what was asked for.
    public func remove(_ key: String) throws {
        var current = values()
        guard current.removeValue(forKey: key) != nil else { return }
        try write(current)
    }

    /// Atomic, 0600, sorted keys so a hand-read diff of the file is stable.
    private func write(_ values: [String: String]) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(values)
            data.append(0x0A)

            // Written beside the target and moved into place: a crash mid-write leaves the old
            // file, never half a JSON object. The permissions go on the temporary file *before*
            // it holds an API key, not after the move.
            let temporary = directory.appendingPathComponent(".settings.json.\(UUID().uuidString)")
            guard FileManager.default.createFile(
                atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]
            ) else {
                throw SettingsStoreError.writeFailed(path: url.path, reason: "could not create a temporary file")
            }
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            // `replaceItemAt` can carry the replaced file's mode over, so state it again.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as SettingsStoreError {
            throw error
        } catch {
            throw SettingsStoreError.writeFailed(path: url.path, reason: "\(error)")
        }
    }
}
