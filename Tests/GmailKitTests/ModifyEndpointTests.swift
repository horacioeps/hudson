import Foundation
import Testing
@testable import GmailKit

private func makeClient(_ transport: MockTransport) throws -> GmailClient {
    let store = InMemoryTokenStore()
    try store.saveTokens(TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture), account: "a")
    let session = AccountSession(account: "a",
        oauth: OAuthClient(credentials: OAuthCredentials(clientID: "i", clientSecret: "s"), transport: transport),
        store: store)
    return GmailClient(session: session, transport: transport, quota: QuotaBucket())
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
