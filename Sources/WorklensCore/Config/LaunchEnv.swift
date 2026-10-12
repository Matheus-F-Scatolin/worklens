import Foundation

/// The launch-environment handshake: which configuration file the running app actually read
/// (#129).
///
/// `scripts/launch.sh` has to relaunch Worklens into the configuration it is already running,
/// and it cannot work that out by itself — `WORKLENS_ENV_FILE` belongs to whoever opened the
/// app, and a Finder or login-item launch passes no environment at all. So the app writes the
/// answer down at startup and the script reads it back.
///
/// The file lives at a **fixed** path, `~/Library/Application Support/Worklens/.launch-env`, and
/// deliberately not inside `DATA_DIR`: `DATA_DIR` is the value in dispute, so a script that had
/// to find the handshake underneath it would already need the answer it came for.
///
/// Only a real override is recorded. With no `WORKLENS_ENV_FILE` the app read the layers every
/// other launch reads, and naming a file here would *change* the configuration rather than
/// reproduce it — `WORKLENS_ENV_FILE` outranks `settings.json`, so pointing it at the App
/// Support `.env` would quietly promote that file above the one Settings writes.
///
/// It holds a path, never a value: nothing here can leak an API key.
public enum LaunchEnv {
    /// `~/Library/Application Support/Worklens/.launch-env`.
    public static var defaultURL: URL {
        Config.appSupportDir().appendingPathComponent(".launch-env")
    }

    static let header = """
        # Written by Worklens each time it launches: the configuration file this app was told
        # to read, through WORKLENS_ENV_FILE. scripts/launch.sh relaunches with exactly this
        # file, so an update does not silently move the app onto another configuration (#129).
        # Deleting it is safe: the next launch writes it again, and a launch without it reads
        # ~/Library/Application Support/Worklens/.env like any other install.
        """

    /// The file's text for a given override.
    public static func contents(envFile: URL) -> String {
        "\(header)\n\(envFile.path)\n"
    }

    /// The path the file names: its first line that is neither blank nor a comment.
    public static func parse(_ text: String) -> String? {
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            return line
        }
        return nil
    }

    /// Records `envFile`, or removes a stale record when there is no override to record.
    ///
    /// Returns the file it wrote, or nil when it removed one (or had nothing to do). Failing to
    /// write is not fatal anywhere: the handshake only saves the script from the fallback it has
    /// always had.
    @discardableResult
    public static func write(
        envFile: URL?,
        to url: URL = LaunchEnv.defaultURL,
        fileManager: FileManager = .default
    ) throws -> URL? {
        guard let envFile else {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            return nil
        }
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try contents(envFile: envFile).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The override a relaunch should pass on, or nil when there is none to pass.
    ///
    /// Nil for a missing handshake *and* for a stale one — the app that wrote it may have been
    /// run from a worktree that has since been deleted, and relaunching into a file that is no
    /// longer there would start Worklens on defaults instead of on the installed configuration.
    public static func resolved(
        at url: URL = LaunchEnv.defaultURL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
            let path = parse(text),
            fileManager.fileExists(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}
