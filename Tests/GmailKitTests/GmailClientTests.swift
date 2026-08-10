import Foundation
import Testing
@testable import GmailKit

private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")!
    return try Data(contentsOf: url)
}

private func makeClient(
    transport: MockTransport,
    oauthTransport: MockTransport = MockTransport(responses: []),
    sleeps: LockedBox<[Double]>? = nil
) throws -> GmailClient {
    let store = InMemoryTokenStore()
    try store.saveTokens(
        TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture),
        account: "a@example.com")
    let session = AccountSession(
        account: "a@example.com",
        oauth: OAuthClient(
            credentials: OAuthCredentials(clientID: "id", clientSecret: "secret"),
            transport: oauthTransport),
        store: store)
    return GmailClient(
        session: session, transport: transport, quota: QuotaBucket(),
        sleep: { seconds in sleeps?.append(seconds) })
}

/// Tiny thread-safe accumulator for observing retry sleeps.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}

extension LockedBox where Value == [Double] {
    func append(_ element: Double) { withLock { $0.append(element) } }
    var values: [Double] { withLock { $0 } }
}

@Test func getProfileDecodesAndAuthorizes() async throws {
    let transport = MockTransport(responses: [(try fixture("profile"), 200)])
    let client = try makeClient(transport: transport)
    let profile = try await client.getProfile()
    #expect(profile == Profile(
        emailAddress: "test-user@example.com", messagesTotal: 42107,
        threadsTotal: 18344, historyId: "9876543"))
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/profile")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer at")
}

@Test func rateLimitedRequestRetriesAfterWaiting() async throws {
    let rateLimitBody = #"{"error": {"errors": [{"reason": "rateLimitExceeded"}]}}"#
    let transport = MockTransport(responses: [
        (Data(rateLimitBody.utf8), 429),
        (try fixture("profile"), 200),
    ])
    let sleeps = LockedBox<[Double]>([])
    let client = try makeClient(transport: transport, sleeps: sleeps)
    _ = try await client.getProfile()
    // One backoff sleep between the two attempts, at the 2^1 rung of the ladder.
    #expect(sleeps.values == [2.0])
}

@Test func serverErrorsRetryThenSucceed() async throws {
    let transport = MockTransport(responses: [
        (Data(), 503),
        (try fixture("profile"), 200),
    ])
    let sleeps = LockedBox<[Double]>([])
    let client = try makeClient(transport: transport, sleeps: sleeps)
    let profile = try await client.getProfile()
    #expect(profile.emailAddress == "test-user@example.com")
    #expect(sleeps.values == [2.0])
}

@Test func invalidRequestNeverRetries() async throws {
    let transport = MockTransport(responses: [(Data(), 404)])
    let client = try makeClient(transport: transport)
    await #expect(throws: GmailError.self) { _ = try await client.getProfile() }
    #expect(await transport.recordedRequests().count == 1)
}

@Test func rateLimitedWaitsForExactRetryAfterHeaderValue() async throws {
    // When Google supplies Retry-After, we must honor it exactly rather than
    // falling back to the exponential default — proves the `retryAfter ??`
    // left-hand side, not just that some sleep happened.
    let rateLimitBody = #"{"error": {"errors": [{"reason": "rateLimitExceeded"}]}}"#
    let transport = MockTransport(
        responses: [(Data(rateLimitBody.utf8), 429), (try fixture("profile"), 200)],
        headers: [0: ["Retry-After": "17"]])
    let sleeps = LockedBox<[Double]>([])
    let client = try makeClient(transport: transport, sleeps: sleeps)
    _ = try await client.getProfile()
    #expect(sleeps.values == [17.0])
}

@Test func exhaustingAllAttemptsThrowsTheLastError() async throws {
    let transport = MockTransport(responses: [
        (Data(), 503), (Data(), 503), (Data(), 503), (Data(), 503),
    ])
    let sleeps = LockedBox<[Double]>([])
    let client = try makeClient(transport: transport, sleeps: sleeps)
    await #expect(throws: GmailError.server(status: 503)) {
        _ = try await client.getProfile()
    }
    #expect(await transport.recordedRequests().count == 4)
    // The backoff ladder before the throwing 4th attempt: 2^1, 2^2, 2^3.
    #expect(sleeps.values == [2.0, 4.0, 8.0])
}

@Test func authFailureForceRefreshesExactlyOnceAcrossRemainingRetries() async throws {
    // 401 then 429 then 200: the 401 should trigger exactly one force-refresh
    // (one POST to the token endpoint); the subsequent 429 retry must reuse
    // the refreshed token via validAccessToken, not force-refresh again.
    let rateLimitBody = #"{"error": {"errors": [{"reason": "rateLimitExceeded"}]}}"#
    let apiTransport = MockTransport(responses: [
        (Data(), 401),
        (Data(rateLimitBody.utf8), 429),
        (try fixture("profile"), 200),
    ])
    let refreshResponse =
        #"{"access_token": "refreshed-at", "expires_in": 3599, "token_type": "Bearer"}"#
    let oauthTransport = MockTransport(responses: [(Data(refreshResponse.utf8), 200)])
    let sleeps = LockedBox<[Double]>([])
    let client = try makeClient(
        transport: apiTransport, oauthTransport: oauthTransport, sleeps: sleeps)

    let profile = try await client.getProfile()

    #expect(profile.emailAddress == "test-user@example.com")
    #expect(await oauthTransport.recordedRequests().count == 1)  // exactly one refresh

    let apiRequests = await apiTransport.recordedRequests()
    #expect(apiRequests.count == 3)
    #expect(apiRequests[0].value(forHTTPHeaderField: "Authorization") == "Bearer at")
    #expect(apiRequests[1].value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-at")
    #expect(apiRequests[2].value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-at")
}
