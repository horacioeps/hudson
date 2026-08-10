import Foundation
import Testing
@testable import GmailKit

private func makeClient(_ transport: MockTransport, quota: QuotaBucket = QuotaBucket()) throws -> GmailClient {
    let store = InMemoryTokenStore()
    try store.saveTokens(TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture), account: "a")
    let session = AccountSession(account: "a",
        oauth: OAuthClient(credentials: OAuthCredentials(clientID: "i", clientSecret: "s"), transport: transport),
        store: store)
    return GmailClient(session: session, transport: transport, quota: quota)
}

@Test func modifyPostsLabelsAndReturnsMessage() async throws {
    let body = #"{"id":"m1","threadId":"t","historyId":"77","labelIds":["UNREAD"]}"#
    let transport = MockTransport(responses: [(Data(body.utf8), 200)])
    let message = try await makeClient(transport).modify(
        id: "m1", addLabelIDs: [], removeLabelIDs: ["INBOX"])
    #expect(message.historyId == "77")
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.path() == "/gmail/v1/users/me/messages/m1/modify")
    let sent = try #require(request.httpBody)
    let json = try JSONSerialization.jsonObject(with: sent) as! [String: Any]
    #expect(json["removeLabelIds"] as? [String] == ["INBOX"])
}

@Test func batchModifyPostsIdsAnd204s() async throws {
    let transport = MockTransport(responses: [(Data(), 204)])
    try await makeClient(transport).batchModify(
        ids: ["m1", "m2"], addLabelIDs: ["STARRED"], removeLabelIDs: [])
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.path() == "/gmail/v1/users/me/messages/batchModify")
    let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    #expect((json["ids"] as? [String])?.sorted() == ["m1", "m2"])
    #expect(json["addLabelIds"] as? [String] == ["STARRED"])
}

// MARK: - Interactive quota lane (M3 final-review Fix 2)
//
// Both tests below saturate the `.background` admission ceiling
// (unitsPerMinute - interactiveReserve = 0) while leaving the full window
// open to `.interactive`. If `modify`/`batchModify` still acquired on
// `.background` (the pre-fix bug — the lane was wired but never used by any
// production caller), `QuotaBucket.acquire` would throw immediately
// (`cost > ceiling`) instead of admitting the request. Success here proves
// the call actually passes `.interactive` through.

@Test func modifyAcquiresOnTheInteractiveQuotaLane() async throws {
    let body = #"{"id":"m1","threadId":"t","historyId":"77","labelIds":["UNREAD"]}"#
    let transport = MockTransport(responses: [(Data(body.utf8), 200)])
    let quota = QuotaBucket(unitsPerMinute: 10, interactiveReserve: 10)  // background ceiling: 0
    let message = try await makeClient(transport, quota: quota).modify(
        id: "m1", addLabelIDs: [], removeLabelIDs: ["INBOX"])
    #expect(message.historyId == "77")
}

@Test func batchModifyAcquiresOnTheInteractiveQuotaLane() async throws {
    let transport = MockTransport(responses: [(Data(), 204)])
    let quota = QuotaBucket(unitsPerMinute: 60, interactiveReserve: 60)  // background ceiling: 0
    try await makeClient(transport, quota: quota).batchModify(
        ids: ["m1", "m2"], addLabelIDs: ["STARRED"], removeLabelIDs: [])
    #expect(await transport.recordedRequests().count == 1)  // no throw == admitted
}
