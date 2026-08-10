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
