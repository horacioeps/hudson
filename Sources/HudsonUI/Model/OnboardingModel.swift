import AppKit
import Foundation
import GmailKit
import Store

/// The in-app "Sign in with Google" flow — the graphical descendant of
/// `HudsonCLI/AuthCommand.connect`, ported verbatim in ordering so its proven
/// loopback-PKCE behavior is preserved: start a local listener → open the
/// browser to Google → catch the redirect on 127.0.0.1 → exchange the code →
/// read the profile → save tokens/secret to the Keychain and `upsertAccount`.
/// A friend gets online with one click; a power user drops in their own
/// Google credentials instead.
///
/// **Privacy #1 — no data middleman.** Every leg runs on this Mac. The
/// `LoopbackServer` binds 127.0.0.1 only; `OAuthClient` talks straight to
/// Google's token endpoint; the resulting tokens land in the Keychain; mail
/// never touches a Hudson-operated server. The shared client (`SharedOAuth`)
/// is identity/branding only — it changes WHICH OAuth client id/secret feed
/// the flow, never where anything is routed.
///
/// **Injected seams (so a test is hermetic).** `tokenStore`, `transport`,
/// `makeLoopback`, and `openURL` are all injectable — mirroring how
/// `ComposerModel`/`SummaryModel` inject their service factories — so the
/// tests drive the REAL `OAuthClient`/`GmailClient` against fakes and never
/// touch the network, the Keychain, or open a browser. Production callers omit
/// them and get the real Keychain / URLSession / `LoopbackServer` / NSWorkspace.
@MainActor
@Observable
public final class OnboardingModel {
    /// Where the onboarding flow is. `OnboardingView` renders purely off this.
    public enum Phase: Equatable {
        /// The welcome/pitch screen — the first thing a fresh install shows.
        case welcome
        /// The "Sign in with Google" screen (with the unverified-app explainer).
        case chooseSignIn
        /// A sign-in is in flight — the browser is open, we're awaiting the
        /// redirect. Shows a spinner + "Waiting for Google…".
        case signingIn
        /// Manual entry of the user's own Google OAuth client id/secret — the
        /// fallback whenever the shared client isn't configured, or the user
        /// chooses to use their own.
        case byoEntry
        /// Connected — the host swaps in the mailbox (`onConnected`).
        case done
        /// Sign-in failed; the message is shown with a "Try again" affordance.
        case failed(String)
    }

    public private(set) var phase: Phase = .welcome

    public let database: HudsonDatabase

    // MARK: - Injected seams

    /// Where tokens + the client secret are persisted. `KeychainTokenStore`
    /// in production; an `InMemoryTokenStore` in tests.
    private let tokenStore: any TokenStore

    /// The HTTP transport the token exchange AND the profile fetch both run
    /// over. `URLSessionTransport` in production; a scripted fake in tests.
    private let transport: any HTTPTransport

    /// Builds a fresh loopback listener per sign-in attempt — `LoopbackServer`
    /// is one-shot (its `start`/`waitForCallback` may each be called once), so
    /// a retry after `.failed` needs a new one. A factory, not an instance,
    /// precisely so that retry works.
    private let makeLoopback: @Sendable () -> any LoopbackServing

    /// Opens the authorization URL in the user's browser. `@MainActor` because
    /// the default hands off to `NSWorkspace`, which is main-actor; tests pass
    /// a recording closure.
    private let openURL: @MainActor (URL) -> Void

    /// Called once a sign-in lands `.done`, with the freshly-stored account —
    /// the host (`AppModel`/`RootView`, Task 4) rebuilds itself around the new
    /// account and shows the mailbox.
    public var onConnected: ((AccountRecord) -> Void)?

    /// Production callers pass only `database`; every seam defaults to its real
    /// implementation. `openURL`'s default is written inline (not a stored
    /// default expression) so it can be `@MainActor`.
    public init(
        database: HudsonDatabase,
        tokenStore: (any TokenStore)? = nil,
        transport: (any HTTPTransport)? = nil,
        makeLoopback: (@Sendable () -> any LoopbackServing)? = nil,
        openURL: (@MainActor (URL) -> Void)? = nil
    ) {
        self.database = database
        self.tokenStore = tokenStore ?? KeychainTokenStore()
        self.transport = transport ?? URLSessionTransport()
        self.makeLoopback = makeLoopback ?? { LoopbackServer() }
        self.openURL = openURL ?? { url in _ = NSWorkspace.shared.open(url) }
    }

    // MARK: - Navigation between screens

    /// Welcome → the "Sign in with Google" screen ("Set up in about 5 minutes").
    public func beginSetup() {
        phase = .chooseSignIn
    }

    /// Jumps to manual BYO credential entry (the "Use my own Google
    /// credentials" affordance).
    public func showBYOEntry() {
        phase = .byoEntry
    }

    /// Returns to the sign-in screen — the "Try again"/back affordance from a
    /// `.failed`/`.byoEntry` state.
    public func retry() {
        phase = .chooseSignIn
    }

    // MARK: - Sign-in

    /// The one-click path. Resolves the shared client's credentials through
    /// `SharedOAuth`; if none are configured (today's empty placeholder, or a
    /// build with no injected secret) there is no one-click path that could
    /// complete, so it routes to `.byoEntry` WITHOUT touching the network —
    /// the user enters their own credentials instead of watching a doomed
    /// sign-in spin.
    public func signInWithGoogle() async {
        guard let credentials = SharedOAuth.credentials() else {
            phase = .byoEntry
            return
        }
        await connect(credentials: credentials, storedClientID: SharedOAuth.clientID)
    }

    /// The BYO path: sign in with the user's own Google OAuth client. Guards
    /// against empty fields so a stray tap can't launch a flow that can never
    /// authenticate.
    public func signInBYO(clientID: String, clientSecret: String) async {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let credentials = SharedOAuth.credentials(byoClientID: id, byoSecret: secret),
            !id.isEmpty, !secret.isEmpty
        else {
            phase = .failed("Enter both a Client ID and a Client Secret.")
            return
        }
        await connect(credentials: credentials, storedClientID: id)
    }

    // MARK: - The ported loopback-PKCE flow

    /// The browser round-trip and persistence, once credentials are in hand —
    /// the exact ordering of `AuthCommand.connect`, adapted to drive `phase`
    /// and the injected seams. `storedClientID` is the id recorded against the
    /// account (`upsertAccount`) and is the same id inside `credentials`; it's
    /// passed explicitly only so the persistence reads clearly. Any failure
    /// (listener, state mismatch, exchange, profile, Keychain, Store) funnels
    /// to `.failed` with a readable message — never a half-connected state,
    /// and the listener is always stopped.
    private func connect(credentials: OAuthCredentials, storedClientID: String) async {
        guard phase != .signingIn else { return }
        phase = .signingIn

        let oauth = OAuthClient(credentials: credentials, transport: transport)
        let server = makeLoopback()
        do {
            let port = try await server.start()
            let redirectURI = "http://127.0.0.1:\(port)/callback"
            let state = randomState()
            let pkce = PKCE()
            let url = oauth.authorizationURL(redirectURI: redirectURI, state: state, pkce: pkce)
            openURL(url)

            let code = try await server.waitForCallback(expectedState: state)
            let tokens = try await oauth.exchangeCode(
                code, verifier: pkce.verifier, redirectURI: redirectURI)

            // Identify the account, then persist everything under its address.
            let profile = try await fetchProfile(credentials: credentials, tokens: tokens)
            try tokenStore.saveTokens(tokens, account: profile.emailAddress)
            try tokenStore.saveClientSecret(credentials.clientSecret, account: profile.emailAddress)
            try await database.upsertAccount(
                email: profile.emailAddress, clientID: storedClientID, consentedAt: Date())
            let record = try await database.account(email: profile.emailAddress)

            await server.stop()
            phase = .done
            if let record { onConnected?(record) }
        } catch {
            await server.stop()
            phase = .failed(Self.message(for: error))
        }
    }

    /// Fetches the account's profile — the only way to learn the email address
    /// (the Keychain key / account id) before we can persist anything under
    /// it. A one-shot session over an in-memory store, exactly as
    /// `AuthCommand.connect` does it, so the profile call reuses the same
    /// injected `transport`.
    private func fetchProfile(
        credentials: OAuthCredentials, tokens: TokenSet
    ) async throws -> Profile {
        let bootstrapStore = InMemoryTokenStore()
        try bootstrapStore.saveTokens(tokens, account: "bootstrap")
        let session = AccountSession(
            account: "bootstrap",
            oauth: OAuthClient(credentials: credentials, transport: transport),
            store: bootstrapStore)
        let client = GmailClient(session: session, transport: transport, quota: QuotaBucket())
        return try await client.getProfile()
    }

    /// Turns an error into a line an onboarding user can act on. `GmailError`'s
    /// cases already carry human phrasing (the loopback/auth/exchange messages
    /// the flow throws); anything else gets a generic, non-alarming fallback.
    private static func message(for error: Error) -> String {
        guard let gmail = error as? GmailError else {
            return "Sign-in failed. Please try again."
        }
        switch gmail {
        case .auth(let message), .network(let message):
            return message
        case .invalidRequest(_, let message):
            return message
        case .rateLimited:
            return "Google is rate-limiting sign-in right now. Please try again in a moment."
        case .server(let status):
            return "Google's servers returned an error (HTTP \(status)). Please try again."
        }
    }
}

/// The loopback listener seam `OnboardingModel` drives — the subset of
/// `LoopbackServer` the flow needs, extracted to a protocol so a test can
/// substitute a socket-free fake that returns a scripted authorization code.
/// `LoopbackServer` conforms below; the protocol lives here (not in GmailKit)
/// so GmailKit stays untouched.
public protocol LoopbackServing: Sendable {
    /// Starts listening; returns the bound ephemeral port for the redirect URI.
    func start() async throws -> UInt16
    /// Suspends until Google's redirect arrives, then returns the code.
    /// Verifies `state` (CSRF guard).
    func waitForCallback(expectedState: String) async throws -> String
    /// Stops the listener; resumes any pending wait with a cancellation error.
    func stop() async
}

extension LoopbackServer: LoopbackServing {
    /// Adapts the real listener's `waitForCallback(expectedState:timeout:)` to
    /// the seam's timeout-free requirement, keeping the shipped 5-minute
    /// default the CLI uses.
    public func waitForCallback(expectedState: String) async throws -> String {
        try await waitForCallback(expectedState: expectedState, timeout: 300)
    }
}
