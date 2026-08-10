import ArgumentParser
import Foundation
import GmailKit
import Store

/// The BYO-OAuth guided setup (spec §6.1): walks the user through creating
/// their own Google Cloud OAuth client, then runs the browser flow and
/// stores credentials. This is the CLI ancestor of the designed onboarding.
struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Connect a Gmail account using your own Google Cloud OAuth client."
    )

    @Flag(help: "Skip the publishing-status confirmation (weekly re-auth warning applies).")
    var allowTesting = false

    func run() async throws {
        printGuidedSetup()

        if !allowTesting {
            let published = ConsoleInput.confirm(
                prompt: "Did you click PUBLISH APP (status shows “In production”)?")
            guard published else {
                print("""

                Please publish the app first — apps left in “Testing” get refresh tokens
                that expire every 7 days, which means re-connecting Hudson weekly.
                (Google Auth Platform → Audience → Publishing status → Publish app:
                https://console.cloud.google.com/auth/audience
                Re-run `hudson auth` when done, or pass --allow-testing to proceed anyway.)
                """)
                return
            }
        }

        let clientID = ConsoleInput.line(prompt: "Paste your OAuth Client ID:")
        let clientSecret = ConsoleInput.secret(prompt: "Paste your OAuth Client Secret (hidden):")

        do {
            try await connect(clientID: clientID, clientSecret: clientSecret)
        } catch let error as GmailError {
            // Routed through the clean stderr printer instead of letting
            // ArgumentParser's default handler debug-print (and mangle) it —
            // see GmailErrorReporting.swift.
            throw reportAndFail(error)
        }
    }

    /// The browser round-trip and persistence, once credentials are in hand.
    /// Isolated from `run()` so every `GmailError` this can throw — the
    /// loopback listener, the token exchange, the profile fetch, the
    /// Keychain writes — funnels through the one catch site above.
    private func connect(clientID: String, clientSecret: String) async throws {
        // Browser flow: loopback listener → system browser → code → tokens.
        let credentials = OAuthCredentials(clientID: clientID, clientSecret: clientSecret)
        let oauth = OAuthClient(credentials: credentials, transport: URLSessionTransport())
        let server = LoopbackServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let state = randomState()
        let pkce = PKCE()
        let url = oauth.authorizationURL(redirectURI: redirectURI, state: state, pkce: pkce)

        print("\nOpening your browser to sign in with Google…")
        print("(Google will show “Google hasn’t verified this app” — that’s expected for a")
        print("personal OAuth client. Click Advanced → “Go to <your app>” to continue.)\n")
        // Printed unconditionally — /usr/bin/open can fail silently (no
        // default browser, SSH session with no display, sandboxed
        // environment), and this is the only way a headless user completes
        // the flow.
        print("If your browser didn't open, paste this URL into it:")
        print(url.absoluteString + "\n")
        openInBrowser(url)

        let code = try await server.waitForCallback(expectedState: state)
        let tokens = try await oauth.exchangeCode(code, verifier: pkce.verifier, redirectURI: redirectURI)

        // Identify the account, then persist everything under its address.
        let profile = try await fetchProfile(credentials: credentials, tokens: tokens)
        let store = KeychainTokenStore()
        try store.saveTokens(tokens, account: profile.emailAddress)
        try store.saveClientSecret(clientSecret, account: profile.emailAddress)

        let database = try HudsonDatabase.open(at: HudsonPaths.databaseURL)
        try await AccountsMigration.runIfNeeded(database: database)
        try await database.upsertAccount(
            email: profile.emailAddress, clientID: clientID, consentedAt: Date())

        print("Connected \(profile.emailAddress) — \(profile.messagesTotal) messages.")
        print("Try: hudson profile")
    }

    private func printGuidedSetup() {
        print("""
        Hudson connects to Gmail through YOUR OWN free Google Cloud OAuth client —
        no fees, no third party in the loop. One-time setup (~5 minutes):

          1. Create a project:   https://console.cloud.google.com/projectcreate
             (any name, e.g. “hudson-mail”)
          2. Enable the Gmail API:
             https://console.cloud.google.com/apis/library/gmail.googleapis.com
          3. Set up the consent screen (left sidebar: “Google Auth Platform”):
             https://console.cloud.google.com/auth/overview
             Audience: External. App name/email: anything. Scopes: none needed here.
          4. IMPORTANT — on the “Audience” page, under Publishing status,
             click “PUBLISH APP” so it reads “In production”:
             https://console.cloud.google.com/auth/audience
             (Testing status = refresh tokens die every 7 days.)
             Google Workspace accounts may choose “Internal” instead — also fine.
          5. Create a client (Google Auth Platform → “Clients” → Create client):
             https://console.cloud.google.com/auth/clients
             Application type “Desktop app”.
          6. Copy the Client ID and Client Secret below.
             (For Desktop clients Google itself says the secret is not confidential —
             pasting it here is safe; Hudson stores it in your Keychain.)

        """)
    }

    private func openInBrowser(_ url: URL) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try? process.run()
    }

    private func fetchProfile(
        credentials: OAuthCredentials, tokens: TokenSet
    ) async throws -> Profile {
        // A one-shot session over an in-memory store: we don't know the email
        // (the Keychain key) until the first getProfile succeeds.
        let bootstrapStore = InMemoryTokenStore()
        try bootstrapStore.saveTokens(tokens, account: "bootstrap")
        let session = AccountSession(
            account: "bootstrap",
            oauth: OAuthClient(credentials: credentials, transport: URLSessionTransport()),
            store: bootstrapStore)
        let client = GmailClient(
            session: session, transport: URLSessionTransport(), quota: QuotaBucket())
        return try await client.getProfile()
    }
}
