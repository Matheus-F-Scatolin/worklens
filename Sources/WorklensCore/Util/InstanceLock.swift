import Foundation

/// An exclusive `flock` on `DATA_DIR/.lock`, held for as long as the value lives.
///
/// This is how two Worklenses are kept off one data directory when the window server cannot
/// help: `swift run Worklens app` has no bundle identifier, so `NSRunningApplication` has
/// nothing to look up. `flock` is the right primitive rather than a PID file because the kernel
/// releases it however the process ends — a crash, a `kill -9`, a debugger — so there is no
/// stale lock to reason about or clean up.
///
/// Releasing is `deinit`, which means the caller has to *keep* the value. A `_ = acquire(…)`
/// would take the lock and drop it on the same line.
public final class InstanceLock {
    public static let fileName = ".lock"

    private let descriptor: Int32
    public let url: URL
    /// False when the lock file could not be opened at all — an unwritable data directory,
    /// which the next database call will report far better than a lock failure would.
    public let isHeld: Bool

    private init(descriptor: Int32, url: URL, isHeld: Bool) {
        self.descriptor = descriptor
        self.url = url
        self.isHeld = isHeld
    }

    deinit {
        // `flock` is released by the close; being explicit costs nothing and says so.
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    /// Takes the lock, or returns nil when another process holds it.
    public static func acquire(dataDir: URL) -> InstanceLock? {
        try? FilePermissions.createPrivateDirectory(at: dataDir)
        let url = dataDir.appendingPathComponent(InstanceLock.fileName)
        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            Log.storage.warn("could not open \(InstanceLock.fileName) in the data directory")
            return InstanceLock(descriptor: -1, url: url, isHeld: false)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return InstanceLock(descriptor: descriptor, url: url, isHeld: true)
    }
}
