import Foundation

/// The Google grant kept in `DATA_DIR/google-token.json` instead of the login keychain —
/// `GOOGLE_TOKEN_STORE=file`.
///
/// Why this exists: a login-keychain item is authorised per *partition*, and for code signed
/// without an Apple Developer Team ID macOS stamps that partition with the binary's exact hash,
/// so every rebuild asks for the login keychain password again and no ACL Worklens can write
/// changes that (`docs/decisions.md`). This trades the dialog for a file, and the file is exactly
/// as exposed as `.env` — which already holds `GOOGLE_CLIENT_SECRET` and every API key in plain
/// text. Mode `0600`, so other accounts on the Mac cannot read it; any process running as you
/// can.
public struct FileTokenStore: GoogleTokenStore {
    public static let fileName = "google-token.json"

    private let url: URL

    public init(dataDir: URL) {
        self.url = dataDir.appendingPathComponent(Self.fileName)
    }

    /// Where the grant is, for the surfaces that tell the user which store is in use.
    public var path: String { url.path }

    /// The file's presence, which — unlike the Keychain's — costs nothing to ask.
    public func hasGrant() throws -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func load() throws -> GoogleAuth.Tokens? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        // Matches `KeychainTokenStore`: a payload that will not decode is "no grant", not a
        // crash, so a truncated file costs one reconnect rather than a broken launch.
        return try? JSONDecoder.google.decode(GoogleAuth.Tokens.self, from: data)
    }

    /// Written 0600 under a temporary name and `rename`d over the old one: the mode is set before
    /// the secret is in a file anyone could open, and the swap is atomic, so a refresh
    /// interrupted halfway cannot leave a half-written grant behind.
    public func save(_ tokens: GoogleAuth.Tokens) throws {
        let data = try JSONEncoder.google.encode(tokens)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporary = directory.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]
        ) else {
            throw Failure.write(url.path)
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.write(url.path)
        }
    }

    public func clear(email: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case write(String)

        public var description: String {
            switch self {
            case let .write(path): return "Could not write the Google grant to \(path)"
            }
        }
    }
}
