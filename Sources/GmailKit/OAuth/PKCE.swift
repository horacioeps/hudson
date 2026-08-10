import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636), required by Google for installed
/// apps. A fresh `PKCE` value is generated per authorization attempt.
public struct PKCE: Sendable {
    /// High-entropy random string sent with the token exchange.
    public let verifier: String
    /// SHA-256(verifier), base64url-encoded — sent with the authorization URL.
    public let challenge: String

    public init() {
        var bytes = [UInt8](repeating: 0, count: 64)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        self.verifier = Data(bytes).base64URLEncoded()
        self.challenge = Self.challenge(for: verifier)
    }

    /// The S256 code-challenge transform.
    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

/// Random `state` parameter tying the OAuth callback to this attempt (CSRF guard).
public func randomState() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
    return Data(bytes).base64URLEncoded()
}

extension Data {
    /// Base64url without padding (RFC 4648 §5), as OAuth requires.
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
