import Foundation
import GmailKit
import Testing
@testable import HudsonCLI

private let invalidGrant = GmailError.auth("invalid_grant: Token has been expired or revoked.")

@Test func recentConsentGetsTestingStatusHint() {
    let consented = Date(timeIntervalSince1970: 0)
    let now = Date(timeIntervalSince1970: 3 * 24 * 3600)  // 3 days later
    guard case .auth(let message) = ProfileCommand.annotated(
        invalidGrant, consentedAt: consented, now: now) else {
        Issue.record("expected .auth"); return
    }
    #expect(message.contains("PUBLISH APP"))
}

@Test func oldConsentPassesErrorThroughUnchanged() {
    let consented = Date(timeIntervalSince1970: 0)
    let now = Date(timeIntervalSince1970: 30 * 24 * 3600)  // 30 days later
    #expect(ProfileCommand.annotated(invalidGrant, consentedAt: consented, now: now) == invalidGrant)
}

@Test func nonGrantErrorsAreNeverAnnotated() {
    let other = GmailError.auth("Keychain has no client secret — run `hudson auth` again.")
    let consented = Date(timeIntervalSince1970: 0)
    let now = Date(timeIntervalSince1970: 3600)
    #expect(ProfileCommand.annotated(other, consentedAt: consented, now: now) == other)
}
