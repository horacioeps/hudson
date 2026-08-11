import Testing

@testable import HudsonUI

struct HTMLEntitiesTests {
    @Test func decodesTheEntitiesGmailLeavesInSnippets() {
        #expect(HTMLEntities.decode("I&#39;m 21, dropped out") == "I'm 21, dropped out")
        #expect(HTMLEntities.decode("Let&#39;s chat") == "Let's chat")
        #expect(HTMLEntities.decode("a &amp; b") == "a & b")
        #expect(HTMLEntities.decode("&lt;tag&gt; &quot;q&quot;") == "<tag> \"q\"")
        #expect(HTMLEntities.decode("&#x27;hex&#x27;") == "'hex'")
        #expect(HTMLEntities.decode("&nbsp;space") == " space")
    }

    @Test func leavesPlainTextAndMalformedEntitiesUntouched() {
        #expect(HTMLEntities.decode("no entities here") == "no entities here")
        #expect(HTMLEntities.decode("A&B without semicolons") == "A&B without semicolons")
        #expect(HTMLEntities.decode("") == "")
        // A double-encoded apostrophe decodes only its outer &amp;, not all the
        // way to ' — the "amp last" guard against re-encoding attacks.
        #expect(HTMLEntities.decode("x&amp;#39;y") == "x&#39;y")
    }
}
