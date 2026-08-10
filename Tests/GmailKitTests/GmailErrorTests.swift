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
