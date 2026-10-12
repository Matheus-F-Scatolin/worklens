import Foundation

/// Owner-only modes for everything Worklens keeps about a day: 0700 folders, 0600 files.
///
/// The data folder holds screenshots, transcripts and the database, and it may sit somewhere
/// another account can traverse (a checkout under `/Users/Shared`, a `DATA_DIR` the person
/// chose). The process umask is usually `022`, so nothing is private unless it is made so here.
/// Only group and other bits are ever removed; the owner's own bits are left as they are.
public enum FilePermissions {
    public static let privateDirectory: Int = 0o700
    public static let privateFile: Int = 0o600

    /// Creates `url` and any missing parents as 0700, then makes `url` itself owner-only even
    /// when it already existed. Parents that already existed are not touched.
    public static func createPrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: privateDirectory]
        )
        restrict(url)
    }

    /// Writes `data` to `url` through a temporary file that is 0600 from the moment it exists,
    /// then renames it into place, so a reader never sees half a file or a readable one.
    public static func writePrivate(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(privateFile))
        guard descriptor >= 0 else { throw posixError(path: url.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            unlink(temporary.path)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            let error = posixError(path: url.path)
            unlink(temporary.path)
            throw error
        }
    }

    /// Creates an empty 0600 file when nothing is at `url`; otherwise makes the existing one
    /// owner-only. SQLite gives a database's `-wal` and `-shm` the main file's mode, so this on
    /// the main file before opening is what keeps the sidecars private too.
    public static func preparePrivateFile(at url: URL) {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(privateFile))
        if descriptor >= 0 {
            close(descriptor)
        } else {
            restrict(url)
        }
    }

    /// Removes group and other bits from one existing file or folder. A missing path or a
    /// symbolic link is left alone. Returns whether the mode changed.
    @discardableResult
    public static func restrict(_ url: URL) -> Bool {
        restrict(path: url.path)
    }

    /// `restrict` on `root` and everything under it, without following symbolic links. Run
    /// once at startup so files written before this existed, or by an older build, become
    /// private too. Returns how many modes changed.
    @discardableResult
    public static func tightenTree(at root: URL) -> Int {
        var changed = restrict(path: root.path) ? 1 : 0
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return changed }
        for case let relative as String in enumerator
            where restrict(path: root.appendingPathComponent(relative).path) {
            changed += 1
        }
        return changed
    }

    private static func restrict(path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { return false }
        let mode = info.st_mode & 0o7777
        guard mode & 0o077 != 0 else { return false }
        return chmod(path, mode & ~mode_t(0o077)) == 0
    }

    private static func posixError(path: String) -> Error {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        return NSError(
            domain: NSPOSIXErrorDomain, code: Int(code.rawValue),
            userInfo: [NSFilePathErrorKey: path]
        )
    }
}
