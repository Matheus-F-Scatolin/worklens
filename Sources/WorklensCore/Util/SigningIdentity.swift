import Foundation
import Security

/// What the keychain and the running binary say about Worklens's signature.
///
/// Moved out of `AutoUpdater` for #118. Two questions live here:
///
/// - `hasIdentity(named:)` is about the **keychain**: could a build be signed properly? The
///   updater refuses to rebuild without one.
/// - `runningTeamIdentifier` is about **this process**: does its signature carry a team? Settings
///   → Connections picks where the Google token is stored from it.
public enum SigningIdentity {
    /// The self-signed certificate `scripts/make-dev-cert.sh` creates. There is no Apple
    /// Developer account behind Worklens and no notarised build; this is the whole scheme.
    public static let development = "Worklens Dev"

    /// The Apple Developer Team ID in the signature of the binary that is running right now, or
    /// nil when it carries none (#139).
    ///
    /// This is the fact behind the login-keychain dialog: a keychain item is authorised per code
    /// *hash* unless the signature carries a team, so on a self-signed or ad-hoc build every
    /// rebuild is a new application and asks for the login password again. Worklens has no Apple
    /// Developer account, so this is nil for every build of it today — which is exactly why the
    /// connect sheet pre-selects the file store rather than the keychain.
    ///
    /// Asked once: a process cannot re-sign itself while it runs.
    public static let runningTeamIdentifier: String? = probeTeamIdentifier()

    /// `SecCodeCopySelf` + `SecCodeCopySigningInformation` → `kSecCodeInfoTeamIdentifier`. No
    /// entitlement, no `codesign` subprocess, and it answers for whatever is executing — the
    /// bundled app, the CLI, or a test binary.
    static func probeTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info
        ) == errSecSuccess,
            let attributes = info as? [String: Any]
        else { return nil }
        return (attributes[kSecCodeInfoTeamIdentifier as String] as? String)?.nonEmpty
    }

    /// `sign.sh`'s own test, in Swift: only an identity `codesign` will accept counts, which is
    /// what `find-identity -v` lists. An untrusted certificate is not listed and so does not
    /// count — creating one and trusting it are separate steps.
    public static func hasIdentity(named name: String = development) -> Bool {
        guard let output = run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        else { return false }
        return output.contains("\"\(name)\"")
    }

    /// One short-lived tool run, stdout and stderr together, nil unless it exited 0.
    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting: a report larger than the pipe buffer would otherwise deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
