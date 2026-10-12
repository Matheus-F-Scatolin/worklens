import Foundation

public enum TaxonomyError: Error, CustomStringConvertible {
    case invalidFile(URL, String)
    case invalidTaxonomy([String])

    public var description: String {
        switch self {
        case let .invalidFile(url, detail):
            return "\(url.path) is not a valid taxonomy: \(detail)"
        case let .invalidTaxonomy(problems):
            return "taxonomy is invalid:\n  - " + problems.joined(separator: "\n  - ")
        }
    }
}

/// Owns `DATA_DIR/taxonomy.json`: seeds it on first run, re-reads it when the user edits it,
/// and answers the two questions the describe path asks — "what app is this frame?" and "what
/// task keys may the model choose from?".
///
/// Strictness differs by moment on purpose. `init` throws on a malformed file, so a broken edit
/// surfaces at startup; a later reload that fails keeps the last good
/// taxonomy and warns, so a half-saved file cannot take the describe worker down mid-day.
public final class TaxonomyStore: @unchecked Sendable {
    public static let fileName = "taxonomy.json"
    /// At most one `stat` per this many seconds, however often `current` is read.
    public static let reloadCheckInterval: TimeInterval = 30

    public let fileURL: URL

    private let lock = NSLock()
    private var cached: Taxonomy
    private var cachedModified: Date?
    private var lastCheckedAt: Date

    /// `now` is injectable so tests do not have to wait out `reloadCheckInterval`.
    private let now: @Sendable () -> Date

    public init(dataDir: URL, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.fileURL = dataDir.appendingPathComponent(TaxonomyStore.fileName)
        self.now = now

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try FilePermissions.createPrivateDirectory(at: dataDir)
            // Written verbatim rather than re-encoded, so the file matches the embedded seed byte
            // for byte and a diff against a later version shows only the user's own edits.
            try Data(TaxonomySeed.json.utf8).write(to: fileURL, options: .atomic)
            Log.describe.info("seeded taxonomy.json")
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw TaxonomyError.invalidFile(fileURL, error.localizedDescription)
        }
        do {
            cached = try Taxonomy.decode(data)
        } catch {
            throw TaxonomyError.invalidFile(fileURL, "\(error)")
        }
        cachedModified = TaxonomyStore.modificationDate(of: fileURL)
        lastCheckedAt = now()
    }

    // MARK: Access

    /// The current taxonomy, re-read from disk when the file changed (checked at most once every
    /// 30 s so a per-frame call does not turn into a per-frame `stat`).
    public var current: Taxonomy {
        lock.lock()
        defer { lock.unlock() }
        reloadIfStaleLocked()
        return cached
    }

    private func reloadIfStaleLocked() {
        let moment = now()
        guard moment.timeIntervalSince(lastCheckedAt) >= TaxonomyStore.reloadCheckInterval else { return }
        lastCheckedAt = moment

        let modified = TaxonomyStore.modificationDate(of: fileURL)
        guard modified != cachedModified else { return }

        guard let data = try? Data(contentsOf: fileURL) else {
            Log.describe.warn("taxonomy.json disappeared or is unreadable; keeping the last good copy")
            return
        }
        do {
            cached = try Taxonomy.decode(data)
            cachedModified = modified
            Log.describe.info("reloaded taxonomy.json (version \(cached.version))")
        } catch {
            Log.describe.warn("taxonomy.json is malformed; keeping the last good copy")
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    // MARK: Resolution

    /// The app (or web app) a frame belongs to. A web-app match wins over the generic browser
    /// entry, and the most specific `url_patterns` entry wins among web apps.
    public func resolve(bundleID: String?, url: String?) -> ResolvedApp? {
        let taxonomy = current
        let app = bundleID.flatMap { taxonomy.app(bundleID: $0) }

        // Web apps are only consulted for a browser (an app that declares them) or when the
        // bundle id told us nothing — a URL alongside Slack should not turn the frame into Gmail.
        let browserish = app == nil || !(app?.webApps?.isEmpty ?? true)
        if browserish, let url, let (host, path) = splitURL(url) {
            var best: (WebAppEntry, Int)?
            for web in taxonomy.allWebApps {
                for pattern in web.urlPatterns.map(URLPattern.init) where pattern.matches(host: host, path: path) {
                    if best == nil || pattern.specificity > best!.1 {
                        best = (web, pattern.specificity)
                    }
                }
            }
            if let (web, _) = best {
                return ResolvedApp(
                    appKey: web.key, name: web.name, category: web.category,
                    tasks: web.tasks, isWebApp: true
                )
            }
        }

        guard let app else { return nil }
        return ResolvedApp(
            appKey: app.key, name: app.name, category: app.category,
            tasks: app.tasks, isWebApp: false
        )
    }

    /// Is `taskKey` allowed for `appKey`? Universal tasks are allowed everywhere, and a task's
    /// aliases count as the task — that is what a merge accepted in Settings → Taxonomy means.
    /// The canonical project a free-text `project_hint` names, or nil when the list does not
    /// claim it yet (#90). Matching is by name or alias, case- and diacritic-insensitively.
    public func resolveProject(hint: String?) -> ProjectEntry? {
        guard let hint, !hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return current.project(matching: hint)
    }

    /// The canonical list as the pure aggregators want it, re-read from disk on the usual 30 s
    /// window like everything else `current` serves.
    public var projects: [ProjectEntry] { current.projectList }

    public func isKnownTask(appKey: String, taskKey: String) -> Bool {
        let taxonomy = current
        if taxonomy.universalTasks.contains(where: { $0.matches(taskKey) }) { return true }
        return taxonomy.tasks(forAppKey: appKey)?.contains { $0.matches(taskKey) } ?? false
    }

    /// The key a name resolves to: itself when it is a key, the target when it is an alias, nil
    /// when the taxonomy has never heard of it.
    public func canonicalTask(appKey: String, taskKey: String) -> String? {
        let taxonomy = current
        if let universal = taxonomy.universalTasks.first(where: { $0.matches(taskKey) }) { return universal.key }
        return taxonomy.tasks(forAppKey: appKey)?.first { $0.matches(taskKey) }?.key
    }

    /// The `byCategory` resolver for `StatsAggregator.daily`, reading the live taxonomy so an
    /// edit to `taxonomy.json` shows up in the next stats read without a restart. Every place
    /// that builds a `StatsService` should pass this; without it every app lands in
    /// "uncategorized".
    public var categoryResolver: StatsAggregator.CategoryResolver {
        { [self] appKey in self.current.category(forAppKey: appKey) }
    }

    /// The block of the describe prompt that lists the legal task keys. Compact on purpose —
    /// it is sent with every frame.
    public func promptFragment(for app: ResolvedApp?) -> String {
        let taxonomy = current
        var lines: [String] = []

        if let app {
            lines.append("App: \(app.name) (key: \(app.appKey), category: \(app.category))")
            lines.append("Task keys for this app:")
            lines += app.tasks.map(Self.taskLine)
        } else {
            lines.append("App: not recognized. Pick the closest of these app keys, else \"other\":")
            lines.append(taxonomy.allAppKeys.joined(separator: ", "))
        }

        lines.append("Universal task keys (always allowed):")
        lines += taxonomy.universalTasks.map(Self.taskLine)
        return lines.joined(separator: "\n")
    }

    private static func taskLine(_ task: TaskEntry) -> String {
        task.description.isEmpty ? "- \(task.key)" : "- \(task.key): \(task.description)"
    }

    // MARK: Writing

    /// Replaces the file, bumping `version` so anything caching by version notices. Atomic:
    /// a crash mid-write leaves the previous file intact.
    public func save(_ taxonomy: Taxonomy) throws {
        let problems = taxonomy.validationProblems()
        guard problems.isEmpty else { throw TaxonomyError.invalidTaxonomy(problems) }

        var next = taxonomy
        next.version = max(taxonomy.version, current.version) + 1

        let data = try Taxonomy.encoder().encode(next)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)

        lock.lock()
        cached = next
        cachedModified = TaxonomyStore.modificationDate(of: fileURL)
        lastCheckedAt = now()
        lock.unlock()
    }
}
