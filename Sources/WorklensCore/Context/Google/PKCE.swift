import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636), S256.
///
/// A desktop app cannot keep a client secret secret, so the authorization code is bound to a
/// one-time verifier that never leaves this process instead.
public struct PKCE: Sendable, Equatable {
    /// 43–128 unreserved characters. 32 random bytes base64url-encoded gives 43.
    public let verifier: String
    /// `base64url(SHA256(verifier))`, sent with the authorization request.
    public let challenge: String

    public init(verifier: String = PKCE.randomVerifier()) {
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
    }

    public static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        // `SecRandomCopyBytes` is the only source worth using here; a failure is not recoverable
        // and must not silently degrade to something guessable.
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return base64URL(Data(bytes))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// base64 with `+/` swapped for `-_` and the padding dropped, per RFC 7636 §A.
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// An opaque value echoed back by the authorization server, so a callback from anywhere else
    /// is rejected.
    public static func randomState() -> String { randomVerifier() }
}
