import Foundation

/// Owns one account's token lifecycle: hands out a valid access token,
/// refreshing through `OAuthClient` and persisting via `TokenStore` when
/// needed. Actor isolation alone does not stop concurrent callers from
/// racing separate `OAuthClient.refresh` calls — `await oauth.refresh`
/// suspends, so another call can observe the same expired token before the
/// first refresh lands. Instead, an in-flight refresh is tracked in
/// `refreshTask`; concurrent callers that arrive while one is running all
/// await that same task rather than starting their own.
public actor AccountSession {
    private let account: String
    private let oauth: OAuthClient
    private let store: any TokenStore
    private let now: @Sendable () -> Date
    /// The currently in-flight refresh, if any — shared by concurrent callers.
    private var refreshTask: Task<String, Error>?

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
    /// looked valid locally (revocation, clock skew). Joins an already
    /// in-flight refresh instead of starting a second one.
    public func forceRefresh() async throws -> String {
        guard let tokens = try store.tokens(account: account) else {
            throw GmailError.auth("No stored tokens — run `hudson auth` first.")
        }
        return try await refreshAndPersist(tokens)
    }

    /// Coalesces concurrent refreshes: the check for `refreshTask` and the
    /// assignment that follows happen with no `await` between them, so no
    /// other actor-isolated call can slip in and start a duplicate refresh.
    private func refreshAndPersist(_ tokens: TokenSet) async throws -> String {
        if let inFlight = refreshTask {
            return try await inFlight.value
        }
        let task = Task<String, Error> {
            let refreshed = try await self.oauth.refresh(tokens)
            try self.store.saveTokens(refreshed, account: self.account)
            Log.auth.info("Refreshed access token.")
            return refreshed.accessToken
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
}
