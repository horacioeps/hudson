import Synchronization

/// Test/preview implementation of `TokenStore`. Thread-safe, non-persistent.
public final class InMemoryTokenStore: TokenStore {
    private struct Entry { var tokens: TokenSet?; var clientSecret: String? }
    private let entries = Mutex<[String: Entry]>([:])

    /// Initializes a thread-safe in-memory token store for testing.
    public init() {}

    public func saveTokens(_ tokens: TokenSet, account: String) throws {
        entries.withLock { $0[account, default: Entry()].tokens = tokens }
    }

    public func tokens(account: String) throws -> TokenSet? {
        entries.withLock { $0[account]?.tokens }
    }

    public func saveClientSecret(_ secret: String, account: String) throws {
        entries.withLock { $0[account, default: Entry()].clientSecret = secret }
    }

    public func clientSecret(account: String) throws -> String? {
        entries.withLock { $0[account]?.clientSecret }
    }

    public func deleteAll(account: String) throws {
        entries.withLock { $0[account] = nil }
    }
}
