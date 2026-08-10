import Foundation
import Testing
@testable import GmailKit

private let credentials = OAuthCredentials(clientID: "id", clientSecret: "secret")

@Test func freshTokenIsReturnedWithoutRefreshing() async throws {
    let store = InMemoryTokenStore()
    try store.saveTokens(
        TokenSet(accessToken: "fresh", refreshToken: "rt", expiresAt: .distantFuture),
        account: "a@example.com")
    let transport = MockTransport(responses: [])  // any network call would throw
    let session = AccountSession(
        account: "a@example.com",
        oauth: OAuthClient(credentials: credentials, transport: transport),
        store: store)
    #expect(try await session.validAccessToken() == "fresh")
}

@Test func expiredTokenIsRefreshedAndPersisted() async throws {
    let store = InMemoryTokenStore()
    try store.saveTokens(
        TokenSet(accessToken: "stale", refreshToken: "rt", expiresAt: .distantPast),
        account: "a@example.com")
    let refreshResponse = #"{"access_token": "renewed", "expires_in": 3599, "token_type": "Bearer"}"#
    let transport = MockTransport(responses: [(Data(refreshResponse.utf8), 200)])
    let session = AccountSession(
        account: "a@example.com",
        oauth: OAuthClient(credentials: credentials, transport: transport),
        store: store)
    #expect(try await session.validAccessToken() == "renewed")
    #expect(try store.tokens(account: "a@example.com")?.accessToken == "renewed")
}

@Test func missingTokensSurfaceAsNeedsAuth() async {
    let session = AccountSession(
        account: "nobody@example.com",
        oauth: OAuthClient(credentials: credentials, transport: MockTransport(responses: [])),
        store: InMemoryTokenStore())
    await #expect(throws: GmailError.auth("No stored tokens — run `hudson auth` first.")) {
        _ = try await session.validAccessToken()
    }
}
