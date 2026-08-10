import Foundation
import Testing
@testable import GmailKit

private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")!
    return try Data(contentsOf: url)
}

private func makeClient(transport: MockTransport) throws -> GmailClient {
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
    return GmailClient(session: session, transport: transport, quota: QuotaBucket())
}

@Test func getMessageDecodesAndExtractsBothParts() async throws {
    let transport = MockTransport(responses: [(try fixture("message_full"), 200)])
    let message = try await makeClient(transport: transport)
        .getMessage(id: "18f0a", format: "full")
    #expect(message.historyId == "4711")
    #expect(message.header("subject") == "Test message")
    #expect(message.header("FROM") == "Ada <ada@example.com>")
    let content = message.extractContent()
    #expect(content.plainText == "hello plain")
    #expect(content.htmlData.map { String(decoding: $0, as: UTF8.self) } == "<b>html</b>")
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.path() == "/gmail/v1/users/me/messages/18f0a")
    #expect(request.url?.query()?.contains("format=full") == true)
}

@Test func historyPageDecodesAllChangeKinds() async throws {
    let transport = MockTransport(responses: [(try fixture("history_page"), 200)])
    let page = try await makeClient(transport: transport)
        .listHistory(startHistoryID: "4711", pageToken: nil)
    let records = try #require(page.history)
    #expect(records.count == 3)
    #expect(records[0].messagesAdded?.first?.message.id == "18f0b")
    #expect(records[1].labelsRemoved?.first?.message.labelIds == ["INBOX"])
    #expect(records[2].messagesDeleted?.first?.message.id == "18f09")
    #expect(page.historyId == "4720")
}

@Test func listMessagesPassesPageToken() async throws {
    let body = #"{"messages": [{"id": "a", "threadId": "t"}], "nextPageToken": "tok2", "resultSizeEstimate": 12}"#
    let transport = MockTransport(responses: [(Data(body.utf8), 200)])
    let page = try await makeClient(transport: transport)
        .listMessages(pageToken: "tok1", maxResults: 50)
    #expect(page.messages?.first?.id == "a")
    #expect(page.nextPageToken == "tok2")
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.query()?.contains("pageToken=tok1") == true)
    #expect(request.url?.query()?.contains("maxResults=50") == true)
}
