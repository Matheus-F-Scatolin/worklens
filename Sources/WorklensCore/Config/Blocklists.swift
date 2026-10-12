import Foundation

/// One of the three "never look at this" lists (#16), editable in place since #128.
///
/// The list itself still resolves through `Config` — `BLOCKED_BUNDLE_IDS`,
/// `BLOCKED_TITLE_PATTERNS`, `BLOCKED_URL_HOSTS` — and `PrivacyPolicy` still reads it from there.
/// What this type adds is the vocabulary the Settings window and the menu
/// share: which key a list is, what a typed entry has to look like, and how the app-owned
/// overlay below folds into what `.env` and the built-in defaults supplied.
public enum Blocklist: String, Sendable, CaseIterable, Codable {
    /// `BLOCKED_BUNDLE_IDS` — exact bundle identifiers.
    case apps
    /// `BLOCKED_TITLE_PATTERNS` — case-insensitive regexes over the window title *and* the URL.
    case titles
    /// `BLOCKED_URL_HOSTS` — hosts, matched at a dot boundary.
    case sites

    public var configKey: String {
        switch self {
        case .apps: return "BLOCKED_BUNDLE_IDS"
        case .titles: return "BLOCKED_TITLE_PATTERNS"
        case .sites: return "BLOCKED_URL_HOSTS"
        }
    }

    /// The heading in Settings → Privacy.
    public var title: String {
        switch self {
        case .apps: return "Blocked apps"
        case .titles: return "Blocked window titles"
        case .sites: return "Blocked sites"
        }
    }

    /// What one entry is, in a word or two, for an error message or a CLI line.
    public var noun: String {
        switch self {
        case .apps: return "app"
        case .titles: return "window title pattern"
        case .sites: return "site"
        }
    }

    /// The placeholder in the "add" field.
    public var placeholder: String {
        switch self {
        case .apps: return "com.apple.Safari"
        case .titles: return "Private Browsing"
        case .sites: return "nubank.com.br"
        }
    }

    /// The list as this configuration resolved it — the overlay already folded in, because
    /// `Config.loadWithProvenance` applies it before anything sees the `Config`.
    public func entries(in config: Config) -> [String] {
        switch self {
        case .apps: return config.blockedBundleIDs
        case .titles: return config.blockedTitlePatterns
        case .sites: return config.blockedURLHosts
        }
    }

    func write(_ entries: [String], into config: inout Config) {
        switch self {
        case .apps: config.blockedBundleIDs = entries
        case .titles: config.blockedTitlePatterns = entries
        case .sites: config.blockedURLHosts = entries
        }
    }

    /// What a typed entry has to look like, checked where it is typed rather than at the next
    /// capture. Returns the value as it will be stored: trimmed, and for a site the bare host,
    /// so pasting `https://app.nubank.com.br/login` out of the address bar works.
    ///
    /// A window-title entry is a **regex**, not a literal (`PrivacyPolicy`, PRIVACY.md), so it
    /// is validated by compiling it — the same check the redactor runs over
    /// `REDACT_EXTRA_PATTERNS`, except that here a pattern that does not compile is refused
    /// where you typed it rather than dropped with a warning at the next load.
    public func normalize(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BlocklistError.empty(self) }
        switch self {
        case .apps:
            guard !trimmed.contains(where: \.isWhitespace), !trimmed.contains("/"), trimmed.contains(".") else {
                throw BlocklistError.notABundleID(trimmed)
            }
            return trimmed
        case .titles:
            guard (try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])) != nil else {
                throw BlocklistError.notARegex(trimmed)
            }
            return trimmed
        case .sites:
            guard let host = PrivacyPolicy.normalizeHost(trimmed) else {
                throw BlocklistError.notAHost(trimmed)
            }
            return host
        }
    }

    /// The spelling two entries are compared by. Never displayed and never stored — it exists so
    /// that removing `Nubank.com.br/` from a `.env` that wrote it that way actually removes it,
    /// and so that adding the same entry twice adds it once.
    public func canonical(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .apps, .titles: return trimmed
        case .sites: return PrivacyPolicy.normalizeHost(trimmed) ?? trimmed.lowercased()
        }
    }
}

/// Why an entry was refused. Every case names what to type instead.
public enum BlocklistError: Error, CustomStringConvertible, Equatable {
    case empty(Blocklist)
    case notABundleID(String)
    case notAHost(String)
    case notARegex(String)

    public var description: String {
        switch self {
        case let .empty(list):
            return "type a \(list.noun) first"
        case let .notABundleID(raw):
            return "\"\(raw)\" is not a bundle identifier: they look like com.apple.Safari. "
                + "Use + to pick the app and Worklens reads its identifier for you."
        case let .notAHost(raw):
            return "\"\(raw)\" has no host in it: write it like nubank.com.br, no scheme and no path."
        case let .notARegex(raw):
            return "\"\(raw)\" is not a regular expression Worklens can compile: a stray ( or [ is usually it."
        }
    }
}

// MARK: - The overlay

/// What *you* changed about the three lists, as against what `.env` and the built-in defaults
/// say (#128).
///
/// Two sets per list rather than one replacement value, for one reason: a pure "additions" layer
/// could never un-block `com.1password.1password`, which is a Swift constant
/// (`Config.defaultBlockedBundleIDs`), and the Settings window puts a "−" on every row. The
/// effective list is `(defaults ∪ .env ∪ added) − removed`.
public struct BlocklistOverlay: Codable, Sendable, Equatable {
    /// Keyed by `Blocklist.rawValue`, so the file stays readable by eye and a list added later
    /// cannot invalidate one written today.
    public var added: [String: [String]]
    public var removed: [String: [String]]

    public init(added: [String: [String]] = [:], removed: [String: [String]] = [:]) {
        self.added = added
        self.removed = removed
    }

    public func additions(to list: Blocklist) -> [String] { added[list.rawValue] ?? [] }
    public func removals(from list: Blocklist) -> [String] { removed[list.rawValue] ?? [] }

    public var isEmpty: Bool {
        added.values.allSatisfy(\.isEmpty) && removed.values.allSatisfy(\.isEmpty)
    }

    /// `(base ∪ added) − removed`, base order first, then the order you added them. Comparison
    /// is by `Blocklist.canonical`, so a host `.env` spelled with a scheme still goes away when
    /// you remove it.
    public func effective(_ list: Blocklist, base: [String]) -> [String] {
        let gone = Set(removals(from: list).map(list.canonical))
        var seen = Set<String>()
        var result: [String] = []
        for entry in base + additions(to: list) {
            let key = list.canonical(entry)
            guard !gone.contains(key), !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(entry)
        }
        return result
    }

    /// The one place the overlay meets a loaded `Config`. `Config.loadWithProvenance` calls it,
    /// and both processes load through that, so the app, the CLI and `PrivacyPolicy` all see the
    /// same three lists without any of them knowing this type exists.
    public func apply(to config: inout Config) {
        for list in Blocklist.allCases {
            list.write(effective(list, base: list.entries(in: config)), into: &config)
        }
    }

    /// Blocks `value`: it stops being something you removed and starts being something you
    /// added. Adding what `.env` or the defaults already say is recorded anyway and changes
    /// nothing — `effective` deduplicates.
    public mutating func block(_ value: String, in list: Blocklist) {
        let key = list.canonical(value)
        removed[list.rawValue] = removals(from: list).filter { list.canonical($0) != key }
        var entries = additions(to: list)
        if !entries.contains(where: { list.canonical($0) == key }) { entries.append(value) }
        added[list.rawValue] = entries
    }

    /// Unblocks `value`, whichever layer put it there: it leaves your additions, and it joins
    /// your removals when something underneath still supplies it — the only way a built-in like
    /// `com.1password.1password` can go.
    ///
    /// `base` is that "underneath": the list as `.env` and the defaults left it
    /// (`ConfigProvenance.base(of:)`). Taking back something only you had added leaves no
    /// tombstone, so the Settings window does not keep showing it as a row you removed.
    public mutating func unblock(_ value: String, in list: Blocklist, base: [String]) {
        let key = list.canonical(value)
        added[list.rawValue] = additions(to: list).filter { list.canonical($0) != key }
        guard base.contains(where: { list.canonical($0) == key }) else { return }
        var entries = removals(from: list)
        if !entries.contains(where: { list.canonical($0) == key }) { entries.append(value) }
        removed[list.rawValue] = entries
    }

    /// Forgets a removal, so whatever `.env` or the defaults said about it counts again.
    public mutating func restore(_ value: String, in list: Blocklist) {
        let key = list.canonical(value)
        removed[list.rawValue] = removals(from: list).filter { list.canonical($0) != key }
    }
}

// MARK: - The file

/// The app-owned half of the blocklists:
/// `~/Library/Application Support/Worklens/blocklists.json`, mode 0600, beside `settings.json`.
///
/// A file of its own rather than three keys in `settings.json`, because that file is a *layer* —
/// one value per key, winning outright — and a blocklist has to add to and subtract from the
/// layer underneath it instead of replacing it. `.env` is never written by any of this: #108's
/// objection to editing it (merge conflicts with the editor you use on it) stands, and this is
/// the answer #90 already gave for the projects list — what the app writes, the app owns.
public struct BlocklistStore: Sendable {
    public let url: URL

    public init(url: URL = BlocklistStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL { url(besideSettings: SettingsStore.defaultURL) }

    /// Always beside the settings file, which is what keeps a test (or a worktree) that points
    /// `settingsFile` at a scratch directory from reading the real one.
    public static func url(besideSettings settings: URL) -> URL {
        settings.deletingLastPathComponent().appendingPathComponent("blocklists.json")
    }

    /// An absent file is an empty overlay; an unparseable one warns and reads as empty, because
    /// a broken file here must not stop Worklens starting — and must not quietly un-block
    /// anything either, which is why the defaults still apply underneath it.
    public func load() -> BlocklistOverlay {
        guard let data = try? Data(contentsOf: url) else { return BlocklistOverlay() }
        guard let decoded = try? JSONDecoder().decode(BlocklistOverlay.self, from: data) else {
            Log.config.warn("\(url.path) is not a blocklist overlay Worklens can read: ignoring it")
            return BlocklistOverlay()
        }
        return decoded
    }

    /// Validates, then writes. Returns the stored spelling, which is what the caller should
    /// print or show — a pasted URL comes back as a bare host.
    @discardableResult
    public func block(_ raw: String, in list: Blocklist) throws -> String {
        let value = try list.normalize(raw)
        try update { $0.block(value, in: list) }
        return value
    }

    /// `base` is what `.env` and the defaults say — `ConfigProvenance.base(of:)`. Passing it
    /// keeps a row you only ever added yourself from leaving a tombstone behind.
    ///
    /// Compared by `canonical`, never by `normalize`: validation belongs on the way *in*. An
    /// entry that does not validate can still be sitting in the list — `Config` keeps a
    /// `BLOCKED_TITLE_PATTERNS` entry that does not compile, and `CaptureScheduler` warns about
    /// it — so Settings → Privacy draws a row with a "−" on it, and that "−" has to work.
    @discardableResult
    public func unblock(_ raw: String, in list: Blocklist, base: [String]) throws -> String {
        let value = list.canonical(raw)
        try update { $0.unblock(value, in: list, base: base) }
        return value
    }

    /// Also by `canonical`, for the same reason: undoing the removal of an unparseable pattern
    /// has to be as possible as the removal was.
    @discardableResult
    public func restore(_ raw: String, in list: Blocklist) throws -> String {
        let value = list.canonical(raw)
        try update { $0.restore(value, in: list) }
        return value
    }

    public func update(_ change: (inout BlocklistOverlay) -> Void) throws {
        var overlay = load()
        change(&overlay)
        try write(overlay)
    }

    /// Atomic, 0600, sorted keys — the discipline `SettingsStore` writes with, for the same
    /// reason: a crash mid-write leaves the old file, never half a JSON object.
    private func write(_ overlay: BlocklistOverlay) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(overlay)
            data.append(0x0A)

            let temporary = directory.appendingPathComponent(".blocklists.json.\(UUID().uuidString)")
            // A failed replace must not leave a stray dot-file in Application Support.
            defer { try? FileManager.default.removeItem(at: temporary) }
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
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as SettingsStoreError {
            throw error
        } catch {
            throw SettingsStoreError.writeFailed(path: url.path, reason: "\(error)")
        }
    }
}

// MARK: - What to show next to a row

/// Which layer put an entry in a list — the per-row marker that replaces a hand-written footnote
/// about what `.env` contributed. Read off the `ConfigProvenance` the load already recorded.
public enum BlocklistSource: Sendable, Equatable {
    /// One of `Config.defaultBlocked*`.
    case builtIn
    /// A layer below the overlay supplied the whole key.
    case file(ConfigLayer)
    /// You added it — here or in the menu.
    case app

    public var label: String {
        switch self {
        case .builtIn: return "built in"
        case .app: return "yours"
        case let .file(layer):
            switch layer {
            case .process: return "the environment"
            case .explicitFile: return "WORKLENS_ENV_FILE"
            case .appSettings: return "settings"
            case .appSupport, .cwd: return ".env"
            case .fallback: return "built in"
            }
        }
    }

    /// Whether you are the one who added it. A row that is not yours is removed by writing a
    /// tombstone rather than by deleting anything, which is worth saying in its tooltip.
    public var isYours: Bool { self == .app }
}

/// One row of one list, as Settings shows it.
public struct BlocklistRow: Sendable, Equatable, Identifiable {
    public let value: String
    public let source: BlocklistSource
    public var id: String { value }

    public init(value: String, source: BlocklistSource) {
        self.value = value
        self.source = source
    }
}

public extension Blocklist {
    /// The effective list with each entry's source. `config` is already overlaid (every load
    /// applies the overlay), so this is the list as capture will use it.
    func rows(config: Config, overlay: BlocklistOverlay, provenance: ConfigProvenance) -> [BlocklistRow] {
        // What the layers supplied wins the label: an entry your `.env` also has is *its* row,
        // however many times you added it, because removing it has to leave a tombstone.
        let base = Set(provenance.base(of: self).map(canonical))
        let mine = Set(overlay.additions(to: self).map(canonical)).subtracting(base)
        let layer = provenance.source(of: configKey)
        return entries(in: config).map { entry in
            if mine.contains(canonical(entry)) { return BlocklistRow(value: entry, source: .app) }
            return BlocklistRow(value: entry, source: layer == .fallback ? .builtIn : .file(layer))
        }
    }
}
