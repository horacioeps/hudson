import Foundation
import Testing
@testable import GmailKit

private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")!
    return try Data(contentsOf: url)
}

private let credentials = OAuthCredentials(clientID: "test-client-id", clientSecret: "test-client-secret")

@Test func authorizationURLCarriesAllRequiredParameters() {
    let client = OAuthClient(credentials: credentials, transport: MockTransport(responses: []))
    let pkce = PKCE()
    let url = client.authorizationURL(
        redirectURI: "http://127.0.0.1:49152/callback", state: "st4te", pkce: pkce)
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
    func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
    #expect(url.host() == "accounts.google.com")
    #expect(value("client_id") == "test-client-id")
    #expect(value("redirect_uri") == "http://127.0.0.1:49152/callback")
    #expect(value("response_type") == "code")
    #expect(value("scope") == GmailKit.oauthScope)
    #expect(value("state") == "st4te")
    #expect(value("code_challenge") == pkce.challenge)
    #expect(value("code_challenge_method") == "S256")
    #expect(value("access_type") == "offline")
}

@Test func exchangeCodePostsFormAndParsesTokens() async throws {
    let transport = MockTransport(responses: [(try fixture("token_success"), 200)])
    let start = Date(timeIntervalSince1970: 1_000)
    let client = OAuthClient(credentials: credentials, transport: transport, now: { start })
    let tokens = try await client.exchangeCode(
        "auth-code", verifier: "verifier123", redirectURI: "http://127.0.0.1:49152/callback")
    #expect(tokens.accessToken == "test-access-token")
    #expect(tokens.refreshToken == "test-refresh-token")
    #expect(tokens.expiresAt == start.addingTimeInterval(3599))

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.host() == "oauth2.googleapis.com")
    #expect(request.httpMethod == "POST")
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    #expect(body.contains("grant_type=authorization_code"))
    #expect(body.contains("code_verifier=verifier123"))
    #expect(body.contains("client_secret=test-client-secret"))
}

@Test func refreshKeepsOldRefreshTokenWhenGoogleOmitsIt() async throws {
    // Google frequently omits refresh_token on refresh responses.
    let response = #"{"access_token": "new-at", "expires_in": 3599, "token_type": "Bearer"}"#
    let transport = MockTransport(responses: [(Data(response.utf8), 200)])
    let client = OAuthClient(credentials: credentials, transport: transport)
    let old = TokenSet(accessToken: "old-at", refreshToken: "keep-me", expiresAt: .distantPast)
    let refreshed = try await client.refresh(old)
    #expect(refreshed.accessToken == "new-at")
    #expect(refreshed.refreshToken == "keep-me")
}

@Test func invalidGrantSurfacesAsAuthError() async throws {
    let transport = MockTransport(responses: [(try fixture("token_invalid_grant"), 400)])
    let client = OAuthClient(credentials: credentials, transport: transport)
    let old = TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: .distantPast)
    await #expect(throws: GmailError.auth("invalid_grant: Token has been expired or revoked.")) {
        _ = try await client.refresh(old)
    }
}
