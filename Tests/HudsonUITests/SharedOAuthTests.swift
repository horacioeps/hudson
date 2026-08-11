import Foundation
import GmailKit
import Testing
@testable import HudsonUI

/// `SharedOAuth` is the seam `OnboardingModel.signInWithGoogle` resolves its
/// credentials through (Task 2) — these tests pin its contract directly,
/// with no network/Keychain/browser involved (there's none to touch here;
/// this is a pure resolver over compiled-in/environment state).
struct SharedOAuthTests {
    /// The real shared Desktop client now ships: `clientID` is the public
    /// Google Cloud client id compiled into `SharedOAuth` (project
    /// `hudson-mail`). Every one-click sign-in path depends on it being present.
    @Test func clientIDIsTheShippedSharedClient() {
        #expect(!SharedOAuth.clientID.isEmpty)
        #expect(SharedOAuth.clientID.hasSuffix(".apps.googleusercontent.com"))
    }

    /// `isConfigured` is derived from `clientID` alone — now that the real
    /// shared client ships, it reads `true`.
    @Test func isConfiguredIsTrueOnceTheSharedClientShips() {
        #expect(SharedOAuth.isConfigured)
    }

    /// No injected secret anywhere in this test process — the expected state
    /// for a plain `swift test` run, since only a build that explicitly sets
    /// `HUDSON_OAUTH_CLIENT_SECRET` (or ships an `Info.plist` key) resolves one.
    @Test func clientSecretWithNoInjectionReturnsNil() {
        #expect(SharedOAuth.clientSecret() == nil)
    }

    /// Even though `clientID` now ships, a plain `swift test`/source checkout
    /// injects no secret, so `clientSecret()` is nil and `credentials()`
    /// returns nil with no BYO — routing `OnboardingModel` to `.byoEntry`.
    /// A packaged build that injects `HUDSON_OAUTH_CLIENT_SECRET` resolves a
    /// real one-click credential here instead.
    @Test func credentialsWithoutInjectedSecretAndNoBYOReturnsNil() {
        #expect(SharedOAuth.clientSecret() == nil)  // precondition: no injection in tests
        let credentials = SharedOAuth.credentials()

        #expect(credentials == nil)
    }

    /// BYO values always win when supplied, regardless of the shared
    /// client's configuration state — this is the path `OnboardingModel
    /// .signInBYO` uses.
    @Test func credentialsWithBYOReturnsThoseCredentials() {
        let credentials = SharedOAuth.credentials(byoClientID: "byo-client-id", byoSecret: "byo-secret")

        #expect(credentials?.clientID == "byo-client-id")
        #expect(credentials?.clientSecret == "byo-secret")
    }
}
