import Foundation

/// Owns one account's token lifecycle: hands out a valid access token,
/// refreshing through `OAuthClient` and persisting via `TokenStore` when
/// needed. An actor so concurrent callers can't trigger duplicate refreshes.
public actor AccountSession {
    private let account: String
    private let oauth: OAuthClient
    private let store: any TokenStore
    private let now: @Sendable () -> Date

    public init(
        account: String,
        oauth: OAuthClient,
        store: any TokenStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.account = account
        self.oauth = oauth
        self.store = store
        self.now = now
    }

    /// A currently-valid access token, refreshing first if it is (nearly) expired.
    public func validAccessToken() async throws -> String {
        guard let tokens = try store.tokens(account: account) else {
            throw GmailError.auth("No stored tokens — run `hudson auth` first.")
        }
        guard tokens.isExpired(asOf: now()) else {
            return tokens.accessToken
        }
        return try await refreshAndPersist(tokens)
    }

    /// Unconditionally refreshes — used once when Gmail rejects a token that
    /// looked valid locally (revocation, clock skew).
    public func forceRefresh() async throws -> String {
        guard let tokens = try store.tokens(account: account) else {
            throw GmailError.auth("No stored tokens — run `hudson auth` first.")
        }
        return try await refreshAndPersist(tokens)
    }

    private func refreshAndPersist(_ tokens: TokenSet) async throws -> String {
        let refreshed = try await oauth.refresh(tokens)
        try store.saveTokens(refreshed, account: account)
        Log.auth.info("Refreshed access token.")
        return refreshed.accessToken
    }
}
