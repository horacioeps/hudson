import Foundation
import Testing
@testable import GmailKit

private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")!
    return try Data(contentsOf: url)
}

private func makeClient(
    transport: MockTransport, sleeps: LockedBox<[Double]>? = nil
) throws -> GmailClient {
    let store = InMemoryTokenStore()
    try store.saveTokens(
        TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture),
        account: "a@example.com")
    let session = AccountSession(
        account: "a@example.com",
        oauth: OAuthClient(
            credentials: OAuthCredentials(clientID: "id", clientSecret: "secret"),
            transport: transport),
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
    #expect(sleeps.values.count == 1)  // one backoff sleep between the two attempts
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
}

@Test func invalidRequestNeverRetries() async throws {
    let transport = MockTransport(responses: [(Data(), 404)])
    let client = try makeClient(transport: transport)
    await #expect(throws: GmailError.self) { _ = try await client.getProfile() }
    #expect(await transport.recordedRequests().count == 1)
}
