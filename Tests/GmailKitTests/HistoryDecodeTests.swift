import Foundation
import Testing
@testable import GmailKit

// Regression coverage for the fix that made ALL sync viable against live Gmail
// (commit 7205b95). Real `history.list` nests only a MINIMAL message in every
// change record — `id`/`threadId` plus the message's current `labelIds`, and
// crucially NO `historyId`, `internalDate`, headers, or payload. The code once
// decoded those records as a full `GmailMessage`, whose `historyId` is
// required, so the whole page decode THREW the instant anything changed in a
// real mailbox (sending adds SENT; every new mail is a messagesAdded) — sync
// was completely broken. These tests pin the exact wire shape that crashed
// production so it can never regress.

/// The exact minimal shape live Gmail returns across all four change kinds:
/// each nested `message` carries only `id`/`threadId`/`labelIds`, with NO
/// `historyId` anywhere on it. Must decode into `HistoryMessageStub`s without
/// throwing, exposing the `id`/`labelIds` the engine reads.
@Test func minimalHistoryListDecodesWithoutMessageHistoryIds() throws {
    let json = """
        {
          "historyId": "987654",
          "nextPageToken": "next-page",
          "history": [
            {
              "id": "987600",
              "messagesAdded": [
                {"message": {"id": "m-new", "threadId": "t-1", "labelIds": ["INBOX", "UNREAD"]}}
              ]
            },
            {
              "id": "987610",
              "labelsAdded": [
                {"message": {"id": "m-star", "threadId": "t-2", "labelIds": ["INBOX", "STARRED"]}}
              ]
            },
            {
              "id": "987620",
              "labelsRemoved": [
                {"message": {"id": "m-read", "threadId": "t-2", "labelIds": ["INBOX"]}}
              ]
            },
            {
              "id": "987630",
              "messagesDeleted": [
                {"message": {"id": "m-del", "threadId": "t-3", "labelIds": ["TRASH"]}}
              ]
            }
          ]
        }
        """

    // The regression itself: before the fix this line threw
    // (`keyNotFound(historyId)`), taking the whole poll — and thus all sync —
    // down with it.
    let page = try JSONDecoder().decode(HistoryPage.self, from: Data(json.utf8))

    #expect(page.historyId == "987654")
    #expect(page.nextPageToken == "next-page")
    let records = try #require(page.history)
    #expect(records.count == 4)

    let added = try #require(records[0].messagesAdded?.first)
    #expect(added.id == "m-new")
    #expect(added.labelIds == ["INBOX", "UNREAD"])

    let labelsAdded = try #require(records[1].labelsAdded?.first)
    #expect(labelsAdded.id == "m-star")
    #expect(labelsAdded.labelIds == ["INBOX", "STARRED"])

    let labelsRemoved = try #require(records[2].labelsRemoved?.first)
    #expect(labelsRemoved.id == "m-read")
    #expect(labelsRemoved.labelIds == ["INBOX"])

    let deleted = try #require(records[3].messagesDeleted?.first)
    #expect(deleted.id == "m-del")
    #expect(deleted.labelIds == ["TRASH"])
}

/// Gmail omits `labelIds` entirely on some records (e.g. a bare
/// messagesDeleted). `labelIds` is optional, so this must still decode —
/// surfacing as nil, which `HistoryMapping` reads as "no labels".
@Test func minimalHistoryMessageWithoutLabelIdsDecodesToNilLabels() throws {
    let json = #"""
        {"history": [
          {"id": "5", "messagesDeleted": [{"message": {"id": "m-gone", "threadId": "t-9"}}]}
        ]}
        """#
    let page = try JSONDecoder().decode(HistoryPage.self, from: Data(json.utf8))
    let stub = try #require(page.history?.first?.messagesDeleted?.first)
    #expect(stub.id == "m-gone")
    #expect(stub.labelIds == nil)
}
