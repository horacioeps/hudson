import GmailKit
import Store
import Testing
@testable import SyncEngine

// M5 Task 5 review fix: `SnapshotMapping.snapshot(from:)` is the only place
// that turns a real Gmail wire payload's `Message-ID`/`References` headers
// into `MessageSnapshot.rfc822MessageID`/`referencesHeader` — every prior
// test exercised the Store write path by hand-seeding a `MessageSnapshot`
// directly, bypassing this mapper entirely. These tests close that loop.

@Test func snapshotMappingCarriesThreadingHeadersThroughFromAGmailPayload() throws {
    let message = testMessage(
        id: "m2", threadID: "t1", historyID: "42",
        messageID: "<m2@mail.example.com>", references: "<m1@mail.example.com>")

    let snapshot = try #require(SnapshotMapping.snapshot(from: message))

    #expect(snapshot.rfc822MessageID == "<m2@mail.example.com>")
    #expect(snapshot.referencesHeader == "<m1@mail.example.com>")
    // Sanity: the rest of the mapping still works alongside the new fields.
    #expect(snapshot.id == "m2")
    #expect(snapshot.threadID == "t1")
    #expect(snapshot.historyID == 42)
}

@Test func snapshotMappingLeavesThreadingHeadersNilWhenThePayloadCarriesNone() throws {
    // A root message legitimately has no `References` header; and a fetch
    // that genuinely lacks a `Message-ID` header (rare, per the doc
    // comment) must not synthesize one out of thin air.
    let message = testMessage(id: "m1", threadID: "t1", historyID: "1")

    let snapshot = try #require(SnapshotMapping.snapshot(from: message))

    #expect(snapshot.rfc822MessageID == nil)
    #expect(snapshot.referencesHeader == nil)
}
