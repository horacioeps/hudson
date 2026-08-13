import Testing
@testable import HudsonUI

// MARK: - Prose routes to the native (dark, Hudson-typed) path

@Test func plainProseIsSimple() {
    #expect(SimpleBody.isSimple(html: "<div dir=\"ltr\">Hey Mannas,<br><br>Glad you're in!</div>"))
}

@Test func richInlineFormattingIsStillSimple() {
    let html = """
        <html><body><p>Hi <b>there</b>, see the <a href="https://x.com">link</a>.</p>
        <ul><li>one</li><li>two</li></ul><blockquote>quoted</blockquote></body></html>
        """
    #expect(SimpleBody.isSimple(html: html))
}

@Test func senderColorsAndFontsDoNotDisqualifyAMessage() {
    // The native path DISCARDS styling rather than honouring it, so a color
    // that would be invisible on dark is irrelevant to the routing decision.
    let html = #"<span style="color:#000000;font-family:Calibri">Regards,</span>"#
    #expect(SimpleBody.isSimple(html: html))
    // Doubled pound delimiters: a bare `"#` inside would close a `#"…"#`.
    #expect(SimpleBody.isSimple(html: ##"<font color="#1F497D" face="Calibri">Sent from Outlook</font>"##))
}

@Test func emptyBodyIsTriviallySimple() {
    #expect(SimpleBody.isSimple(html: ""))
}

@Test func proseContainingALessThanSignIsNotMistakenForMarkup() {
    // "a < b" must not read as an unknown tag and force the card.
    #expect(SimpleBody.isSimple(html: "<p>if a < b then ship it</p>"))
}

// MARK: - Rich mail keeps the white card

@Test func layoutTablesRouteToTheCard() {
    #expect(!SimpleBody.isSimple(html: "<table><tr><td>Receipt</td></tr></table>"))
}

@Test func contentImagesRouteToTheCard() {
    // No size information, so it has to be assumed real — deleting a picture
    // from a message is far worse than showing an unnecessary card.
    #expect(!SimpleBody.isSimple(html: #"<p>Hi</p><img src="https://x.com/logo.png">"#))
    #expect(!SimpleBody.isSimple(html: #"<img src="https://x.com/hero.png" width="480">"#))
}

// MARK: - Tracking pixels must not push prose onto the card

@Test func aRealTrackingPixelDoesNotDisqualifyAProseReply() {
    // Verbatim from a real message in the author's mailbox — this exact tag
    // was routing ordinary prose replies to the white card, because the rule
    // used to disqualify on the mere presence of <img>. Nearly every message
    // sent through a mailing platform carries one of these.
    let html = """
        <div dir="ltr"><p>Hey Mannas, completely fair!</p>
        <p>Sent with <a href="https://slashy.com">Slashy</a></p></div>
        <img src="https://track.example/o.gif" width="1" height="1" border="0" alt=""
             style="display:none;width:1px;height:1px;border:0;visibility:hidden;" />
        """
    #expect(SimpleBody.isSimple(html: html))
}

@Test func pixelsAreRecognisedByEachOfTheirTells() {
    for tag in [
        #"<img src="https://t.example/p" width="1" height="1">"#,
        #"<img src="https://t.example/p" style="width:1px;height:1px">"#,
        #"<img src="https://t.example/p" style="display:none">"#,
        #"<img src="https://t.example/p" style="visibility: hidden">"#,
        #"<img src="https://t.example/p" width="0" height="0">"#,
    ] {
        #expect(SimpleBody.isTrackingPixel(tag), "should read as a pixel: \(tag)")
        #expect(SimpleBody.isSimple(html: "<p>prose</p>\(tag)"))
    }
}

@Test func oneContentImageBesideAPixelStillRoutesToTheCard() {
    let html = """
        <p>Here's the mockup:</p><img src="https://x.example/shot.png" width="600" height="400">
        <img src="https://t.example/p" width="1" height="1" style="display:none">
        """
    #expect(!SimpleBody.isSimple(html: html))
}

@Test func embeddedStylesheetsRouteToTheCard() {
    #expect(!SimpleBody.isSimple(html: "<style>.a{color:red}</style><p>Hi</p>"))
}

@Test func newsletterLayoutHiddenInAnMSOConditionalCommentStillRoutesToTheCard() {
    // Scanning INTO comments is the conservative direction, and this is why:
    // stripping them first would let a newsletter's real layout slip onto the
    // native path, where it would render as a wall of unstyled text.
    let html = """
        <p>View in browser</p>
        <!--[if mso]><table role="presentation"><tr><td><![endif]-->
        <p>Hello</p>
        """
    #expect(!SimpleBody.isSimple(html: html))
}

@Test func doctypeAndCommentsAloneDoNotDisqualifyAMessage() {
    let html = "<!DOCTYPE html><!-- a note --><html><body><p>Hi</p></body></html>"
    #expect(SimpleBody.isSimple(html: html))
}

// MARK: - Mailer-wrapped prose (a sentence inside a marketing skeleton)

/// The shape a sales/CRM platform actually sends: one line of prose wrapped in
/// nested layout tables, an Outlook `<xml>` island, a stylesheet, and a
/// tracking pixel. Verbatim in structure from two messages in the author's
/// mailbox that kept landing on the white card.
private func mailerWrapped(_ prose: String) -> String {
    """
    <html><head><style>.x{color:#000}</style><xml><o:p></o:p></xml></head>
    <body><table><tbody><tr><td>
      <table><tbody><tr><td><div><span>\(prose)</span></div></td></tr>
      <tr><td></td></tr><tr><td></td></tr></tbody></table>
    </td></tr></tbody></table>
    <img alt="" src="https://t.example/o.gif" style="display: none; width: 1px; height: 1px;">
    </body></html>
    """
}

@Test func aOneLineReplyWrappedInMailerTablesRendersNatively() {
    let html = mailerWrapped("Lets do it! https://cal.com/farza/chat-about-clicky")
    // Layout tables alone used to disqualify this, so a one-sentence reply
    // sent through a sales tool kept the white card.
    // 2611 = the real extracted length of that message, which includes its
    // quoted history and hidden preheader copy, not just the sentence shown.
    #expect(SimpleBody.isSimple(html: html, visibleTextLength: 2_611))
}

@Test func theSameWrappersAroundARealNewsletterStillKeepTheCard() {
    // 137k is what the image-bearing newsletters in a real mailbox measure.
    #expect(!SimpleBody.isSimple(html: mailerWrapped("x"), visibleTextLength: 137_000))
}

/// Length is only the backstop: a newsletter is disqualified by its pictures
/// first, whatever its length. This is what lets the length bound be generous.
@Test func contentImagesAreTheGateThatActuallyCatchesNewsletters() {
    let newsletter = mailerWrapped("Sale")
        + (1...10).map { #"<img src="https://x.example/\#($0).png" width="600">"# }.joined()
    #expect(!SimpleBody.isSimple(html: newsletter, visibleTextLength: 100))
}

@Test func wrappedProseWithAContentImageStillKeepsTheCard() {
    // Length is irrelevant once there's a real picture to lose.
    let html = mailerWrapped("Short note") + #"<img src="https://x.example/hero.png" width="600">"#
    #expect(!SimpleBody.isSimple(html: html, visibleTextLength: 10))
}

@Test func pureProseIsSimpleAtAnyLength() {
    // The short-document rule gates WRAPPERS only — an unwrapped long reply
    // must not get carded just for being long.
    #expect(SimpleBody.isSimple(html: "<div><p>a</p></div>", visibleTextLength: 50_000))
}

@Test func anUnknownTagIsStillDisqualifyingHoweverShort() {
    #expect(!SimpleBody.isSimple(html: "<p>hi</p><canvas></canvas>", visibleTextLength: 2))
}
