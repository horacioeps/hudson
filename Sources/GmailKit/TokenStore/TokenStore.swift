/// Persistence seam for secrets: OAuth tokens and the user's BYO client
/// secret. Production uses `KeychainTokenStore`; tests use
/// `InMemoryTokenStore` so CI never touches a real keychain (spec §6.3).
public protocol TokenStore: Sendable {
    func saveTokens(_ tokens: TokenSet, account: String) throws
    func tokens(account: String) throws -> TokenSet?
    func saveClientSecret(_ secret: String, account: String) throws
    func clientSecret(account: String) throws -> String?
    func deleteAll(account: String) throws
}
