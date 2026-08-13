import Foundation
import Testing
@testable import HudsonUI

private func newText(_ html: String) -> String {
    ParsedBody.text(MessageBodyParser.parse(html: html).new)
}

private func quotedText(_ html: String) -> String {
    ParsedBody.text(MessageBodyParser.parse(html: html).quoted)
}

// MARK: - Text extraction

@Test func extractsProseAndDecodesEntities() {
    #expect(newText("<div>I&#39;m in &amp; excited</div>") == "I'm in & excited")
}

@Test func collapsesInsignificantWhitespaceButKeepsWordSpacing() {
    #expect(newText("<p>Hey    Mannas,\n   glad   you're in</p>") == "Hey Mannas, glad you're in")
}

@Test func breaksAndBlocksBecomeNewlines() {
    #expect(newText("<div>one<br>two</div><p>three</p>") == "one\ntwo\n\nthree")
}

@Test func preservesWhitespaceInsidePre() {
    #expect(newText("<pre>let x = 1\n    let y = 2</pre>") == "let x = 1\n    let y = 2")
}

@Test func leadingAndTrailingDocumentScaffoldingIsTrimmed() {
    // The wrapping <html>/<body> blocks would otherwise leave blank lines at
    // both ends of every Gmail message.
    #expect(newText("<html><body><p>Hi</p></body></html>") == "Hi")
}

@Test func listsGetMarkers() {
    #expect(newText("<ul><li>one</li><li>two</li></ul>") == "• one\n• two")
    #expect(newText("<ol><li>first</li><li>second</li></ol>") == "1. first\n2. second")
}

// MARK: - Styling is semantic, never presentational

@Test func inlineTagsBecomeSemanticFlags() {
    let spans = MessageBodyParser.parse(html: "plain <b>bold</b> <i>italic</i>").new
    #expect(spans.contains { $0.text == "bold" && $0.bold && !$0.italic })
    #expect(spans.contains { $0.text == "italic" && $0.italic && !$0.bold })
}

@Test func senderStylingIsDiscardedEntirely() {
    // There is no span field that can carry a color or a font family, so an
    // invisible-on-dark color cannot survive the parse. This is what makes the
    // native path safe on a dark ground.
    let spans = MessageBodyParser.parse(
        html: #"<span style="color:#000000;font-family:Comic Sans">hi</span>"#).new
    #expect(spans == [BodySpan(text: "hi")])
}

@Test func misNestedTagsDoNotLeakStylingIntoTheRestOfTheMessage() {
    // Real mail is full of this. The bold must not run to the end of the body.
    let spans = MessageBodyParser.parse(html: "<b>bold<i>both</b>neither</i>").new
    #expect(spans.last?.text == "neither")
    #expect(spans.last?.bold == false)
}

@Test func strayClosingTagIsIgnoredRatherThanDiscardingStyling() {
    let spans = MessageBodyParser.parse(html: "<b>still bold</u> here</b>").new
    #expect(spans.allSatisfy { $0.bold })
}

// MARK: - Links

@Test func safeSchemesBecomeLinks() {
    let spans = MessageBodyParser.parse(html: #"<a href="https://slashy.com">Slashy</a>"#).new
    #expect(spans == [BodySpan(text: "Slashy", link: URL(string: "https://slashy.com"))])
}

@Test func unsafeSchemesRenderAsInertText() {
    // Same scheme allowlist PlainTextLinkifier enforces — a body must not be
    // able to smuggle a javascript:/file: link past either path.
    for href in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,<b>x"] {
        let spans = MessageBodyParser.parse(html: #"<a href="\#(href)">click</a>"#).new
        #expect(spans.allSatisfy { $0.link == nil }, "\(href) must not become a link")
    }
}

@Test func anEntityEncodedHrefStillResolves() {
    let spans = MessageBodyParser.parse(
        html: #"<a href="https://x.com/a?b=1&amp;c=2">go</a>"#).new
    #expect(spans.first?.link == URL(string: "https://x.com/a?b=1&c=2"))
}

// MARK: - Quoted history splitting

@Test func gmailQuoteIsSplitOff() {
    let html = """
        <div>Thanks !</div>
        <div class="gmail_quote"><div>On Aug 11, Harsha wrote:</div><div>Hey Mannas</div></div>
        """
    #expect(newText(html) == "Thanks !")
    #expect(quotedText(html).contains("Hey Mannas"))
}

@Test func appleMailCiteBlockquoteIsSplitOff() {
    let html = #"<div>Sure thing</div><blockquote type="cite"><div>earlier note</div></blockquote>"#
    #expect(newText(html) == "Sure thing")
    #expect(quotedText(html) == "earlier note")
}

@Test func outlookReplyContainerIsSplitOff() {
    // This one fell straight through before: the old CSS only knew about
    // Gmail and Apple Mail, so Outlook replies showed their whole ancestry.
    let html = """
        <div>Sounds good.</div><div id="divRplyFwdMsg">From: Harsha<br>Sent: Monday</div>
        """
    #expect(newText(html) == "Sounds good.")
    #expect(quotedText(html).contains("From: Harsha"))
}

@Test func aBareBlockquoteAfterRealTextIsTreatedAsHistory() {
    let html = "<div>My reply</div><blockquote>the older message</blockquote>"
    #expect(newText(html) == "My reply")
    #expect(quotedText(html) == "the older message")
}

@Test func aMessageOpeningWithABlockquoteIsNeverCollapsedToNothing() {
    // The hasNewContent guard: without it this renders a blank message with a
    // "···" pill and nothing else, which is the worst possible failure.
    let html = "<blockquote>quote-first prose</blockquote><div>and my point</div>"
    #expect(newText(html).contains("quote-first prose"))
    #expect(quotedText(html).isEmpty)
}

@Test func everythingAfterTheBoundaryStaysQuotedEvenAcrossSiblings() {
    // A reply chain nests N deep; once history starts it does not stop.
    let html = """
        <div>Top reply</div><div class="gmail_quote">first</div><div>trailing scrap</div>
        """
    #expect(newText(html) == "Top reply")
    #expect(quotedText(html).contains("trailing scrap"))
}

@Test func aMessageWithNoQuoteHasNoQuotedHalf() {
    #expect(MessageBodyParser.parse(html: "<p>Just a note</p>").quoted.isEmpty)
}

// MARK: - Hostile and malformed input

@Test func unterminatedTagDoesNotHangOrCrash() {
    #expect(newText("<div>text<span class=\"unclosed") == "text")
}

@Test func attributeValueContainingAngleBracketDoesNotEndTheTagEarly() {
    let spans = MessageBodyParser.parse(html: #"<a href="https://x.com/?q=a>b">go</a>"#).new
    #expect(ParsedBody.text(spans) == "go")
    #expect(spans.first?.link != nil)
}

@Test func deeplyNestedMarkupTerminates() {
    let html = String(repeating: "<div>", count: 2000) + "deep"
        + String(repeating: "</div>", count: 2000)
    #expect(newText(html) == "deep")
}

@Test func scriptContentIsNotExecutableHereButItsTextIsStillJustText() {
    // A body carrying <script> never reaches this parser (SimpleBody routes it
    // to the sandboxed web view), but the parser must still be total on it.
    #expect(!newText("<div>hi</div><script>alert(1)</script>").isEmpty)
}
