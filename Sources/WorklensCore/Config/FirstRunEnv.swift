import Foundation

/// Creating `~/Library/Application Support/Worklens/.env` the first time there is none (#116).
///
/// Someone who installed the app rather than the checkout has no `.env.example` to copy and no
/// `make install-env` to run, so the app writes the file itself — once, at mode 600, from
/// `EnvTemplate` — and then has somewhere real to open when the menu says "Open .env…". It
/// never touches a file that already exists: whatever is there is the user's.
public enum FirstRunEnv {
    /// Writes `contents` to `url` when nothing is there yet, creating the directory if needed.
    ///
    /// Returns `url` when it wrote the file and nil when one was already there. The file is
    /// 0600 (it is where API keys go) and a directory this creates is 0700; an existing
    /// directory's mode is left alone, since it is not ours to change. An existing file loses
    /// any group or other bits it had.
    @discardableResult
    public static func createIfMissing(
        at url: URL = Config.appSupportEnvURL(),
        contents: String = EnvTemplate.text
    ) throws -> URL? {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else {
            // An existing one may predate this rule; the keys in it are no less secret.
            FilePermissions.restrict(url)
            return nil
        }
        let directory = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        // `createFile` applies the mode as it creates the file, so it is 0600 before anything
        // is in it — the keys the user types here are never briefly world-readable.
        guard fm.createFile(
            atPath: url.path,
            contents: Data(contents.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}
