import Foundation
import GmailKit

/// Resolves the OAuth credentials `OnboardingModel`'s "Sign in with Google"
/// button uses: a bundled, Hudson-branded Desktop OAuth client by default —
/// so a friend clicks one button, no Google Cloud console required — falling
/// back to the user's own BYO client whenever the shared one isn't
/// configured, or whenever the caller explicitly supplies BYO values.
///
/// **Privacy #1 — identity only, never a data path.** This resolver only
/// decides WHICH OAuth client id/secret feed the loopback PKCE flow
/// (`OnboardingModel.signInWithGoogle`, ported from `AuthCommand.connect`).
/// That flow still runs entirely on this Mac: `LoopbackServer` catches the
/// redirect locally, `OAuthClient.exchangeCode` talks straight to Google's
/// token endpoint, and the resulting tokens land straight in the Keychain.
/// The shared client is branding, not a middleman — it never routes mail,
/// tokens, or anything else through a Hudson-operated server.
///
/// **No secret committed.** `clientID` is a compiled constant — safe to
/// ship, since Google does not treat a Desktop-app client id as
/// confidential — but starts as an EMPTY placeholder until the real shared
/// client exists (`isConfigured` tracks this). `clientSecret` is never
/// hard-coded: it's injected at build time (an env var baked into the
/// binary, or an `Info.plist` key for the packaged `.app`) and resolved only
/// at call time, so a source checkout alone never contains it. Whenever the
/// shared client isn't configured, or its secret can't be resolved,
/// `credentials` returns `nil` and the caller falls back to `.byoEntry` —
/// so Hudson is fully usable today, before the real shared client ships.
public enum SharedOAuth {
    /// The bundled Desktop OAuth client's id (Google Cloud project
    /// `hudson-mail`, published/in-production). Safe to commit — Google does
    /// not treat a Desktop-app client id as confidential; the paired secret is
    /// build-injected, never committed (see `clientSecret()`).
    public static let clientID = "419433933435-1cjpc7j8e6efq4eh7rkop8dkmvlgsk7j.apps.googleusercontent.com"

    /// The env var a build that injects the shared secret sets (e.g. via
    /// `swift build` with the variable exported, or a CI/notarization step).
    static let secretEnvironmentKey = "HUDSON_OAUTH_CLIENT_SECRET"

    /// The `Info.plist` key a packaged `.app` build injects the secret
    /// under, for distribution builds that bake it into the bundle rather
    /// than the environment.
    static let secretInfoPlistKey = "HudsonOAuthClientSecret"

    /// Whether a shared client id has been compiled in. `false` today (the
    /// placeholder above is empty) — the only thing that flips this `true`
    /// is shipping a real `clientID`, never a runtime toggle.
    public static var isConfigured: Bool { !clientID.isEmpty }

    /// Reads the build-injected shared client secret: the environment
    /// variable first (the common case for a build-time injection), then
    /// the `Info.plist` key (the packaged `.app`'s path). `nil` when neither
    /// is set — the expected state until the shared client ships, and the
    /// signal `credentials` uses to fall back to BYO.
    public static func clientSecret() -> String? {
        if let value = ProcessInfo.processInfo.environment[secretEnvironmentKey], !value.isEmpty {
            return value
        }
        if let value = Bundle.main.infoDictionary?[secretInfoPlistKey] as? String, !value.isEmpty {
            return value
        }
        return nil
    }

    /// The credentials `OnboardingModel.signInWithGoogle`/`signInBYO` hand to
    /// `OAuthClient`. BYO values, when both are supplied, always win — an
    /// explicit user choice beats the default. Otherwise the shared client is
    /// used only if it's configured AND its secret actually resolves;
    /// otherwise `nil`, so the caller routes to `.byoEntry` instead of
    /// attempting a shared sign-in that could never complete.
    public static func credentials(
        byoClientID: String? = nil, byoSecret: String? = nil
    ) -> OAuthCredentials? {
        if let byoClientID, let byoSecret {
            return OAuthCredentials(clientID: byoClientID, clientSecret: byoSecret)
        }
        guard isConfigured, let secret = clientSecret() else { return nil }
        return OAuthCredentials(clientID: clientID, clientSecret: secret)
    }
}
