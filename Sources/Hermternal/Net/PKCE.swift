import CryptoKit
import Foundation

/// RFC 7636 PKCE pair for the RFC 8252 native-app login.
///
/// The gateway validates `S256(verifier) == challenge` at
/// `POST /auth/native/token`, so the verifier must never leave this process
/// until that exchange.
struct PKCE: Sendable {
    let verifier: String
    let challenge: String

    init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        verifier = Self.base64URL(Data(bytes))
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// base64url without `=` padding (RFC 7636 §4).
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// High-entropy CSRF `state`, echoed verbatim on the loopback redirect.
    static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }
}
