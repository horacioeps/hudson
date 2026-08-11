import Foundation
import GmailKit
import Store
import Testing

@testable import HudsonUI

/// A scriptable `HTTPTransport` double so `OnboardingModel`'s tests drive the
/// REAL `OAuthClient.exchangeCode` + `GmailClient.getProfile` (the same code
/// the shipped flow runs) without ever touching Google — it answers the token
/// exchange with a canned `TokenSet` JSON and the profile fetch with a canned
/// `Profile` JSON, matched by endpoint host. Exactly the seam
/// `OnboardingModel`'s injectable `transport` exists for (spec: never the real
/// network in a test). Records every request so a test can assert the
/// not-configured path performs NONE.
private actor ScriptedTransport: HTTPTransport {
    private(set) var requestedURLs: [String] = []
    private let tokenStatus: Int

    /// `tokenStatus` lets a test force the token endpoint to fail (a non-200)
    /// so the `.failed` path is exercised; defaults to a successful exchange.
    init(tokenStatus: Int = 200) {
        self.tokenStatus = tokenStatus
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        requestedURLs.append(url.absoluteString)

        let body: Data
        let status: Int
        if url.absoluteString.contains("oauth2.googleapis.com/token") {
            if tokenStatus == 200 {
                body = Data(#"{"access_token":"at-123","expires_in":3600,"refresh_token":"rt-123"}"#.utf8)
                status = 200
            } else {
                body = Data(#"{"error":"invalid_grant","error_description":"bad code"}"#.utf8)
                status = tokenStatus
            }
        } else if url.absoluteString.contains("gmail.googleapis.com") {
            body = Data(
                #"{"emailAddress":"friend@example.com","messagesTotal":42,"threadsTotal":7,"historyId":"9"}"#
                    .utf8)
            status = 200
        } else {
            throw GmailError.network("ScriptedTransport hit an unexpected URL: \(url)")
        }

        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (body, response)
    }

    func urls() -> [String] { requestedURLs }
}

/// A `LoopbackServing` double: no socket, no browser round-trip — `start()`
/// hands back a fixed port and `waitForCallback` immediately returns a
/// scripted authorization code, so the whole `OnboardingModel` flow runs
/// synchronously and hermetically. Records `start()`/`stop()` so a test can
/// prove the not-configured path never opens a listener.
private actor FakeLoopback: LoopbackServing {
    private let code: String
    private(set) var didStart = false
    private(set) var didStop = false

    init(code: String) { self.code = code }

    func start() async throws -> UInt16 {
        didStart = true
        return 49_152
    }

    func waitForCallback(expectedState: String) async throws -> String { code }

    func stop() async { didStop = true }

    func started() -> Bool { didStart }
    func stopped() -> Bool { didStop }
}

/// Records the URLs `OnboardingModel` asks the browser to open, so a happy
/// path can assert the authorization URL was handed off and the
/// not-configured path can assert nothing was.
@MainActor
private final class OpenSpy {
    var urls: [URL] = []
}

// MARK: - Happy path (BYO credentials drive the real exchange/profile)

/// The core of Task 2: a full in-app sign-in. With BYO credentials the model
/// runs the ported loopback-PKCE flow end to end against injected fakes and
/// lands `.done`, persisting the account (`upsertAccount`), the tokens, and
/// the client secret — then reports the new `AccountRecord` via `onConnected`
/// so the host can swap onboarding → mailbox. No network, no Keychain, no
/// browser is real.
@MainActor
@Test func signInBYODrivesSigningInToDoneAndPersistsTheAccount() async throws {
    let db = try HudsonDatabase.inMemory()
    let transport = ScriptedTransport()
    let loopback = FakeLoopback(code: "auth-code-xyz")
    let tokenStore = InMemoryTokenStore()
    let openSpy = OpenSpy()

    let model = OnboardingModel(
        database: db,
        tokenStore: tokenStore,
        transport: transport,
        makeLoopback: { loopback },
        openURL: { openSpy.urls.append($0) })

    var connected: AccountRecord?
    model.onConnected = { connected = $0 }

    #expect(model.phase == .welcome)

    await model.signInBYO(clientID: "byo-client-id", clientSecret: "byo-secret")

    #expect(model.phase == .done)

    // The account landed in the store under the profile's address.
    let record = try #require(try await db.account(email: "friend@example.com"))
    #expect(record.clientID == "byo-client-id")

    // Tokens + secret went to the (injected) token store, keyed by the email.
    #expect(try tokenStore.tokens(account: "friend@example.com") != nil)
    #expect(try tokenStore.clientSecret(account: "friend@example.com") == "byo-secret")

    // The host got the record to swap in the mailbox.
    #expect(connected?.email == "friend@example.com")

    // The browser was handed Google's authorization URL, and the listener was
    // started then cleaned up.
    #expect(openSpy.urls.count == 1)
    #expect(openSpy.urls.first?.absoluteString.contains("accounts.google.com") == true)
    #expect(await loopback.started())
    #expect(await loopback.stopped())
}

// MARK: - Not configured + no BYO → BYO entry, zero network

/// When `SharedOAuth` can't resolve a one-click credential — the shared client
/// id ships, but a plain test run injects no secret, so `credentials()` is nil —
/// and no BYO values are supplied, `signInWithGoogle` must route straight to
/// `.byoEntry` and perform NO network, NO listener, NO browser open: there is no
/// one-click path that could complete, so the user is sent to enter their own
/// credentials instead of watching a doomed sign-in spin.
@MainActor
@Test func signInWithGoogleWithNoResolvableCredentialRoutesToBYOAndTouchesNothing() async throws {
    // Guard the premise: no shared secret is injected in this test process, so
    // the one-click credential can't resolve and the BYO fallback is expected.
    try #require(SharedOAuth.credentials() == nil)

    let db = try HudsonDatabase.inMemory()
    let transport = ScriptedTransport()
    let loopback = FakeLoopback(code: "unused")
    let openSpy = OpenSpy()

    let model = OnboardingModel(
        database: db,
        tokenStore: InMemoryTokenStore(),
        transport: transport,
        makeLoopback: { loopback },
        openURL: { openSpy.urls.append($0) })

    await model.signInWithGoogle()

    #expect(model.phase == .byoEntry)
    #expect(await transport.urls().isEmpty)
    #expect(await loopback.started() == false)
    #expect(openSpy.urls.isEmpty)
}

// MARK: - Failure surfaces as .failed

/// When the token exchange fails (Google rejects the code), the flow lands in
/// `.failed` with a message — never `.done`, never a half-persisted account —
/// so `OnboardingView` can show the error and a Try Again affordance.
@MainActor
@Test func signInBYOWithARejectedCodeLandsInFailed() async throws {
    let db = try HudsonDatabase.inMemory()
    let transport = ScriptedTransport(tokenStatus: 400)
    let loopback = FakeLoopback(code: "auth-code-xyz")
    let openSpy = OpenSpy()

    let model = OnboardingModel(
        database: db,
        tokenStore: InMemoryTokenStore(),
        transport: transport,
        makeLoopback: { loopback },
        openURL: { openSpy.urls.append($0) })

    var connected: AccountRecord?
    model.onConnected = { connected = $0 }

    await model.signInBYO(clientID: "byo-client-id", clientSecret: "byo-secret")

    guard case .failed = model.phase else {
        Issue.record("expected .failed, got \(model.phase)")
        return
    }
    #expect(connected == nil)
    #expect(try await db.account(email: "friend@example.com") == nil)
    // The listener was still cleaned up on the failure path.
    #expect(await loopback.stopped())
}
