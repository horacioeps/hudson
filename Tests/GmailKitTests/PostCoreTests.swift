import Foundation
import Testing
@testable import GmailKit

private func makeClient(_ transport: MockTransport, sleeps: LockedBox<[Double]>? = nil) throws -> GmailClient {
    let store = InMemoryTokenStore()
    try store.saveTokens(TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture), account: "a")
    let session = AccountSession(
        account: "a",
        oauth: OAuthClient(credentials: OAuthCredentials(clientID: "i", clientSecret: "s"), transport: transport),
        store: store)
    return GmailClient(
        session: session, transport: transport, quota: QuotaBucket(),
        sleep: { seconds in sleeps?.append(seconds) })
}

private struct Empty: Encodable {}

@Test func postVoidSucceedsOn204EmptyBody() async throws {
    let transport = MockTransport(responses: [(Data(), 204)])
    try await makeClient(transport).postVoid(
        template: "users/me/messages/batchModify", path: "users/me/messages/batchModify",
        body: Empty(), cost: GmailQuotaCost.messagesBatchModify)
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
}

@Test func postDecodes200Body() async throws {
    let body = #"{"id":"m1","threadId":"t","historyId":"42"}"#
    let transport = MockTransport(responses: [(Data(body.utf8), 200)])
    let message: GmailMessage = try await makeClient(transport).post(
        template: "users/me/messages/{id}/modify", path: "users/me/messages/m1/modify",
        body: Empty(), cost: GmailQuotaCost.messagesModify)
    #expect(message.historyId == "42")
}

@Test func postStillRetriesServerErrorsThenSucceeds() async throws {
    let ok = #"{"id":"m1","threadId":"t","historyId":"42"}"#
    let transport = MockTransport(responses: [(Data(), 503), (Data(ok.utf8), 200)])
    let sleeps = LockedBox<[Double]>([])
    let client = try makeClient(transport, sleeps: sleeps)
    let message: GmailMessage = try await client.post(
        template: "t", path: "users/me/messages/m1/modify", body: Empty(),
        cost: GmailQuotaCost.messagesModify)
    #expect(message.historyId == "42")
    // One backoff sleep between the two attempts, at the 2^1 rung of the
    // ladder — proves post shares get's retry loop (via `perform`) rather
    // than duplicating it.
    #expect(sleeps.values == [2.0])
}
