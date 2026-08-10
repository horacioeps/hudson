import Foundation
import Testing
@testable import GmailKit

@Test func status401MapsToAuth() {
    let error = GmailError.from(status: 401, data: Data(), retryAfterHeader: nil)
    #expect(error == .auth("Gmail rejected the access token (HTTP 401)."))
}

@Test func status429MapsToRateLimitedWithRetryAfter() {
    let error = GmailError.from(status: 429, data: Data(), retryAfterHeader: "13")
    #expect(error == .rateLimited(retryAfter: 13))
}

@Test func rateLimitExceeded403MapsToRateLimited() {
    let body = #"{"error": {"errors": [{"reason": "rateLimitExceeded"}]}}"#
    let error = GmailError.from(status: 403, data: Data(body.utf8), retryAfterHeader: nil)
    #expect(error == .rateLimited(retryAfter: nil))
}

@Test func status500MapsToServer() {
    #expect(GmailError.from(status: 500, data: Data(), retryAfterHeader: nil) == .server(status: 500))
}

@Test func status400CarriesGoogleMessage() {
    let body = #"{"error": {"message": "Invalid id value"}}"#
    let error = GmailError.from(status: 400, data: Data(body.utf8), retryAfterHeader: nil)
    #expect(error == .invalidRequest(status: 400, message: "Invalid id value"))
}

@Test func rateLimit403RequiresReasonField() {
    // The literal string outside the reason field must NOT classify as rate limiting.
    let decoy = #"{"error": {"message": "try rateLimitExceeded backoff", "errors": [{"reason": "forbidden"}]}}"#
    let error = GmailError.from(status: 403, data: Data(decoy.utf8), retryAfterHeader: nil)
    #expect(error == .invalidRequest(status: 403, message: "try rateLimitExceeded backoff"))
}

@Test func rateLimit403MatchesUserRateLimitReason() {
    let body = #"{"error": {"errors": [{"reason": "userRateLimitExceeded"}]}}"#
    #expect(GmailError.from(status: 403, data: Data(body.utf8), retryAfterHeader: nil)
        == .rateLimited(retryAfter: nil))
}

@Test func invalidGrantPredicateMatchesOAuthClientPhrasing() {
    #expect(GmailError.auth("invalid_grant: Token has been expired or revoked.").indicatesInvalidGrant)
    #expect(!GmailError.auth("No stored tokens — run `hudson auth` first.").indicatesInvalidGrant)
    #expect(!GmailError.rateLimited(retryAfter: nil).indicatesInvalidGrant)
}
