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

// MARK: - sendRawMessage

@Test func sendRawMessageReturnsIDAndThreadID() async throws {
    let body = #"{"id":"18f1a","threadId":"t99","labelIds":["SENT"]}"#
    let transport = MockTransport(responses: [(Data(body.utf8), 200)])
    let sent = try await makeClient(transport).sendRawMessage(Data("hello mime".utf8), threadID: "t99")
    #expect(sent.id == "18f1a")
    #expect(sent.threadId == "t99")
    #expect(sent.labelIds == ["SENT"])
}

@Test func sendRawMessagePostsBase64URLRawAndThreadID() async throws {
    let body = #"{"id":"18f1a","threadId":"t99","labelIds":["SENT"]}"#
    let transport = MockTransport(responses: [(Data(body.utf8), 200)])
    // A plain ASCII MIME body happens to base64-encode identically under
    // both standard base64 and base64url (no '+'/'/'/'=' ever appear), so
    // it can't distinguish the two encoders. Appending these four
    // high-entropy trailing bytes forces standard base64 to contain '+',
    // '/', AND '=' padding (verified directly: `Data(mimeBytes)
    // .base64EncodedString()` on this exact sequence is
    // "...Ym9kef/+/fs="), while base64url of the same bytes contains none
    // of those characters — so this fixture actually exercises which
    // encoder was used, unlike the all-ASCII fixture it replaces.
    let mime = Data("From: a@example.com\r\nSubject: hi\r\n\r\nbody".utf8)
        + Data([0xFF, 0xFE, 0xFD, 0xFB])
    _ = try await makeClient(transport).sendRawMessage(mime, threadID: "t99")

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.path() == "/gmail/v1/users/me/messages/send")
    let sentBody = try #require(request.httpBody)
    let json = try JSONSerialization.jsonObject(with: sentBody) as! [String: Any]
    #expect(json["threadId"] as? String == "t99")

    // Gmail requires base64URL (RFC 4648 §5), not standard base64 — no
    // '+'/'/' characters and no '=' padding, and it must round-trip back to
    // the exact MIME bytes handed in.
    let raw = try #require(json["raw"] as? String)
    #expect(!raw.contains("+"))
    #expect(!raw.contains("/"))
    #expect(!raw.contains("="))
    var padded = raw.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while padded.count % 4 != 0 { padded.append("=") }
    #expect(Data(base64Encoded: padded) == mime)
}

@Test func sendRawMessageOmitsThreadIDWhenNil() async throws {
    let body = #"{"id":"18f1a","threadId":"t99","labelIds":["SENT"]}"#
    let transport = MockTransport(responses: [(Data(body.utf8), 200)])
    _ = try await makeClient(transport).sendRawMessage(Data("hello".utf8), threadID: nil)

    let request = try #require(await transport.recordedRequests().first)
    let sentBody = try #require(request.httpBody)
    let json = try JSONSerialization.jsonObject(with: sentBody) as! [String: Any]
    // An edited-subject reply deliberately starts a new thread by omitting
    // threadId entirely — not sending it as JSON null (spec §7.1).
    #expect(json["threadId"] == nil)
    #expect(json.keys.contains("threadId") == false)
}

// A send is always foreground/user-initiated (Privacy #1: no background
// send) — it must acquire on `.interactive`, never queue behind a
// saturated `.background` lane the way polling/backfill do. Mirrors
// `ModifyEndpointTests`' interactive-lane proof: this quota saturates the
// `.background` admission ceiling to zero while leaving the full window to
// `.interactive`, so a `.background`-routed call would throw immediately.
@Test func sendRawMessageAcquiresOnTheInteractiveQuotaLane() async throws {
    let body = #"{"id":"18f1a","threadId":"t99","labelIds":["SENT"]}"#
    let transport = MockTransport(responses: [(Data(body.utf8), 200)])
    let quota = QuotaBucket(unitsPerMinute: 100, interactiveReserve: 100)  // background ceiling: 0
    let sent = try await makeClient(transport, quota: quota).sendRawMessage(Data("hi".utf8), threadID: nil)
    #expect(sent.id == "18f1a")
}

// MARK: - findSentMessageID (restart dedup probe)

@Test func findSentMessageIDReturnsFirstHitFromSent() async throws {
    let body = #"{"messages": [{"id": "m1", "threadId": "t1"}], "resultSizeEstimate": 1}"#
    let transport = MockTransport(responses: [(Data(body.utf8), 200)])
    let found = try await makeClient(transport)
        .findSentMessageID(rfc822MessageID: "<abc-123@hudson.local>")
    #expect(found == "m1")

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.path() == "/gmail/v1/users/me/messages")
    let query = try #require(request.url?.query())
    // `<`/`>`/space are outside the shared `encodedQuery` allowed set and
    // get percent-encoded; `:`/`@` are pchar-legal in a query component and
    // stay literal (verified against `CharacterSet.urlQueryAllowed`, not
    // guessed — Foundation's exact allowed set is otherwise easy to get
    // subtly wrong).
    #expect(query.contains("q=rfc822msgid:%3Cabc-123@hudson.local%3E%20in:sent"))
    #expect(query.contains("maxResults=1"))
}

@Test func findSentMessageIDReturnsNilOnMiss() async throws {
    let body = #"{"resultSizeEstimate": 0}"#
    let transport = MockTransport(responses: [(Data(body.utf8), 200)])
    let found = try await makeClient(transport)
        .findSentMessageID(rfc822MessageID: "<never-sent@hudson.local>")
    #expect(found == nil)
}
