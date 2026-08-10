import Foundation
import Testing
@testable import GmailKit

@Test func verifierIsUnreservedAndLongEnough() {
    let pkce = PKCE()
    // RFC 7636 §4.1: 43–128 chars from [A-Za-z0-9-._~].
    #expect(pkce.verifier.count >= 43 && pkce.verifier.count <= 128)
    let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    #expect(pkce.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
}

@Test func challengeMatchesRFC7636TestVector() {
    // Appendix B of RFC 7636.
    let challenge = PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@Test func stateIsUniquePerCall() {
    #expect(randomState() != randomState())
}
