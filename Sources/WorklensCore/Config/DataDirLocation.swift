import Foundation

/// Whether `DATA_DIR` points somewhere a SQLite database may safely live.
///
/// The storage layer assumes a local disk twice over: `Database` opens a WAL `DatabasePool`, and
/// `InstanceLock` takes an `flock` on `DATA_DIR/.lock` precisely to keep two Worklenses apart.
/// Neither holds across a file provider. A folder that iCloud Drive, Dropbox or Google Drive is
/// syncing can hand back a partially materialised `-wal`, and `Database.init` catches *every*
/// error from open, migrate or `PRAGMA quick_check` — so a perfectly healthy database is renamed
/// `worklens.sqlite.corrupt-<ts>` and replaced by an empty one. The `flock` is worse: it is a
/// kernel lock on one machine, so two Macs signed into the same account interleave writes without
/// either of them ever seeing the other's lock.
///
/// The check is deliberately pure. `check(_:home:probe:)` takes the paths it judges, so the tests
/// exercise every provider without a cloud folder — or a network — anywhere near them.
public struct DataDirLocation: Sendable, Equatable {
    /// What gave the folder away. Ordered by how much it is trusted.
    public enum Signal: String, Sendable, Equatable, Codable, CaseIterable {
        /// The path itself is inside a known provider's folder. The primary test.
        case pathPrefix
        /// `URLResourceKey.isUbiquitousItemKey` — an iCloud folder somewhere unexpected.
        case ubiquitous
        /// The folder holds `.icloud` placeholders. Only evicted files have these, so this is a
        /// weak secondary signal and never the primary test.
        case placeholders
        /// `URLResourceKey.volumeIsLocalKey` said no: an SMB or NFS mount. Note that iCloud
        /// Drive, Dropbox and Google Drive all sit on the local boot volume and answer *true*,
        /// which is why this case catches only real network volumes.
        case networkVolume
    }

    /// What to call it when telling the user: "iCloud Drive", "Dropbox", "a network volume".
    public let provider: String
    public let signal: Signal
    /// The resolved path that was flagged, abbreviated with `~` when it is under the home folder.
    public let path: String

    public init(provider: String, signal: Signal, path: String) {
        self.provider = provider
        self.signal = signal
        self.path = path
    }

    // MARK: What the user reads

    /// The menu row. One line, because that is what a menu item is: the folder, that capture is
    /// off, the risk in a clause, and both ways out.
    public var menuMessage: String {
        "DATA_DIR is in \(provider) (\(path)): capture is off. A synced folder can hand Worklens "
            + "a half-written database, and .lock cannot reach a second Mac. Move it to this Mac's "
            + "own disk, or set \(DataDirLocation.overrideKey)=true."
    }

    /// The long form: the CLI's refusal and the `config-dump` warning. Says the same thing with
    /// room to say why.
    public var explanation: String {
        """
        DATA_DIR is in \(provider): \(path)

        Worklens keeps a SQLite database there with a write-ahead log, and a lock on
        \(InstanceLock.fileName) in the same folder to keep two Worklenses off one history.
        A file provider breaks both: it can sync a `-wal` out from under an open database,
        which Worklens reads as corruption and answers by moving the file aside and starting
        an empty one; and the lock is a kernel lock on this Mac, so a second Mac syncing the
        same folder never sees it.

        \(DataDirLocation.fixAdvice)
        """
    }

    /// The fix, in one place so the menu, the CLI and `config-dump` cannot drift apart.
    public static let fixAdvice = """
        Point DATA_DIR at a folder on this Mac's own disk, edit the .env that set it, then run
        `make install-env`, or set \(DataDirLocation.overrideKey)=true if you have read the
        above and accept the risk.
        """

    /// The escape hatch's name, spelled once.
    public static let overrideKey = "ALLOW_NONLOCAL_DATA_DIR"

    /// The exit code a refused CLI run uses: 3, not the 2 a busy run once exited, so a script
    /// that retried a busy run does not retry this one.
    public static let refusedExitCode: Int32 = 3

    // MARK: The check

    /// The filesystem questions the check asks, injected so a test never needs a cloud folder.
    ///
    /// Every closure answers for a *path*, not for the process, and `.none` answers no to all of
    /// them — which leaves the path rules, and those are pure.
    public struct Probe: Sendable {
        public var isUbiquitous: @Sendable (URL) -> Bool
        /// nil when the volume cannot be read at all (a path that does not exist yet).
        public var isOnLocalVolume: @Sendable (URL) -> Bool?
        public var hasICloudPlaceholders: @Sendable (URL) -> Bool

        public init(
            isUbiquitous: @escaping @Sendable (URL) -> Bool,
            isOnLocalVolume: @escaping @Sendable (URL) -> Bool?,
            hasICloudPlaceholders: @escaping @Sendable (URL) -> Bool
        ) {
            self.isUbiquitous = isUbiquitous
            self.isOnLocalVolume = isOnLocalVolume
            self.hasICloudPlaceholders = hasICloudPlaceholders
        }

        /// What the app uses.
        public static let live = Probe(
            isUbiquitous: { url in
                (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
            },
            isOnLocalVolume: { url in
                // Only an answer when the volume could be read; a folder that does not exist yet
                // has no volume and must not be called remote for it.
                (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal
            },
            hasICloudPlaceholders: { url in
                let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                return names.contains { $0.hasSuffix(".icloud") }
            }
        )

        /// Path rules only. Tests use this, and so does anything that must not touch the disk.
        public static let none = Probe(
            isUbiquitous: { _ in false },
            isOnLocalVolume: { _ in nil },
            hasICloudPlaceholders: { _ in false }
        )
    }

    /// Nil when the folder looks like ordinary local storage.
    ///
    /// Symlinks are resolved first: `~/Dropbox` is usually one, and so is `/tmp`.
    public static func check(
        _ dataDir: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        probe: Probe = .live
    ) -> DataDirLocation? {
        let resolved = dataDir.resolvingSymlinksInPath()
        let resolvedHome = home.resolvingSymlinksInPath()
        let display = abbreviate(resolved, home: resolvedHome)

        if let provider = providerFromPath(resolved, home: resolvedHome) {
            return DataDirLocation(provider: provider, signal: .pathPrefix, path: display)
        }
        if probe.isUbiquitous(resolved) {
            return DataDirLocation(provider: "iCloud Drive", signal: .ubiquitous, path: display)
        }
        if probe.isOnLocalVolume(resolved) == false {
            return DataDirLocation(provider: "a network volume", signal: .networkVolume, path: display)
        }
        if probe.hasICloudPlaceholders(resolved) {
            return DataDirLocation(provider: "iCloud Drive", signal: .placeholders, path: display)
        }
        return nil
    }

    // MARK: Path rules

    /// The provider whose folder `url` is inside, by path alone.
    private static func providerFromPath(_ url: URL, home: URL) -> String? {
        // Checked against the whole path as well as against the home-relative one: the two
        // system folders are the same wherever a symlink or a second account puts them.
        let path = url.path
        if path.contains("/Library/Mobile Documents/") || path.hasSuffix("/Library/Mobile Documents") {
            return "iCloud Drive"
        }
        if let name = component(after: "/Library/CloudStorage/", in: path) {
            return cloudStorageProvider(name)
        }

        guard let first = relativeComponents(of: url, under: home).first else { return nil }
        if first == "Dropbox" || first.hasPrefix("Dropbox (") { return "Dropbox" }
        if first.hasPrefix("Google Drive") { return "Google Drive" }
        if first.hasPrefix("OneDrive") { return "OneDrive" }
        return nil
    }

    /// The path components of `url` below `home`, or empty when it is not under it.
    private static func relativeComponents(of url: URL, under home: URL) -> [String] {
        let homeParts = home.pathComponents
        let parts = url.pathComponents
        guard parts.count > homeParts.count, Array(parts.prefix(homeParts.count)) == homeParts
        else { return [] }
        return Array(parts.dropFirst(homeParts.count))
    }

    /// The single path component that follows `marker`, if `marker` is in `path` at all.
    private static func component(after marker: String, in path: String) -> String? {
        guard let range = path.range(of: marker) else { return nil }
        let rest = path[range.upperBound...]
        let name = rest.prefix { $0 != "/" }
        return name.isEmpty ? nil : String(name)
    }

    /// `~/Library/CloudStorage` names a folder per account — `GoogleDrive-you@example.com`,
    /// `OneDrive-Personal`, `Dropbox`. The user reads the product, not the folder.
    private static func cloudStorageProvider(_ folder: String) -> String {
        let known = [
            ("GoogleDrive", "Google Drive"),
            ("OneDrive", "OneDrive"),
            ("Dropbox", "Dropbox"),
            ("Box", "Box"),
            ("iCloud", "iCloud Drive"),
            ("ProtonDrive", "Proton Drive"),
        ]
        for (prefix, name) in known where folder.hasPrefix(prefix) { return name }
        return String(folder.prefix { $0 != "-" })
    }

    /// `~/…` rather than `/Users/you/…`: shorter in a menu row, and the home folder's name is
    /// often a person's name.
    private static func abbreviate(_ url: URL, home: URL) -> String {
        let parts = relativeComponents(of: url, under: home)
        return parts.isEmpty ? url.path : "~/" + parts.joined(separator: "/")
    }
}
