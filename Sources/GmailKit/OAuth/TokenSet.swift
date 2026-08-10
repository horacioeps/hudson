import Foundation

/// One account's OAuth tokens. Persisted only via a `TokenStore` — never to
/// disk, config files, or logs (spec §9.1).
public struct TokenSet: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// True when the access token is expired or will be within `leeway`
    /// seconds — refresh slightly early rather than race the deadline.
    public func isExpired(asOf now: Date, leeway: TimeInterval = 60) -> Bool {
        now >= expiresAt.addingTimeInterval(-leeway)
    }
}
