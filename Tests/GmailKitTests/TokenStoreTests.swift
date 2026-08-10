import Foundation
import Testing
@testable import GmailKit

@Test func roundTripsTokensAndSecret() throws {
    let store = InMemoryTokenStore()
    let tokens = TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture)
    try store.saveTokens(tokens, account: "a@example.com")
    try store.saveClientSecret("shh", account: "a@example.com")
    #expect(try store.tokens(account: "a@example.com") == tokens)
    #expect(try store.clientSecret(account: "a@example.com") == "shh")
}

@Test func unknownAccountReturnsNil() throws {
    #expect(try InMemoryTokenStore().tokens(account: "nobody@example.com") == nil)
}

@Test func deleteAllRemovesEverythingForOneAccountOnly() throws {
    let store = InMemoryTokenStore()
    let tokens = TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture)
    try store.saveTokens(tokens, account: "a@example.com")
    try store.saveTokens(tokens, account: "b@example.com")
    try store.deleteAll(account: "a@example.com")
    #expect(try store.tokens(account: "a@example.com") == nil)
    #expect(try store.tokens(account: "b@example.com") == tokens)
}

@Test func expiryUsesLeeway() {
    let tokens = TokenSet(
        accessToken: "at", refreshToken: "rt",
        expiresAt: Date(timeIntervalSince1970: 1_000))
    // 30s before expiry is "expired" under the default 60s leeway.
    #expect(tokens.isExpired(asOf: Date(timeIntervalSince1970: 970)))
    #expect(!tokens.isExpired(asOf: Date(timeIntervalSince1970: 900)))
}
