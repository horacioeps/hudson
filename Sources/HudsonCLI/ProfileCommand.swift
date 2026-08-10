import ArgumentParser
import Foundation
import GmailKit

/// Smoke-test command: proves auth, refresh, quota, and the typed client work
/// end-to-end against the real API.
struct ProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Show the connected Gmail account's profile."
    )

    func run() async throws {
        // `consentedAt` is only known once `AccountsFile.primary()` succeeds;
        // it stays nil for failures before that (e.g. no account connected),
        // which `annotated` treats as "no Testing-status diagnostic applies".
        var consentedAt: Date?
        do {
            let account = try AccountsFile.primary()
            consentedAt = account.consentedAt
            let store = KeychainTokenStore()
            guard let clientSecret = try store.clientSecret(account: account.email) else {
                throw GmailError.auth("Keychain has no client secret — run `hudson auth` again.")
            }
            let session = AccountSession(
                account: account.email,
                oauth: OAuthClient(
                    credentials: OAuthCredentials(clientID: account.clientID, clientSecret: clientSecret),
                    transport: URLSessionTransport()),
                store: store)
            let client = GmailClient(
                session: session, transport: URLSessionTransport(), quota: QuotaBucket())

            let profile = try await client.getProfile()
            print("Account:   \(profile.emailAddress)")
            print("Messages:  \(profile.messagesTotal)")
            print("Threads:   \(profile.threadsTotal)")
            print("History ID: \(profile.historyId)  (M2's backfill cursor)")
        } catch let error as GmailError {
            // Routed through the clean stderr printer instead of letting
            // ArgumentParser's default handler debug-print (and mangle) it —
            // see GmailErrorReporting.swift.
            throw reportAndFail(annotated(error, consentedAt: consentedAt))
        }
    }

    /// The spec-§6.1 heuristic: a dead refresh token within ~8 days of consent
    /// usually means the OAuth app was left in Testing status.
    private func annotated(_ error: GmailError, consentedAt: Date?) -> GmailError {
        guard let consentedAt,
              case .auth(let message) = error, message.contains("invalid_grant"),
              Date().timeIntervalSince(consentedAt) < 8 * 24 * 3600 else {
            return error
        }
        return .auth(message + """


        Your grant died within a week of setup — the OAuth app is probably still in
        “Testing” status, where refresh tokens expire every 7 days. Fix: Google Cloud
        Console → APIs & Services → OAuth consent screen → PUBLISH APP, then `hudson auth`.
        """)
    }
}
