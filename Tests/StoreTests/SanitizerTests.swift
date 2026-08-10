import Foundation
import Testing
@testable import Store

@Test func prefersProvidedPlainTextOverHTML() {
    let body = Sanitizer.sanitize(html: Data("<p>html</p>".utf8), plainText: "the plain part")
    #expect(body.plainText == "the plain part")
    #expect(body.rawHTML == Data("<p>html</p>".utf8))
    #expect(body.sanitizerVersion == Sanitizer.version)
}

@Test func derivesTextFromHTMLWhenNoPlainPart() {
    let html = "<div>Hello<br>world &amp; <b>friends</b><script>evil()</script></div>"
    let body = Sanitizer.sanitize(html: Data(html.utf8), plainText: nil)
    #expect(body.plainText.contains("Hello"))
    #expect(body.plainText.contains("world & friends"))
    #expect(!body.plainText.contains("evil"))       // script content dropped
    #expect(!body.plainText.contains("<"))          // no tags survive
}

@Test func collectsCidAndRemoteReferences() {
    let html = #"<img src="cid:logo@x"><img src="https://t.example/px.gif"><a href="http://a.example/y">l</a>"#
    let body = Sanitizer.sanitize(html: Data(html.utf8), plainText: "t")
    #expect(body.cidReferences == ["logo@x"])
    #expect(body.remoteURLs.contains("https://t.example/px.gif"))
    #expect(body.remoteURLs.contains("http://a.example/y"))
}

@Test func terminalSafeStripsEscapesAndControls() {
    let hostile = "subject\u{1B}[31mred\u{1B}]0;title\u{07}\u{0007}bell\u{9B}csi\nok\ttab"
    let safe = Sanitizer.terminalSafe(hostile)
    #expect(!safe.contains("\u{1B}"))
    #expect(!safe.contains("\u{9B}"))
    #expect(!safe.contains("\u{07}"))
    #expect(safe.contains("\nok\ttab"))  // newline and tab survive
    #expect(safe.contains("subject"))
}

@Test func saveBodyMarksMessageHydrated() async throws {
    let database = try HudsonDatabase.inMemory()
    let snapshot = MessageSnapshot(
        id: "m1", threadID: "t1", historyID: 1, internalDate: 99,
        fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: [])
    _ = try await database.applySnapshot(snapshot, account: "x")
    try await database.saveBody(
        messageID: "m1", account: "x",
        body: Sanitizer.sanitize(html: nil, plainText: "hello"))
    let fetched = try #require(try await database.message(id: "m1", account: "x"))
    #expect(fetched.row.hasBody)
    #expect(fetched.plainText == "hello")
    #expect(try await database.messageIDsNeedingBodies(account: "x", since: 0, limit: 10).isEmpty)
}

// IMPORTANT 1: Invalid UTF-8 → lossy decode, non-empty text + inventory preserved
@Test func lossilyDecodesInvalidUTF8AndPreservesInventory() {
    var badBytes = Data("<img src=\"https://t.example/px\">".utf8)
    badBytes.append(0xFF)  // Invalid UTF-8 byte
    badBytes.append(contentsOf: " text".utf8)
    let body = Sanitizer.sanitize(html: badBytes, plainText: nil)
    #expect(!body.plainText.isEmpty)
    #expect(body.plainText.contains("text"))
    #expect(body.remoteURLs.contains("https://t.example/px"))
}

// IMPORTANT 2: &amp; decodes last to prevent re-encoding attacks
@Test func preventDoubleEncodedEntityAttacks() {
    let html = "<div>&amp;lt;script&amp;gt;</div>"
    let body = Sanitizer.sanitize(html: Data(html.utf8), plainText: nil)
    #expect(!body.plainText.contains("<script>"))
    #expect(!body.plainText.contains("<"))
}

// IMPORTANT 3: Unterminated script/style tags drop their body
@Test func handleUnteminatedScriptTags() {
    let html = "<div>keep</div><script>var x = fetch(...); alert('xss')<div>gone</div>"
    let body = Sanitizer.sanitize(html: Data(html.utf8), plainText: nil)
    #expect(body.plainText.contains("keep"))
    #expect(!body.plainText.contains("fetch"))
    #expect(!body.plainText.contains("xss"))
    #expect(!body.plainText.contains("gone"))
}

// IMPORTANT 4: Case-insensitive, single-quoted, CSS url() variants
@Test func collectsVariantCidAndRemoteFormats() {
    let html = #"""
    <img SRC="cid:logo@x">
    <img src='https://t.example/px.gif'>
    <a HREF=http://a.example/y>link</a>
    <div style="background: url('https://bg.example/img.png')">bg</div>
    <div style='background: url(https://bg2.example/img2.png)'>bg2</div>
    """#
    let body = Sanitizer.sanitize(html: Data(html.utf8), plainText: nil)
    #expect(body.cidReferences.contains("logo@x"))
    #expect(body.remoteURLs.contains("https://t.example/px.gif"))
    #expect(body.remoteURLs.contains("http://a.example/y"))
    #expect(body.remoteURLs.contains("https://bg.example/img.png"))
    #expect(body.remoteURLs.contains("https://bg2.example/img2.png"))
}

// IMPORTANT 5: Version bump re-derives bodies
@Test func versionBumpReDerivesOutdatedBodies() async throws {
    let database = try HudsonDatabase.inMemory()
    let snapshot = MessageSnapshot(
        id: "m1", threadID: "t1", historyID: 1, internalDate: 99,
        fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: [])
    _ = try await database.applySnapshot(snapshot, account: "x")
    try await database.saveBody(
        messageID: "m1", account: "x",
        body: Sanitizer.sanitize(html: nil, plainText: "v1"))
    #expect((try await database.messageIDsNeedingBodies(account: "x", since: 0, limit: 10)).isEmpty)

    // Simulate an outdated body by manually downgrading version in DB
    try await database.writer.write { db in
        try db.execute(
            sql: "UPDATE message_bodies SET sanitizer_version = 0 WHERE message_id = ?",
            arguments: ["m1"])
    }
    #expect(try await database.messageIDsNeedingBodies(account: "x", since: 0, limit: 10) == ["m1"])
}

// IMPORTANT 7: singleLine collapses newlines/tabs for list display
@Test func singleLineCollapsesNewlinesAndTabs() {
    let text = "row 1\nrow 2\tspaced"
    let normal = Sanitizer.terminalSafe(text, singleLine: false)
    let single = Sanitizer.terminalSafe(text, singleLine: true)
    #expect(normal.contains("\nrow 2"))
    #expect(normal.contains("\t"))
    #expect(!single.contains("\n"))
    #expect(!single.contains("\t"))
    #expect(single.contains("row 1 row 2"))
}

// IMPORTANT 8: Bidi and zero-width characters stripped
@Test func stripsBidiAndZeroWidthCharacters() {
    let hostile = "normal\u{200B}zero-width\u{200F}ltr\u{202E}rlo\u{2028}para\u{2029}sep"
    let safe = Sanitizer.terminalSafe(hostile)
    #expect(!safe.contains("\u{200B}"))
    #expect(!safe.contains("\u{200F}"))
    #expect(!safe.contains("\u{202E}"))
    #expect(!safe.contains("\u{2028}"))
    #expect(!safe.contains("\u{2029}"))
    #expect(safe.contains("normal"))
}

// IMPORTANT 9: saveBody upsert overwrites prior body
@Test func saveBodyUpsertOverwritesPrior() async throws {
    let database = try HudsonDatabase.inMemory()
    let snapshot = MessageSnapshot(
        id: "m1", threadID: "t1", historyID: 1, internalDate: 99,
        fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: [])
    _ = try await database.applySnapshot(snapshot, account: "x")

    try await database.saveBody(
        messageID: "m1", account: "x",
        body: Sanitizer.sanitize(html: nil, plainText: "v1"))
    var fetched = try #require(try await database.message(id: "m1", account: "x"))
    #expect(fetched.plainText == "v1")

    try await database.saveBody(
        messageID: "m1", account: "x",
        body: Sanitizer.sanitize(html: nil, plainText: "v2 overwrites"))
    fetched = try #require(try await database.message(id: "m1", account: "x"))
    #expect(fetched.plainText == "v2 overwrites")
}
