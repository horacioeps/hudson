import Foundation
import GmailKit
import Testing
@testable import HudsonUI

/// `SharedOAuth` is the seam `OnboardingModel.signInWithGoogle` resolves its
/// credentials through (Task 2) — these tests pin its contract directly,
/// with no network/Keychain/browser involved (there's none to touch here;
/// this is a pure resolver over compiled-in/environment state).
struct SharedOAuthTests {
    /// Until the real shared Desktop client ships, `clientID` is the empty
    /// placeholder the plan calls for — the guard every other test here
    /// (and `OnboardingModel`'s BYO-routing) depends on.
    @Test func clientIDIsTheEmptyPlaceholderUntilTheSharedClientShips() {
        #expect(SharedOAuth.clientID.isEmpty)
    }

    /// `isConfigured` is derived from `clientID` alone — with today's empty
    /// placeholder it must read `false`.
    @Test func isConfiguredIsFalseWhileClientIDIsEmpty() {
        #expect(SharedOAuth.isConfigured == false)
    }

    /// No injected secret anywhere in this test process — the expected state
    /// for a plain `swift test` run, since only a build that explicitly sets
    /// `HUDSON_OAUTH_CLIENT_SECRET` (or ships an `Info.plist` key) resolves one.
    @Test func clientSecretWithNoInjectionReturnsNil() {
        #expect(SharedOAuth.clientSecret() == nil)
    }

    /// The core "no one-click path yet" case: no shared client configured
    /// (empty `clientID`) and no BYO values supplied → `nil`, which is what
    /// routes `OnboardingModel` to `.byoEntry` instead of attempting a shared
    /// sign-in that could never complete.
    @Test func credentialsWithNoSharedConfigAndNoBYOReturnsNil() {
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
