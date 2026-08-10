import Testing
@testable import GmailKit

@Test func oauthScopeIsGmailModify() {
    #expect(GmailKit.oauthScope == "https://www.googleapis.com/auth/gmail.modify")
}
