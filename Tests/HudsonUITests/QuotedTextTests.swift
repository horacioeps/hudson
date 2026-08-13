import Testing
@testable import HudsonUI

@Test func angleQuotedRunIsSplitOff() {
    let body = """
        Thanks !

        > On Aug 11, Harsha wrote:
        > Hey Mannas, glad you're in
        """
    let (new, quoted) = QuotedText.split(body)
    #expect(new == "Thanks !")
    #expect(quoted.contains("glad you're in"))
}

@Test func attributionLineIsSplitOff() {
    let body = """
        Sounds good, talk soon.

        On Mon, Aug 11, 2026 at 9:47 PM Harsha Gaddipati <h@slashy.com> wrote:
        Hey Mannas, awesome, glad you're in!
        """
    let (new, quoted) = QuotedText.split(body)
    #expect(new == "Sounds good, talk soon.")
    #expect(quoted.hasPrefix("On Mon, Aug 11"))
}

@Test func attributionLineWrappedAcrossLinesIsStillFound() {
    // Clients hard-wrap this line freely; the terminating "wrote:" is what
    // confirms the match, wherever it lands.
    let body = """
        Got it.

        On Mon, Aug 11, 2026 at 9:47 PM Harsha Gaddipati
        <harsha@slashy.com>
        wrote:
        Hey Mannas
        """
    let (new, quoted) = QuotedText.split(body)
    #expect(new == "Got it.")
    #expect(quoted.contains("Hey Mannas"))
}

@Test func outlookOriginalMessageSeparatorIsSplitOff() {
    let body = """
        Will do.

        -----Original Message-----
        From: Harsha
        """
    let (new, quoted) = QuotedText.split(body)
    #expect(new == "Will do.")
    #expect(quoted.contains("From: Harsha"))
}

@Test func outlookUnderscoreRuleIsSplitOff() {
    let body = """
        Confirmed.

        ________________________________
        From: Harsha Gaddipati
        """
    let (new, quoted) = QuotedText.split(body)
    #expect(new == "Confirmed.")
    #expect(quoted.contains("From: Harsha Gaddipati"))
}

@Test func anOrdinarySentenceStartingWithOnIsNotAQuoteBoundary() {
    // "wrote:" is required precisely so this doesn't truncate the message.
    let body = "On Tuesday I'll send the draft over. Let me know if that works."
    let (new, quoted) = QuotedText.split(body)
    #expect(new == body)
    #expect(quoted.isEmpty)
}

@Test func aBodyThatIsEntirelyQuotedStaysFullyVisible() {
    // A bare forward has no reply above the boundary. Collapsing it would show
    // an empty message with only a "···" pill.
    let body = """
        > the whole thing
        > is quoted
        """
    let (new, quoted) = QuotedText.split(body)
    #expect(new == body)
    #expect(quoted.isEmpty)
}

@Test func aBodyWithNoQuoteIsReturnedUnchanged() {
    let body = "Just a short note.\n\nThanks,\nMannas"
    let (new, quoted) = QuotedText.split(body)
    #expect(new == body)
    #expect(quoted.isEmpty)
}

@Test func onlyTheEarliestBoundaryIsUsed() {
    // A reply that both attributes and angle-quotes must split once, at the
    // top of the history — not at the deepest marker.
    let body = """
        Reply text.

        On Mon Harsha wrote:
        > older still
        """
    let (new, quoted) = QuotedText.split(body)
    #expect(new == "Reply text.")
    #expect(quoted.hasPrefix("On Mon Harsha wrote:"))
}
